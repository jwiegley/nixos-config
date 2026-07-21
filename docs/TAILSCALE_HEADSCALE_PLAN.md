# Tailscale and Headscale on vulcan and OPNsense — Analysis and Deployment Runbook

**Host:** vulcan (aarch64, NixOS, Asahi) · **Gateway:** OPNsense at `192.168.1.1` · **Server:** vulcan at `192.168.1.2` · **LAN:** `192.168.1.0/24`
**Author of record:** prepared for John Wiegley
**Date:** 2026-07-11
**Status:** design accepted; not yet implemented

---

## About this document

This document serves two purposes in sequence. Part I weighs the merits and costs of building a Tailscale mesh coordinated by a self-hosted Headscale control server against the alternatives already in service — the WireGuard instance on OPNsense and the Cloudflare tunnels on vulcan — and records the architecture chosen and why. Part II is the build itself: an ordered runbook that stands up the control server on vulcan, turns OPNsense into the network's entry point, enrolls every class of client device, and establishes the DNS, certificate, resilience, and monitoring properties that make the result trustworthy in daily use.

The reader is assumed competent with NixOS, OPNsense, and the existing services on this host; the prose therefore explains the reasoning behind each decision rather than the underlying tools.

### A note on volatile facts

Headscale and the OPNsense Tailscale plugin change their configuration keys, command syntax, and feature limits between releases more often than most software, and the client applications rearrange their interfaces from version to version. Every version number, configuration-key name, command sub-verb, and interface path below carries a light attribution and was checked on **2026-07-11**; each is marked where it is known to drift. Confirm the particulars against the current upstream documentation for the exact versions you install before relying on them — the durable grounding (the architecture, the trust model, the resilience reasoning) holds regardless, but the mechanical particulars must be reconfirmed. The canonical sources are the Headscale documentation (`headscale.net/stable`), the Tailscale knowledge base (`tailscale.com/kb`), the OPNsense plugin documentation, and the `services.headscale` module in nixpkgs (`search.nixos.org`).

### Contents

- Part I — Analysis
  - 1. How the pieces fit together
  - 2. The chosen architecture
  - 3. Pros and cons: Tailscale as the mesh technology
  - 4. Pros and cons: Headscale versus the Tailscale SaaS control plane
  - 5. Pros and cons: the control server on vulcan
  - 6. Pros and cons: OPNsense as the network's entry point
  - 7. This design against what you already run
  - 8. The resilience model — what survives a vulcan outage
- Part II — Deployment runbook
  - Phase 0. Prerequisites and decisions
  - Phase 1. Headscale on vulcan
  - Phase 2. Users and pre-authentication keys
  - Phase 3. OPNsense as subnet router and exit node
  - Phase 4. Enrolling your own devices
  - Phase 5. Split-DNS and certificates
  - Phase 6. The exit node (optional)
  - Phase 7. Friends' scoped access
  - Phase 8. Durability — non-expiring keys and the WireGuard fallback
  - Phase 9. Monitoring and backup
  - Phase 10. Verification and acceptance
- Operations and maintenance
- Troubleshooting
- Appendices — reference configuration, command cheat-sheet, sources

---

# Part I — Analysis

## 1. How the pieces fit together

Tailscale is a mesh VPN built on WireGuard (Tailscale documentation, checked 2026-07-11). Two separable layers compose it, and holding them apart is the key to every decision that follows.

The **control plane** is the coordination server. It authenticates devices, assigns each a stable address in the `100.64.0.0/10` range, distributes the public keys and network map that let peers find one another, and enforces access policy. It is consulted when a device logs in and when configuration changes; it does not sit in the data path. Headscale is an open-source, self-hosted implementation of exactly this server (Headscale documentation, `headscale.net/stable`), deliberately scoped to a single network for personal or small-group use.

The **data plane** is the set of WireGuard tunnels themselves, negotiated directly between peers. Where two peers cannot open a direct path through their respective NATs, traffic falls back to a **DERP relay** (Designated Encrypted Relay for Packets), an encrypted TCP relay that carries packets the peers cannot exchange directly. A **subnet router** is a data-plane node that advertises a LAN prefix so that remote peers reach devices which do not themselves run Tailscale; an **exit node** is a data-plane node that offers itself as a full-tunnel internet gateway.

The consequence of this separation is the property the whole design rests on: Tailscale tolerates a control-plane outage. Nodes cache their network map and continue to connect over existing keys when the coordination server is unreachable; only new enrollments and key re-authentications require the server to be up (Tailscale documentation, checked 2026-07-11). This is what allows the control server and the network's entry point to live on different machines with different availability, and it is examined in full in Section 8.

## 2. The chosen architecture

The design places each responsibility on the host best suited to hold it.

