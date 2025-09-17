#![feature(lock_value_accessors)]
#![feature(normalize_lexically)]

use log::{debug, info, warn, error};
use std::num::NonZero;
use std::path::{PathBuf};
use std::str::FromStr;
use std::sync::Mutex;
use std::{sync::Arc};

use actix_files::NamedFile;
use actix_web::http::header::{HeaderName, HeaderValue, TryIntoHeaderPair};
use actix_web::http::{header, StatusCode};
use actix_web::{Either, HttpRequest, HttpResponseBuilder};
use anyhow::{bail, Result};

use uuid::Uuid;

use nix_expr::{
    eval_state::EvalState,
    value::{Value, ValueType},
};
use nix_flake::EvalStateBuilderExt as _;

use actix_web::{
    web, App, HttpResponse, HttpServer
};
use nix_store::path::StorePath;
use nix_store::store::Store;

fn get_flake(
    eval_state: &mut EvalState,
    fetch_settings: nix_fetchers::FetchersSettings,
    flake_settings: nix_flake::FlakeSettings,
    flakeref_str: &str,
    input_overrides: &Vec<(String, String)>,
) -> Result<Value> {
    let mut parse_flags = nix_flake::FlakeReferenceParseFlags::new(&flake_settings)?;

    let cwd = std::env::current_dir()
        .map_err(|e| anyhow::anyhow!("failed to get current directory: {}", e))?;
    let cwd = cwd
        .to_str()
        .ok_or_else(|| anyhow::anyhow!("failed to convert current directory to string"))?;
    parse_flags.set_base_directory(cwd)?; // TODO: nope, not this.

    let parse_flags = parse_flags;

    let mut lock_flags = nix_flake::FlakeLockFlags::new(&flake_settings)?;
    lock_flags.set_mode_write_as_needed()?; // TODO: nope, not this.
    for (override_path, override_ref_str) in input_overrides {
        let (override_ref, fragment) = nix_flake::FlakeReference::parse_with_fragment(
            &fetch_settings,
            &flake_settings,
            &parse_flags,
            override_ref_str,
        )?;
        if !fragment.is_empty() {
            bail!(
                "input override {} has unexpected fragment: {}",
                override_path,
                fragment
            );
        }
        lock_flags.add_input_override(override_path, &override_ref)?;
    }
    let lock_flags = lock_flags;

    let (flakeref, fragment) = nix_flake::FlakeReference::parse_with_fragment(
        &fetch_settings,
        &flake_settings,
        &parse_flags,
        flakeref_str,
    )?;
    if !fragment.is_empty() {
        bail!(
            "flake reference {} has unexpected fragment: {}",
            flakeref_str,
            fragment
        );
    }
    let flake = nix_flake::LockedFlake::lock(
        &fetch_settings,
        &flake_settings,
        eval_state,
        &lock_flags,
        &flakeref,
    )?;

    flake.outputs(&flake_settings, eval_state)
}

pub struct FlackApp {
    address: &'static str,
    port: u16,
    system: String,
    flake: Value,
    eval_state: Arc<Mutex<EvalState>>
}

#[derive(Clone, Debug)]
struct FlackResponse {
    code: u16,
    headers: Vec<(HeaderName, HeaderValue)>,
    body: Option<String>,
    body_path: Option<PathBuf>
}

impl FlackResponse {
    fn new() -> FlackResponse {
        FlackResponse { code: 0, headers: Vec::new(), body: None, body_path: None }
    }

    fn to_builder(&self) -> HttpResponseBuilder {
        let mut builder = HttpResponseBuilder::new(StatusCode::from_u16(self.code).unwrap());
        for (key, value) in &self.headers {
            builder.append_header((key, value));
        }
        builder
    }

    fn headers_into_response<'a>(&'a self, res: &'a mut HttpResponse) -> &'a mut HttpResponse {
        for (key, value) in &self.headers {
            res.headers_mut().append(key.clone(), value.clone());
        }
        res
    }

