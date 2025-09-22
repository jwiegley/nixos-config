# Certificate Management with Step CA

This document outlines how to manage certificates using Step CA on the vulcan host.

## Overview

Step CA is configured to provide a private certificate authority for issuing TLS and SSH certificates within the local network.

## Configuration

The Step CA service is configured in `/etc/nixos/modules/services/certificates.nix` with:
- Listening on `127.0.0.1:8443` (localhost only)
- State directory at `/var/lib/step-ca-state`
- Root and intermediate CA certificates
- Automatic initialization via `step-ca-init` service
- JWK provisioner with admin access
- Support for TLS certificates (SSH can be enabled)

## Architecture

### Services
- **step-ca.service**: Main Step CA daemon
- **step-ca-init.service**: Initialization service that runs before step-ca

### Directory Structure
```
/var/lib/step-ca-state/
├── certs/           # CA certificates
│   ├── root_ca.crt
│   └── intermediate_ca.crt
├── secrets/         # Private keys (mode 0700)
│   ├── root_ca_key
│   └── intermediate_ca_key
├── db/              # BadgerDB database
├── config/          # Configuration files
└── templates/       # Certificate templates
```

### Secrets Management
- CA password stored in SOPS at `step-ca-password`
- Accessible by step-ca user/group only
- Located at `/run/secrets/step-ca-password`

## Basic Usage

### Check CA Status
```bash
# Check if Step CA is running
sudo systemctl status step-ca

# Check initialization service
sudo systemctl status step-ca-init

# Check CA health
step ca health --ca-url https://localhost:8443 --root /var/lib/step-ca-state/certs/root_ca.crt

# Quick health check
curl -k https://127.0.0.1:8443/health
```

### Request a Certificate
```bash
# Request a TLS certificate (will prompt for provisioner password)
step ca certificate "service.vulcan.lan" service.crt service.key \
  --ca-url https://localhost:8443 \
  --root /var/lib/step-ca-state/certs/root_ca.crt

# Request with specific duration
step ca certificate "service.vulcan.lan" service.crt service.key \
  --ca-url https://localhost:8443 \
  --root /var/lib/step-ca-state/certs/root_ca.crt \
  --not-after 24h

# Request with password from file
echo "your-provisioner-password" | step ca certificate "service.vulcan.lan" service.crt service.key \
  --ca-url https://localhost:8443 \
  --root /var/lib/step-ca-state/certs/root_ca.crt \
  --provisioner "Admin JWK" \
  --provisioner-password-file /dev/stdin

# With specific SANs (Subject Alternative Names)
step ca certificate "myservice.vulcan.lan" myservice.crt myservice.key \
  --san myservice.lan \
  --san 192.168.1.100 \
  --ca-url https://localhost:8443 \
  --root /var/lib/step-ca-state/certs/root_ca.crt
```

### Renew a Certificate
```bash
step ca renew service.crt service.key \
  --ca-url https://localhost:8443 \
  --root /var/lib/step-ca-state/certs/root_ca.crt \
  --force  # Force renewal even if not expired
```

### List Provisioners
```bash
step ca provisioner list \
  --ca-url https://localhost:8443 \
  --root /var/lib/step-ca-state/certs/root_ca.crt
```

### List Issued Certificates
```bash
step ca certificate list \
  --ca-url https://localhost:8443 \
  --root /var/lib/step-ca-state/certs/root_ca.crt
```

### Revoke a Certificate
```bash
step ca revoke --serial-number <SERIAL> \
  --ca-url https://localhost:8443 \
  --root /var/lib/step-ca-state/certs/root_ca.crt
```

## Certificate Information

### View Certificate Details
```bash
# Using step CLI
step certificate inspect service.crt --short

# Full details
step certificate inspect service.crt

# Using OpenSSL (requires nix-shell)
nix-shell -p openssl --run "openssl x509 -in service.crt -noout -text"
```

### Get Root Certificate Fingerprint
```bash
step certificate fingerprint /var/lib/step-ca-state/certs/root_ca.crt
```

### Verify Certificate Chain
```bash
step certificate verify service.crt \
  --roots /var/lib/step-ca-state/certs/root_ca.crt
```

## Automatic Certificate Renewal with systemd

Create a systemd timer for automatic renewal:

```bash
# Create renewal service
sudo tee /etc/systemd/system/cert-renewal@.service <<EOF
[Unit]
Description=Certificate renewal for %i
After=network.target

[Service]
Type=oneshot
ExecStart=/run/current-system/sw/bin/step ca renew /etc/certificates/%i.crt /etc/certificates/%i.key --daemon --ca-url https://localhost:8443 --root /var/lib/step-ca-state/certs/root_ca.crt
EOF

# Create renewal timer
sudo tee /etc/systemd/system/cert-renewal@.timer <<EOF
[Unit]
Description=Daily certificate renewal check for %i

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Enable for a specific certificate
sudo systemctl enable --now cert-renewal@myservice.timer
```

## Signing External Certificate Requests

When other servers need certificates signed by this CA:

```bash
# On the remote server, generate a CSR
openssl req -new -nodes -keyout server.key -out server.csr \
  -subj "/C=US/ST=State/L=City/O=Organization/CN=server.example.lan"

# Copy the CSR to this CA server and sign it
step ca sign server.csr server.crt \
  --ca-url https://localhost:8443 \
  --root /var/lib/step-ca-state/certs/root_ca.crt \
  --not-after 8760h

# Send the signed certificate back to the requesting server
```

## SSH Certificate Management

If SSH CA is enabled in the provisioners:

