# Host-side parent module for the Hermes Agent microVM.
# Imported by /etc/nixos/hosts/vulcan/default.nix.
#
# The guest sits on its own private /30 bridge. That was originally so this VM
# and a second agent VM could not affect each other's networking; the second VM
# is gone, but the isolation is kept on its own merits — the guest reaches host
# services only through the explicit DNAT list below, and nothing else.
#
# INBOUND FROM THE LAN: https://hermes.vulcan.lan, for the Conduit iOS client.
# nginx on the host is the sole ingress; the guest itself remains reachable only
# over the /30 bridge. HTTPS ONLY — this endpoint carries API_SERVER_KEY, and
# nothing on this host may offer a LAN service unencrypted. Also an ALLOWLIST,
# because several Hermes routes need no credential. Both constraints are
# explained at the vhost below; read them before changing either.
#
# There IS outbound-direction DNAT: since 2026-05-12 a two-stage DNAT lets the
# guest reach host loopback services; see the dnatPorts block below.
{
  config,
  lib,
  pkgs,
  inputs,
  system,
  ...
}:
let
  # Imported here (in addition to hermes-vm.nix) so the host service has
  # something to key restart triggers on — changing models.nix should
  # restart microvm@hermes during the next nixos-rebuild switch.
  models = import ../../models.nix;

  bridgeName = "hermes-br0";
  tapName = "vm-hermes";
  bridgeAddr = "10.99.1.1";
  bridgeCidr = "${bridgeAddr}/30";
  vmAddr = "10.99.1.2";

  # External NIC used for VM NAT: the host's physical interface on this
  # Asahi/aarch64 box. Note the host is multi-homed (end0 + WiFi) and this
  # deliberately names the wired NIC only.
  externalInterface = "end0";

  # Hermes api_server listen port. Single source of truth: it is `inherit`ed
  # into the guest config below, so hermes-vm.nix's API_SERVER_PORT and its
  # firewall rule derive from THIS value rather than restating it. Consumed by
  # the LAN reverse proxy below.
  apiServerPort = 8080;

  vmHostname = "hermes-vm";
  hermesUid = 932;
  hermesGid = 932;
  stateDir = "/var/lib/hermes";

  # Host-side staging dir for SOPS secret *content* shared into the VM via
  # virtiofs as /run/hermes-secrets. sops-nix decrypts on the host; the
  # hermes-prepare-secrets oneshot copies the content here at 0400
  # hermes:hermes before the VM starts (the guest has no sops-nix).
  secretsStagingDir = "/var/lib/microvms/hermes/secrets";

  # -- Host-side loopback services that the VM needs to reach --
  # Two-stage DNAT, so guest code can use plain 127.0.0.1:port addresses:
  #   1. Guest nftables OUTPUT: 127.0.0.1:port -> 10.99.1.1:port
  #   2. Host iptables PREROUTING (on hermes-br0): 10.99.1.1:port -> 127.0.0.1:port
  #   3. Host sysctl route_localnet=1 on hermes-br0 (allows the loopback hop)
  # The host PREROUTING DNAT, per-interface INPUT accepts, and the
  # hermes-isolate RETURN rules below are all parameterized on this list, so
  # adding a port here propagates to all three automatically:
  #   443  nginx HTTPS (searxng.vulcan.lan, vane.vulcan.lan, trader.vulcan.lan)
  #   993  Dovecot IMAPS (email-contacts)
  #   2525 Postfix SMTP (email-contacts)
  #   4000 LLM gateway (chat + org-search embeddings, nginx -> hera)
  #   5232 Radicale CardDAV (contacts)
  #   5432 PostgreSQL (org-db read-only)
  #   8123 Home Assistant (mcp-proxy bridge)
  #   9082 drafts-mcp (Drafts(hera) MCP SSE bridge)
  # Deliberately EXCLUDED: 6334/6335 and 9081.
  #   6334 Qdrant gRPC — the memory provider is REST-only by construction
  #        (pkgs/hermes-qdrant-memory/src/qdrant_rest.py), so gRPC is pure
  #        attack surface with no consumer.
  #   6335 Qdrant inference bridge — called BY qdrant on the host to reach the
  #        LLM gateway for server-side embeddings. It is never a client-side
  #        callee, so the guest has no use for it.
  #   9081 hermes-mcp's own SSE port — this guest IS what that port fronts, so
  #        forwarding it into the guest would be a loop.
  #
  # 6333 was excluded until 2026-08-03 on the theory that Qdrant served only
  # another agent's memory. That stopped being true when Hermes got her own
  # Qdrant-backed memory. Honest note on what including it does and does not
  # change: 443 is already forwarded and nginx already fronts
  # qdrant.vulcan.lan, so the guest could reach Qdrant before this. Adding 6333
  # buys explicitness and a clean failure mode, NOT new privilege.
  dnatPorts = [
    443
    993
    2525
    4000
    5232
    5432
    6333 # Qdrant HTTP REST — Hermes memory provider (REST only; NOT 6334/gRPC)
    8123
    9082
  ];
  # NO-SPACE comma join: this string feeds both `iptables -m multiport
  # --dports` (host isolate chain below) and the guest's nftables
  # `tcp dport { ... }` set. iptables multiport rejects spaces (an unquoted
  # "443, 993" word-splits into a trailing-comma token -> "invalid port ''"),
  # and nftables sets accept the comma-only form fine. Was ", " when only
  # port 4000 was in the list, which hid the bug.
  dnatPortList = lib.concatStringsSep "," (map toString dnatPorts);
  hostDnatRules = lib.concatMapStringsSep "\n" (port: ''
    iptables -t nat -A PREROUTING -i ${bridgeName} -d ${bridgeAddr} -p tcp --dport ${toString port} -j DNAT --to-destination 127.0.0.1:${toString port}
  '') dnatPorts;
  hostDnatCleanupRules = lib.concatMapStringsSep "\n" (port: ''
    iptables -t nat -D PREROUTING -i ${bridgeName} -d ${bridgeAddr} -p tcp --dport ${toString port} -j DNAT --to-destination 127.0.0.1:${toString port} 2>/dev/null || true
  '') dnatPorts;
  # Shared proxy body for every forwarded Hermes location. Written as raw
  # extraConfig rather than proxyPass= so the same text can back an exact-match
  # location (`= /health`), which the NixOS locations option renders verbatim.
  hermesProxyPass = ''
    proxy_pass http://${vmAddr}:${toString apiServerPort};

    # Audit provenance. api_server.py reads X-Forwarded-For and X-Real-IP by
    # name into its request-audit context and persists them onto cron jobs
    # created over HTTP. Behind a proxy its own request.remote is always the
    # bridge, so without these the only provenance it can record is whatever
    # the caller chose to send. $remote_addr, not $proxy_add_x_forwarded_for,
    # so a client-supplied value is overwritten rather than appended to.
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Host hermes.vulcan.lan;

    # Hermes streams over SSE (not WebSockets -- Conduit uses
    # Accept: text/event-stream on this path). Buffering would hold a whole
    # agent turn until it completed.
    proxy_buffering off;
    proxy_cache off;

    # Conduit allows a 5-minute idle and 30-minute maximum on a stream, so the
    # proxy must outlast that rather than cutting turns short. NOTE an nginx
    # RELOAD still terminates in-flight requests at worker_shutdown_timeout,
    # which web.nix:30 sets to 300s.
    proxy_connect_timeout 30s;
    proxy_send_timeout 3600s;
    proxy_read_timeout 3600s;

    # Bound what an unauthenticated caller can make the host absorb: nginx
    # buffers the whole body before proxying, and /health needs no key.
    client_max_body_size 32m;
    client_body_buffer_size 1m;
    limit_req zone=hermes_api burst=20 nodelay;
    limit_conn hermes_api_conn 16;

    # Defence in depth against prompt injection: the guest can reach the host,
    # so without this a compromised agent could re-enter its own control API
    # through the front door -- and it is the one principal already holding
    # API_SERVER_KEY. Host-side callers (hermes-mcp, the e2e probe, Open WebUI)
    # go direct over the bridge, so nothing legitimate is denied.
    deny ${vmAddr};
    allow all;

    proxy_http_version 1.1;
    proxy_set_header Connection "";
  '';

