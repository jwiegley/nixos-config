# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in this NixOS configuration repository, please report it by:

1. Opening a [Security Advisory](https://github.com/jwiegley/nixos-config/security/advisories/new) (preferred)
2. Or emailing the maintainer directly (see profile for contact information)

Please include:
- A clear description of the vulnerability
- Steps to reproduce the issue
- Potential impact assessment
- Any suggested fixes or mitigations

## Security Considerations

This repository contains personal NixOS system configurations.

> **Status (2026-07-27):** the CI-based scanning described here has largely
> lapsed, and this section is kept as a statement of intent rather than of
> current fact. Verified state of the repository today:
>
> - The canonical remote is a **self-hosted Gitea** (`gitea:johnw/nixos-config.git`).
>   `github.com/jwiegley/nixos-config` still exists but was last pushed
>   **2026-05-05**, so anything running GitHub-side is looking at a stale tree.
> - There is **no `.github/workflows/` directory at all** — no CodeQL workflow,
>   no CI security workflow. The one third-party scanner that was wired up
>   (`.github/workflows/codacy.yml`) was removed on 2025-10-31 (commit 3455881).
> - `.github/dependabot.yml` is present but only covers the `github-actions`
>   and `docker` ecosystems, and the repo contains neither GitHub Actions
>   workflow files nor a Dockerfile — so it has nothing to update.
> - GitHub secret-scanning push protection, if enabled, is configured
>   repository-side and is not verifiable from this tree.
>
> What *is* actually running is on-host, not in CI:
>
> - **Secret management**: secrets are age-encrypted with SOPS in a separate
>   git repo (`/etc/nixos/secrets/`, consumed as the `secrets` flake input);
>   `/secrets` is excluded by `.gitignore`.
> - **Container CVE scanning**: `container-cve-exporter.service` runs Trivy
>   weekly over the deployed images and exports fixable-CVE counts to
>   Prometheus; accepted findings are listed in `.trivyignore`.
> - **File integrity**: `modules/security/aide.nix` maintains an AIDE ruleset
>   over system configuration paths.

## Response Timeline

Security issues will be addressed as follows:
- **Critical vulnerabilities**: Within 24-48 hours
- **High severity**: Within 1 week
- **Medium/Low severity**: Within 2-4 weeks

## Disclosure Policy

This is a personal configuration repository. Once a vulnerability is fixed, details may be shared in the commit history and release notes.