```
                          Internet
                             │
                   (WAN 443/tcp DNAT)         (Tailscale 41641/udp)
                             │                          │
                    ┌────────┴──────────────────────────┴────────┐
                    │            OPNsense  192.168.1.1            │
                    │  • Subnet router: advertises 192.168.1.0/24 │
                    │  • Exit node (optional, full-tunnel)        │
                    │  • Existing WireGuard — retained, break-glass│
                    │  • Port-forward WAN:443 → 192.168.1.2:8442  │
                    └────────┬────────────────────────────────────┘
                             │  LAN 192.168.1.0/24
                    ┌────────┴────────────────────────────────────┐
                    │             vulcan  192.168.1.2             │
                    │  • Headscale control server  :8442 (TLS)    │
                    │  • Metrics :9089 → Prometheus               │
                    │  • Technitium DNS (.lan authority)          │
                    │  • step-ca, nginx, Cloudflare tunnels       │
                    └─────────────────────────────────────────────┘

  Clients (laptops, phones, tablets, friends) run the Tailscale app,
  pointed at login server https://headscale.newartisans.com,
  reaching the LAN through the OPNsense subnet router.
```

- **Control plane:** Headscale runs on vulcan through the `services.headscale` NixOS module, listening on `8442`, terminating its own TLS with a publicly-trusted certificate obtained by `security.acme` via a Cloudflare DNS-01 challenge, and published to the internet by a single OPNsense port-forward from `WAN:443`. Trusted devices are set not to expire.
- **Data-plane entry:** OPNsense is the subnet router for `192.168.1.0/24` and, at your option, the exit node, installed through the `os-tailscale` plugin. This keeps networking on the gateway, where your WireGuard already lives, and keeps the way into the house independent of vulcan's health.
- **Break-glass:** the existing OPNsense WireGuard remains in place, untouched, depending on neither vulcan nor Headscale.
- **Clients:** the standard Tailscale application on each device, pointed at the Headscale login server; friends are onboarded as scoped users constrained by policy.
- **DNS and certificates:** split-DNS resolves `*.vulcan.lan` over the tunnel to `192.168.1.2`, so the existing step-ca certificates continue to validate remotely.
- **Public web services** remain on the Cloudflare tunnels; the tailnet carries private, authenticated access only.

The rationale for each placement is the subject of the sections that follow.

## 3. Pros and cons: Tailscale as the mesh technology

The prior question is whether a coordinated WireGuard mesh earns its place beside plain WireGuard at all. For a single point-to-point tunnel it does not; its value appears as the number of devices and the variety of networks grow.

**In favor.** Tailscale removes the manual key and endpoint bookkeeping that plain WireGuard demands: each device is configured once, and the coordination server thereafter distributes keys and tracks changing addresses, so a laptop that moves between home, office, and cellular networks stays reachable without edited configuration (Tailscale documentation, checked 2026-07-11). It traverses NAT without inbound port-forwarding on the client side, connecting even from networks that block non-standard ports — the failure mode that collapses hand-rolled tunnels on hostile Wi-Fi (MakeUseOf, "I Finally Tried Tailscale", 2026). It assigns every device a stable `100.x` address regardless of location, and, with MagicDNS, resolvable names. The data path remains WireGuard, so the cryptography and throughput are those of WireGuard, not a heavier overlay.

**Against.** The mesh introduces a coordination server as a new component to run and secure — the very component this document is largely about. It is more moving parts than a single WireGuard tunnel, and for a threat model that distrusts the userspace Tailscale daemon or its NAT-traversal machinery, plain WireGuard is the smaller, more auditable surface. The endpoint-dependent NAT that firewalls such as OPNsense perform can defeat direct connections and force traffic onto DERP relays, adding latency (Tailscale documentation; OPNsense forum thread 46938). None of these outweighs the operational relief across many devices, but they are the price of it.

## 4. Pros and cons: Headscale versus the Tailscale SaaS control plane

Given a mesh, the control plane may be Tailscale's hosted service or a self-hosted Headscale. The two differ chiefly in who holds the coordination data and who guarantees its availability.

**Headscale — in favor.** The coordination server, and with it the record of which devices exist and how your network is shaped, stays on your hardware; no third party learns your device topology (Headscale documentation, checked 2026-07-11). It is free of per-seat cost and of the SaaS tier limits. On NixOS it is declarative: the control plane becomes configuration in this repository, versioned with the system and rolled back by selecting a prior generation. It is coherent with the rest of your posture — step-ca, Technitium, and the self-hosted services already here.

**Headscale — against.** You now operate the control plane: you patch it, you back up its database, and its availability is yours to guarantee rather than a provider's. Headscale implements a single network only; it has no multi-tenant model, and — consequential for friends — it lacks the SaaS feature that shares a single node across separate tailnets, so friends become users *within* your network rather than guests from their own (Section 7). Its configuration keys and commands drift between releases more than most software, so upgrades demand attention. Being self-hosted behind your gateway, it must be published to the internet to be reachable, which the SaaS never requires.

**Tailscale SaaS — in favor.** The control plane is operated for you and is effectively always available, so enrolling and re-authenticating devices never depends on your own hardware being up — the property most relevant to your resilience concern (Section 8). Setup is faster, and the node-sharing and access-control features are more mature.

**Tailscale SaaS — against.** The coordination server is Tailscale's; it learns your device topology, though not your traffic content, and its availability and terms are outside your control. The free tier bounds you to three users and one hundred devices (Tailscale documentation, checked 2026-07-11; a volatile figure).

**The decision.** Headscale is chosen, for the self-hosting and privacy reasons above. The one place this trades against the resilience goal — that a self-hosted control plane is only as available as the machine hosting it — is addressed directly in Section 8 rather than waved away.

