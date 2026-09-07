{
  hosts.vulcan = {
    system = "x86_64-linux";
    hostName = "probe-vulcan";
    domain = "example.invalid";
    dnsName = "probe-vulcan.example.invalid";
    username = "probe-user";
    uid = 2100;
    gid = 2190;
    homeDirectory = "/fixture-home/vulcan";
    ipv4 = {
      lan = "198.51.100.2";
      podman = "198.51.100.1";
    };
    hostId = "0123abcd";
  };
  hosts.hera = {
    system = "x86_64-linux";
    dnsName = "probe-hera.example.invalid";
    mdnsName = "Probe-Hera.local";
    ipv4.mdns = "198.51.100.3";
  };
  networkPeers.router.ipv4.lan = "198.51.100.254";
  networkPeers.quad9Dns.ipv4 = {
    primary = "203.0.113.11";
    secondary = "203.0.113.12";
  };
  networkPeers.cloudflareDns.ipv4 = {
    primary = "203.0.113.21";
    secondary = "203.0.113.22";
  };
  networkPeers.openDns.ipv4 = {
    primary = "203.0.113.31";
    secondary = "203.0.113.32";
  };
  inferenceServices.omlx.gatewayPort = 9443;
  inferenceServices.llm-proxy.port = 4400;
  probeHostGroups = {
    local = [ "198.51.100.10" ];
    dns = [ "198.51.100.20" ];
    backbone = [ "probe.example.invalid" ];
    remote = [ "remote.example.invalid" ];
  };
}
