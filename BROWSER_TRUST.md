# Browser Certificate Trust Setup for Vulcan CA

This document provides detailed instructions for trusting the Vulcan Certificate Authority in various browsers.

## Certificate Files

- **Root CA Certificate**: `/var/lib/step-ca-state/certs/root_ca.crt`
- **Export for clients**: `scp johnw@vulcan.lan:/var/lib/step-ca-state/certs/root_ca.crt ~/vulcan-root-ca.crt`

## Firefox (All Platforms)

Firefox uses its own certificate store and does NOT use the system certificate store.

### Method 1: Import via Firefox Settings (Recommended)

1. Open Firefox and navigate to `about:preferences#privacy`
2. Scroll down to "Certificates" section
3. Click "View Certificates..."
4. Go to "Authorities" tab
5. Click "Import..."
6. Select the `vulcan-root-ca.crt` file
7. Check "Trust this CA to identify websites"
8. Click OK

### Method 2: Import via Security Devices

1. Navigate to `about:preferences#privacy`
2. Click "Security Devices..."
3. Click "Load"
4. Module Name: `Vulcan CA`
5. Module filename: Browse to the certificate file location

### Method 3: Enterprise Policy (System-wide)

Create policy file for Firefox to use system certificates:

**Linux**: `/usr/lib/firefox/distribution/policies.json`
**macOS**: `/Applications/Firefox.app/Contents/Resources/distribution/policies.json`

```json
{
  "policies": {
    "Certificates": {
      "ImportEnterpriseRoots": true,
      "Install": [
        "/path/to/vulcan-root-ca.crt"
      ]
    }
  }
}
```

### Common Firefox Certificate Errors and Solutions

#### SEC_ERROR_UNKNOWN_ISSUER
**Cause**: Firefox doesn't recognize the CA
**Solution**: Import the root CA certificate as described above

#### SSL_ERROR_BAD_CERT_DOMAIN
**Cause**: Certificate doesn't match the domain
**Solution**: Ensure you're accessing via the correct domain (vulcan.lan, not IP address)

#### MOZILLA_PKIX_ERROR_SELF_SIGNED_CERT
**Cause**: Firefox sees a self-signed certificate
**Solution**: Ensure nginx is serving the full certificate chain (now fixed)

## Safari / macOS

### System Keychain Method (Recommended)

1. **Download the root CA certificate**:
   ```bash
   scp johnw@vulcan.lan:/var/lib/step-ca-state/certs/root_ca.crt ~/Desktop/vulcan-root-ca.crt
   ```

2. **Import to System Keychain**:
   ```bash
   # Via command line
   sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/Desktop/vulcan-root-ca.crt

   # Or via GUI:
   # - Double-click vulcan-root-ca.crt
   # - Select "System" keychain
   # - Click "Add"
   ```

3. **Trust the Certificate**:
   - Open Keychain Access app
   - Select "System" keychain
   - Find "Vulcan Certificate Authority"
   - Double-click it
   - Expand "Trust" section
   - Set "When using this certificate" to "Always Trust"
   - Close and enter password to save

### Safari-Specific Requirements

Safari requires certificates to be fully standards-compliant:
- ✅ Valid for ≤398 days
- ✅ Contains `basicConstraints = critical,CA:FALSE`
- ✅ Proper key usage extensions
- ✅ Full certificate chain served by the server

## Chrome / Chromium

Chrome uses the system certificate store on macOS and Windows, but on Linux it may use NSS.

### Linux
```bash
# For system-wide trust
sudo cp vulcan-root-ca.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates

# For Chrome/Chromium specifically (NSS database)
certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n "Vulcan CA" -i vulcan-root-ca.crt
```

### macOS
Chrome uses the macOS Keychain - follow the Safari instructions above.

### Windows
```powershell
# Run as Administrator
certutil -addstore -f "ROOT" vulcan-root-ca.crt
```

## Edge

### Windows
Edge uses the Windows certificate store:
```powershell
# Run as Administrator
certutil -addstore -f "ROOT" vulcan-root-ca.crt
```

### macOS
Edge uses the macOS Keychain - follow the Safari instructions above.

### Linux
```bash
# Edge on Linux uses NSS like Chrome
certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n "Vulcan CA" -i vulcan-root-ca.crt
```

## Mobile Browsers

### iOS (Safari)
1. Email `vulcan-root-ca.crt` to yourself or host it on a web server
2. Open the certificate file on your iOS device
3. Go to Settings → General → VPN & Device Management
4. Find the profile under "Downloaded Profile" and tap it
5. Tap "Install" and enter your passcode
6. Go to Settings → General → About → Certificate Trust Settings
7. Enable full trust for "Vulcan Certificate Authority"

### Android (Chrome)
1. Copy `vulcan-root-ca.crt` to your device
2. Go to Settings → Security → Encryption & credentials
3. Tap "Install a certificate" → "CA certificate"
4. Select the certificate file
5. Name it "Vulcan CA"

## Verification Steps

After importing the certificate, verify it's working:

### Check Certificate Chain
```bash
# Should show 3 certificates in the chain
echo | openssl s_client -connect vulcan.lan:443 -servername vulcan.lan -showcerts 2>/dev/null | grep -c "BEGIN CERTIFICATE"
```

### Test HTTPS Access
1. Clear browser cache and cookies
2. Navigate to https://vulcan.lan
3. Check for the padlock icon (no warnings)
4. Click the padlock and verify certificate details

### Browser Certificate Viewer
- **Firefox**: Click padlock → Connection secure → More information → View Certificate
- **Chrome**: Click padlock → Connection is secure → Certificate is valid
- **Safari**: Click padlock → Show Certificate

## Troubleshooting

### Certificate Still Not Trusted After Import

1. **Clear browser cache**:
   - Firefox: `Ctrl+Shift+Del` → Clear everything
   - Chrome: `chrome://settings/clearBrowserData`
   - Safari: Develop menu → Empty Caches

2. **Restart the browser completely**

3. **Check certificate validity**:
   ```bash
   nix-shell -p openssl --run "openssl x509 -in /var/lib/nginx-certs/vulcan-fullchain.crt -noout -dates"
   ```

4. **Verify DNS resolution**:
   ```bash
   nslookup vulcan.lan
   ping vulcan.lan
   ```

### Firefox Still Shows Warning

If Firefox continues to show warnings after importing:

1. Navigate to `about:config`
2. Search for `security.enterprise_roots.enabled`
3. Set it to `true` (allows Firefox to use system certificates)

### Certificate Not Showing in Browser

Verify nginx is serving the full chain:
```bash
echo | nix-shell -p openssl --run "openssl s_client -connect vulcan.lan:443 -servername vulcan.lan 2>/dev/null" | nix-shell -p openssl --run "openssl x509 -noout -subject -issuer"
```

Should show:
- subject: CN = vulcan.lan
- issuer: O = Vulcan Certificate Authority, CN = Vulcan Certificate Authority Intermediate CA

## Quick Test URLs

After setting up trust, these should all work without warnings:
- https://vulcan.lan
- https://jellyfin.vulcan.lan
- https://organizr.vulcan.lan
- https://litellm.vulcan.lan
- https://smokeping.vulcan.lan
- https://wallabag.vulcan.lan

## Security Notes

1. **Private CA**: This is a private Certificate Authority - only trust it for internal services
2. **Root Certificate**: Keep the root certificate secure - anyone with it can create trusted certificates
3. **Validity Period**: Certificates are valid for 1 year and must be renewed
4. **Scope**: Only trust for `*.vulcan.lan` domains