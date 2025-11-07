#![feature(lock_value_accessors)]
#![feature(normalize_lexically)]

use actix_web::mime::{self};
use log::{debug, info, warn};
use nix_bindings_expr::eval_state::ThreadRegistrationGuard;
use std::num::NonZero;
use std::ops::Deref;
use std::path::{PathBuf};
use std::str::FromStr;
use std::sync::Mutex;
use std::{sync::Arc};

use actix_files::NamedFile;
use actix_web::http::header::{HeaderName, HeaderValue, TryIntoHeaderPair};
use actix_web::http::{header, StatusCode};
use actix_web::{Either, HttpMessage, HttpRequest, HttpResponseBuilder};
use actix_web::{
    web, App, HttpResponse, HttpServer
};

use uuid::Uuid;

use clap::Parser;

use nix_bindings_expr::{
    eval_state::EvalState,
    value::{Value, ValueType},
};
use nix_bindings_flake::EvalStateBuilderExt as _;

use nix_bindings_store::path::StorePath;
use nix_bindings_store::store::{Store, StoreWeak};

#[derive(Parser, Clone, Debug)]
#[command(version, about, long_about = None)]
struct FlackArgs {
    /// The directory to use; defaults to the current working directory
    #[arg(short = 'd', long, default_value = ".")]
    dir: String,

    /// The flake reference to use; defaults to "."
    #[arg(short = 'f', long, default_value = ".")]
    flake: String,

    /// The flake attribute containing the Flack app
    #[arg(short = 'a', long, default_value = "flack.apps.default")]
    attr: String,

    /// The store URI
    #[arg(short = 's', long, default_value = "unix://")]
    store: String,

    /// The maximum number of connections to the store; set to 0 to use all CPUs
    #[arg(short = 'c', long, default_value_t = 0)]
    max_connections: u16,

    /// The host to spawn the server on
    #[arg(short = 'H', long, default_value = "localhost")]
    host: String,

    /// The port to spawn the server on
    #[arg(short = 'p', long, default_value_t = 2019)]
    port: u16,

    /// The log level
    #[arg(short = 'l', long, default_value = "info")]
    log_level: String,

    /// The log style
    #[arg(short = 'L', long, default_value = "always")]
    log_style: String
}

pub struct FlackApp {
    args: FlackArgs,
    system: String,
    state: Arc<Mutex<EvalState>>,
    flake: Arc<Mutex<Value>>,
    app: Arc<Mutex<Value>>,
}

#[derive(serde::Serialize, Clone, Debug)]
struct FlackError {
    error: String,

    #[serde(skip_serializing)]
    long: String
}

#[derive(Clone, Debug)]
struct FlackResponse {
    code: u16,
    headers: Vec<(HeaderName, HeaderValue)>,
    body: Option<String>,
    body_path: Option<PathBuf>,
    error: Option<FlackError>
}

fn get_gc_guard() -> std::io::Result<ThreadRegistrationGuard> {
    nix_bindings_expr::eval_state::init()
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;

    nix_bindings_expr::eval_state::gc_register_my_thread()
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))
}

fn get_state(
    store: Store
) -> std::io::Result<(EvalState, ThreadRegistrationGuard)> {
    let gc_guard = get_gc_guard()?;

    let flake_settings = nix_bindings_flake::FlakeSettings::new()
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
    let state = nix_bindings_expr::eval_state::EvalStateBuilder::new(store)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?
        .flakes(&flake_settings)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?
        .build()
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;

    Ok((state, gc_guard))
}