## 5. Pros and cons: the control server on vulcan

With Headscale chosen, the control server may run on vulcan or on the OPNsense gateway. These are weighed in full because the question recurs. The short of it: the *control server* belongs on vulcan; the *entry point* belongs on OPNsense (Section 6); the two are different roles and need not share a host.

**vulcan — in favor.** Nixpkgs ships a first-class `services.headscale` module, so the control plane is declarative and reproducible. Headscale's state — SQLite by default, or PostgreSQL — sits on a host already covered by the nightly database backup and ZFS snapshots. Its metrics endpoint is scrapeable by the Prometheus and Grafana already watching this box. Its lifecycle is decoupled from the firewall: it is updated, restarted, and rolled back without touching routing for the house, and a fault in it cannot degrade packet forwarding. Placing the self-hosted brain on the declarative, observed, backed-up hub is the coherent expression of the decision to self-host it.

**vulcan — against.** Sitting behind OPNsense, it must be published to the internet through a port-forward and a certificate — a one-time piece of plumbing, detailed in Phase 1, rather than a recurring fragility. A LAN device resolving the public control-server name from inside the network must be handled so it does not attempt to reach your own WAN address in a loop; a local DNS override answers this (the "routing loop during authentication" the Gurucomputing guide names). And the control plane is only as available as vulcan — the consideration Section 8 exists to resolve.

**OPNsense — in favor.** It already holds the public WAN address, so a control server there is reachable from the internet with a firewall rule and a certificate, and no port-forward.

**OPNsense — against, and heavily.** There is no first-class Headscale package for OPNsense; you would run an unpackaged FreeBSD binary maintained by hand, or force a container onto an appliance with no supported container story, against the maintainers' own advice on containers and reverse proxies (Headscale documentation, checked 2026-07-11). It couples the coordination plane to the firewall's upgrade and reboot cycle — the same cycle in which the forum already documents Tailscale reboot re-authentication and a FreeBSD restart race (OPNsense forum thread 46938). It places a stateful, internet-facing web service on the single most critical box on the network, enlarging both its attack surface and its blast radius, with none of vulcan's backup, monitoring, or configuration-as-code around it.

**The decision.** The control server runs on vulcan. OPNsense's lone advantage, edge reachability, is bought back cheaply with a port-forward and a certificate; running the server on the firewall trades away packaging, backups, observability, and a clean failure domain for it.

## 6. Pros and cons: OPNsense as the network's entry point

The data-plane entry point — the subnet router, and the exit node if used — is a distinct role from the control server, and the resilience logic points to a different host for it.

**OPNsense — in favor.** The governing principle is that the recovery path must not run through the box being recovered: if vulcan is both the data server and the only way in, then a failed vulcan locks you out of the network you need in order to repair it. An entry point on OPNsense keeps the door open when vulcan is down — you reach the router, reach other devices, inspect and even power-cycle vulcan. It also matches where your networking already lives, since your WireGuard runs on OPNsense, and the two coexist on different ports (Tailscale defaults to `41641/udp`). The gateway is the natural, always-on place for the network's front door.

**OPNsense — against.** The `os-tailscale` plugin is community-supported, not maintained by Tailscale, and the forum records concrete faults: re-authentication required after some reboots, and a FreeBSD `tailscaled` restart race that has broken DNS for clients using the box as an exit node (OPNsense forum thread 46938). The firewall's endpoint-dependent NAT makes direct peer connections harder and pushes traffic onto DERP more often; mitigations exist (static outbound NAT with port randomization, or NAT-PMP) but add configuration (Tailscale documentation; computingforgeeks, "Tailscale client on OPNsense"). OPNsense does not assign the Tailscale interface automatically, so inbound tailnet traffic to the box is dropped until the interface is assigned and a pass rule added — a step that is easy to miss (Tailscale documentation, checked 2026-07-11).

**The alternative considered.** Running the subnet router on vulcan instead would avoid the plugin's fragility and would be declarative, and Tailscale's `100.64.0.0/10` range does not collide with vulcan's existing policy routing. It was set aside because it violates the recovery-path principle and departs from your router-centric preference; the plugin's faults are real but are the lesser risk, and the retained WireGuard sits beneath the plugin as a fallback in any case.

**The decision.** OPNsense is the subnet router and exit node. Its faults are mitigated in Phase 3 and bounded by the WireGuard fallback in Phase 8.

## 7. This design against what you already run

The tailnet neither replaces nor is replaced by the two remote-access mechanisms already in service; each keeps the work it does best.

The **Cloudflare tunnels** publish specific web services to the *public* over HTTPS — the `data` and `rsync` hostnames — with the edge terminating TLS and no inbound port opened for them. The tailnet, by contrast, grants *your authenticated devices* private access to the whole LAN on any port and protocol. The benefit of keeping both is that public consumers stay on Cloudflare while your own administrative reach moves onto the tailnet; the trade-off is two systems to understand, resolved by the simple rule that anything a stranger may use belongs on Cloudflare and anything only you and yours may use belongs on the tailnet.

