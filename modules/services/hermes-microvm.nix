# Host-side parent module for the Hermes Agent microVM.
# Imported by /etc/nixos/hosts/vulcan/default.nix.
#
# Sibling to modules/services/openclaw-microvm.nix; intentionally on
# its own private /30 bridge so neither VM's networking can affect the
# other. No DNAT/inbound in Phase 1 — Hermes is outbound-only.
{
  config,
  lib,
  pkgs,
  inputs,
  system,
  ...
}:
let
  bridgeName = "hermes-br0";
  bridgeAddr = "10.99.1.1";
  bridgeCidr = "${bridgeAddr}/30";
  vmAddr = "10.99.1.2";
  vmCidr = "${vmAddr}/30";

  vmHostname = "hermes-vm";
  hermesUid = 932;
  hermesGid = 932;
  stateDir = "/var/lib/hermes";
in
{
  imports = [
    inputs.microvm.nixosModules.host
  ];

  # ---- Host user/group ----
  users.users.hermes = {
    isSystemUser = true;
    uid = hermesUid;
    group = "hermes";
    home = stateDir;
    description = "Hermes Agent runtime user";
  };
  users.groups.hermes.gid = hermesGid;

  # ---- Host-side persistent state ----
  # `d` directive — preserves contents across rebuilds (CLAUDE.md rule).
  # `C+` directive stages the Vulcan root CA into the state share for the
  # guest's `security.pki.certificateFiles` to pick up (copy-once, never
  # overwrites; rerun a `nixos-rebuild` after rotating the cert).
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 hermes hermes -"
    "C+ ${stateDir}/vulcan-root-ca.crt 0644 hermes hermes - /etc/nixos/certs/vulcan-root-ca.crt"
  ];

  # ---- Host bridge ----
  systemd.network = {
    enable = true;
    netdevs."40-${bridgeName}" = {
      netdevConfig = {
        Name = bridgeName;
        Kind = "bridge";
      };
    };
    networks."40-${bridgeName}" = {
      matchConfig.Name = bridgeName;
      address = [ bridgeCidr ];
      networkConfig = {
        ConfigureWithoutCarrier = true;
        IPMasquerade = "ipv4";
      };
    };
  };

  # ---- Egress filtering (host nftables) ----
  # Allow VM → bridge gateway for DNS, then allow VM → external (the
  # masquerade rule above handles SNAT). Drop everything else from the
  # bridge subnet to host services. Mirrors the openclaw-egress shape.
  networking.nftables.tables.hermes-egress = {
    family = "inet";
    content = ''
      chain forward {
        type filter hook forward priority filter; policy accept;
        # VM → bridge gateway DNS (TCP+UDP). The host's resolved/DNS
        # listener handles the actual query.
        ip saddr ${vmAddr} ip daddr ${bridgeAddr} udp dport 53 accept
        ip saddr ${vmAddr} ip daddr ${bridgeAddr} tcp dport 53 accept

        # VM → outbound (model APIs, Discord gateway, etc.). No specific
        # destination allowlist for Phase 1 — observe what Hermes
        # actually reaches and tighten in Phase 2.
        ip saddr ${vmAddr} oifname != "${bridgeName}" accept

        # Block any other host-internal access from the VM.
        ip saddr ${vmAddr} ip daddr 10.0.0.0/8 drop
        ip saddr ${vmAddr} ip daddr 172.16.0.0/12 drop
        ip saddr ${vmAddr} ip daddr 192.168.0.0/16 drop
      }
    '';
  };

  # ---- SOPS secret staged for the VM's environmentFile ----
  # sops-nix decrypts on the host (where the age key lives) and writes
  # the cleartext to `path`. Because that path is inside the state share
  # virtio-fs'd into the VM, Hermes inside the VM reads it transparently
  # as /var/lib/hermes/env. Mode 0640 + owner hermes lets the in-VM
  # hermes user read it; the file never crosses to non-hermes processes.
  sops.secrets."hermes/env" = {
    mode = "0640";
    owner = "hermes";
    group = "hermes";
    path = "${stateDir}/env";
  };

  # ---- microvm.nix declaration ----
  microvm.vms.hermes = {
    autostart = true;
    config = {
      imports = [ ./hermes-vm.nix ];
      _module.args = {
        inherit
          bridgeAddr
          vmHostname
          hermesUid
          hermesGid
          stateDir
          ;
      };
    };
    # microvm.nix runner config
    specialArgs = { inherit inputs system; };
  };

  # The microVM runtime itself
  microvm = {
    autostart = [ "hermes" ];
  };
}
