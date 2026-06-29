# Eternal Terminal (et) — persistent remote shell server (etserver).
#
# WHAT: Runs `etserver` (pkgs.eternal-terminal 6.2.11) so that `et` clients can
# hold a shell session that survives network drops, IP roaming, and laptop sleep
# — the SSH equivalent of mosh, but pure TCP (no UDP) and with a real reconnect/
# replay buffer. The eternal-terminal package also installs the `et` CLIENT and
# `etterminal` helper system-wide, which is required: the remote `et` client
# bootstraps over SSH and invokes `etterminal` on this host on every connect.
#
# HOW IT AUTHS: et does NOT authenticate on its own port. The client first SSHes
# in using the host's normal sshd (key-only here: PasswordAuthentication=false,
# PermitRootLogin=no), and a per-session passkey is minted and handed back ONLY
# inside that encrypted SSH channel. etserver then accepts the persistent TCP
# connection on port 2022 keyed by that passkey (libsodium-encrypted stream).
# Net: et's effective auth strength == this host's sshd. sshd is the bootstrap
# and is deliberately left UNCHANGED by this module.
#
# WHY LAN-ONLY (secure-by-default): the NixOS module does NOT open the firewall,
# and etserver always binds 0.0.0.0 + :: (the stock module exposes no bind_ip /
# settings escape hatch, so the listen address can't be narrowed in-process). The
# port is therefore unauthenticated to anyone who can't already SSH in, and et is
# a niche C++ daemon with a history of memory-safety CVEs (e.g. the pre-6.1.9
# stack overflow). So we admit port 2022 ONLY on the two physical LAN NICs via
# per-interface firewall rules, and never add it to the global allowedTCPPorts.
# Traffic on the microVM bridges/veths (hermes-br0, vm-*, ve-*) and any future
# interface is dropped. Loopback is always allowed by the NixOS firewall, so the
# local etterminal<->etserver handshake still works.
#
# TO WIDEN BEYOND THE LAN (don't, by default): et is TCP-only, so this needs just
# ONE TCP port reachable — but do NOT port-forward 2022 at the router or bind it
# on a public interface; that exposes et's pre-/around-auth parser to the whole
# internet. The right way to get off-LAN access is to first reach the LAN (a
# future WireGuard/Tailscale, or tunnel et inside SSH), then connect as if local.
# vulcan has no VPN today, which is exactly why LAN-only is the correct scope now.
#
# CLIENT (run on your laptop, not here):
#   et johnw@vulcan.lan                                   # basic
#   et johnw@vulcan.lan -c "tmux new-session -A -s main"  # auto-attach tmux
# (-p / host:PORT set the ET port; sshd is reached via --ssh-option Port=N or
# ~/.ssh/config. Our sshd is the default 22 and et's port is the default 2022,
# so no flags are needed.)
#
# Modeled on: modules/services/vane.nix (let-port + per-interface firewall idiom),
# modules/services/network-services.nix (sshd, left untouched here).

{ lib, ... }:

let
  # etserver TCP port (Eternal Terminal default). Registered in docs/ports.txt.
  etPort = 2022;

  # Physical LAN interfaces only. Deliberately excludes microVM bridges/veths
  # (hermes-br0, vm-*, ve-*) and any future interface — fail-closed if a NIC is
  # ever renamed (traffic simply stops being admitted, never silently widened).
  lanInterfaces = [
    "end0" # wired (static 192.168.1.2, default route)
    "wlp1s0f0" # wifi
  ];
in
{
  # etserver runs as root by design: it forks each interactive session as the
  # SSH-authenticated user, so the aggressive systemd sandbox knobs (User=,
  # NoNewPrivileges, ProtectHome, PrivateTmp, SystemCallFilter, IPAddress*) are
  # intentionally NOT set — they would break login-session spawning. The stock
  # module's Restart=on-failure (DoS resilience) is kept.
  services.eternal-terminal = {
    enable = true;
    port = etPort;
    # verbosity = 0 (default): avoid spilling session clientids into logs.
    # silent = false (default): keep an audit trail.
  };

  # Fix a defect in the stock nixpkgs unit: it is Type=forking and launches
  # `etserver --daemon` but sets NO PIDFile=, so systemd cannot adopt the
  # double-forked daemon. Observed result on first deploy: the unit flips to
  # "inactive (dead)" 2ms after start while etserver keeps running orphaned
  # (reparented to PID 1) — which silently disables Restart=on-failure, makes
  # `systemctl`/monitoring report it down, and (worst) leaves the next switch
  # unable to rebind 2022 because the orphan still holds the socket.
  # etserver reliably writes /run/etserver.pid when run as root (verified), so
  # pointing systemd at it lets Type=forking track the real MainPID. KillMode is
  # left at the module's "process" so a restart does NOT tear down live login
  # sessions etserver has spawned.
  systemd.services.eternal-terminal.serviceConfig.PIDFile = "/run/etserver.pid";

  # Secure-by-default reachability: admit etserver's TCP port ONLY on the
  # physical LAN NICs. The module does not touch the firewall, and we keep 2022
  # OUT of the global networking.firewall.allowedTCPPorts on purpose.
  networking.firewall.interfaces = lib.genAttrs lanInterfaces (_: {
    allowedTCPPorts = [ etPort ];
  });
}