fn get_flake(
    eval_state: &mut EvalState,
    fetch_settings: nix_bindings_fetchers::FetchersSettings,
    basedir_str: &String,
    flakeref_str: &String,
    input_overrides: &Vec<(String, String)>,
) -> std::io::Result<Value> {
    let flake_settings = nix_bindings_flake::FlakeSettings::new()
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;

    let mut parse_flags = nix_bindings_flake::FlakeReferenceParseFlags::new(&flake_settings)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidInput, e))?;

    parse_flags.set_base_directory(basedir_str.as_str())
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidInput, e))?;

    let parse_flags = parse_flags;

    let mut lock_flags = nix_bindings_flake::FlakeLockFlags::new(&flake_settings)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidInput, e))?;
    lock_flags.set_mode_virtual()
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidInput, e))?;

    for (override_path, override_ref_str) in input_overrides {
        let (override_ref, fragment) = nix_bindings_flake::FlakeReference::parse_with_fragment(
            &fetch_settings,
            &flake_settings,
            &parse_flags,
            override_ref_str)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidInput, e))?;

        if !fragment.is_empty() {
            return std::io::Result::Err(
                std::io::Error::new(
                    std::io::ErrorKind::Unsupported,
                    format!(
                        "input override {} has unexpected fragment: {}",
                        override_path,
                        fragment
                    ).as_str()
                )
            );
        }
        lock_flags.add_input_override(override_path, &override_ref)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidInput, e))?;
    }
    let lock_flags = lock_flags;

    let (flakeref, fragment) = nix_bindings_flake::FlakeReference::parse_with_fragment(
        &fetch_settings,
        &flake_settings,
        &parse_flags,
        flakeref_str.as_str())
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidInput, e))?;
    if !fragment.is_empty() {
        return std::io::Result::Err(
            std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                format!(
                    "flake reference {} has unexpected fragment: {}",
                    flakeref_str,
                    fragment
                ).as_str()
            )
        )
    }

    let flake = nix_bindings_flake::LockedFlake::lock(
        &fetch_settings,
        &flake_settings,
        eval_state,
        &lock_flags,
        &flakeref)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;

    let outputs = flake.outputs(&flake_settings, eval_state)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;

    std::io::Result::Ok(outputs)
}

impl FlackResponse {
    fn new() -> FlackResponse {
        FlackResponse {
            code: 0,
            headers: Vec::new(),
            body: None,
            body_path: None,
            error: None
        }
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
        self.set(500, Either::Left(FlackError{ error: "Internal server error".to_string(), long: err.to_string() }))
    }

    fn bad_request<S: std::fmt::Display>(&mut self, err: S) -> Self {
        self.set(400, Either::Left(FlackError{ error: "Bad request".to_string(), long: err.to_string() }))
    }

    fn not_found<S: std::fmt::Display>(&mut self, err: S) -> Self {
        self.set(404, Either::Left(FlackError{ error: "Not found".to_string(), long: err.to_string() }))
    }

    fn ok(&mut self, body: Either<FlackError, Either<String, PathBuf>>) -> Self {
        self.set(200, body)
    }

    fn ok_string<S: std::fmt::Display>(&mut self, body: S) -> Self {
        self.ok(Either::Right(Either::Left(body.to_string())))
    }

    fn ok_path(&mut self, body: PathBuf) -> Self {
        self.ok(Either::Right(Either::Right(body)))
    }

