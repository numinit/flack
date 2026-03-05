{
  lib,
  stdenv,
  ipxe,
  OVMF,
  qemu_test,
  testers,
  inputs,
  ...
}:

let
  mkStartCommand =
    {
      nic,
      net,
      machine,
      memory ? 2048,
      pxe ? true,
      uefi ? true,
      extraFlags ? [ ],
    }:
    let
      qemu-common = import "${inputs.nixpkgs}/nixos/lib/qemu-common.nix" { inherit lib stdenv; };
      qemu = qemu-common.qemuBinary qemu_test;

      zeroPad =
        n:
        lib.optionalString (n < 16) "0"
        + (if n > 255 then throw "Can't have more than 255 nets or nodes!" else lib.toHexString n);

      qemuNicMac = net: machine: "52:54:00:12:${zeroPad net}:${zeroPad machine}";

      qemuNicFlags = nic: net: machine: [
        "-device"
        "virtio-net-pci,netdev=vlan${toString nic},mac=${qemuNicMac net machine}${lib.optionalString (pxe && uefi) ",romfile=${ipxe}/ipxe.efirom"}"
        "-netdev"
        ''vde,id=vlan${toString nic},sock="$QEMU_VDE_SOCKET_${toString net}"''
      ];

      flags = [
        "-m"
        (toString memory)
      ]
      ++ qemuNicFlags nic net machine
      ++ lib.optionals pxe [
        "-boot"
        "order=n"
      ]
      ++ lib.optionals uefi [
        "-drive"
        "if=pflash,format=raw,unit=0,readonly=on,file=${OVMF.firmware}"
        "-drive"
        "if=pflash,format=raw,unit=1,readonly=on,file=${OVMF.variables}"
      ]
      ++ extraFlags;

      flagsStr = lib.concatStringsSep " " flags;
    in
    "${qemu} ${flagsStr}";
in
testers.runNixOSTest {
  name = "flack-netboot";

  nodes = let
    mkNode = module: lib.mkMerge [
      module
      ({ pkgs, ... }: {
        imports = [
          inputs.flack-lib.nixosModules.default

          ../../systems/netboot.nix
          ../../systems/netboot/flack.nix
        ];
        virtualisation.cores = 8;
        virtualisation.vlans = [ 1 ];
        virtualisation.memorySize = 4096;
        # Don't clobber the test NIC which is eth0.
        #systemd.network.networks."30-flack-ports".matchConfig.Type = lib.mkVMOverride "eth[1-9]";
        #systemd.network.networks.
      })
    ];
  in {
    alpha = mkNode {
    };

  };

  testScript = ''
    alpha.start()
    alpha.wait_for_unit('multi-user.target')
    alpha.wait_until_succeeds("curl -f http://localhost:2020/netboot.ipxe")

    beta = create_machine("""${
      mkStartCommand {
        nic = 1;
        net = 1;
        machine = 2;
      }
    }""")

    beta.start()
    beta.wait_for_unit('multi-user.target')
  '';
}
