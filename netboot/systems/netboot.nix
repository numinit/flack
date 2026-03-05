{
  lib,
  pkgs,
  config,
  modulesPath,
  ...
}:

let
  baseDomain = "flack.dev";
  domain = "replicator.${baseDomain}";

  netName = "flack";

  networks = {
    flack = rec {
      id = 1;
      prefix = 24;
      subnet = "10.23.0.0/${toString prefix}";
      address = "10.23.0.1";
      addressFull = "${address}/${toString prefix}";
      dhcpStart = "10.23.0.128";
      dhcpEnd = "10.23.0.254";
      dhcpDomain = "${netName}.${domain}";
    };
  };

  defaultUser = "nixos";
  defaultPassword = "nixos";

  keaTsigSecretFile = "/etc/kea/tsig.key";
  knotTsigSecretFile = "/etc/knot/tsig.conf";
  tsigKeyName = "tsig-key";
  tsigKeyAlgorithm = "hmac-sha256";
  tsigKeyLength = 32;
  wirelessSecretsFile = "/etc/wireless.env";
in
{
  # Work on serial consoles
  boot.kernelParams = lib.mkAfter [
    "console=tty0"
    "console=ttyS0,115200n8"
  ];

  networking = {
    useDHCP = false;
    nftables = {
      enable = true;
      tables = {
        tftp = {
          family = "ip";
          content = ''
            ct helper helper-tftp {
              type "tftp" protocol udp
            }

            chain sethelper {
              type filter hook forward priority 0; policy accept;
              udp dport 69 ct helper set "helper-tftp"
            }
          '';
        };
      };
    };
    firewall = {
      # Need to allow TFTP and NTP for the local network.
      allowedUDPPorts = [
        69
        123
      ];
    };
    wireless = {
      # Enable it even in VM tests
      enable = lib.mkOverride 0 true;
      allowAuxiliaryImperativeNetworks = true;
      userControlled.enable = true;
      secretsFile = wirelessSecretsFile;
    };
  };

  systemd.network = {
    enable = true;
    netdevs = {
      # Create the bridge
      "20-${netName}" = {
        netdevConfig = {
          Kind = "bridge";
          Name = netName;
        };
      };
    };
    networks = {
      # Bridge all ethernet ports
      "30-${netName}-ports" = {
        matchConfig.Type = lib.mkDefault "ether";
        networkConfig.Bridge = netName;
        linkConfig.RequiredForOnline = "enslaved";
      };
      # Assign an address to the bridge
      "40-${netName}" = {
        matchConfig.Name = netName;
        address = [
          networks.flack.addressFull
        ];
        bridgeConfig = { };
        networkConfig.LinkLocalAddressing = "no";
        linkConfig = {
          RequiredForOnline = "routable";
        };
      };
      # Use DHCP for all wifi networks
      "41-dhcp" = {
        matchConfig.Type = lib.mkDefault "wlan";
        networkConfig = {
          DHCP = "yes";
          IgnoreCarrierLoss = "5s";
        };
      };
    };
  };

  systemd.services = {
    tftpd = {
      after = [ "nftables.service" ];
      description = "TFTP server";
      serviceConfig = rec {
        User = "tftpd";
        Group = "tftpd";
        Restart = "always";
        RestartSec = 5;
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = AmbientCapabilities;
        Type = "exec";
        RuntimeDirectory = "tftpd";
        PIDFile = "${RuntimeDirectory}/tftpd.pid";
        ExecStart = "${pkgs.tftp-hpa}/bin/in.tftpd -v -l -a 0.0.0.0:69 -P /run/${PIDFile} ${pkgs.ipxe}";
        TimeoutStopSec = 20;
      };
      wantedBy = [ "multi-user.target" ];
    };
  };

  security.sudo = {
    wheelNeedsPassword = false;
  };

  users = {
    motd = lib.mkAfter ''
      vvv
      Welcome to ${config.system.nixos.distroName}, provided by ${config.system.nixos.vendorName}!
      The default credentials are ${defaultUser} / ${defaultPassword}
      ^^^
    '';
    users = {
      tftpd = {
        isSystemUser = true;
        group = "tftpd";
      };
      ${defaultUser} = lib.mkDefault {
        isNormalUser = true;
        initialPassword = defaultPassword;
        extraGroups = [ "wheel" ];
      };
    };
    groups.tftpd = { };
  };

  services = {
    chrony = {
      enable = true;
      extraConfig = ''
        allow ${networks.flack.subnet}
      '';
    };

    getty = {
      autologinUser = defaultUser;
      autologinOnce = true;
    };

    kea.dhcp4 = {
      enable = true;
      settings = {
        valid-lifetime = 3600;
        renew-timer = 900;
        rebind-timer = 1800;

        lease-database = {
          type = "memfile";
          persist = true;
          name = "/var/lib/kea/dhcp4.leases";
        };

        interfaces-config = {
          dhcp-socket-type = "raw";
          interfaces = [
            netName
          ];
        };

        client-classes = [
          {
            name = "XClient_iPXE";
            test = "substring(option[77].hex,0,4) == 'iPXE'";
            boot-file-name = "http://${networks.flack.address}/netboot.ipxe";
          }

          {
            name = "UEFI-64-1";
            test = "substring(option[60].hex,0,20) == 'PXEClient:Arch:00007'";
            boot-file-name = "${pkgs.ipxe}/ipxe.efi";
          }

          {
            name = "UEFI-64-2";
            test = "substring(option[60].hex,0,20) == 'PXEClient:Arch:00008'";
            boot-file-name = "${pkgs.ipxe}/ipxe.efi";
          }

          {
            name = "UEFI-64-3";
            test = "substring(option[60].hex,0,20) == 'PXEClient:Arch:00009'";
            boot-file-name = "${pkgs.ipxe}/ipxe.efi";
          }

          {
            name = "Legacy";
            test = "substring(option[60].hex,0,20) == 'PXEClient:Arch:00000'";
            boot-file-name = "${pkgs.ipxe}/undionly.kpxe";
          }
        ];

        subnet4 = [
          {
            inherit (networks.flack) subnet id;
            pools = [
              {
                pool = "${networks.flack.dhcpStart} - ${networks.flack.dhcpEnd}";
              }
            ];
            ddns-qualifying-suffix = "${networks.flack.dhcpDomain}.";
            option-data = [
              {
                name = "routers";
                data = networks.flack.address;
                always-send = true;
              }
              {
                name = "domain-name-servers";
                data = networks.flack.address;
                always-send = true;
              }
              {
                name = "domain-name";
                data = networks.flack.dhcpDomain;
                always-send = true;
              }
              {
                name = "ntp-servers";
                data = networks.flack.address;
                always-send = true;
              }
            ];
          }
        ];

        # Enable communication between dhcp4 and a local dhcp-ddns
        # instance.
        # https://kea.readthedocs.io/en/kea-2.2.0/arm/dhcp4-srv.html#ddns-for-dhcpv4
        dhcp-ddns = {
          enable-updates = true;
        };

        ddns-send-updates = true;
        ddns-qualifying-suffix = "${domain}.";
        ddns-update-on-renew = true;
        ddns-replace-client-name = "when-not-present";
        hostname-char-set = "[^A-Za-z0-9.-]";
        hostname-char-replacement = "";
      };
    };

    kea.dhcp-ddns = {
      enable = true;
      settings = {
        forward-ddns = {
          ddns-domains = [
            {
              name = "${baseDomain}.";
              key-name = tsigKeyName;
              dns-servers = [
                {
                  ip-address = "127.0.0.1";
                  port = 53535;
                }
              ];
            }
          ];
        };
        tsig-keys = [
          {
            name = tsigKeyName;
            algorithm = lib.toUpper tsigKeyAlgorithm;
            secret-file = keaTsigSecretFile;
          }
        ];
      };
    };

    knot =
      let
        zone = pkgs.writeTextDir "${baseDomain}.zone" ''
          @ SOA ns noc.${baseDomain} 10 86400 7200 3600000 172800
          @ NS nameserver
          nameserver A 127.0.0.1
          ${domain}. A ${networks.flack.address}
        '';
        zonesDir = pkgs.buildEnv {
          name = "knot-zones";
          paths = [ zone ];
        };
      in
      {
        enable = true;
        extraArgs = [
          "-v"
        ];
        keyFiles = [ knotTsigSecretFile ];
        settings = {
          server = {
            listen = "127.0.0.1@53535";
          };
          log = {
            syslog = {
              any = "debug";
            };
          };
          acl = {
            tsig-acl = {
              key = tsigKeyName;
              action = "update";
            };
          };
          template = {
            default = {
              storage = zonesDir;
              zonefile-sync = -1;
              zonefile-load = "difference-no-serial";
              journal-content = "all";
            };
          };
          zone = {
            ${baseDomain} = {
              file = "${baseDomain}.zone";
              acl = [ "tsig-acl" ];
            };
          };
        };
      };

    kresd = {
      # knot resolver daemon
      enable = true;
      package = pkgs.knot-resolver.override { extraFeatures = true; };
      listenPlain = [
        "${networks.flack.address}:53"
        "127.0.0.1:53"
        "[::1]:53"
      ];
      extraConfig = ''
        cache.size = 32 * MB
        -- verbose(true)

        modules = {
          'policy',
          'view',
          'hints',
          'serve_stale < cache',
          'workarounds < iterate',
          'stats',
          'predict'
        }

        -- Accept all requests from these subnets
        subnets = {
          '${networks.flack.subnet}',
          '127.0.0.0/8'
        }
        for i, v in ipairs(subnets) do
          view:addr(v, function(req, qry) return policy.PASS end)
        end

        -- Drop everything that hasn't matched
        view:addr('0.0.0.0/0', function (req, qry) return policy.DROP end)

        -- We are responsible for these.
        our_domains = {
          '${baseDomain}.'
        }
        policy:add(policy.domains(policy.STUB('127.0.0.1@53535'), policy.todnames(our_domains)))

        -- Forward requests for the local DHCP domains.
        local_domains = { '${domain}.' }
        for i, v in ipairs(local_domains) do
          policy:add(policy.suffix(policy.STUB('127.0.0.1@53535'), {todname(v)}))
        end

        -- Uncomment one of the following stanzas in case you want to forward all requests to 1.1.1.1 or 9.9.9.9 via DNS-over-TLS.
        policy:add(policy.all(policy.TLS_FORWARD({
          { '9.9.9.9', hostname='dns.quad9.net', ca_file='/etc/ssl/certs/ca-certificates.crt' },
          { '2620:fe::fe', hostname='dns.quad9.net', ca_file='/etc/ssl/certs/ca-certificates.crt' },
          { '1.1.1.1', hostname='cloudflare-dns.com', ca_file='/etc/ssl/certs/ca-certificates.crt' },
          { '2606:4700:4700::1111', hostname='cloudflare-dns.com', ca_file='/etc/ssl/certs/ca-certificates.crt' },
        })))

        -- Prefetch learning (20-minute blocks over 24 hours)
        predict.config({ window = 20, period = 72 })
      '';
    };

  };

  system = {
    activationScripts = {
      tsig.text =
        let
          userGroup =
            serviceName: default:
            let
              name = config.systemd.services.${serviceName}.serviceConfig.user or default;
              group = config.users.users.${name}.group;
              uidAndGid = lib.escapeShellArg "${toString name}:${toString group}";
            in
            uidAndGid;
        in
        ''
          kea_tsig_secret=${lib.escapeShellArg keaTsigSecretFile}
          kea_user_group=${userGroup "kea-dhcp-ddns-server" "kea"}
          if [ ! -f "$kea_tsig_secret" ]; then
            echo "Generating Kea TSIG secret ($kea_tsig_secret) for $kea_user_group." >&2
            mkdir -p "$(dirname -- "$kea_tsig_secret")"
            touch "$kea_tsig_secret"
            chmod 0600 "$kea_tsig_secret"
            chown "$kea_user_group" "$kea_tsig_secret"
            ${lib.getExe pkgs.openssl} rand -base64 ${toString tsigKeyLength} >> "$kea_tsig_secret"
          fi

          knot_tsig_secret=${lib.escapeShellArg knotTsigSecretFile}
          knot_user_group=${userGroup "knot" "knot"}
          if [ ! -f "$knot_tsig_secret" ]; then
            echo "Generating Knot TSIG secret ($knot_tsig_secret) for $knot_user_group." >&2
            mkdir -p "$(dirname -- "$knot_tsig_secret")"
            touch "$knot_tsig_secret"
            chmod 0600 "$knot_tsig_secret"
            chown "$knot_user_group" "$knot_tsig_secret"
            cat <<EOF >>"$knot_tsig_secret"
          key:
            - id: ${tsigKeyName}
              algorithm: ${tsigKeyAlgorithm}
              secret: $(<"$kea_tsig_secret")
          EOF
          fi

          wireless_env=${lib.escapeShellArg wirelessSecretsFile}
          if [ ! -f "$wireless_env" ]; then
            echo "Creating empty $wireless_env." >&2
            mkdir -p "$(dirname -- "$wireless_env")"
            touch "$wireless_env"
            chmod 0600 "$wireless_env"
          fi
        '';
    };
    nixos.vendorName = "SCaLE 23x";
    stateVersion = lib.versions.majorMinor lib.version;
  };

  time.timeZone = lib.mkOverride 10 "America/Los_Angeles";

  # Include this file in /etc/nixos
  environment.etc."nixos/configuration.nix".text = builtins.readFile ./netboot.nix;
}
