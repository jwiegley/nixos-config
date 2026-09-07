{ pkgs, inputs }:

let
  vhostModules = {
    "services/loki" = "loki";
    "services/grafana" = "grafana";
    "services/qdrant" = "qdrant";
    "services/searxng" = "searxng";
    "services/glances" = "glances";
    "services/aria2" = "aria";
    "services/radicale" = "radicale";
    "services/glance" = "glance";
    "services/atd-nginx" = "atd";
    "services/alertmanager" = "alertmanager";
    "services/immich" = "immich";
    "services/vane" = "vane";
    "services/dns" = "dns";
    "services/gitea" = "gitea";
    "services/promtail" = "promtail";
    "services/vdirsyncer" = "vdirsyncer";
    "services/node-red" = "nodered";
    "services/home-assistant" = "hass";
    "services/media" = "jellyfin";
    "monitoring/services/prometheus-nginx" = "prometheus";
    "monitoring/services/victoriametrics" = "victoriametrics";
  };
  expectedVhosts =
    domain:
    pkgs.lib.mapAttrs (_: subdomain: {
      names = [ "${subdomain}.${domain}" ];
      sslCertificate = "/var/lib/nginx-certs/${subdomain}.${domain}.crt";
      sslCertificateKey = "/var/lib/nginx-certs/${subdomain}.${domain}.key";
    }) vhostModules;
  # Inspect constructor arguments and module declarations, not a complete system.
  capture =
    nixConfig:
    let
      outputs = (import ../flake.nix).outputs (
        inputs
        // {
          nix-config = nixConfig;
          nixpkgs = inputs.nixpkgs // {
            lib = inputs.nixpkgs.lib // {
              nixosSystem = args: args;
            };
          };
        }
      );
      declaration = outputs.nixosConfigurations.vulcan;
      moduleArgs = declaration.specialArgs // {
        inherit pkgs;
        lib = pkgs.lib;
        config.sops.templates."hera-llm-proxy-auth.conf".path = "/fixture-auth-snippet";
        config.services = {
          grist.enable = true;
          node-red.port = 1880;
          prometheus.exporters.blackbox = {
            enable = true;
            port = 9115;
          };
        };
      };
      hostPolicy = declaration.specialArgs.hostPolicy;
      accountModule = import ../modules/users/johnw.nix moduleArgs;
      account = accountModule.users.users.${hostPolicy.username};
      managedHome =
        (
          (import ../modules/users/home-manager/johnw.nix moduleArgs)
          .home-manager.users.${hostPolicy.username}
          {
            inherit pkgs;
            config = { };
            hostname = hostPolicy.hostName;
          }
        ).home;
      remoteNode = builtins.head (builtins.head (
        (import ../modules/monitoring/services/remote-nodes.nix moduleArgs)
        .services.prometheus.scrapeConfigs
      )).static_configs;
      blackbox = (import ../modules/services/blackbox-monitoring.nix moduleArgs).config;
      gateway =
        (import ../modules/services/hera-llm-proxy.nix moduleArgs)
        .services.nginx.virtualHosts.hera-llm-proxy;
      gatewayLocation = gateway.locations."/";
      probeTargets =
        jobName:
        pkgs.lib.concatMap (group: group.targets)
          (pkgs.lib.findFirst (
            job: job.job_name == jobName
          ) (throw "Missing probe ${jobName}") blackbox.services.prometheus.scrapeConfigs).static_configs;
      common = import ../modules/lib/common.nix {
        hostPolicy = declaration.specialArgs.hostPolicy;
        secrets.outPath = "/fixture-secrets";
      };
      networking =
        (import ../modules/core/networking.nix (
          declaration.specialArgs
          // {
            inherit pkgs;
            lib = pkgs.lib;
            config = { };
          }
        )).networking;
    in
    {
      inherit (declaration) system;
      inherit remoteNode;
      account = {
        names = builtins.attrNames accountModule.users.users;
        inherit (account) uid group home;
        gid = accountModule.users.groups.${account.group}.gid;
        inherit (managedHome) username homeDirectory;
      };
      probeHostGroups = blackbox.services.blackbox-monitoring.hostGroups;
      heraProbeTargets = probeTargets "blackbox_hera_qwen";
      dnsProbeTargets = probeTargets "blackbox_dns";
      formatterSystems = builtins.attrNames outputs.formatter;
      inherit (networking) hostId hostName domain;
      hostMappings = networking.hosts;
      gateway = {
        inherit (gateway) listen;
        inherit (gatewayLocation) proxyPass;
        followsHost = pkgs.lib.all (line: pkgs.lib.hasInfix line gatewayLocation.extraConfig) [
          "proxy_ssl_name ${declaration.specialArgs.hostRegistry.hosts.hera.dnsName};"
          "proxy_set_header Host ${declaration.specialArgs.hostRegistry.hosts.hera.dnsName};"
        ];
      };
      certificatePaths = common.nginxSSLPaths "fixture";
      databaseHost = common.postgresDefaults.host;
      vhosts = pkgs.lib.mapAttrs (
        file: subdomain:
        let
          hostPolicy = declaration.specialArgs.hostPolicy;
          module = import (../modules + "/${file}.nix") {
            inherit pkgs hostPolicy;
            lib = pkgs.lib;
            config = { };
          };
          virtualHosts = module.services.nginx.virtualHosts;
          vhost = virtualHosts."${subdomain}.${hostPolicy.dnsName}";
        in
        {
          names = builtins.attrNames virtualHosts;
          inherit (vhost) sslCertificate sslCertificateKey;
        }
      ) vhostModules;
    };
  registry = import "${inputs.nix-config}/config/hosts.nix";
  host = registry.hosts.vulcan;
  heraPlatform = pkgs.lib.systems.elaborate registry.hosts.hera.system;
  baseline = capture inputs.nix-config;
  changed = capture ./fixtures/host-identity;