The **OPNsense WireGuard** overlaps the tailnet's purpose — private remote access — but is retained deliberately, not redundantly. It depends on neither vulcan nor Headscale, and so remains the entry that works when both are down. The tailnet becomes the everyday driver for its convenience across many devices and networks; WireGuard becomes the break-glass path held in reserve. Some independent way in is better than none, and this one costs nothing to keep.

A consolidated view:

| Mechanism | Reaches | Who may use it | Depends on | Best kept for |
|---|---|---|---|---|
| Cloudflare tunnels | Chosen web services | The public (unless gated) | vulcan + Cloudflare | Public HTTPS services |
| Tailnet (Tailscale + Headscale) | Whole LAN, any port | Your authenticated devices and scoped friends | OPNsense (entry) + vulcan (enrollment only) | Daily private access |
| OPNsense WireGuard | Whole LAN | You, by static config | OPNsense alone | Break-glass when vulcan is down |

## 8. The resilience model — what survives a vulcan outage

Because this concern drove the architecture, it deserves an exact accounting rather than reassurance. Consider the design in force — entry point on OPNsense, control server on vulcan — and ask what works while vulcan is unreachable.

An **already-enrolled device keeps working.** Its cached network map and existing keys let it connect to the OPNsense subnet router directly or over DERP, so a laptop abroad still reaches the LAN through the gateway even though the Headscale brain is dark (Tailscale documentation, checked 2026-07-11). The scenario that motivated the design is therefore satisfied for every device you have already set up.

What does *not* work during the outage is **new enrollment and re-authentication**: adding a device never before seen, or one whose key has just expired, needs the control server. Two levers narrow this gap, and a third closes it:

1. **Disable key expiry on trusted devices**, so an established device never again needs the control plane merely to keep functioning (Phase 8). This reduces the exposure to the single case of enrolling a brand-new device at the exact moment vulcan is down.
2. **Keep the OPNsense WireGuard as break-glass** (Section 7), an entry that depends on neither vulcan nor Headscale.
3. **If even new-device enrollment must survive a vulcan outage**, move the control plane off vulcan — a small VPS running Headscale, or the Tailscale SaaS. This is the one point at which the self-hosting goal and the maximal-resilience goal genuinely diverge; levers 1 and 2 resolve it for all practical purposes without surrendering self-hosting, and lever 3 remains available should the residual case ever matter.

One corollary shapes Phase 1: **do not self-host the DERP relay on vulcan.** Rely on Tailscale's public DERP mesh, or place a relay on OPNsense or a VPS, so that a vulcan outage does not also remove the relay that established peers fall back to. The recovery path, once more, must not run through the box being recovered.

---

# Part II — Deployment runbook

The phases are ordered so that the system is testable at each boundary. Stand up and verify the control server before creating keys; create keys before enrolling the router; enroll and verify the router before the client devices depend on it. Each phase states its purpose, then its steps; volatile particulars are flagged for reconfirmation.

Throughout, the example public control-server name is `headscale.newartisans.com` and the example MagicDNS base domain is `tailnet.newartisans.com`; substitute your own, keeping the two distinct (Headscale requires the base domain not to overlap the server-URL host; Headscale DNS reference, checked 2026-07-11).

## Phase 0. Prerequisites and decisions

**Purpose.** Settle the few facts the later phases consume, so the build does not stall midway.

1. **Choose the control-server name and confirm the DNS zone.** `headscale.newartisans.com` lives in the Cloudflare-managed `newartisans.com` zone, which is what makes the DNS-01 certificate in Phase 1 straightforward. Decide now whether the public A record points at your current WAN address and how that address is kept current if it is dynamic.
2. **Decide the exposure method.** The runbook uses a **port-forward** on OPNsense from `WAN:443` to `192.168.1.2:8442`, so that clients reach the control plane on the universally-permitted port 443 — the port that survives restrictive café and hotel networks. The alternative is to route Headscale through a **Cloudflare tunnel**, opening no inbound port but adding a proxy hop that Headscale's maintainers discourage and complicating DERP; it is documented as a variant in Troubleshooting. The port-forward is recommended for its directness and its clean fit with a self-hosted, un-proxied control plane.
3. **Provision a Cloudflare API token for DNS-01**, scoped to edit DNS for the `newartisans.com` zone only, and place it in SOPS (`secrets.yaml`) as, for example, `cloudflare-dns-api-token`. Grant it the minimum: `Zone:DNS:Edit` on that one zone. This token is a secret; it is declared to `security.acme` by file, never inlined.
4. **Register the ports** in `docs/ports.txt` at implementation time: `8442` for the Headscale listener (published via the OPNsense forward) and `9089` for its loopback metrics endpoint. Both were confirmed free against the registry on 2026-07-11.
5. **Confirm OPNsense is recent enough** for the `os-tailscale` plugin (the plugin is offered from OPNsense 24.7 onward; Tailscale documentation, checked 2026-07-11).

## Phase 1. Headscale on vulcan

**Purpose.** Bring up the control server, give it a publicly-trusted certificate, and publish it — with nothing yet depending on it, so it can be proven in isolation.

