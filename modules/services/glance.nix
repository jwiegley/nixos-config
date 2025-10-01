{ config, lib, pkgs, ... }:
with lib;

{
  # Enable the glance service using the NixOS module
  services.glance = {
    enable = true;

    # Configure glance settings
    settings = {
      server = {
        host = "127.0.0.1";
        port = 3050;
      };

      theme = {
        background-color = "240 21 15";
        primary-color = "217 78 84";
        positive-color = "115 54 76";
        negative-color = "347 70 65";
      };

      pages = [
        {
          name = "Home";
          columns = [
            {
              size = "small";
              widgets = [
                {
                  type = "monitor";
                  cache = "1m";
                  title = "System";
                  metrics = [
                    {
                      label = "CPU";
                      query = "cpu";
                    }
                    {
                      label = "Memory";
                      query = "memory";
                    }
                    {
                      label = "Disk /";
                      query = "disk:/";
                    }
                  ];
                }
                {
                  type = "weather";
                  location = "Sacramento, US";
                  units = "imperial";
                  cache = "15m";
                }
                {
                  type = "markets";
                  markets = [
                    {
                      symbol = "SPY";
                      name = "S&P 500";
                    }
                    {
                      symbol = "COIN";
                      name = "Coinbase";
                    }
                    {
                      symbol = "AAPL";
                      name = "Apple";
                    }
                  ];
                  cache = "15m";
                }
              ];
            }

            {
              size = "full";
              widgets = [
                # GitHub Notifications (using extension widget)
                {
                  type = "extension";
                  title = "GitHub Inbox";
                  subtitle = "jwiegley";
                  url = "http://127.0.0.1:8082/github-notifications";
                  cache = "5m";
                  allow-potentially-dangerous-html = true;
                }

                # XDA-Developers RSS Feed
                {
                  type = "rss";
                  title = "XDA-Developers";
                  cache = "30m";
                  limit = 15;
                  collapse-after = 5;
                  feeds = [
                    {
                      url = "https://www.xda-developers.com/feed/";
                      title = "XDA Latest";
                    }
                  ];
                }

                # Google News Feed
                {
                  type = "rss";
                  title = "Google News - John Wiegley";
                  cache = "30m";
                  limit = 10;
                  collapse-after = 5;
                  feeds = [
                    {
                      url = "https://news.google.com/rss/search?q=john+wiegley&hl=en-US&gl=US&ceid=US:en";
                      title = "News";
                    }
                  ];
                }

                # Reddit New Posts
                {
                  type = "reddit";
                  subreddit = "all";
                  show-thumbnails = true;
                  limit = 20;
                  collapse-after = 8;
                  sort-by = "new";
                  cache = "10m";
                }
              ];
            }

            {
              size = "small";
              widgets = [
                {
                  type = "bookmarks";
                  groups = [
                    {
                      title = "Services";
                      color = "10 70 50";
                      links = [
                        {
                          title = "Grafana";
                          url = "https://grafana.vulcan.lan";
                        }
                        {
                          title = "PostgreSQL";
                          url = "https://postgres.vulcan.lan";
                        }
                        {
                          title = "Alertmanager";
                          url = "https://alertmanager.vulcan.lan";
                        }
                        {
                          title = "Jellyfin";
                          url = "https://jellyfin.vulcan.lan";
                        }
                      ];
                    }
                    {
                      title = "Development";
                      color = "200 50 50";
                      links = [
                        {
                          title = "GitHub";
                          url = "https://github.com/jwiegley";
                        }
                        {
                          title = "NixOS Search";
                          url = "https://search.nixos.org";
                        }
                        {
                          title = "Reddit";
                          url = "https://old.reddit.com";
                        }
                        {
                          title = "XDA Forums";
                          url = "https://forum.xda-developers.com";
                        }
                      ];
                    }
                  ];
                }
              ];
            }
          ];
        }
      ];
    };
  };

  # Import SOPS secrets (optional - will be added later)
  # Commented out until secrets are added to secrets.yaml
  sops.secrets = {
    glance_github_token = {
      sopsFile = ../../secrets.yaml;
      mode = "0400";
      owner = "glance";
      group = "glance";
      restartUnits = [ "glance.service" ];
    };
    # glance_reddit_client_id = {
    #   mode = "0400";
    #   owner = "glance";
    # };
    # glance_reddit_client_secret = {
    #   mode = "0400";
    #   owner = "glance";
    # };
  };

  # GitHub extension service
  systemd.services.glance-github-extension = {
    description = "Glance GitHub Extension Service";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    path = with pkgs; [ coreutils ];

    serviceConfig = {
      Type = "simple";
      User = "glance";
      Group = "glance";
      Restart = "always";
      RestartSec = 5;

      ExecStart = let
        githubExtensionScript = pkgs.writeScript "glance-github-server.py" ''
          #!/usr/bin/env ${pkgs.python3}/bin/python3

          import http.server
          import socketserver
          import json
          import urllib.request
          import urllib.error
          import os
          from datetime import datetime

          # Read GitHub token from environment or file
          github_token = None
          # Token file will be configured once secrets are added to secrets.yaml
          token_file = "/run/secrets/glance_github_token"

          try:
              if os.path.exists(token_file):
                  with open(token_file, 'r') as f:
                      github_token = f.read().strip()
          except Exception as e:
              print(f"Warning: Could not read GitHub token: {e}")

          if not github_token:
              github_token = "placeholder_token"
              print("Warning: GitHub token not configured. Using placeholder...")

          class GitHubHandler(http.server.BaseHTTPRequestHandler):
              def do_GET(self):
                  if self.path == '/github-notifications':
                      try:
                          if github_token == 'placeholder_token':
                              html = '<div class="glance-github-notifications">'
                              html += '<p style="color: orange;">⚠️ GitHub token not configured yet.</p>'
                              html += '<p>Please add <code>glance_github_token</code> to secrets.yaml</p>'
                              html += '</div>'
                          else:
                              req = urllib.request.Request(
                                  'https://api.github.com/notifications',
                                  headers={
                                      'Accept': 'application/vnd.github+json',
                                      'Authorization': f'Bearer {github_token}',
                                      'X-GitHub-Api-Version': '2022-11-28'
                                  }
                              )

                              with urllib.request.urlopen(req) as response:
                                  data = json.loads(response.read())

                              # Format as HTML for Glance
                              html = '<div class="glance-github-notifications">'
                              if not data:
                                  html += '<p style="color: green;">✓ No new notifications</p>'
                              else:
                                  html += f'<p><a href="https://github.com/notifications" target="_blank" style="color: inherit; text-decoration: none;"><strong>{len(data)} notification(s)</strong></a></p>'
                                  html += '<ul style="list-style-type: none; padding-left: 0;">'
                                  for notif in data[:10]:  # Limit to 10 notifications
                                      reason = notif.get('reason', ''').replace('_', ' ').title()
                                      repo = notif.get('repository', {}).get('name', 'Unknown')
                                      repo_full = notif.get('repository', {}).get('full_name', ''')
                                      title = notif.get('subject', {}).get('title', 'No title')
                                      subject_type = notif.get('subject', {}).get('type', ''')
                                      url = notif.get('subject', {}).get('url', ''')
                                      latest_comment_url = notif.get('subject', {}).get('latest_comment_url', ''')
                                      unread = notif.get('unread', False)

                                      # Build web URL from API URL or use latest comment URL as fallback
                                      web_url = '''
                                      if url:
                                          # Convert API URL to web URL
                                          web_url = url.replace('https://api.github.com/repos/', 'https://github.com/')
                                          if '/pulls/' in web_url:
                                              web_url = web_url.replace('/pulls/', '/pull/')
                                      elif latest_comment_url:
                                          # Use latest comment URL as fallback
                                          web_url = latest_comment_url.replace('https://api.github.com/repos/', 'https://github.com/')

                                      # If still no URL, construct based on type and repository
                                      if not web_url and repo_full:
                                          if subject_type == 'Release':
                                              web_url = f"https://github.com/{repo_full}/releases"
                                          elif subject_type == 'RepositoryInvitation':
                                              web_url = f"https://github.com/{repo_full}/invitations"
                                          else:
                                              # Default to notifications page filtered by repo
                                              web_url = f"https://github.com/notifications?query=repo%3A{repo_full.replace('/', '%2F')}"

                                      # Format notification - make entire item clickable
                                      unread_marker = '●' if unread else '○'
                                      html += f'<li style="margin-bottom: 8px;">'
                                      if web_url:
                                          html += f'<a href="{web_url}" target="_blank" style="color: inherit; text-decoration: none; display: block;">'
                                          html += f'{unread_marker} <strong>[{repo}]</strong> '
                                          html += f'<span style="color: #4a9eff; text-decoration: underline;">{title}</span>'
                                          html += f' <small style="color: #888;">({reason})</small>'
                                          html += f'</a>'
                                      else:
                                          html += f'{unread_marker} <strong>[{repo}]</strong> {title}'
                                          html += f' <small style="color: #888;">({reason})</small>'
                                      html += f'</li>'
                                  html += '</ul>'
                              html += '</div>'

                          self.send_response(200)
                          self.send_header('Content-Type', 'text/html; charset=utf-8')
                          self.send_header('Widget-Content-Type', 'html')
                          self.send_header('Access-Control-Allow-Origin', '*')
                          self.end_headers()
                          self.wfile.write(html.encode())

                      except urllib.error.HTTPError as e:
                          if e.code == 401:
                              html = '<div class="glance-github-notifications">'
                              html += '<p style="color: red;">❌ Authentication failed</p>'
                              html += '<p>Please check your GitHub token in secrets.yaml</p>'
                              html += '</div>'
                          else:
                              html = f'<p style="color: red;">Error: {e}</p>'

                          self.send_response(200)
                          self.send_header('Content-Type', 'text/html')
                          self.send_header('Widget-Content-Type', 'html')
                          self.send_header('Access-Control-Allow-Origin', '*')
                          self.end_headers()
                          self.wfile.write(html.encode())

                      except Exception as e:
                          self.send_response(200)
                          self.send_header('Content-Type', 'text/html')
                          self.send_header('Widget-Content-Type', 'html')
                          self.send_header('Access-Control-Allow-Origin', '*')
                          self.end_headers()
                          self.wfile.write(f'<p style="color: red;">Error: {e}</p>'.encode())
                  else:
                      self.send_response(404)
                      self.end_headers()

              def log_message(self, format, *args):
                  pass  # Suppress request logging

          with socketserver.TCPServer(('127.0.0.1', 8082), GitHubHandler) as httpd:
              print('GitHub extension service running on port 8082')
              httpd.serve_forever()
        '';
      in "${githubExtensionScript}";
    };
  };

  # Nginx reverse proxy configuration
  services.nginx.virtualHosts."glance.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/var/lib/nginx-certs/glance.vulcan.lan.crt";
    sslCertificateKey = "/var/lib/nginx-certs/glance.vulcan.lan.key";

    locations."/" = {
      proxyPass = "http://127.0.0.1:3050/";
      recommendedProxySettings = true;
    };
  };

  networking.firewall.interfaces."lo".allowedTCPPorts = [ 3050 8082 ];
}
