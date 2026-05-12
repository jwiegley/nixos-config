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
  tapName = "vm-hermes";
  bridgeAddr = "10.99.1.1";
  bridgeCidr = "${bridgeAddr}/30";
  vmAddr = "10.99.1.2";
  vmCidr = "${vmAddr}/30";

  # External NIC used for VM NAT. Matches openclaw-microvm.nix:25 — the
  # host's physical interface on this Asahi/aarch64 box. Update both
  # files together if it ever changes.
  externalInterface = "end0";

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
  # `C+` directive stages the Vulcan root CA into the state share.
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 hermes hermes -"
    "C+ ${stateDir}/vulcan-root-ca.crt 0644 hermes hermes - /etc/nixos/certs/vulcan-root-ca.crt"
  ];

  # ---- NetworkManager coexistence ----
  networking.networkmanager.unmanaged = [
    "interface-name:${bridgeName}"
    "interface-name:${tapName}"
  ];

  # ---- systemd-networkd: bridge + TAP ----
  systemd.network.enable = true;
  systemd.network.wait-online.anyInterface = true;
  systemd.network.netdevs."50-${bridgeName}".netdevConfig = {
    Kind = "bridge";
    Name = bridgeName;
  };
  systemd.network.networks."50-${bridgeName}" = {
    matchConfig.Name = bridgeName;
    addresses = [ { Address = bridgeCidr; } ];
    networkConfig.ConfigureWithoutCarrier = true;
  };
  systemd.network.networks."51-${tapName}" = {
    matchConfig.Name = tapName;
    networkConfig.Bridge = bridgeName;
  };

  # ---- NAT: VM internet access ----
  networking.nat = {
    enable = true;
    internalInterfaces = [ bridgeName ];
    externalInterface = externalInterface;
  };

  # ---- Egress isolation (iptables-nft, matching OpenClaw) ----
  networking.firewall.extraCommands = ''
    # ── Hermes network isolation ──
    iptables -N hermes-isolate 2>/dev/null || iptables -F hermes-isolate

    # DNS to bridge gateway (Technitium binds to 0.0.0.0:53)
    iptables -A hermes-isolate -d ${bridgeAddr} -p tcp --dport 53 -j RETURN
    iptables -A hermes-isolate -d ${bridgeAddr} -p udp --dport 53 -j RETURN

    # Drop everything else originating from the VM toward host services
    iptables -A hermes-isolate -j DROP
    iptables -I nixos-fw 3 -i ${bridgeName} -j hermes-isolate

    # FORWARD chain: block private-network-bound traffic.
    iptables -A FORWARD -i ${bridgeName} -d 10.0.0.0/8 -j DROP
    iptables -A FORWARD -i ${bridgeName} -d 172.16.0.0/12 -j DROP
    iptables -A FORWARD -i ${bridgeName} -d 192.168.0.0/16 -j DROP

    # Egress logging — log new outbound connections from the bridge
    iptables -A FORWARD -i ${bridgeName} -o ${externalInterface} -m conntrack --ctstate NEW -j LOG --log-prefix "hermes-egress: " --log-level info
  '';
  networking.firewall.extraStopCommands = ''
    iptables -D nixos-fw -i ${bridgeName} -j hermes-isolate 2>/dev/null || true
    iptables -F hermes-isolate 2>/dev/null || true
    iptables -X hermes-isolate 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -d 10.0.0.0/8 -j DROP 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -d 172.16.0.0/12 -j DROP 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -d 192.168.0.0/16 -j DROP 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -o ${externalInterface} -m conntrack --ctstate NEW -j LOG --log-prefix "hermes-egress: " --log-level info 2>/dev/null || true
  '';

  # ---- Nix store / virtiofs interaction ----
  # The guest mounts /nix/store via virtiofs in hermes-vm.nix.
  # Auto-optimise on the host can produce stale file handles inside
  # the guest — disable. Matches openclaw-microvm.nix:623.
  nix.optimise.automatic = false;

  # ---- SOPS secret staged for the VM's environmentFile ----
  sops.secrets."hermes/env" = {
    mode = "0640";
    owner = "hermes";
    group = "hermes";
    path = "${stateDir}/env";
    # Restart the microVM unit when the secret changes so the
    # in-VM hermes process picks up the new env vars.
    restartUnits = [ "microvm@hermes.service" ];
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
          tapName
          ;
      };
    };
    specialArgs = { inherit inputs system; };
  };

  microvm = {
    autostart = [ "hermes" ];
  };
}
