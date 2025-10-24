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

This repository contains personal NixOS system configurations. Security is maintained through:

- **Automated Scanning**: CodeQL, Dependabot, and multiple third-party security tools continuously monitor for vulnerabilities
- **Secret Protection**: Push protection prevents accidental credential commits
- **Dependency Updates**: Automated security and version updates via Dependabot
- **Code Scanning**: Multiple static analysis tools check for security issues

## Response Timeline

Security issues will be addressed as follows:
- **Critical vulnerabilities**: Within 24-48 hours
- **High severity**: Within 1 week
- **Medium/Low severity**: Within 2-4 weeks

## Disclosure Policy

This is a personal configuration repository. Once a vulnerability is fixed, details may be shared in the commit history and release notes.
