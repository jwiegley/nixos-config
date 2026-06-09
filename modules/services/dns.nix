{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Make Technitium's "active" state mean "actually answering on 127.0.0.1:53",
  # and gate nss-lookup.target on it. Previously Technitium was Type=simple with no
  # readiness signal and unordered vs nss-lookup.target, so the target (and every
  # After=nss-lookup.target consumer — notably cloudflared, the sole hard
  # network-online.target consumer) treated DNS as "ready" ~2min before Technitium
  # actually served, causing cloudflared to crash-loop on connection-refused and
  # give up. See docs/BOOT_SWITCH_ROBUSTNESS_AUDIT.md (cold-boot DNS race).
  # NOTE: this intentionally delays nss-lookup.target (and its consumers) at boot
  # until DNS truly answers — correctness over boot speed on this server.
  systemd.services.technitium-dns-server = {
    before = [ "nss-lookup.target" ];
    wantedBy = [ "nss-lookup.target" ];
    serviceConfig = {
      WorkingDirectory = lib.mkForce null;
      BindPaths = lib.mkForce null;
      # Block activation until the resolver answers a query (bounded). dig exits 0
      # as soon as Technitium returns ANY response (incl. NXDOMAIN), i.e. it is
      # serving; it exits non-zero on connection-refused/no-reply. Cold boots have
      # been observed taking ~110-120s before :53 served.
      ExecStartPost = pkgs.writeShellScript "technitium-wait-ready" ''
        for _ in $(seq 1 200); do
          ${pkgs.dnsutils}/bin/dig +short +timeout=1 +tries=1 @127.0.0.1 vulcan.lan A >/dev/null 2>&1 && exit 0
          sleep 1
        done
        echo "technitium-wait-ready: resolver did not answer within ~200s" >&2
        exit 1
      '';
      # Room for the readiness probe beyond Technitium's own startup.
      TimeoutStartSec = lib.mkForce 300;
    };
  };

  services.technitium-dns-server = {
    enable = true;
    openFirewall = false;
  };

  services.nginx.virtualHosts."dns.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/dns.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/dns.vulcan.lan.key";
    locations."/" = {
      proxyPass = "http://127.0.0.1:5380/";
      proxyWebsockets = true;
    };
  };

  networking.firewall = {
    allowedTCPPorts = lib.mkIf config.services.technitium-dns-server.enable [
      53
      853
    ];
    allowedUDPPorts = lib.mkIf config.services.technitium-dns-server.enable [ 53 ];
  };
}