    fn add_header(&mut self, key: String, value: String) -> &mut Self {
        match HeaderName::from_str(key.as_str()) {
            Ok(header_key) => {
                match HeaderValue::from_str(value.as_str()) {
                    Ok(header_value) => {
                        self.headers.push((header_key, header_value))
                    },
                    Err(_) => ()
                }
            },
            Err(_) => ()
        }
        self
    }

    fn server_error<S: std::fmt::Display>(&mut self, err: S) -> Self {
        self.set(500, Either::Left(err.to_string()))
    }

    fn not_found<S: std::fmt::Display>(&mut self, err: S) -> Self {
        self.set(404, Either::Left(err.to_string()))
    }

    fn ok(&mut self, body: Either<String, PathBuf>) -> Self {
        self.set(200, body)
    }

    fn ok_string<S: std::fmt::Display>(&mut self, body: S) -> Self {
        self.ok(Either::Left(body.to_string()))
    }

    fn ok_path(&mut self, body: PathBuf) -> Self {
        self.ok(Either::Right(body))
    }

    fn set(&mut self, code: u16, body: Either<String, PathBuf>) -> Self {
        self.code = code;
        match body {
            Either::Left(left) => {
                self.body = Some(left.to_owned());
            },
            Either::Right(right) => {
                self.body_path = Some(right.to_owned());
            }
        };
        self.clone()
    }
}

fn add_str_value(
    response: &mut FlackResponse,
    st: &mut EvalState,
    pairs: &mut Vec<(String, Value)>,
    key: &str,
    value: &str
) -> Result<(), FlackResponse> {
    let val = st.new_value_str(value)
        .map_err(|_| response.server_error("error creating environment variable from string"))?;
    pairs.push((key.to_string(), val));
    Ok(())
}

fn add_int_value(
    response: &mut FlackResponse,
    st: &mut EvalState,
    pairs: &mut Vec<(String, Value)>,
    key: &str,
    value: i64
) -> Result<(), FlackResponse> {
    let val = st.new_value_int(value)
        .map_err(|_| response.server_error("error creating environment variable from integer"))?;
    pairs.push((key.to_string(), val));
    Ok(())
}

fn get_safe_path(
    response: &mut FlackResponse,
    store: &mut Store,
    unsafe_path_str: &str
) -> Result<(PathBuf, PathBuf, StorePath), FlackResponse> {
    let store_root_str = format!(
        "{}/",
        store.get_storedir()
            .map_err(|err| response.server_error(err))?
    );
    if unsafe_path_str.starts_with(store_root_str.as_str()) {
        // It looks like a store path... is it really one?
        let store_root = PathBuf::from_str(store_root_str.as_str())
            .map_err(|err| response.server_error(err))?;

        if !store_root.is_absolute() {
            // Sanity check it.
            return Err(response.server_error("store root was not absolute, bailing out"));
        }

        let num_components = store_root.components().count() + 1;
        let unsafe_path = PathBuf::from_str(unsafe_path_str)
            .map_err(|err| response.server_error(err))?
            .normalize_lexically()
            .map_err(|err| response.server_error(err))?;
        if unsafe_path.starts_with(store_root) {
            let mut base_path = PathBuf::new();
            unsafe_path.components().take(num_components).for_each(|c| base_path.push(c));

            match store.parse_store_path(base_path.to_str().ok_or_else(|| response.server_error("could not create base path"))?) {
                Ok(parsed_path) => Ok((base_path, unsafe_path, parsed_path)),
                Err(err) => Err(response.server_error(err))
            }
        } else {
            Err(response.server_error("not a store path"))
        }
    } else {
        // May not be a store path.
        Err(response.server_error("not a path"))
    }
}

