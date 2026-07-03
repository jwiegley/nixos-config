# Explicit default servers for nginx (2026-07-03 post-reboot audit).
#
# Without a default :443 server, nginx routes HTTPS requests for any hostname
# that matches no server_name to the alphabetically-first ssl server block —
# which happened to be the Alertmanager UI (observed live: curl for the
# orphaned copyparty.vulcan.lan name landed on Alertmanager). rejectSSL uses
# ssl_reject_handshake, so no certificate is presented and the TLS handshake
# is aborted outright; unmatched plain-HTTP requests get 444 (connection
# closed without response).
{ ... }:

{
  services.nginx.virtualHosts."_default" = {
    default = true;
    rejectSSL = true;
    locations."/".return = "444";
  };
}
