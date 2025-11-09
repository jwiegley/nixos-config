# GitHub to Gitea Mirror Setup

This document explains how to configure the automated GitHub to Gitea repository mirroring service.

## Overview

The service automatically discovers and creates **bidirectional mirrors** for all repositories from GitHub user `jwiegley` to the local Gitea instance at https://gitea.vulcan.lan.

**Bidirectional Mirroring:**
- **Pull mirrors:** Gitea pulls changes FROM GitHub every 8 hours
- **Push mirrors:** Gitea pushes changes TO GitHub every 8 hours
- This ensures that changes made in either location are synchronized

**Configuration:**
- Discovery runs daily at 3 AM
- Gitea syncs each mirror (both pull and push) every 8 hours
- Only non-forked, non-archived repositories are mirrored
- All mirrors are created as public repositories under the `johnw` Gitea user

## Required Secrets

Two secrets must be added to `/etc/nixos/secrets.yaml` using SOPS:

### 1. GitHub Personal Access Token

```bash
# Edit secrets file
sops /etc/nixos/secrets.yaml
```

Add the following key:
```yaml
github-mirror-token: "ghp_YOUR_GITHUB_TOKEN_HERE"
```

**How to generate:**
1. Go to https://github.com/settings/tokens
2. Click "Generate new token" → "Generate new token (classic)"
3. Give it a descriptive name: "Gitea Mirror - vulcan"
4. Select scopes:
   - `repo` (Full control of private repositories)
     - This includes: repo:status, repo_deployment, public_repo, repo:invite, security_events
5. Click "Generate token"
6. Copy the token (starts with `ghp_`)

**Security:** The token allows read access to all your repositories. Keep it secure and never commit it unencrypted.

### 2. Gitea Access Token

```bash
# Edit secrets file
sops /etc/nixos/secrets.yaml
```

Add the following key:
```yaml
gitea-mirror-token: "YOUR_GITEA_TOKEN_HERE"
```

**How to generate:**
1. Go to https://gitea.vulcan.lan/user/settings/applications
2. Under "Manage Access Tokens", enter:
   - **Token Name:** "GitHub Mirror Service"
   - **Permissions:** Select "Read and Write" for all categories:
     - `repository` (allows creating and managing repos, including push mirrors)
     - `user` (allows reading user information)
     - All other categories can be set to "Read and Write" for full functionality