fn serve_path_or_text(
    response: &mut FlackResponse,
    st: &mut EvalState,
    store: &mut Store,
    value: &Value
) -> Result<FlackResponse, FlackResponse> {
    debug!("Forcing value");
    let to_string = st.eval_from_string("builtins.toString", ".")
        .map_err(|err| response.server_error(err))?;
    let to_string_value = st.call(to_string, value.clone())
        .map_err(|err| response.server_error(err))?;
    let string_value = st.require_string(&to_string_value)
        .map_err(|err| response.server_error(err))?;

    // Could be a string that represents a store path.
    match get_safe_path(response, store, &string_value) {
        Ok((base_path, path, store_path)) => {
            debug!("Realising store path {:?}", base_path);
            st.realise_string(&to_string_value, false)
                .map_err(|err| response.server_error(err))?;
            debug!("Realised {:?}", store_path.name());

            // Serve the store path.
            Ok(response.ok_path(path.clone()))
        },
        Err(_) => {
            // Serve raw text content.
            debug!("Serving text: {}", string_value);
            Ok(response.ok_string(string_value))
        }
    }
}

async fn flack_handler(req: HttpRequest, body: &web::Bytes) -> Result<FlackResponse, FlackResponse> {
    let app = req.app_data::<web::Data<FlackApp>>().unwrap();
    let port = app.port;
    let system = app.system.as_str();

    let mut response = FlackResponse::new();

    let _gc_guard = nix_expr::eval_state::gc_register_my_thread()
        .map_err(|err| response.server_error(err))?;

    let mut st = app.eval_state.get_cloned()
        .map_err(|err| response.server_error(err))?;

    let connection_info = req.connection_info();
    let http_version = format!("{:?}", req.version());
    let request_id = Uuid::now_v7().to_string();
    let str_inputs = [
        ("RACK", "flack"),
        ("REQUEST_METHOD", req.method().as_str()),
        ("PATH_INFO", req.path()),
        ("QUERY_STRING", req.query_string()),
        ("SERVER_NAME", connection_info.host()),
        ("SERVER_PROTOCOL", http_version.as_str()),
        ("rack.url_scheme", connection_info.scheme()),
        ("flack.system", system),
        ("flack.request_id", request_id.as_str())
    ];
    let int_inputs = [
        ("SERVER_PORT", port as i64),
    ];

    let mut pairs = Vec::with_capacity(str_inputs.len() + int_inputs.len());
    for (key, value) in str_inputs {
        add_str_value(&mut response, &mut st, &mut pairs, key, value)?;
    }
    for (key, value) in int_inputs {
        add_int_value(&mut response, &mut st, &mut pairs, key, value)?;
    }

    match req.headers().get("host") {
        Some(v) => add_str_value(&mut response, &mut st, &mut pairs, "HTTP_HOST", v.to_str().unwrap_or("")),
        None => Ok(())
    }?;

    match req.headers().get("content-type") {
        Some(v) => add_str_value(&mut response, &mut st, &mut pairs, "CONTENT_TYPE", v.to_str().unwrap_or("")),
        None => Ok(())
    }?;

    if !body.is_empty() {
        add_int_value(&mut response, &mut st, &mut pairs, "CONTENT_LENGTH", body.len() as i64)?;
    }

    for (key, value) in req.headers().iter() {
        if key.as_str().eq("host") || key.as_str().eq("content-type") {
            continue;
        }

        let key_str = key.as_str();
        if key_str.chars().all(|c| matches!(c, 'A'..='Z' | 'a'..='z' | '-')) {
            let env_str = format!("HTTP_{}", key_str.to_ascii_uppercase().replace("-", "_"));
            add_str_value(&mut response, &mut st, &mut pairs, &env_str, value.to_str().unwrap_or(""))?;
        }
    }

    let eval_state_mutex = app.eval_state.clone();
    let response_mutex = Arc::new(Mutex::<FlackResponse>::new(response.clone()));
    let flake_mutex = Arc::new(Mutex::<Value>::new(app.flake.clone()));
    let env_mutex = Arc::new(
        Mutex::<Value>::new(
            st.new_value_attrs(pairs)
                .map_err(|err| response.server_error(err))?
        )
    );

    // Offload eval once we've assembled the request context, since it will block.
    web::block(move || {
        let mut response = response_mutex.get_cloned()
            .map_err(|err| FlackResponse::new().server_error(err))?;

        let _gc_guard = nix_expr::eval_state::gc_register_my_thread()
            .map_err(|err| response.server_error(err))?;

        let mut st = eval_state_mutex.get_cloned()
            .map_err(|err| response.server_error(err))?;

        let mut store = st.store().clone();

        let flake = flake_mutex.get_cloned()
            .map_err(|err| response.server_error(err))?;

        let flack = match st
            .require_attrs_select_opt(&flake, "flack")
            .map_err(|err| response.not_found(err))?
        {
            Some(v) => v,
            None => return Err(response.not_found("attribute 'flack' not found")),
        };

        let app = match st
            .require_attrs_select_opt(&flack, "app")
            .map_err(|err| response.not_found(err))?
        {
            Some(v) => v,
            None => return Err(response.not_found("attribute 'flack.app' not found")),
        };

        let env = env_mutex.get_cloned()
            .map_err(|err| response.server_error(err))?;

        let res = st.call(app, env)
            .map_err(|err| response.server_error(err))?;

        let length = st.require_list_size(&res)
            .map_err(|err| response.server_error(err))?;
        if length != 3 {
            return Err(response.server_error("result of flack.app did not have length 3"));
        }
        let code_val = match st.require_list_select_idx(&res, 0)
            .map_err(|err| response.server_error(err))?
        {
            Some(val) => val,
            None => return Err(response.server_error("error getting code"))
        };
        let code = st.require_int(&code_val)
            .map_err(|err| response.server_error(err))?;
        if !(100..=599).contains(&code) {
            return Err(response.server_error("invalid status code"));
        }

        let res_headers_value = match st.require_list_select_idx(&res, 1)
            .map_err(|err| response.server_error(err))?
        {
            Some(val) => val,
            None => return Err(response.server_error("error getting headers"))
        };
        let res_headers_names = st.require_attrs_names(&res_headers_value)
            .map_err(|err| response.server_error(err))?;

        let body = match st.require_list_select_idx(&res, 2)
            .map_err(|err| response.server_error(err))?
        {
            Some(val) => val,
            None => return Err(response.server_error("error getting body"))
        };

        let body_type = st.value_type(&body)
            .map_err(|err| response.server_error(err))?;

        let mut content_type_set: bool = false;
        for header_name in res_headers_names.iter() {
            match st.require_attrs_select(&res_headers_value, header_name) {
                Ok(val) => {
                    match st.require_string(&val) {
                        Ok(header_value) => {
                            if header_name.eq_ignore_ascii_case("content-type") {
                                content_type_set = true;
                            }
                            response.add_header(header_name.to_string(), header_value.to_string());
                        },
                        Err(_) => ()
                    }
                },
                Err(_) => ()
            };
        }

        if body_type == ValueType::String {
            serve_path_or_text(&mut response, &mut st, &mut store, &body)
        } else if body_type == ValueType::AttrSet {
            // Could be a derivation.
            let attrs_type = match st.require_attrs_select_opt(&body, "type") {
                Ok(maybe_val) => match maybe_val {
                    Some(val) => match st.require_string(&val) {
                        Ok(val_str) => val_str,
                        Err(_) => "attrs".to_string()
                    },
                    None => "attrs".to_string(),
                },
                Err(_) => "attrs".to_string(),
            };
            if attrs_type.as_str().eq("derivation") {
                serve_path_or_text(&mut response, &mut st, &mut store, &body)
            } else {
                // Normal attrset, try to coerce to JSON
                let to_json = st.eval_from_string("builtins.toJSON", ".")
                    .map_err(|err| response.server_error(err))?;
                let json_str_value = st.call(to_json, body)
                    .map_err(|err| response.server_error(err))?;
                let json_str = st.require_string(&json_str_value)
                    .map_err(|err| response.server_error(err))?;

                debug!("Serving attrset as JSON: {}", json_str);

                if !content_type_set {
                    // Force it to JSON if there was not a content type overridden by the app.
                    let header = header::ContentType::json().try_into_pair()
                        .map_err(|err| response.server_error(err))?;
                    let key = header.0.to_string();
                    let value = header.1.to_str().map_err(|err| response.server_error(err))?.to_string();
                    response.add_header(key, value);
                }
                Ok(response.ok_string(json_str))
            }
        } else {
            Err(response.server_error("body was not a string or attribute set"))
        }
    })
    .await
    .map_err(|err| FlackResponse::new().server_error(err))?
}