    fn set(&mut self, code: u16, body: Either<FlackError, Either<String, PathBuf>>) -> Self {
        self.code = code;
        match body {
            Either::Left(left) => {
                self.error = Some(left.to_owned());
            },
            Either::Right(right) => {
                match right {
                    Either::Left(left) => {
                        self.body = Some(left.to_owned());
                    },
                    Either::Right(right) => {
                        self.body_path = Some(right.to_owned());
                    }
                }
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
    dir: &String,
    value: &Value
) -> Result<FlackResponse, FlackResponse> {
    debug!("Forcing value");
    let to_string = st.eval_from_string("builtins.toString", dir.as_str())
        .map_err(|err| response.server_error(err))?;
    let to_string_value = st.call(to_string, value.clone())
        .map_err(|err| response.server_error(err))?;
    let string_value = st.require_string(&to_string_value)
        .map_err(|err| response.server_error(err))?;

    // Could be a string that represents a store path.
    let mut store = st.store().clone();
    match get_safe_path(response, &mut store, &string_value) {
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

async fn flack_handler(req: HttpRequest, request_body: web::Bytes) -> Result<FlackResponse, FlackResponse> {
    let app = req.app_data::<web::Data<FlackApp>>().unwrap().clone();

    let port = app.args.port;

    let http_version = format!("{:?}", req.version());
    let request_id = Uuid::now_v7().to_string();
    let str_inputs = [
        ("RACK", "flack".to_string()),
        ("REQUEST_METHOD", req.method().to_string()),
        ("PATH_INFO", req.path().to_string()),
        ("QUERY_STRING", req.query_string().to_string()),
        ("SERVER_NAME", req.connection_info().host().to_string()),
        ("SERVER_PROTOCOL", http_version.to_string()),
        ("rack.url_scheme", req.connection_info().scheme().to_string()),
        ("flack.system", app.system.to_string()),
        ("flack.request_id", request_id),
    ];
    let int_inputs = [
        ("SERVER_PORT", port as i64),
    ];

    let headers = req.headers().clone();
    let mime_type = req.mime_type();
    let request_body_mutex = Arc::new(Mutex::<web::Bytes>::new(request_body));

    // Offload eval once we've assembled the request context, since it will block.
    web::block(move || {
        let _guard = get_gc_guard();

        let dir = app.args.dir.clone();

        let mut response = FlackResponse::new();

        let mut st = app.state.get_cloned()
            .map_err(|err| response.server_error(err))?;

        let mut pairs = Vec::with_capacity(str_inputs.len() + int_inputs.len() + 1);
        for (key, value) in str_inputs {
            add_str_value(&mut response, &mut st, &mut pairs, key, value.as_str())?;
        }
        for (key, value) in int_inputs {
            add_int_value(&mut response, &mut st, &mut pairs, key, value)?;
        }

        match headers.get("host") {
            Some(v) => add_str_value(&mut response, &mut st, &mut pairs, "HTTP_HOST", v.to_str().unwrap_or("")),
            None => Ok(())
        }?;

        match headers.get("content-type") {
            Some(v) => add_str_value(&mut response, &mut st, &mut pairs, "CONTENT_TYPE", v.to_str().unwrap_or("")),
            None => Ok(())
        }?;

        let request_body = request_body_mutex.get_cloned()
            .map_err(|err| response.server_error(err))?;

        if !request_body.is_empty() {
            add_int_value(&mut response, &mut st, &mut pairs, "CONTENT_LENGTH", request_body.len() as i64)?;

            let json_body = match mime_type {
                Ok(v) => {
                    match v {
                        Some(mime) => {
                            match (mime.type_(), mime.subtype()) {
                                (mime::APPLICATION, mime::JSON) => {
                                    let request_body_str = std::str::from_utf8(&request_body);
                                    match request_body_str {
                                        Ok(request_body) => {
                                            Some(request_body)
                                        },
                                        Err(err) => {
                                            return Err(response.bad_request(err));
                                        }
                                    }
                                },
                                _ => None
                            }
                        },
                        None => None
                    }
                },
                Err(err) => {
                    return Err(response.bad_request(err));
                }
            };

            match json_body {
                Some(body) => {
                    let from_json = st.eval_from_string("builtins.fromJSON", dir.as_str())
                        .map_err(|err| response.server_error(err))?;
                    let body_val = st.new_value_str(body)
                        .map_err(|err| response.bad_request(err))?;
                    debug!("fromJSON on body");
                    let body_attrset_val = st.call(from_json, body_val)
                        .map_err(|err| response.bad_request(err))?;
                    pairs.push(("flack.body".to_string(), body_attrset_val));
                    ()
                },
                None => ()
            }
        }

        for (key, value) in headers.iter() {
            if key.as_str().eq("host") || key.as_str().eq("content-type") {
                continue;
            }

            let key_str = key.as_str();
            if key_str.chars().all(|c| matches!(c, 'A'..='Z' | 'a'..='z' | '-')) {
                let env_str = format!("HTTP_{}", key_str.to_ascii_uppercase().replace("-", "_"));
                add_str_value(&mut response, &mut st, &mut pairs, &env_str, value.to_str().unwrap_or(""))?;
            }
        }

        let env = st.new_value_attrs(pairs)
            .map_err(|err| response.server_error(err))?;

        debug!("calling into app");
        let flack_app = app.app.get_cloned()
            .map_err(|err| response.server_error(err))?;

        let res = st.call(flack_app, env)
            .map_err(|err| response.server_error(err))?;

        let length = st.require_list_size(&res)
            .map_err(|err| response.server_error(err))?;
        if length != 3 {
            return Err(response.server_error("result of flack app did not have length 3"));
        }
        let code_val = match st.require_list_select_idx_strict(&res, 0)
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

        let res_headers_value = match st.require_list_select_idx_strict(&res, 1)
            .map_err(|err| response.server_error(err))?
        {
            Some(val) => val,
            None => return Err(response.server_error("error getting headers"))
        };
        let res_headers_names = st.require_attrs_names(&res_headers_value)
            .map_err(|err| response.server_error(err))?;

        let body = match st.require_list_select_idx_strict(&res, 2)
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
            serve_path_or_text(&mut response, &mut st, &dir, &body)
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
                serve_path_or_text(&mut response, &mut st, &dir, &body)
            } else {
                // Normal attrset, try to coerce to JSON
                let to_json = st.eval_from_string("builtins.toJSON", dir.as_str())
                    .map_err(|err| response.server_error(err))?;
                debug!("toJSON on result");
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
                    let cloned_response = response.clone().not_found("store path was not a file");
                    let error = cloned_response.error.as_ref().unwrap();
                    warn!("Error ({}): {}", error.error, error.long);
                    let mut builder = cloned_response.to_builder();
                    builder.status(StatusCode::from_u16(cloned_response.code).unwrap());
                    builder.json(web::Json(error))
                }
            },
            Err(_err) => {
                let cloned_response = response.clone().not_found("cannot open file");
                let error = cloned_response.error.as_ref().unwrap();
                warn!("Error ({}): {}", error.error, error.long);
                let mut builder = cloned_response.to_builder();
                builder.status(StatusCode::from_u16(cloned_response.code).unwrap());
                builder.json(web::Json(error))
            }
        }
    } else {
        let error = response.error.as_ref().unwrap();
        warn!("Error ({}): {}", error.error, error.long);
        let mut builder = response.to_builder();
        builder.status(StatusCode::from_u16(response.code).unwrap());
        builder.json(web::Json(error))
    }
}

async fn flack(req: HttpRequest, body: web::Bytes) -> actix_web::Result<HttpResponse> {
    match flack_handler(req.clone(), body).await
    {
        Ok(response) => Ok(build_response(req.clone(), &response).await),
        Err(response) => Ok(build_response(req.clone(), &response).await)
    }
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    let mut args = FlackArgs::parse();

    let env = env_logger::Env::default()
        .filter_or("FLACK_LOG_LEVEL", args.log_level.as_str())
        .write_style_or("FLACK_LOG_STYLE", args.log_style.as_str());
    env_logger::init_from_env(env);

    args.dir = std::fs::canonicalize(args.dir)?.to_str().unwrap_or(".").to_string();

    info!("Serving project directory: {}", args.dir);

    if args.max_connections < 1 {
        // Default the max connections to the available parallelism.
        let max_connections = match std::thread::available_parallelism() {
            Ok(val) => val,
            Err(err) => {
                warn!("Error getting parallelism, defaulting to 1: {:?}", err);
                NonZero::new(1).unwrap()
            }
        };
        args.max_connections = max_connections.get() as u16;
    }

    let store_uri = url::Url::parse_with_params(
        args.store.as_str(),
        &[("max-connections", format!("{}", args.max_connections).as_str())])
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidInput, e))?;

    info!("Connecting to store: {}", store_uri.to_string());

    let store = nix_bindings_store::store::Store::open(Some(store_uri.to_string().as_str()), [])
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::ConnectionRefused, e))?;

    info!("Loading flake: {}", args.flake);

    let (mut st, _guard) = get_state(store)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;

    // Get the flake.
    let fetch_settings = nix_bindings_fetchers::FetchersSettings::new()
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
    let flake = get_flake(&mut st, fetch_settings, &args.dir, &args.flake, &std::vec::Vec::new())?;

    info!(
        "Flake loaded successfully: {:?}",
        st.require_attrs_names(&flake)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?
    );

    // Get the app.
    let mut app = flake.clone();

    let attr: Vec<String> = args.attr.split('.').map(str::to_string).collect();
    for item in &attr {
        app = match st
            .require_attrs_select_opt(&app, item)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::NotFound, e))?
        {
            Some(v) => v,
            None => return Err(std::io::Error::new(std::io::ErrorKind::NotFound, format!("attribute '{}' not found", item))),
        };
    }

    info!("App loaded successfully.");

    let host = args.host.clone();
    let log_host = args.host.clone();
    let port = args.port.clone();

    let args_mutex = Arc::new(Mutex::<FlackArgs>::new(args));
    let state_mutex = Arc::new(Mutex::<EvalState>::new(st.clone()));
    let flake_mutex = Arc::new(Mutex::<Value>::new(flake));
    let app_mutex = Arc::new(Mutex::<Value>::new(app));

    let server = HttpServer::new(move || {
        let args_data = args_mutex.get_cloned().expect("no args");
        let state_data = state_mutex.get_cloned().expect("no state");
        let flake_data = flake_mutex.get_cloned().expect("no flake");
        let app_data = app_mutex.get_cloned().expect("no app");

        let app = FlackApp {
            args: args_data,
            system: nix_bindings_util::settings::get("system").unwrap_or("unknown".to_string()),
            state: Arc::new(Mutex::<EvalState>::new(state_data)),
            flake: Arc::new(Mutex::<Value>::new(flake_data)),
            app: Arc::new(Mutex::<Value>::new(app_data))
        };

        App::new()
            .wrap(actix_web::middleware::Logger::default())
            .app_data(web::Data::new(app))
            .default_service(web::route().to(flack))
    })
    .bind((host, port))?;

    info!(r#"
    ________    ___   ________ __
   / ____/ /   /   | / ____/ //_/
  / /_  / /   / /| |/ /   / ,<
 / __/ / /___/ ___ / /___/ /| |
/_/   /_____/_/  |_\____/_/ |_|
Bound to {}:{}
"#, log_host, port);

    server.run().await
}