**Step 1 — Obtain the certificate.** Configure `security.acme` to issue a certificate for `headscale.newartisans.com` by DNS-01 against Cloudflare, and hand ownership of the resulting files to the `headscale` service so it can read the private key. The shape (verify option names against `search.nixos.org`, as the module evolves):

```nix
security.acme = {
  acceptTerms = true;
  defaults.email = "jwiegley@gmail.com";
  certs."headscale.newartisans.com" = {
    dnsProvider = "cloudflare";
    # SOPS-provided; contains CF_DNS_API_TOKEN=…
    environmentFile = config.sops.secrets."cloudflare-dns-api-token".path;
    group = "headscale";              # so Headscale can read the key
    reloadServices = [ "headscale.service" ];
  };
};
```

The `group` and `reloadServices` settings matter: certificate files are group-readable, so the `headscale` group must own them, and Headscale must be reloaded when the certificate renews. A certificate the service cannot read, or does not reload after renewal, is a silent outage in waiting.

**Step 2 — Declare Headscale.** Enable the module, terminate TLS with the acme certificate, and point clients at the public URL (verify keys against the module and the Headscale configuration reference for your version — the `dns` block in particular was `dns_config` before Headscale 0.24, and the database block has likewise been reorganized):

```nix
services.headscale = {
  enable = true;
  address = "0.0.0.0";          # reached via the OPNsense forward
  port = 8442;
  settings = {
    server_url = "https://headscale.newartisans.com";
    tls_cert_path = "/var/lib/acme/headscale.newartisans.com/fullchain.pem";
    tls_key_path  = "/var/lib/acme/headscale.newartisans.com/key.pem";

    metrics_listen_addr = "127.0.0.1:9089";

    dns = {
      magic_dns = true;
      base_domain = "tailnet.newartisans.com";   # distinct from server_url host
      # Split-DNS is added in Phase 5.
    };

    # Resilience: use Tailscale's public DERP, not a relay on this host (Section 8).
    derp.urls = [ "https://controlplane.tailscale.com/derpmap/default" ];

    database = {
      type = "sqlite";
      sqlite.path = "/var/lib/headscale/db.sqlite3";
    };
  };
};
```

SQLite is the default and is sufficient at this scale; its file sits under `/var/lib/headscale`, which the ZFS snapshots and backup already cover. PostgreSQL is available should you prefer the database in your existing instance, at the cost of a little more configuration.

**Step 3 — Open the firewall on vulcan** for the listener, and rebuild:

```nix
networking.firewall.allowedTCPPorts = [ 8442 ];   # add to the existing list
```

```bash
sudo nixos-rebuild switch --flake '.#vulcan'
```

**Step 4 — Publish through OPNsense.** In the OPNsense interface, add a port-forward (Firewall ▸ NAT ▸ Port Forward) from `WAN` TCP `443` to destination `192.168.1.2:8442`, and confirm the associated firewall pass rule it offers to create. Nothing else on your WAN currently answers on 443, since the public services use outbound Cloudflare tunnels, so this is a deliberate, minimal new exposure of one hardened endpoint (verify menu path against your OPNsense version).

**Step 5 — Verify in isolation.** From inside, confirm the service is healthy and the certificate is served:

```bash
systemctl status headscale
sudo -u headscale headscale users list          # empty list is success
curl -sI https://headscale.newartisans.com/health   # from an external vantage, expect 200
```

Reaching the health endpoint from *outside* your network confirms the port-forward and certificate before any device depends on them. If a LAN client cannot resolve or reach the public name, that is the hairpin case; Phase 5's split-DNS and a local override resolve it.

## Phase 2. Users and pre-authentication keys

**Purpose.** Create the identities devices register against, and the keys that let them do so unattended.

Headscale groups devices under **users** (called *namespaces* before the 0.23 rename; Headscale documentation, checked 2026-07-11). Create one for yourself, and separate users for others so that policy can distinguish them (Phase 7).

```bash
sudo -u headscale headscale users create john
sudo -u headscale headscale users create friends
```

A **pre-authentication key** lets a device enroll without an interactive browser step — necessary for the OPNsense plugin and convenient for headless devices. Create a short-lived, single-use key per device where you can, and reserve reusable keys for deliberate cases:

```bash
# Single device, valid one hour, one use:
sudo -u headscale headscale preauthkeys create --user john --expiration 1h
# Reusable, for onboarding several of your own devices in a session:
sudo -u headscale headscale preauthkeys create --user john --reusable --expiration 24h
```

Treat these keys as secrets; each authorizes a device to join your network. The exact flags (`--user` by name or numeric identifier, in particular) vary by version; confirm with `headscale preauthkeys create --help`.

## Phase 3. OPNsense as subnet router and exit node

**Purpose.** Make the gateway the network's entry point — advertising the LAN so remote devices reach everything, not only the Tailscale-running hosts.

**Step 1 — Install the plugin.** In OPNsense, open System ▸ Firmware ▸ Plugins, enable community plugins if hidden, and install `os-tailscale` (Tailscale documentation; computingforgeeks, checked 2026-07-11). A Tailscale entry appears under the VPN (or Services) menu.

