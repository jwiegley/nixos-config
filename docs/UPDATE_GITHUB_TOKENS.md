# Updating GitHub Tokens for Gitea Mirrors

This document explains how to bulk update GitHub authentication tokens for all repositories in Gitea that sync with GitHub.

## Overview

The `/etc/nixos/scripts/update-github-tokens.py` script updates GitHub tokens for:
- **Push mirrors** (Gitea → GitHub sync) - on ALL repositories, including regular repos like `nixos-config`
- **Pull mirrors** (GitHub → Gitea sync) - only on repositories marked as mirrors

This is useful when:
- A GitHub Personal Access Token (PAT) expires
- You need to rotate tokens for security
- You want to change token permissions

## Requirements

- Python 3.7+ (standard library only, no external dependencies)
- Root access (to read `/run/secrets/gitea-mirror-token`)
- Valid GitHub Personal Access Token with appropriate permissions

## Usage

### Basic Usage

```bash
# Dry-run mode (recommended first)
sudo /etc/nixos/scripts/update-github-tokens.py <new-github-token> --dry-run

# Actually update the tokens
sudo /etc/nixos/scripts/update-github-tokens.py <new-github-token>
```

### Recommended Workflow

1. **Test with dry-run first:**
   ```bash
   sudo /etc/nixos/scripts/update-github-tokens.py ghp_newtoken123 --dry-run --verbose
   ```

2. **Test with a single repository:**
   ```bash
   sudo /etc/nixos/scripts/update-github-tokens.py ghp_newtoken123 --dry-run --repo sizes
   ```

3. **Update all repositories:**
   ```bash
   sudo /etc/nixos/scripts/update-github-tokens.py ghp_newtoken123 --verbose
   ```

### Security Best Practice

Use stdin to avoid exposing the token in process lists or shell history:

```bash
# Read token from stdin
echo "ghp_newtoken123" | sudo /etc/nixos/scripts/update-github-tokens.py --stdin --verbose

# Or from a secure file
cat ~/secure-token.txt | sudo /etc/nixos/scripts/update-github-tokens.py --stdin
```

## Command-Line Options

- `github_token` - New GitHub token (positional argument)
- `--stdin` - Read GitHub token from stdin (more secure)
- `--dry-run` - Show what would be updated without making changes
- `--verbose` / `-v` - Enable detailed debug logging
- `--repo NAME` - Only update a specific repository (useful for testing)
- `--help` / `-h` - Show help message

## Configuration

The script uses these hardcoded values:
- **Gitea URL:** `https://gitea.vulcan.lan`
- **Gitea user:** `johnw`
- **GitHub user:** `jwiegley`
- **Gitea token source:** `/run/secrets/gitea-mirror-token`

To change these, edit the constants at the top of the script.

## What It Does

For each repository in Gitea:

1. **Checks for push mirrors** via Gitea API (on ALL repositories, not just mirrors)
2. **Updates push mirror credentials** (for Gitea → GitHub sync) if any GitHub push mirrors exist
   - Uses `PATCH /api/v1/repos/{owner}/{repo}/push_mirrors/{mirror_name}`
   - Updates `remote_password` field
   - Includes regular repos like `nixos-config` that have push mirrors configured
3. **Updates pull mirror credentials** (for GitHub → Gitea sync) ONLY for repositories marked as mirrors
   - Uses `PATCH /api/v1/repos/{owner}/{repo}`
   - Updates `mirror_password` field

## Output Example

```
=========================================
GitHub Token Update for Gitea Mirrors
=========================================
Gitea user:   johnw
GitHub user:  jwiegley
Gitea URL:    https://gitea.vulcan.lan

*** DRY RUN MODE - No changes will be made ***

Fetching repositories (page 1)...
Total repositories found: 163
Processing: gitlib
  → Updating push mirror: gitlib
  ✓ Updated push mirror
  → Updating pull mirror credentials...
  ✓ Updated pull mirror credentials
...

========================================
Update Summary
========================================
Repositories processed:     163
Push mirrors updated:       142
Pull mirrors updated:       146
Push mirrors failed:        0
Pull mirrors failed:        0
Repositories skipped:       17
========================================
Total mirrors updated:      288
Total failures:             0
========================================
```

## Error Handling

The script:
- Validates the Gitea token exists and is readable
- Handles API errors gracefully
- Continues processing even if individual repositories fail
- Returns exit code 1 if any updates failed
- Provides detailed error messages in logs

## Notes

- Non-mirror repositories are automatically skipped
- The "org" repository is always skipped (not a GitHub mirror)
- Only push mirrors with GitHub URLs are updated
- SSL verification is disabled for `.lan` domains
- The script uses Python's standard library (urllib) - no external dependencies

## Related Files

- `/etc/nixos/scripts/add-push-mirrors.sh` - Original bash script for adding push mirrors
- `/etc/nixos/modules/services/github-gitea-mirror.nix` - Gitea mirroring service configuration
- `/etc/nixos/secrets.yaml` - SOPS-encrypted secrets (contains tokens)

## Troubleshooting

### Permission Denied

```
ERROR: Permission denied reading /run/secrets/gitea-mirror-token
```

**Solution:** Run with `sudo`

### No Repositories Found

Check that:
1. Gitea is accessible at `https://gitea.vulcan.lan`
2. The Gitea token is valid and has appropriate permissions
3. The user `johnw` exists in Gitea

### API Errors

Use `--verbose` to see detailed API responses:

```bash
sudo /etc/nixos/scripts/update-github-tokens.py <token> --dry-run --verbose
```

## Future Enhancements

Potential improvements:
- Make configuration (URLs, users) configurable via command-line arguments
- Add support for batch processing with rate limiting
- Add option to update from SOPS secrets instead of command-line
- Support for other git hosting platforms (GitLab, etc.)