3. Click "Generate Token"
4. Copy the token immediately (it won't be shown again)

**Security:** The token allows creating repositories and managing mirrors under the `johnw` account. Keep it secure.

## Configuration

The service is configured in `/etc/nixos/hosts/vulcan/default.nix`:

```nix
services.github-gitea-mirror = {
  enable = true;
  githubUser = "jwiegley";          # GitHub user to mirror from
  giteaUser = "johnw";              # Gitea user to create repos under
  giteaUrl = "https://gitea.vulcan.lan";
  mirrorInterval = "8h";            # 8 hours (Go duration format)
  schedule = "*-*-* 03:00:00";      # Daily at 3 AM
};
```

## Applying Configuration

After adding the secrets and configuring the service:

```bash
# Build the new configuration (test)
sudo nixos-rebuild build --flake '.#vulcan'

# Switch to the new configuration
sudo nixos-rebuild switch --flake '.#vulcan'
```

## Testing

### Manual Test Run

Trigger the service manually to test:

```bash
# Start the service manually
sudo systemctl start github-mirror.service

# Watch the logs in real-time
sudo journalctl -u github-mirror.service -f
```

Expected output:
```
Starting GitHub to Gitea mirror discovery
GitHub user: jwiegley
Gitea user: johnw
Gitea URL: https://gitea.vulcan.lan
Mirror sync interval: 28800 seconds

Fetching Gitea user ID for johnw...
Gitea user ID: 1

Fetching GitHub repositories (page 1)...
Processing 50 repositories...
  ✓ Created mirror: repo1
  ✓ Created mirror: repo2
  → Already exists: repo3
  ...

=========================================
Mirror discovery completed
=========================================
Repositories processed: 150
Mirrors created: 145
Already existing: 5
Skipped (archived/forked): 23
Failed: 0
=========================================
```

### Check Timer Status

Verify the timer is scheduled:

```bash
# View timer status
sudo systemctl status github-mirror.timer

# List all timers to see next activation
sudo systemctl list-timers github-mirror.timer
```

Expected output:
```
NEXT                        LEFT       LAST PASSED UNIT                 ACTIVATES
Sat 2025-11-09 03:00:00 UTC 5h 30min   -    -      github-mirror.timer  github-mirror.service
```

## Monitoring

### View Logs

```bash
# View latest service run
sudo journalctl -u github-mirror.service

# View logs from the last 24 hours
sudo journalctl -u github-mirror.service --since "24 hours ago"

# Follow logs in real-time during a run
sudo journalctl -u github-mirror.service -f
```

### Check Service Status

```bash
# View service status
sudo systemctl status github-mirror.service

# View timer status
sudo systemctl status github-mirror.timer
```

### Gitea Mirror Status

Check mirror sync status in Gitea:

1. Go to https://gitea.vulcan.lan/johnw?tab=repositories
2. Look for repositories with a mirror icon
3. Click on a repository → Settings → Repository
4. Under "Pull Mirror Settings" you can see:
   - Last sync time
   - Next sync time (every 8 hours)
   - Pull sync status
5. Under "Push Mirror Settings" you can see:
   - Remote address (GitHub URL)
   - Last update time
   - Sync interval (8 hours)
   - Push sync status

## Troubleshooting

### Service Fails to Start

**Check secrets are properly configured:**
```bash
# Verify secrets exist
ls -la /run/secrets/github-mirror-token
ls -la /run/secrets/gitea-mirror-token

# Check template was created
ls -la /run/secrets-rendered/github-mirror-env
```

**View error logs:**
```bash
sudo journalctl -u github-mirror.service -n 50
```

### No Repositories Created

**Check GitHub token permissions:**
- Ensure the token has `repo` scope
- Test the token manually:
  ```bash
  curl -H "Authorization: token YOUR_GITHUB_TOKEN" \
    https://api.github.com/user/repos?per_page=5
  ```

**Check Gitea token permissions:**
- Ensure the token has repository creation permissions
- Test the token manually:
  ```bash
  curl -H "Authorization: token YOUR_GITEA_TOKEN" \
    https://gitea.vulcan.lan/api/v1/user
  ```

### Some Repositories Skipped

The service intentionally skips:
- **Forked repositories** - Only original repos are mirrored
- **Archived repositories** - Inactive repos are excluded

This is by design and can be verified in the logs:
```
Skipped 10 archived/forked repositories on this page
```

### Mirrors Not Syncing

**Check Gitea's mirror sync status:**
```bash
# Check Gitea logs
sudo journalctl -u gitea.service | grep -i mirror
```

**Manually trigger a mirror sync in Gitea:**
1. Go to repository → Settings → Repository
2. Under "Mirror Settings", click "Sync Now"

## Customization

### Change Discovery Schedule

Edit `/etc/nixos/hosts/vulcan/default.nix`:

```nix
services.github-gitea-mirror = {
  # ... other settings ...

  # Twice daily (3 AM and 3 PM)
  schedule = "*-*-* 03,15:00:00";

  # Weekly on Sunday at 2 AM
  # schedule = "Sun *-*-* 02:00:00";

  # Every 6 hours
  # schedule = "*-*-* 00,06,12,18:00:00";
};
```

### Change Mirror Sync Interval

Edit `/etc/nixos/hosts/vulcan/default.nix`:

```nix
services.github-gitea-mirror = {
  # ... other settings ...

  # Every hour (Go duration format)
  # mirrorInterval = "1h";

  # Every 4 hours
  # mirrorInterval = "4h";

  # Every 12 hours
  # mirrorInterval = "12h";

  # Daily (24 hours)
  # mirrorInterval = "24h";
};
```

After making changes, rebuild and switch:
```bash
sudo nixos-rebuild switch --flake '.#vulcan'
```

## Architecture

The service uses a two-phase approach with bidirectional synchronization:

### Phase 1: Discovery (Custom Service)
- **When:** Runs on schedule (default: daily at 3 AM)
- **What:** Discovers new repositories from GitHub
- **How:** Creates mirror repositories in Gitea via API
  - Creates pull mirror (Gitea pulls FROM GitHub)
  - Creates push mirror (Gitea pushes TO GitHub)
- **Filters:** Excludes forked and archived repositories

### Phase 2: Synchronization (Gitea Built-in)
- **When:** Runs automatically every 8 hours (configurable)
- **What:** Syncs each mirror bidirectionally
  - **Pull sync:** Fetches changes from GitHub to Gitea
  - **Push sync:** Pushes changes from Gitea to GitHub
- **How:** Gitea's built-in mirror functionality
- **Status:** Visible in Gitea UI per repository

### Use Cases
- **Work in Gitea:** Make commits locally in Gitea, changes automatically pushed to GitHub
- **Work in GitHub:** Make commits on GitHub, changes automatically pulled to Gitea
- **Backup:** Gitea serves as a complete backup of all GitHub repositories
- **Local availability:** All repos available even if GitHub is down

## Security Considerations

1. **Tokens stored in SOPS** - Encrypted at rest in `secrets.yaml`
2. **Minimal permissions** - Tokens have only necessary scopes
3. **Environment file mode 0400** - Readable only by root
4. **HTTPS only** - All API calls use TLS encryption
5. **No token logging** - Tokens never appear in logs

## Future Enhancements

Potential improvements:
- Mirror GitHub organizations
- Filter by language or topics
- Remove mirrors for deleted GitHub repos
- Prometheus metrics for mirror status
- Email notifications for new repos discovered
- Web dashboard for mirror overview
