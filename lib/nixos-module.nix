{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib.options) mkOption;

  inherit (lib.modules) mkMerge mkIf;

  inherit (lib.lists) unique filter optional;

  inherit (lib.strings) escapeShellArgs concatStringsSep makeBinPath;

  inherit (lib.attrsets) mapAttrsToList;

  inherit (lib) types;

  nameToId = serverName: "flack-${serverName}";
  genArgs =
    serverName: serverCfg:
    [
      "--host"
      serverCfg.host
      "--port"
      serverCfg.port
    ]
    ++ lib.optional (!serverCfg.substituteOnPreload) "--no-preload-substitute"
    ++ serverCfg.extraArgs;

  cfg = config.services.flack;
  enabledServers = lib.filterAttrs (n: v: v.enable) cfg.servers;
in
{
  options = {
    services.flack = {
      servers = mkOption {
        description = "Flack server definitions";
        default = { };
        type = types.attrsOf (
          types.submodule {
            options = {
              enable = mkOption {
                type = types.bool;
                default = true;
                description = "Enable or disable this server.";
              };

              closure = mkOption {
                type = types.package;
                description = "The closure of this Flack server";
              };

              host = mkOption {
                type = types.str;
                default = "localhost";
                description = "The host for this Flack server";
              };

              port = mkOption {
                type = types.port;
                default = 2020;
                description = "The port for this Flack server";
              };

              openFirewall = mkOption {
                type = types.bool;
                default = false;
                description = "Open the firewall to clients";
              };

              substituteOnPreload = mkOption {
                type = types.bool;
                default = true;
                description = "Enable substitution during app preload";
              };

              extraArgs = mkOption {
                type = with types; listOf str;
                default = [ ];
                description = "Extra arguments to add to the Flack server.";
              };
            };
          }
        );
      };
    };
  };

  config = mkIf (enabledServers != { }) {
    systemd.services = mkMerge (
      lib.mapAttrsToList (
        serverName: serverCfg:
        let
          siteId = nameToId serverName;
          args = genArgs serverName serverCfg;
          capabilities =
            let
              inherit (serverCfg) port;
            in
            concatStringsSep " " (
              # binding to privileged ports
              optional (port > 0 && port < 1024) "CAP_NET_BIND_SERVICE"
            );
        in
        {
          "flack@${serverName}" = {
            description = "Flack webserver for ${serverName}";
            wants = [ "basic.target" ];
            after = [
              "basic.target"
              "network.target"
            ];
            wantedBy = [ "multi-user.target" ];
            environment = {
              HOME = "/run/${siteId}";
            };
            path = [ pkgs.git ];
            serviceConfig = {
              Type = "simple";
              Restart = "always";
              ExecStart = "${serverCfg.closure.flack-serve}/bin/flack-serve ${escapeShellArgs args}";
              UMask = "0027";
              CapabilityBoundingSet = capabilities;
              AmbientCapabilities = capabilities;
              LockPersonality = true;
              NoNewPrivileges = true;
              PrivateDevices = true;
              DevicePolicy = "closed";
              PrivateTmp = true;
              PrivateUsers = false;
              ProtectClock = true;
              ProtectControlGroups = true;
              ProtectHome = true;
              ProtectHostname = true;
              ProtectKernelLogs = true;
              ProtectKernelModules = true;
              ProtectKernelTunables = true;
              ProtectProc = "invisible";
              ProtectSystem = true;
              RestrictNamespaces = true;
              RestrictSUIDSGID = true;
              RuntimeDirectory = siteId;
              User = siteId;
              Group = siteId;
            };
          };
        }
      ) enabledServers
    );

    networking.firewall.allowedTCPPorts = unique (
      filter (port: port > 0) (mapAttrsToList (serverName: serverCfg: serverCfg.port) enabledServers)
    );

    users.users = mkMerge (
      mapAttrsToList (serverName: serverCfg: {
        ${nameToId serverName} = {
          group = nameToId serverName;
          description = "Flack service user for server ${serverName}";
          isSystemUser = true;
        };
      }) enabledServers
    );

    users.groups = mkMerge (
      mapAttrsToList (serverName: serverCfg: {
        ${nameToId serverName} = { };
      }) enabledServers
    );
  };
}