### Generate SSH Host Certificate
```bash
# For SSH host certificates
step ssh certificate vulcan.lan /etc/ssh/ssh_host_ed25519_key-cert.pub \
  --host \
  --sign \
  --ca-url https://localhost:8443 \
  --root /var/lib/step-ca-state/certs/root_ca.crt

# Add to sshd_config
echo "HostCertificate /etc/ssh/ssh_host_ed25519_key-cert.pub" | sudo tee -a /etc/ssh/sshd_config
```

### Generate SSH User Certificate
```bash
# For SSH user certificates
step ssh certificate user@vulcan.lan ~/.ssh/id_ed25519-cert.pub \
  --sign \
  --ca-url https://localhost:8443 \
  --root /var/lib/step-ca-state/certs/root_ca.crt
```

## Trust the Root Certificate

To trust the Step CA root certificate on client machines:

```bash
# Export the root certificate
sudo cp /var/lib/step-ca-state/certs/root_ca.crt ~/vulcan-root-ca.crt

# Or download it from the CA
step ca root vulcan-root-ca.crt --ca-url https://localhost:8443
```

### macOS
```bash
# Add to system keychain
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/vulcan-root-ca.crt
```

### Linux (Debian/Ubuntu)
```bash
sudo cp vulcan-root-ca.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates
```

### Linux (Fedora/RHEL/NixOS)
```bash
sudo cp vulcan-root-ca.crt /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust
```

### Windows
```powershell
certutil -addstore -f "ROOT" vulcan-root-ca.crt
```

### iOS (iPhone/iPad)
1. Email the `vulcan-root-ca.crt` file to yourself or host it on a web server
2. Open the certificate file on your iOS device
3. Go to Settings → General → VPN & Device Management
4. Find the profile under "Downloaded Profile" and tap it
5. Tap "Install" and enter your passcode
6. Go to Settings → General → About → Certificate Trust Settings
7. Enable full trust for the "Vulcan Certificate Authority"

### Android
1. Copy `vulcan-root-ca.crt` to your device
2. Go to Settings → Security → Encryption & credentials
3. Tap "Install a certificate" → "CA certificate"
4. Select the certificate file
5. Give it a name like "Vulcan CA"

## Troubleshooting

### View Logs
```bash
# View step-ca service logs
sudo journalctl -u step-ca -f

# View initialization logs
sudo journalctl -u step-ca-init -f

# Check recent errors
sudo journalctl -xeu step-ca --since "5 minutes ago"
```

### Common Issues

#### Service Won't Start
```bash
# Check for permission issues
ls -la /var/lib/step-ca-state/
ls -la /run/secrets/step-ca-password

# Check configuration syntax
sudo -u step-ca step-ca /etc/smallstep/ca.json --validate
```

#### Certificate Requests Fail
```bash
# Verify CA is listening
ss -tlnp | grep 8443

# Check firewall
sudo nft list ruleset | grep 8443
```

### Reset CA (WARNING: Destructive!)

This will delete all CA data and require redistributing the root certificate:

```bash
# Stop services
sudo systemctl stop step-ca
sudo systemctl stop step-ca-init

# Remove all CA data
sudo rm -rf /var/lib/step-ca-state/*

# Restart services (will reinitialize)
sudo systemctl start step-ca-init
sudo systemctl start step-ca

# Verify new CA is working
step ca health --ca-url https://localhost:8443 --root /var/lib/step-ca-state/certs/root_ca.crt
```

## NixOS Configuration Notes

### Rebuild After Changes
```bash
# After modifying certificates.nix
sudo nixos-rebuild switch --flake .#vulcan
```

### Service Dependencies
- `step-ca-init.service` runs before `step-ca.service`
- Both services depend on `sops-install-secrets.service`
- State directories are managed by systemd with StateDirectory

### Permissions
- State directory: owned by `step-ca:step-ca`
- Secrets: mode 0700, owned by step-ca
- SOPS secret: mode 0400, owned by step-ca

### Integration with NixOS Services

To use certificates with NixOS services:

```nix
# Example: nginx with step-ca certificate
services.nginx = {
  enable = true;
  virtualHosts."myservice.vulcan.lan" = {
    forceSSL = true;
    sslCertificate = "/etc/certificates/myservice.crt";
    sslCertificateKey = "/etc/certificates/myservice.key";
  };
};

# Example: Postfix with step-ca certificate
services.postfix = {
  sslCert = "/etc/certificates/mail.crt";
  sslKey = "/etc/certificates/mail.key";
};
```

## Security Considerations

1. **Localhost Only**: CA only listens on 127.0.0.1, not exposed to network
2. **Password Protection**: Provisioner requires password for certificate issuance (stored in SOPS)
3. **Short-lived Certificates**: Default duration is 5 minutes for testing, recommended 90 days for production
4. **Secure Storage**: Private keys stored with restrictive permissions (mode 0700)
5. **Regular Rotation**: Consider rotating CA password periodically (see PASSWORDS.md)
6. **Audit Logging**: Monitor certificate issuance via journalctl
7. **Network Isolation**: Only expose to network if absolutely necessary
8. **Backup**: Regular backup of `/var/lib/step-ca-state/` for disaster recovery

## Additional Resources

- [smallstep documentation](https://smallstep.com/docs/)
- [step-ca configuration reference](https://smallstep.com/docs/step-ca/configuration)
- [ACME protocol specification](https://datatracker.ietf.org/doc/html/rfc8555)
- [X.509 certificate best practices](https://smallstep.com/blog/everything-pki.html)