in
{
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
  # The Vulcan root CA is embedded into the VM's trust store at
  # evaluation time via security.pki.certificates (see hermes-vm.nix),
  # so no host-side staging is needed.
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 hermes hermes -"
  ];

  # Resolvable name for the guest, so host-side consumers can address the
  # api_server without restating its bridge address. Open WebUI uses this in
  # modules/users/home-manager/open-webui.nix; keeping the mapping here means
  # vmAddr stays the single source of truth. Host-only: this is /etc/hosts on
  # vulcan, not a DNS record, so the name is not resolvable from the LAN.
  networking.hosts."${vmAddr}" = [ "hermes-vm" ];

  # Per-client limits for the LAN-facing Hermes ingress. Must be at http
  # scope; limit_req_zone/limit_conn_zone cannot live in a server block.
  services.nginx.appendHttpConfig = ''
    limit_req_zone $binary_remote_addr zone=hermes_api:10m rate=10r/s;
    limit_conn_zone $binary_remote_addr zone=hermes_api_conn:10m;
  '';

  # ---- LAN ingress for the Conduit iOS client ----
  # hermes-br0 is a /30 host-only bridge, so the guest is unreachable from the
  # LAN. This vhost is the only way a phone can talk to Hermes.
  #
  # HTTPS ONLY. This endpoint carries API_SERVER_KEY on every request, and no
  # LAN-facing service on this host may be offered unencrypted.
  #
  # CLIENT COMPATIBILITY, CONFIRMED WORKING 2026-08-02: Conduit connects to this
  # endpoint over HTTPS with the step-ca certificate. Worth recording because a
  # source reading of the app predicted otherwise -- its Hermes path builds a
  # bare Dio client with no badCertificateCallback and no custom
  # SecurityContext, which was expected to mean Dart's built-in roots and no
  # regard for the iOS trust store. In practice the CA installed on the phone is
  # honoured. Do not "fix" a future connection failure by reverting to
  # plaintext: this endpoint carries API_SERVER_KEY.
  #
  # forceSSL (rather than a bare 443 listener) keeps the port-80 behaviour
  # explicit: a client misconfigured with http:// gets a 301 and, because
  # Conduit sets followRedirects: false, fails loudly on the FIRST request
  # instead of silently shipping the key in clear on every one. One header
  # reaches port 80 in that case; there is no way to prevent that server-side,
  # since any listener reads the request before it can answer.
  services.nginx.virtualHosts."hermes.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/hermes.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/hermes.vulcan.lan.key";

    # ---- Proxied surface is an ALLOWLIST ----
    # Hermes does not authenticate everything. Verified live 2026-08-02 against
    # the guest: /health and /health/detailed both answer 200 with no
    # credential (upstream docs claim /health/detailed is authenticated; this
    # build disagrees, so do not rely on the doc).
    #
    #   /health          ALLOWED. Conduit's "Test connection" button hits
    #                    exactly this and nothing else, so the endpoint is
    #                    load-bearing. Its body is only {"status","platform"} --
    #                    no state worth withholding.
    #   /health/detailed BLOCKED. Returns gateway state, connected-platform
    #                    inventory, active agent count, last exit reason and the
    #                    pid, to any device on the LAN with no key. Conduit can
    #                    call it, so some status display may degrade; that is
    #                    preferred to publishing it. Flip to a proxied location
    #                    if a feature actually needs it.
    #   /v1/ /api/       ALLOWED. The real API surface, all key-gated.
    #   everything else  404.
    locations = {
      "= /health".extraConfig = hermesProxyPass;
      "= /health/detailed".extraConfig = "return 404;";
      "/v1/".extraConfig = hermesProxyPass;
      "/api/".extraConfig = hermesProxyPass;
      "/".extraConfig = "return 404;";
    };
  };

  # ---- NetworkManager coexistence ----
  networking.networkmanager.unmanaged = [
    "interface-name:${bridgeName}"
    "interface-name:${tapName}"
  ];

  # ---- systemd-networkd: bridge + TAP ----
  systemd.network.enable = true;
  # systemd-networkd-wait-online is disabled host-wide (modules/core/networking.nix);
  # the old `anyInterface` override here was moot and was removed.
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

  # ---- Per-interface INPUT accepts ----
  # Technitium DNS on the host binds to 0.0.0.0:53, so the VM uses
  # bridgeAddr as its DNS server. PREROUTING DNAT rewrites
  # bridgeAddr:PORT → 127.0.0.1:PORT but the packet still arrives via
  # hermes-br0; the INPUT chain must whitelist the post-DNAT ports on
  # this interface or `nixos-fw-log-refuse` drops them at end-of-chain.
  networking.firewall.interfaces.${bridgeName} = {
    allowedUDPPorts = [ 53 ];
    allowedTCPPorts = [ 53 ] ++ dnatPorts;
  };

  # ---- Egress isolation (iptables-nft) ----
  # Outbound reaches the public internet on TCP/UDP 443 (Discord +
  # OpenRouter via the hera/* route) and TCP/UDP 53 (DNS) only;
  # everything else leaving the bridge is logged as
  # "hermes-egress-rejected" and DROPped by the FORWARD rules below
  # (tightened 2026-05-15 — before that, all outbound was allowed).
  # The hermes-isolate chain below separately restricts the VM's
  # access *back* into the host's private network.
  #
  # TODO(phase-2): tighten egress further to an allowlist of known
  # endpoint IP ranges — Discord runs behind Cloudflare (AS13335) and
  # OpenRouter publishes its egress addresses. Until then, a
  # compromised Hermes process could still exfiltrate to arbitrary
  # public IPs over port 443.
  networking.firewall.extraCommands = ''
    # ── Hermes network isolation ──
    iptables -N hermes-isolate 2>/dev/null || iptables -F hermes-isolate

    # DNS to bridge gateway (Technitium binds to 0.0.0.0:53)
    iptables -A hermes-isolate -d ${bridgeAddr} -p tcp --dport 53 -j RETURN
    iptables -A hermes-isolate -d ${bridgeAddr} -p udp --dport 53 -j RETURN

    # DNAT'd host services (the LLM gateway, etc.) — accept inbound traffic to
    # bridgeAddr on these ports.  NOTE: PREROUTING DNAT rewrites the
    # destination to 127.0.0.1 BEFORE the INPUT chain (and therefore this
    # isolation chain) runs, so the post-DNAT packet has dst=127.0.0.1, not
    # bridgeAddr. We need BOTH rules — the bridgeAddr one is belt-and-
    # suspenders if the DNAT ever stops running (the connection then fails
    # noisily rather than silently slipping through), and the 127.0.0.1 one
    # is what actually matches in steady state.
    iptables -A hermes-isolate -d ${bridgeAddr} -p tcp -m multiport --dports ${dnatPortList} -j RETURN
    iptables -A hermes-isolate -d 127.0.0.1 -p tcp -m multiport --dports ${dnatPortList} -j RETURN

    # Drop everything else originating from the VM toward host services
    iptables -A hermes-isolate -j DROP
    iptables -I nixos-fw 3 -i ${bridgeName} -j hermes-isolate

    # Bridge→bridge forwarding for DNAT return path. The DNAT happens
    # in PREROUTING (host iptables nat:PREROUTING), then the kernel
    # routes 127.0.0.1 via lo. The reply packet's source is 127.0.0.1
    # which gets SNAT'd back to bridgeAddr via the FORWARD chain.
    iptables -A FORWARD -i ${bridgeName} -o ${bridgeName} -j ACCEPT

    # FORWARD chain: block private-network-bound traffic.
    iptables -A FORWARD -i ${bridgeName} -d 10.0.0.0/8 -j DROP
    iptables -A FORWARD -i ${bridgeName} -d 172.16.0.0/12 -j DROP
    iptables -A FORWARD -i ${bridgeName} -d 192.168.0.0/16 -j DROP

    # Allow conservative outbound set (per 7-day egress log review):
    # - TCP 443 (HTTPS — Discord, OpenRouter, internal hera)
    # - UDP 443 (HTTP/3 — Cloudflare-fronted services increasingly use it)
    # - TCP/UDP 53 (DNS)
    iptables -A FORWARD -i ${bridgeName} -o ${externalInterface} -p tcp --dport 443 -j ACCEPT
    iptables -A FORWARD -i ${bridgeName} -o ${externalInterface} -p udp --dport 443 -j ACCEPT
    iptables -A FORWARD -i ${bridgeName} -o ${externalInterface} -p tcp --dport 53  -j ACCEPT
    iptables -A FORWARD -i ${bridgeName} -o ${externalInterface} -p udp --dport 53  -j ACCEPT

    # Egress logging — log new outbound connections that didn't match
    # any ACCEPT above (i.e. about to be DROPped by the final rule).
    iptables -A FORWARD -i ${bridgeName} -o ${externalInterface} -m conntrack --ctstate NEW -j LOG --log-prefix "hermes-egress-rejected: " --log-level info

    # Final DROP — anything not matched by the ACCEPT rules above is rejected
    iptables -A FORWARD -i ${bridgeName} -o ${externalInterface} -j DROP

    # Belt-and-suspenders IPv6: the guest has v6 disabled and the
    # bridge is v4-only, but if anything ever flips v6 forwarding on
    # this host (or adds a v6 addr to the bridge), the v4 rules above
    # silently fail to filter it. Drop any v6 forward off the bridge.
    ip6tables -A FORWARD -i ${bridgeName} -j DROP
  '';
  networking.firewall.extraStopCommands = ''
    iptables -D nixos-fw -i ${bridgeName} -j hermes-isolate 2>/dev/null || true
    iptables -F hermes-isolate 2>/dev/null || true
    iptables -X hermes-isolate 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -o ${bridgeName} -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -d 10.0.0.0/8 -j DROP 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -d 172.16.0.0/12 -j DROP 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -d 192.168.0.0/16 -j DROP 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -o ${externalInterface} -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -o ${externalInterface} -p udp --dport 443 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -o ${externalInterface} -p tcp --dport 53  -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -o ${externalInterface} -p udp --dport 53  -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -o ${externalInterface} -m conntrack --ctstate NEW -j LOG --log-prefix "hermes-egress-rejected: " --log-level info 2>/dev/null || true
    iptables -D FORWARD -i ${bridgeName} -o ${externalInterface} -j DROP 2>/dev/null || true
    ip6tables -D FORWARD -i ${bridgeName} -j DROP 2>/dev/null || true
  '';

  # ---- Two-stage DNAT (stage 2: host PREROUTING) ----
  # See dnatPorts comment in `let` block. The guest's stage 1 (OUTPUT
  # DNAT 127.0.0.1:port -> bridgeAddr:port) is in hermes-vm.nix. This
  # piece rewrites the bridge-bound packets back to host loopback, and
  # the sysctl below lets the kernel actually route loopback via the
  # bridge interface.
  boot.kernel.sysctl."net.ipv4.conf.${bridgeName}.route_localnet" = 1;

  systemd.services.hermes-host-dnat = {
    description = "DNAT rules for Hermes VM to reach host loopback services";
    wantedBy = [ "microvm@hermes.service" ];
    before = [ "microvm@hermes.service" ];
    after = [
      "network-online.target"
      "sys-subsystem-net-devices-${bridgeName}.device"
    ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    path = [ pkgs.iptables ];

    script = ''
      ${hostDnatRules}
      echo "Hermes host DNAT rules installed for ports: ${dnatPortList}"
    '';

    preStop = ''
      ${hostDnatCleanupRules}
    '';
  };

  # ---- Nix store / virtiofs interaction ----
  # The guest mounts /nix/store via virtiofs in hermes-vm.nix.
  # Auto-optimise on the host can produce stale file handles inside
  # the guest — disable.
  nix.optimise.automatic = false;

  # ---- LAN-facing reverse proxy for the Hermes API server ----
  # hermes-br0 is a /30 host-only bridge, so the guest's api_server is
  # reachable from vulcan and nothing else. This vhost is the only way another
  # machine on the LAN can talk to Hermes.
  #
  # Upstream is PLAIN HTTP. The api_server does not do TLS (verified 2026-08-01:
  # a TLS client gets `wrong version number`, i.e. a plaintext server). That was
  # fine while the only reachable client was on the host bridge; it is why this
  # vhost terminates TLS on the LAN side. docs/ports.txt used to claim the
  # upstream was HTTPS and has been corrected.
  #
  # AUTHENTICATION IS DELIBERATELY PASSED THROUGH, NOT INJECTED.
  # The gateway at :4000 (hera-llm-proxy.nix) injects its upstream key because
  # it is loopback-only. The opposite choice is correct here: this listener is
  # LAN-facing, and Hermes can send mail, read the calendar, query PostgreSQL
  # and drive Home Assistant. Injecting a key would make all of that reachable
  # by anything on the network with no credential. Clients present
  # API_SERVER_KEY themselves and Hermes enforces its own 401.
  #
  # Consequently: do NOT add a `proxy_set_header Authorization` here. If a
  # client gets 401, the fix is to give that client the key, never to make the
  # proxy supply one.
  # ---- SOPS secret staged for the VM's environmentFile ----
  # Note: NO `path` option — sops-nix's `path` writes a symlink at the
  # target, and inside the VM the symlink target /run/secrets/hermes/env
  # doesn't exist (the VM has no sops-nix). So we let sops deploy to its
  # default /run/secrets/hermes/env on the host, and a prepare-secrets
  # oneshot below copies the *content* into the state share at
  # ${stateDir}/env so the in-VM hermes-agent.service can read a real
  # file via virtio-fs.
  sops.secrets."hermes/env" = {
    mode = "0640";
    owner = "hermes";
    group = "hermes";
    # Restart both the staging service and the microVM when the secret
    # rotates so the new env vars propagate.
    restartUnits = [
      "hermes-prepare-secrets.service"
      "microvm@hermes.service"
    ];
  };

  # ---- Reused SOPS secrets: append Hermes restart triggers only ----
  # owner/group/mode for these five are declared by their canonical
  # owners (email-tester, vdirsyncer). Declaring
  # them again here would conflict; sops-nix `restartUnits` is a list
  # that merges across modules, so we add ONLY the restart triggers so
  # that rotating any of these re-stages the secret and restarts the VM.
  sops.secrets."email-tester-imap-password".restartUnits = [
    "hermes-prepare-secrets.service"
    "microvm@hermes.service"
  ];
  sops.secrets."vdirsyncer-johnw/radicale-password".restartUnits = [
    "hermes-prepare-secrets.service"
    "microvm@hermes.service"
  ];
  # DO NOT RENAME THESE THREE. The `openclaw/` prefix is not a leftover
  # reference to a removed service — it is the literal KEY NAME inside the
  # encrypted secrets.yaml, which lives in a separate repo and is not edited
  # from here. The name in this file must match the name in that file or
  # sops-nix has nothing to decrypt. Hermes is now their only consumer, and
  # deleting or renaming them breaks hermes-prepare-secrets and with it three
  # of her capabilities at once: the Home Assistant bridge, org-db, and
  # Perplexity. Renaming is possible, but only as a coordinated change to
  # secrets.yaml, and it buys nothing but tidiness.
  #
  # owner root, and that is correct: no `openclaw` user exists any more, and
  # hermes-prepare-secrets is a Type=oneshot with no User=, so it runs as root
  # and `install -m 0400 -o hermes -g hermes` copies each one into
  # /run/hermes-secrets itself. Root-owned sources are exactly what it needs.
  sops.secrets."openclaw/home-assistant-token" = {
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [
      "hermes-prepare-secrets.service"
      "microvm@hermes.service"
    ];
  };
  sops.secrets."openclaw/org-db-password" = {
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [
      "hermes-prepare-secrets.service"
      "microvm@hermes.service"
      # postgresql-openclaw-setup still uses this password to provision the
      # read-only `openclaw` role that Hermes' org-db MCP connects as.
      "postgresql-openclaw-setup.service"
    ];
  };
  sops.secrets."openclaw/perplexity-api-key" = {
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [
      "hermes-prepare-secrets.service"
      "microvm@hermes.service"
    ];
  };

  # ---- Stage SOPS secret content into the VM's virtio-fs state share ----
  systemd.services.hermes-prepare-secrets = {
    description = "Stage SOPS secrets for Hermes microVM";
    wantedBy = [ "microvm@hermes.service" ];
    before = [ "microvm@hermes.service" ];
    after = [ "sops-nix.service" ];

    # Force re-stage when the model catalog changes — Type=oneshot + RemainAfterExit
    # means switch-to-configuration would otherwise skip restarting this unit
    # on closure changes, leaving the staged config out of sync.
    restartTriggers = [ (builtins.toJSON { agent = models.llm.reasoning; }) ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      install -d -m 0750 -o hermes -g hermes "${stateDir}"
      install -m 0640 -o hermes -g hermes \
        "${config.sops.secrets."hermes/env".path}" \
        "${stateDir}/env"
      echo "Hermes env staged to ${stateDir}/env"

      # Staging dir for the virtio-fs hermes-secrets share. Owned by root
      # (0755); virtiofs handles per-file access, the files themselves are
      # 0400 hermes:hermes.
      mkdir -p "${secretsStagingDir}"
      chmod 0755 "${secretsStagingDir}"

      # Stage the five reused SOPS secrets' *content* into the share. These are
      # not hermes-owned SOPS entries — they are shared with email-tester,
      # vdirsyncer, and the legacy `openclaw/`-named keys above — so guard each
      # copy with `if [ -f ]`: a missing source must not fail the unit and block
      # the VM from starting at all.

      # IMAP/SMTP password (reuse email-tester-imap-password — same Dovecot passdb)
      IMAP_PASS_SRC="${config.sops.secrets."email-tester-imap-password".path}"
      if [ -f "$IMAP_PASS_SRC" ]; then
        install -m 0400 -o hermes -g hermes \
          "$IMAP_PASS_SRC" "${secretsStagingDir}/imap-password"
        echo "IMAP credentials staged"
      fi

      # Qdrant API key for the memory provider. Reuses the EXISTING
      # `qdrant/api-key` secret that qdrant.nix also reads, so there is exactly
      # one copy of this key in SOPS. The alternative -- adding
      # QDRANT_API_KEY to the hermes/env blob -- would create a second copy that
      # silently desyncs on the next rotation, and would need an interactive sops
      # session to establish.
      QDRANT_KEY_SRC="${config.sops.secrets."qdrant/api-key".path}"
      if [ -f "$QDRANT_KEY_SRC" ]; then
        install -m 0400 -o hermes -g hermes \
          "$QDRANT_KEY_SRC" "${secretsStagingDir}/qdrant-api-key"
        echo "Qdrant API key staged"
      fi

      # Radicale CardDAV password (reuse vdirsyncer-johnw radicale credentials)
      RADICALE_PASS_SRC="${config.sops.secrets."vdirsyncer-johnw/radicale-password".path}"
      if [ -f "$RADICALE_PASS_SRC" ]; then
        install -m 0400 -o hermes -g hermes \
          "$RADICALE_PASS_SRC" "${secretsStagingDir}/radicale-password"
        echo "Radicale CardDAV credentials staged"
      fi

      # Home Assistant long-lived access token (mcp-proxy bridge → /api/mcp)
      HA_TOKEN_SRC="${config.sops.secrets."openclaw/home-assistant-token".path}"
      if [ -f "$HA_TOKEN_SRC" ]; then
        install -m 0400 -o hermes -g hermes \
          "$HA_TOKEN_SRC" "${secretsStagingDir}/home-assistant-token"
        echo "Home Assistant token staged"
      fi

      # org PostgreSQL password (read-only role `openclaw`)
      ORG_DB_PASS_SRC="${config.sops.secrets."openclaw/org-db-password".path}"
      if [ -f "$ORG_DB_PASS_SRC" ]; then
        install -m 0400 -o hermes -g hermes \
          "$ORG_DB_PASS_SRC" "${secretsStagingDir}/org-db-password"
        echo "Org database password staged"
      fi

      # Perplexity API key (perplexity-mcp.py wrapper exports it from this file)
      PERPLEXITY_KEY_SRC="${config.sops.secrets."openclaw/perplexity-api-key".path}"
      if [ -f "$PERPLEXITY_KEY_SRC" ]; then
        install -m 0400 -o hermes -g hermes \
          "$PERPLEXITY_KEY_SRC" "${secretsStagingDir}/perplexity-api-key"
        echo "Perplexity API key staged"
      fi



      echo "Hermes secrets staged to ${secretsStagingDir}"
    '';
  };

  # Restart the host's microvm@hermes service whenever models.nix changes,
  # so a `nixos-rebuild switch` propagates new model selections into the
  # running VM without manual intervention.
  systemd.services."microvm@hermes".restartTriggers = [
    (builtins.toJSON { agent = models.llm.reasoning; })
  ];

  # ---- microvm.nix declaration ----
  microvm.vms.hermes = {
    autostart = true;
    config = {
      imports = [ ./hermes-vm.nix ];
      _module.args = {
        inherit
          apiServerPort
          bridgeAddr
          vmAddr
          vmHostname
          hermesUid
          hermesGid
          stateDir
          tapName
          ;
        # Secrets share root (guest mounts this as /run/hermes-secrets) and
        # the comma-joined DNAT port set (guest threads it into its
        # OUTPUT-DNAT rule).
        # Both inherit the single let-block source of truth so the host
        # firewall rules and the guest DNAT can never drift.
        inherit secretsStagingDir dnatPortList;
      };
    };
    specialArgs = { inherit inputs system; };
  };

  # Both the per-VM `autostart = true` (above) and this target list
  # are required by microvm.nix — the former installs the systemd unit
  # link, the latter drives microvms.target boot ordering. Don't
  # consolidate.
  microvm = {
    autostart = [ "hermes" ];
  };
}