async fn build_response(req: HttpRequest, response: &FlackResponse) -> HttpResponse {
    if response.body.is_some() {
        let mut builder = response.to_builder();
        builder.body(response.body.as_ref().unwrap().clone())
    } else if response.body_path.is_some() {
        match NamedFile::open_async(response.body_path.as_ref().unwrap().clone()).await {
            Ok(file) => {
                if file.metadata().is_file() {
                    debug!("Serving file {:?}", response.body_path.as_ref().unwrap());
                    let mut res = file.into_response(&req);
                    response.headers_into_response(&mut res);
                    res
                } else {
                    let mut builder = response.to_builder();
                    builder.status(StatusCode::NOT_FOUND);
                    builder.body("store path was not a file")
                }
            },
            Err(err) => {
                let mut builder = response.to_builder();
                builder.status(StatusCode::NOT_FOUND);
                builder.body("error opening file")
            }
        }
    } else {
        let mut builder = response.to_builder();
        builder.status(StatusCode::INTERNAL_SERVER_ERROR);
        builder.body("neither body string nor path was set")
    }
}

async fn flack(req: HttpRequest, body: web::Bytes) -> actix_web::Result<HttpResponse> {
    match flack_handler(req.clone(), &body).await
    {
        Ok(response) => Ok(build_response(req.clone(), &response).await),
        Err(response) => Ok(build_response(req.clone(), &response).await)
    }
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    let env = env_logger::Env::default()
        .filter_or("FLACK_LOG_LEVEL", "info")
        .write_style_or("FLACK_LOG_STYLE", "always");

    env_logger::init_from_env(env);

    let _gc_guard = nix_expr::eval_state::gc_register_my_thread()
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;

    let max_connections = match std::thread::available_parallelism() {
        Ok(val) => val,
        Err(err) => {
            debug!("Error getting max connections: {:?}", err);
            NonZero::new(1).unwrap()
        }
    };

    let uri = format!("unix://?max-connections={}", max_connections);
    info!("Initializing with store URI: {}", uri);

    let store = nix_store::store::Store::open(Some(uri.as_str()), [])
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
    let flake_settings = nix_flake::FlakeSettings::new()
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
    let fetch_settings = nix_fetchers::FetchersSettings::new()
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
    let mut eval_state = nix_expr::eval_state::EvalStateBuilder::new(store)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?
        .flakes(&flake_settings)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?
        .build()
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
    let flake = get_flake(&mut eval_state, fetch_settings, flake_settings, ".", &std::vec::Vec::new())
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;

    info!("Loaded flake: {:?}", eval_state.require_attrs_names(&flake));

    let flake_mutex = Arc::new(Mutex::<Value>::new(flake));
    let eval_mutex = Arc::new(Mutex::<EvalState>::new(eval_state));

    let address = "127.0.0.1";
    let port = 1111;

    HttpServer::new(move || {
        let flake_data = flake_mutex.get_cloned();
        let eval_data = eval_mutex.get_cloned();
        let app = FlackApp {
            address, port,
            system: nix_util::settings::get("system").unwrap_or("unknown".to_string()),
            flake: flake_data.expect("no flake"),
            eval_state: Arc::new(Mutex::<EvalState>::new(eval_data.expect("no eval state")))
        };
        App::new()
            .app_data(web::Data::new(app))
            .default_service(web::route().to(flack))
    })
    .bind((address, port))?
    .run()
    .await
}