in
assert
  baseline == {
    inherit (host)
      system
      hostId
      hostName
      domain
      ;
    formatterSystems = [ host.system ];
    account = {
      names = [ host.username ];
      inherit (host)
        uid
        gid
        username
        homeDirectory
        ;
      group = host.username;
      home = host.homeDirectory;
    };
    remoteNode = {
      targets = [ "${registry.hosts.hera.dnsName}:9100" ];
      labels = {
        instance = "hera";
        os = heraPlatform.parsed.kernel.name;
        arch = heraPlatform.uname.processor;
      };
    };
    inherit (registry) probeHostGroups;
    hostMappings = {
      "127.0.0.2" = [ ];
      "${host.ipv4.lan}" = [
        host.dnsName
        host.hostName
      ];
      "${registry.hosts.hera.ipv4.mdns}" = [ registry.hosts.hera.mdnsName ];
    };
    gateway = {
      listen = [
        {
          addr = "127.0.0.1";
          port = registry.inferenceServices.llm-proxy.port;
        }
      ];
      proxyPass = "https://${registry.hosts.hera.dnsName}:${toString registry.inferenceServices.omlx.gatewayPort}";
      followsHost = true;
    };
    heraProbeTargets = [
      "https://${registry.hosts.hera.dnsName}:${toString registry.inferenceServices.omlx.gatewayPort}/v1/models"
    ];
    dnsProbeTargets = [
      registry.networkPeers.router.ipv4.lan
      host.ipv4.lan
      registry.networkPeers.quad9Dns.ipv4.primary
      registry.networkPeers.quad9Dns.ipv4.secondary
      registry.networkPeers.cloudflareDns.ipv4.primary
      registry.networkPeers.cloudflareDns.ipv4.secondary
      registry.networkPeers.openDns.ipv4.primary
      registry.networkPeers.openDns.ipv4.secondary
    ];
    certificatePaths = {
      sslCertificate = "/var/lib/nginx-certs/fixture.${host.dnsName}.crt";
      sslCertificateKey = "/var/lib/nginx-certs/fixture.${host.dnsName}.key";
    };
    databaseHost = host.ipv4.podman;
    vhosts = expectedVhosts host.dnsName;
  };
assert
  changed == {
    system = "x86_64-linux";
    formatterSystems = [ "x86_64-linux" ];
    account = {
      names = [ "probe-user" ];
      username = "probe-user";
      uid = 2100;
      gid = 2190;
      group = "probe-user";
      home = "/fixture-home/vulcan";
      homeDirectory = "/fixture-home/vulcan";
    };
    hostMappings = {
      "127.0.0.2" = [ ];
      "198.51.100.2" = [
        "probe-vulcan.example.invalid"
        "probe-vulcan"
      ];
      "198.51.100.3" = [ "Probe-Hera.local" ];
    };
    gateway = {
      listen = [
        {
          addr = "127.0.0.1";
          port = 4400;
        }
      ];
      proxyPass = "https://probe-hera.example.invalid:9443";
      followsHost = true;
    };
    remoteNode = {
      targets = [ "probe-hera.example.invalid:9100" ];
      labels = {
        instance = "hera";
        os = "linux";
        arch = "x86_64";
      };
    };
    probeHostGroups = {
      local = [ "198.51.100.10" ];
      dns = [ "198.51.100.20" ];
      backbone = [ "probe.example.invalid" ];
      remote = [ "remote.example.invalid" ];
    };
    heraProbeTargets = [ "https://probe-hera.example.invalid:9443/v1/models" ];
    dnsProbeTargets = [
      "198.51.100.254"
      "198.51.100.2"
      "203.0.113.11"
      "203.0.113.12"
      "203.0.113.21"
      "203.0.113.22"
      "203.0.113.31"
      "203.0.113.32"
    ];
    hostId = "0123abcd";
    hostName = "probe-vulcan";
    domain = "example.invalid";
    certificatePaths = {
      sslCertificate = "/var/lib/nginx-certs/fixture.probe-vulcan.example.invalid.crt";
      sslCertificateKey = "/var/lib/nginx-certs/fixture.probe-vulcan.example.invalid.key";
    };
    databaseHost = "198.51.100.1";
    vhosts = expectedVhosts "probe-vulcan.example.invalid";
  };
pkgs.runCommand "vulcan-host-identity" { } ''
  mkdir -p "$out"
  cp ${pkgs.writeText "baseline-identity.json" (builtins.toJSON baseline)} "$out/baseline.json"
  cp ${pkgs.writeText "changed-identity.json" (builtins.toJSON changed)} "$out/changed.json"
''
