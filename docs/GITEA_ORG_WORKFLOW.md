# Gitea Actions Workflow for org-jw Repository

This document describes the Gitea Actions workflow setup for automatically building and deploying your org site.

## Prerequisites

Before building the NixOS configuration, you need to add two secrets to SOPS:

### 1. Add Secrets to SOPS

Run `sops /etc/nixos/secrets.yaml` and add the following keys:

```yaml
# Gitea Actions Runner registration token
# Get this from: https://gitea.vulcan.lan/admin/runners
gitea-runner-token: YOUR_RUNNER_TOKEN_HERE

# Rclone configuration file with obscured password
# First, obscure your password: rclone obscure "your-plain-password"
# Then add the obscured output to the pass field below
rclone-config: |
  [fastmail]
  type = webdav
  url = https://webdav.fastmail.com
  vendor = fastmail
  user = your-email@fastmail.com
  pass = YOUR_OBSCURED_PASSWORD_HERE
```

### 2. Create Workflow File in org Repository

After the NixOS configuration is applied and the runner is registered, create the following file in your org repository:

**File: `.github/workflows/build-and-deploy.yml`** (or `.gitea/workflows/build-and-deploy.yml`)

```yaml
name: Build and Deploy Org Site

on:
  push:
    branches:
      - main
      - master

jobs:
  build-deploy:
    runs-on: org-builder

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 0  # Full history for org processing

      - name: Build org site
        run: |
          # The actions/checkout action checks out code to $GITHUB_WORKSPACE (current directory)
          # Assuming your repository structure:
          #   - org.yaml (at repository root)
          #   - org.dot (at repository root)
          #   - newartisans/config.yaml (subdirectory)
          #   - Output: newartisans/_site (generated)

          nix run github:jwiegley/org-jw -- \
              --config ./org.yaml \
              --keywords ./org.dot \
              site build ./newartisans/config.yaml

      - name: Sync to Fastmail
        run: |
          # Point rclone to the config file from SOPS (includes obscured password)
          export RCLONE_CONFIG=/run/secrets/rclone-config

          # Sync the generated site (in the workspace) to Fastmail
          rclone sync -v \
                 --checksum \
                 --refresh-times \
                 --delete-after \
                 ./newartisans/_site \
                 fastmail:/johnw.newartisans.com/files/newartisans
```

## How It Works

1. **Trigger**: The workflow runs automatically when you push commits to the `main` or `master` branch of your org repository.

2. **Runner**: The job runs on the `org-builder` runner, which is configured with:
   - The `org` command from the org-jw flake
   - `rclone` for syncing files
   - Access to necessary secrets via SOPS

3. **Build Step**: Runs the org command to generate the static site from your org files.

4. **Deploy Step**: Uses rclone to sync the generated site to your Fastmail hosting.

## Runner Registration

After building the NixOS configuration:

1. Go to https://gitea.vulcan.lan/admin/runners
2. Click "Create new Runner"
3. Copy the registration token
4. Add it to SOPS as shown above
5. Rebuild NixOS - the runner will auto-register

## Secrets Access

The runner has access to secrets via:
- `/run/secrets/rclone-config` - The rclone configuration file from SOPS (includes obscured password)
- `/run/secrets/gitea-runner-token` - The runner registration token
- Secrets are accessible to the gitea-runner user (via the `keys` group)
- Permissions: 0440 (read-only for root and keys group - NOT world-readable)

## Testing

To test the workflow:

1. Make a commit to your org repository
2. Push to the main branch
3. Check the Actions tab in Gitea to see the workflow run
4. Check logs: `sudo journalctl -u gitea-runner-org-builder.service -f`

## Troubleshooting

**Runner not appearing in Gitea:**
```bash
sudo systemctl status gitea-runner-org-builder.service
sudo journalctl -u gitea-runner-org-builder.service -f
```

**Secrets not accessible:**
```bash
sudo ls -la /run/secrets/
stat /run/secrets/rclone-config
stat /run/secrets/gitea-runner-token
# Verify gitea-runner can read the config
sudo -u gitea-runner cat /run/secrets/rclone-config > /dev/null && echo "OK"
```

**Workflow fails:**
- Check the Actions tab in Gitea for detailed logs
- Verify the org and rclone commands work manually as the gitea-runner user
- Check that all paths in the workflow match your actual directory structure