**Step 2 — Point it at Headscale and advertise the LAN.** In the plugin's settings, set the login-server URL to `https://headscale.newartisans.com`, supply a pre-auth key from Phase 2, set the advertised routes to `192.168.1.0/24`, and enable acceptance of routes. Leave the exit-node option for Phase 6. Field names vary by plugin version; the Gurucomputing guide ("Configuring Tailscale on OPNSense") and the computingforgeeks walkthrough show the equivalents, and the underlying command is:

```
tailscale up --login-server=https://headscale.newartisans.com \
  --authkey=<preauth-key> --advertise-routes=192.168.1.0/24 \
  --accept-routes --accept-dns=false
```

`--accept-dns=false` keeps OPNsense from adopting tailnet DNS over its own — the split-DNS is arranged deliberately in Phase 5 instead.

**Step 3 — Assign the interface and pass traffic.** This is the step OPNsense does not perform for you, and omitting it silently drops inbound tailnet traffic to the box (Tailscale documentation, checked 2026-07-11). Under Interfaces ▸ Assignments, add the `tailscale0` device, enable the new interface, give it a description, and lock it against accidental removal. Under Firewall ▸ Rules, on the Tailscale interface, add a pass rule appropriate to your intent — permissive to start, narrowed later with an alias of tailnet addresses.

**Step 4 — Approve the route on the Headscale side.** Advertising a route only offers it; the control server must approve it before peers use it. List the node and enable its route (command form is markedly version-dependent — `headscale routes enable -r <id>` in the 0.23 era, reorganized under `headscale nodes` in later releases; confirm with `--help`):

```bash
sudo -u headscale headscale nodes list
sudo -u headscale headscale routes list
sudo -u headscale headscale routes enable -r <route-id>
```

**Step 5 — Verify.** From a device already on the tailnet (enroll one from Phase 4 first if needed), confirm you can reach a LAN host that does *not* run Tailscale — the router's own web interface, or a printer — by its `192.168.1.x` address. Success here proves the subnet router end to end.

## Phase 4. Enrolling your own devices

**Purpose.** Put the tailnet on the machines you carry. Every platform runs the ordinary Tailscale client; the only departure from a default install is directing the client at your Headscale login server instead of Tailscale's. Because the client interfaces change between releases, the essential action is given for each platform and the exact interface path is deferred to Headscale's own "Connect a node" pages (Headscale documentation, checked 2026-07-11), which are kept current per platform.

**Linux and NixOS.** Enable the client and bring it up against your login server:

```nix
services.tailscale.enable = true;   # on any NixOS client
```
```bash
sudo tailscale up --login-server=https://headscale.newartisans.com --accept-routes
```

Accepting routes is what lets the client use the OPNsense subnet route to reach the wider LAN. Complete registration with a pre-auth key, or by running the printed `headscale nodes register` command on vulcan.

**macOS.** The standard Tailscale application supports an alternate control server; set the login server to `https://headscale.newartisans.com` through the app's custom-login flow, then sign in (Headscale "Connect a node — Apple", checked 2026-07-11). The exact gesture to reveal the custom-server field changes between app builds, which is why the upstream page is the authority.

**iOS and iPadOS.** As on macOS, the app accepts a custom coordination server; follow Headscale's Apple page for the current sequence to set the login server before signing in.

**Android.** The Tailscale app exposes a custom login-server setting in its account or overflow menu; set it to your URL, then authenticate (Headscale "Connect a node — Android", checked 2026-07-11).

**Windows.** Install Tailscale for Windows and direct it at the login server, either by the documented registry value under `HKLM\SOFTWARE\Tailscale IPN` or by `tailscale up --login-server=…` from an elevated prompt (Headscale "Connect a node — Windows", checked 2026-07-11).

After each device appears, confirm it on vulcan with `headscale nodes list`, and reach a `*.vulcan.lan` service to confirm end-to-end connectivity once Phase 5 is in place.

## Phase 5. Split-DNS and certificates

**Purpose.** Let your internal names keep working remotely with their existing certificates, rather than falling back to bare `100.x` addresses no certificate matches.

The mechanism is split-DNS: instruct the tailnet to send queries for your internal domain to your internal resolver, reached over the subnet route. Configure Headscale's DNS block so that `.lan` (or specifically `vulcan.lan`) resolves at Technitium on `192.168.1.2`, which clients reach through the OPNsense subnet router (Headscale DNS reference, checked 2026-07-11 — the key was `restricted_nameservers` under `dns_config` before the 0.24 reorganization to `dns.nameservers.split`):

```nix
services.headscale.settings.dns = {
  magic_dns = true;
  base_domain = "tailnet.newartisans.com";
  nameservers.split = {
    "lan" = [ "192.168.1.2" ];    # Technitium, the .lan authority
  };
};
```

Rebuild vulcan, then, on a remote client, resolve `vulcan.lan` and confirm it returns `192.168.1.2` and that an HTTPS service there validates against its step-ca certificate. Because the name and the address are unchanged from their on-LAN values, the existing certificate is correct as issued; nothing new must be minted for remote use.

Should a device *inside* the LAN struggle to reach the public control-server name (the hairpin case from Phase 1), add a host override on Technitium mapping `headscale.newartisans.com` to `192.168.1.2`, so internal clients reach the listener directly rather than looping out to the WAN address.

