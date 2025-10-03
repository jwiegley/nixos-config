{ config, lib, pkgs, ... }:

let
  transformerScript = pkgs.writeScriptBin "opnsense-api-transformer" ''
    #!${pkgs.python3}/bin/python3
    """
    OPNsense API Response Transformer

    A simple HTTP proxy that transforms OPNsense API responses to fix
    type mismatches in the opnsense-exporter.

    Specifically fixes: monitor_disable field from boolean to string
    """

    from http.server import HTTPServer, BaseHTTPRequestHandler
    import json
    import urllib.request
    import urllib.error
    import ssl
    import sys

    TARGET_HOST = "192.168.1.1"
    TARGET_PORT = 443
    LISTEN_PORT = 8444

    class TransformingProxy(BaseHTTPRequestHandler):
        def do_GET(self):
            self.proxy_request()

        def do_POST(self):
            self.proxy_request()

        def proxy_request(self):
            # Build target URL
            target_url = f"https://{TARGET_HOST}:{TARGET_PORT}{self.path}"

            # Get request body if present
            content_length = self.headers.get('Content-Length')
            body = None
            if content_length:
                body = self.rfile.read(int(content_length))

            # Create SSL context that doesn't verify certificates (internal network)
            ssl_context = ssl.create_default_context()
            ssl_context.check_hostname = False
            ssl_context.verify_mode = ssl.CERT_NONE

            try:
                # Build request
                req = urllib.request.Request(target_url, data=body)

                # Copy headers (excluding Host and Content-Length)
                for header, value in self.headers.items():
                    if header.lower() not in ['host', 'content-length']:
                        req.add_header(header, value)

                # Make the request
                with urllib.request.urlopen(req, context=ssl_context) as response:
                    # Read response
                    response_body = response.read()

                    # Transform response if it's the gateway endpoint
                    if '/api/routing/settings/searchGateway' in self.path:
                        try:
                            data = json.loads(response_body)
                            if 'rows' in data:
                                for row in data['rows']:
                                    # Convert boolean monitor_disable to string
                                    if 'monitor_disable' in row and isinstance(row['monitor_disable'], bool):
                                        row['monitor_disable'] = str(row['monitor_disable']).lower()
                                    # Convert numeric priority to string
                                    if 'priority' in row and isinstance(row['priority'], (int, float)):
                                        row['priority'] = str(row['priority'])
                            response_body = json.dumps(data).encode()
                        except (json.JSONDecodeError, KeyError):
                            pass  # If we can't parse, just pass through unchanged

                    # Send response
                    self.send_response(response.getcode())
                    for header, value in response.headers.items():
                        if header.lower() != 'content-length':
                            self.send_header(header, value)
                    self.send_header('Content-Length', str(len(response_body)))
                    self.end_headers()
                    self.wfile.write(response_body)

            except urllib.error.HTTPError as e:
                self.send_response(e.code)
                self.end_headers()
                self.wfile.write(e.read())
            except Exception as e:
                self.send_response(502)
                self.end_headers()
                self.wfile.write(f"Proxy error: {str(e)}".encode())

        def log_message(self, format, *args):
            # Suppress default logging
            pass

    if __name__ == "__main__":
        server = HTTPServer(('0.0.0.0', LISTEN_PORT), TransformingProxy)
        print(f"OPNsense API Transformer listening on port {LISTEN_PORT}", flush=True)
        print(f"Proxying to https://{TARGET_HOST}:{TARGET_PORT}", flush=True)
        server.serve_forever()
  '';
in
{
  # OPNsense API Transformer Service
  #
  # This is a workaround for issue #70 in opnsense-exporter v0.0.11:
  # https://github.com/AthennaMind/opnsense-exporter/issues/70
  #
  # The OPNsense API returns monitor_disable as a boolean, but the exporter
  # expects it as a string. This proxy transforms the response before it
  # reaches the exporter.

  systemd.services.opnsense-api-transformer = {
    description = "OPNsense API Response Transformer Proxy";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${transformerScript}/bin/opnsense-api-transformer";
      Restart = "always";
      RestartSec = "10s";
      User = "nobody";
      Group = "nogroup";

      # Security hardening
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;

      # Capabilities
      AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
      CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
    };
  };

  # Open firewall ports for the transformer
  networking.firewall.interfaces = {
    lo.allowedTCPPorts = [ 8444 ];
    podman0.allowedTCPPorts = [ 8444 ];  # Allow containers to access the transformer
  };
}