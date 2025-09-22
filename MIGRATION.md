# Migration Guide

## Reinstalling the System with New SSH Host Keys

If you reinstall the system or need to change SSH host keys, follow these steps to update the sops-nix secrets configuration:

### Prerequisites
- Access to your GPG key (`1476CCC0D9C897534A1F00ED6060E33E7AEE9418`)
- The `sops` command available locally
- Access to this repository

### Migration Steps

#### Option A: Update After Installation (Simple)

1. **Install the new system** with your NixOS configuration

2. **Get the new age public key** from the new SSH host key:
   ```bash
   nix-shell -p ssh-to-age --run "ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub"
   ```
   This will output something like: `age1hepljzv8l2quqn2ekv40qdeecnknz2rjzhnet533j4d3m7ag03eqyjrp3s`

3. **Update `.sops.yaml`** with the new age recipient:
   ```yaml
   creation_rules:
       - path_regex: .*\.yaml$
         pgp: "1476CCC0D9C897534A1F00ED6060E33E7AEE9418"
         age: "YOUR_NEW_AGE_KEY_HERE"
   ```

4. **Re-encrypt the secrets** with the new recipient:
   ```bash
   sops updatekeys secrets.yaml
   ```
   Answer 'y' when prompted to confirm the key change.

5. **Deploy the configuration**:
   ```bash
   sudo nixos-rebuild switch --flake .#vulcan
   ```

#### Option B: Pre-stage Before Installation (Zero Downtime)

1. **Before reinstalling**, if you know the new SSH host key that will be used:
   - Convert it to an age key using `ssh-to-age`
   - Add it to `.sops.yaml` alongside the existing age key
   - Run `sops updatekeys secrets.yaml`
   - Commit and push the changes

2. **Install the new system** - it will already have access to the secrets

3. **After installation**, remove the old age key from `.sops.yaml` and run `sops updatekeys` again

### Troubleshooting

If secrets fail to decrypt after migration:

1. **Verify the age key** is correctly derived:
   ```bash
   # Check that the host key exists
   ls -la /etc/ssh/ssh_host_ed25519_key

   # Verify the conversion
   nix-shell -p ssh-to-age --run "ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub"
   ```

2. **Test manual decryption** with your GPG key:
   ```bash
   sops -d secrets.yaml
   ```
   If this works, the issue is with the host's age key configuration.

3. **Check sops-nix configuration** in `modules/core/system.nix`:
   ```nix
   sops = {
     defaultSopsFile = ../../secrets.yaml;
     age = {
       sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
       keyFile = "/var/lib/sops-nix/key.txt";
       generateKey = true;
     };
   };
   ```

4. **Verify secrets are accessible** after deployment:
   ```bash
   sudo ls -la /run/secrets/
   ```

### Important Notes

- Always keep your GPG private key (`1476CCC0D9C897534A1F00ED6060E33E7AEE9418`) secure and backed up
- The GPG key allows you to recover and re-encrypt secrets even if the host key is lost
- Consider keeping a backup of the SSH host key if you want to preserve it across reinstalls
- The age public key is derived deterministically from the SSH host key, so the same SSH key always produces the same age key

### Current Keys

For reference, the current configuration uses:
- **GPG Key**: `1476CCC0D9C897534A1F00ED6060E33E7AEE9418`
- **Age Key**: `age1hepljzv8l2quqn2ekv40qdeecnknz2rjzhnet533j4d3m7ag03eqyjrp3s` (derived from `/etc/ssh/ssh_host_ed25519_key`)