## Phase 6. The exit node (optional)

**Purpose.** Offer full-tunnel egress through home for devices on untrusted networks, so that all their internet traffic leaves from your address and is shielded on hostile Wi-Fi.

Advertise OPNsense as an exit node — in the plugin's settings, or by adding `--advertise-exit-node` to its Tailscale invocation — then approve the exit route on the Headscale side as in Phase 3, Step 4. On OPNsense, ensure IP forwarding and an outbound NAT path exist for tailnet traffic leaving to the internet, and a firewall pass rule permits it; the plugin handles part of this, but confirm rather than assume (computingforgeeks, checked 2026-07-11). Each client then selects the exit node when it wants full-tunnel — a per-device, on-demand choice, not a global one.

Note the interaction the forum records: enabling an exit node has broken split-DNS resolution for some Windows clients, and a FreeBSD restart race has disrupted exit-node DNS (OPNsense forum thread 46938). Treat the exit node as a feature to validate deliberately on each platform that will use it, not one to assume works everywhere.

## Phase 7. Friends' scoped access

**Purpose.** Admit friends' devices to reach only what you intend — a specific service or two — rather than the whole network.

Under Headscale, friends are **users within your single network**, not guests bridged from their own; Headscale implements one network and has no cross-tailnet sharing (Headscale documentation, checked 2026-07-11). You therefore create a user for them (Phase 2's `friends`), issue them a pre-auth key, and confine them with an **access-control policy**. The policy is HuJSON, defined by file or in the database depending on version (Headscale policy reference, checked 2026-07-11). A minimal shape granting yourself everything and friends only a single service:

```json
{
  "groups": {
    "group:home":    ["john"],
    "group:friends": ["friends"]
  },
  "acls": [
    { "action": "accept", "src": ["group:home"],    "dst": ["*:*"] },
    { "action": "accept", "src": ["group:friends"], "dst": ["100.64.0.2:443"] }
  ]
}
```

Replace the destination with the tailnet address or tagged name of the one service friends may reach. The default is deny, so a friend's device sees only what a rule admits. Point Headscale at the policy (`services.headscale.settings.policy.path`, or load it by command, per version) and confirm from a friend-scoped device that the permitted service answers and a forbidden one does not — verifying the denial matters as much as verifying the grant.

## Phase 8. Durability — non-expiring keys and the WireGuard fallback

**Purpose.** Make established devices independent of the control plane's availability, and keep a way in that needs neither vulcan nor Headscale.

**Set trusted devices not to expire.** So that an established device never needs the control server merely to keep functioning (Section 8), mark your own nodes non-expiring rather than letting the default key lifetime force periodic re-authentication (the default node-key lifetime is 180 days; Tailscale documentation, checked 2026-07-11). Confirm the exact command for your Headscale version — recent releases expose per-node expiry control; where they do not, a long-lived registration serves. Apply this only to devices you trust durably, since disabling expiry weakens the periodic re-verification it otherwise imposes.

**Verify the WireGuard break-glass.** The existing OPNsense WireGuard is retained precisely for the case where both vulcan and Headscale are unreachable. Confirm now — while everything works — that you can still connect over it from outside, so that it is known-good before it is ever needed. An untested fallback is a hope, not a safeguard.

## Phase 9. Monitoring and backup

**Purpose.** Bring the new control plane under the observation and backup the rest of the host already enjoys, so its failures are seen and its state is recoverable.

**Scrape the metrics.** Add the Headscale metrics endpoint on `127.0.0.1:9089` to Prometheus, and add an alert that fires when the control server is down or the target is absent, consistent with the coverage plan already in place for this host. A control plane whose outage is silent is worse than none, because it fails at the moment you try to enroll a device and cannot see why.

**Confirm the database is backed up.** Headscale's SQLite file under `/var/lib/headscale` falls within the existing ZFS snapshots and backup sweep; confirm it is captured, and that a restore returns a working control plane. The device records and pre-auth state live there; losing them means re-enrolling every device.

## Phase 10. Verification and acceptance

**Purpose.** Establish, by observation rather than assumption, that the system does what the design promised. Treat the following as acceptance tests; the work is complete when each passes, and remains complete only so long as they continue to.

- The Headscale `/health` endpoint answers over HTTPS from *outside* the network, with a valid certificate.
- `headscale nodes list` shows the OPNsense router and at least one of your devices.
- A remote device reaches a LAN host that does not run Tailscale, by its `192.168.1.x` address, through the subnet router.
- A remote device resolves `vulcan.lan` to `192.168.1.2` and validates the step-ca certificate of a service there.
- A friend-scoped device reaches the one permitted service and is denied a forbidden one.
- With Headscale deliberately stopped on vulcan, an already-enrolled device still reaches the LAN through OPNsense — the resilience property of Section 8, observed rather than trusted.
- The OPNsense WireGuard still admits a connection from outside — the break-glass path, confirmed good.
- Prometheus shows the Headscale target up, and the down-alert fires when the service is stopped.
- If the exit node was built: a client selecting it egresses from the home address, and its DNS still resolves.

---

## Operations and maintenance

Completion is a state to be maintained, not a finish line. A few practices keep it so.

**Upgrades demand attention.** Headscale's configuration keys and command verbs drift between releases more than most software; read the release notes before upgrading, and re-run the Phase 10 checks after (Headscale documentation, checked 2026-07-11). The OPNsense plugin updates on the firewall's own cycle and has been seen to require re-authentication after some reboots; expect to confirm the tailnet after firmware updates (OPNsense forum thread 46938).

**Key hygiene.** Pre-auth keys are secrets that authorize enrollment; create them short-lived and single-use by default, and revoke any that leak. Review the node list periodically and remove devices no longer in use.

**The vulcan-down procedure.** Should vulcan fail, established devices retain LAN access through OPNsense; use that access to inspect and recover vulcan. If a device must be enrolled while vulcan is down, fall back to the OPNsense WireGuard for entry, and enroll once vulcan returns. This procedure is the design working as intended, not a workaround.

**Removing a device.** Delete it from Headscale (`headscale nodes delete`), and, if it was granted anything specific in policy, remove that grant. Removal at the control plane is what withdraws a lost or retired device's access.

## Troubleshooting

The known failure modes, each with its cause and its answer:

- **A LAN client cannot reach the public control-server name.** This is NAT hairpinning: the client tries to reach your own WAN address from inside. Add a Technitium host override mapping `headscale.newartisans.com` to `192.168.1.2` (Phase 5).
- **Peers connect only slowly, or all traffic appears to relay.** OPNsense's endpoint-dependent NAT is defeating direct connections and forcing DERP. Apply static outbound NAT with port randomization, or enable NAT-PMP, per the Tailscale OPNsense guidance (Tailscale documentation; forum thread 46938).
- **The Tailscale interface exists but inbound tailnet traffic to OPNsense is dropped.** The interface was not assigned, or lacks a pass rule (Phase 3, Step 3).
- **Tailscale on OPNsense needs re-authentication after a reboot**, or DNS breaks after a service restart. These are the documented FreeBSD plugin faults (forum thread 46938); re-authenticate, and treat the exit node as validate-after-restart. Persistent trouble is the reason the WireGuard fallback is kept.
- **Headscale cannot read its certificate after renewal.** The certificate group or the reload hook is misconfigured (Phase 1, Step 1); confirm `group = "headscale"` and `reloadServices`.
- **A configuration key or command is rejected after an upgrade.** A version drift; consult the reference for the installed version — `dns_config`↔`dns`, the database block, and the routes commands are the usual movers.

**Variant — exposure through a Cloudflare tunnel instead of a port-forward.** If opening `WAN:443` is unwanted, route `headscale.newartisans.com` through a Cloudflare tunnel to `127.0.0.1:8442` on vulcan, as the existing `data` and `rsync` tunnels are routed. This opens no inbound port, at the cost of a proxy hop Headscale's maintainers discourage and of DERP traffic that an HTTP tunnel does not carry — so direct connections and the public DERP mesh must suffice. It is a supported posture, not the recommended one.

## Appendices

### A. Reference configuration

The Nix fragments in Phases 1 and 5 are the canonical illustrations; keep them in one module (for example `modules/services/headscale.nix`) so there is a single place to change. The OPNsense side is configured through its interface and is not captured in this repository; record the plugin settings and firewall rules in a short companion note so the gateway's state is documented even though it is not declarative.

### B. Command cheat-sheet

All `headscale` commands run as the service user; command verbs are version-sensitive (checked 2026-07-11):

```bash
sudo -u headscale headscale users list
sudo -u headscale headscale users create <name>
sudo -u headscale headscale preauthkeys create --user <name> --expiration 1h
sudo -u headscale headscale nodes list
sudo -u headscale headscale routes list
sudo -u headscale headscale routes enable -r <route-id>
sudo -u headscale headscale nodes delete -i <id>
```

### C. Sources

Durable grounding:
- Headscale documentation — `headscale.net/stable` (features, configuration, registration, routes, DNS, policy, DERP, connect-a-node pages).
- Headscale project — `github.com/juanfont/headscale`.
- Tailscale documentation — `tailscale.com/kb` and `tailscale.com/kb/install/opnsense`.
- `services.headscale` and `services.tailscale` — nixpkgs, `search.nixos.org`.

Community and platform-specific:
- OPNsense forum thread 46938 — Tailscale split-DNS on OPNsense, and the documented FreeBSD faults.
- Gurucomputing, "Configuring Tailscale on OPNSense" (Headscale-specific).
- computingforgeeks, "How to install and configure Tailscale client on OPNsense".
- MakeUseOf, "I Finally Tried Tailscale, and Now I Get the Hype" — motivation and feature overview.

### D. Volatile facts to reconfirm (last checked 2026-07-11)

- Headscale configuration keys: `dns` (was `dns_config`), the `database` block shape, `nameservers.split` (was `restricted_nameservers`).
- Headscale command verbs, especially route approval (`routes enable` versus the later `nodes`-based form) and per-node expiry control.
- The `os-tailscale` plugin's field names and menu location, and the OPNsense version that first offers it (24.7).
- Tailscale client interface paths for setting a custom login server on macOS, iOS, Android, and Windows.
- The Tailscale SaaS free-tier limits (three users, one hundred devices).
```
