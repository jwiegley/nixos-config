# NixOS Configuration Enhancement

Ultrathink. Use nix-pro to proceed with analysis or implementation of the
following design within the current NixOS installation.

- Do not, under any circumstances, decrypt the SOPS secrets.yaml file.
- Do not, under any circumstances, change how the system boots. It is not
  compatible with systemd-boot, which is why GRUB is being used.
- GRUB configuration optimization is permitted, but boot method must remain GRUB.

Other than these restrictions, feel free to use the NixOS MCP server and Web
Search as much as necessary to resolve the requests given.

## Executive Summary

This PRD outlines a comprehensive enhancement plan for the NixOS configuration
of the "vulcan" host system. The configuration currently has a solid
foundation but requires security hardening, monitoring improvements, and
modernization to meet production standards. This document provides a
structured approach to transform the system into a security-hardened, highly
maintainable, and observable NixOS deployment.

## Constraints and Requirements

### Critical Constraints (DO NOT VIOLATE)

1. **SOPS Secrets**: Do not decrypt or access the SOPS secrets.yaml file under
   any circumstances
2. **Boot System**: Maintain GRUB as the boot loader - system is incompatible
   with systemd-boot
3. **State Preservation**: System state version must remain at 25.05
4. **Service Continuity**: Minimize service disruption during implementation

### Technical Requirements

- **Hardware**: Apple T2 x86_64-linux system with 64GB RAM
- **Storage**: ZFS with rpool (system) and tank (data) pools
- **Backup**: Restic to Backblaze B2 (not rsync.net as incorrectly documented)
- **Containers**: Podman (not Docker) for containerized services
- **Certificates**: Step-CA for internal certificate management

## Current State Analysis

### System Strengths (Preserve)

- Well-organized modular configuration structure
- Comprehensive Restic backup strategy to Backblaze B2
- Step-CA integration for certificate management
- SOPS-nix for secrets management
- ZFS with Sanoid for automatic snapshots
- Good package selection and organization

### Service Inventory

- **Databases**: PostgreSQL 16 with pgvector, SSL/TLS enabled
- **Web Services**: nginx (NixOS container), Organizr, Wallabag, SillyTavern
  (Podman)
- **Infrastructure**: Step-CA, Restic backups, SmokePing, Logwatch
- **Containers**: LiteLLM and multiple web apps via Podman
- **Storage**: ZFS with monthly scrubs, Sanoid snapshots

## Implementation Phases

### Phase 1: Critical Security & Foundation (Week 1-2) [MVP]

#### 1.1 Security Hardening

- [ ] Enable audit framework (auditd) with security monitoring rules
- [ ] Configure AppArmor in permissive mode (preparation for enforcement)

#### 1.2 Basic Monitoring Infrastructure

- [ ] Deploy Prometheus with retention configuration
- [ ] Configure node_exporter for system metrics
- [ ] Setup PostgreSQL exporter for database monitoring
- [ ] Implement systemd exporter for service health
- [ ] Create comprehensive alert rules for critical metrics

#### 1.3 Documentation Updates

- [ ] Correct backup destination references (B2, not rsync.net)
- [ ] Document all security changes and new procedures
- [ ] Create runbooks for common operations

### Phase 2: Performance & Reliability (Week 3-4)

#### 2.1 ZFS Optimization

- [ ] Tune ARC settings for 64GB RAM system
  - Target: arc_max = 32GB (50% of RAM)
  - Configure arc_min = 4GB
  - Enable compression: lz4 for general, zstd for archival
- [ ] Add ZFS performance monitoring and alerting

#### 2.2 Backup Enhancements

- [ ] Implement automated restore testing (monthly)
- [ ] Add backup completion monitoring
- [ ] Create backup status dashboard
- [ ] Document and test disaster recovery procedures
- [ ] Implement 3-2-1 backup strategy validation

#### 2.3 Service Dependencies & Health

- [ ] Configure proper systemd service ordering
- [ ] Implement health checks with automatic restart policies
- [ ] Set resource limits per service (memory, CPU)
- [ ] Create graceful shutdown procedures
- [ ] Add service dependency visualization

#### 2.4 Configuration Testing

- [ ] Implement pre-deployment validation
- [ ] Create rollback procedures and documentation
- [ ] Setup staging environment in VM
- [ ] Add configuration drift detection

### Phase 3: Advanced Security & Observability (Week 5-6)

#### 3.1 Full Monitoring Stack

- [ ] Deploy Grafana with pre-configured dashboards
- [ ] Implement Loki for centralized log aggregation
- [ ] Configure Alertmanager with routing rules
- [ ] Setup Blackbox exporter for endpoint monitoring
- [ ] Create SLI/SLO dashboards

#### 3.2 Advanced Hardening

- [ ] Enforce AppArmor profiles for all services
- [ ] Implement comprehensive audit logging

#### 3.3 Security Automation

- [ ] Automated vulnerability scanning
- [ ] Security compliance reporting
- [ ] Automated security updates with testing
- [ ] Incident response automation

### Phase 4: Optimization & Modernization (Week 7-8)

#### 4.1 Configuration Modularization

- [ ] Convert to proper NixOS modules with options
- [ ] Create reusable security profiles
- [ ] Implement configuration as code best practices
- [ ] Create module documentation generation

#### 4.2 Container Strategy

- [ ] Evaluate each Podman container for NixOS container migration
- [ ] Decision criteria:
  - Stateless services → NixOS containers
  - Complex dependencies → Keep Podman
  - Performance critical → Native NixOS services
- [ ] Implement container security policies
- [ ] Configure container resource management
- [ ] Setup container registry with security scanning

#### 4.3 Performance Optimization

- [ ] Analyze metrics and optimize based on data
- [ ] Implement caching strategies

#### 4.4 Automation & Self-Healing

- [ ] Implement self-healing for common issues
- [ ] Automated certificate renewal and distribution
- [ ] Predictive alerting based on trends
- [ ] Automated capacity planning

## Success Metrics

### Phase 1 Metrics (Security)

- **SSH Security**: Zero successful root login attempts
- **fail2ban Effectiveness**: >95% malicious attempt blocking rate
- **Monitoring Coverage**: 100% service failure detection
- **Audit Compliance**: All security events logged

### Phase 2 Metrics (Performance)

- **Backup Reliability**: 100% successful restore tests
- **Service Availability**: Zero unplanned outages
- **Resource Utilization**: <70% baseline CPU/memory usage

## Risk Management

### Technical Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| ZFS data loss during optimization | Critical | Full backup verification before changes, VM testing, maintain snapshots |
| Service disruption during hardening | High | Staged rollout, maintenance windows (2-4 AM PST), instant rollback capability |
| Boot failure after kernel changes | Critical | Maintain 3+ working generations, rescue media prepared, console access |
| Performance degradation from security | Medium | Baseline metrics, incremental changes, performance testing |
| Backup corruption | Critical | Multiple backup destinations, regular restore tests, integrity checks |

### Operational Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| Scope creep | Medium | Strict phase boundaries, clear success criteria |
| Knowledge gaps | Medium | Documentation, training, external expertise when needed |
| Maintenance overhead | Medium | Automation focus, monitoring to prevent issues |
| Compliance requirements | Low | Regular audits, documentation, security scanning |

## Testing Strategy

### Pre-Production Testing

- **Configuration Validation**: `sudo nixos-rebuild build` before deployment
- **VM Testing**: Full configuration in `sudo nixos-rebuild build-vm`
- **Security Testing**: Configuration scanning, vulnerability assessment
- **Performance Testing**: Load testing, stress testing, chaos engineering

### Rollback Procedures

1. **Immediate Rollback**: `sudo nixos-rebuild switch --rollback`
2. **Generation Selection**: `sudo nixos-rebuild switch --profile /nix/var/nix/profiles/system --rollback`

### Validation Criteria

- All services start successfully
- No security warnings in logs
- Performance metrics within acceptable range
- All health checks passing
- Backup operations successful

## Implementation Guidelines

### Daily Operations

- Monitor Prometheus dashboards
- Review security alerts
- Check backup completion
- Validate service health

### Weekly Tasks

- Review performance metrics
- Check for security updates
- Validate backup integrity
- Update documentation

### Monthly Tasks

- Full backup restore test
- Security audit review
- Performance optimization review
- Capacity planning update

### Quarterly Tasks

- Disaster recovery drill
- Security assessment
- Architecture review
- Documentation audit

## Appendix A: Technical Specifications

### System Configuration

- **OS**: NixOS unstable channel with flakes
- **Kernel**: Latest stable with hardening patches
- **Network**: NetworkManager with firewall enabled

### Storage Configuration

- **ZFS Pools**:
  - rpool: System datasets, SSD-based
  - tank: Data datasets, HDD-based
- **Backup Targets**:
  - Backblaze B2 via Restic

### Service Ports

- SSH: 22 (rate-limited)
- PostgreSQL: 5432 (localhost + VPN only)
- step-ca: 8443 (internal only)
- Prometheus: 9090 (localhost only)
- Node Exporter: 9100 (localhost only)

### Security Policies

- **Authentication**: Key-based only, no passwords
- **Authorization**: RBAC with minimal privileges
- **Encryption**: TLS 1.2+ for all services
- **Auditing**: All privileged operations logged
- **Compliance**: CIS benchmarks where applicable

## Appendix B: Decision Log

### Key Decisions Made

1. **Container Strategy**: Keep Podman for complex apps, migrate simple
   services to NixOS containers
2. **Monitoring Stack**: Prometheus/Grafana over alternatives for NixOS
   integration
3. **Backup Strategy**: Continue with B2, add local backup in Phase 2
4. **Boot System**: Maintain GRUB despite systemd-boot being preferred in
   NixOS

## Appendix C: Reference Documentation

### Internal Documentation

- `/etc/nixos/CLAUDE.md`: System overview and commands
- `/etc/nixos/certs/CERTIFICATES.md`: Certificate management procedures
- `/etc/nixos/MIGRATION.md`: Migration notes from previous system

### External Resources

- [NixOS Manual](https://nixos.org/manual/nixos/stable/)
- [NixOS Security](https://nixos.wiki/wiki/Security)
- [systemd Hardening](https://www.freedesktop.org/software/systemd/man/systemd.exec.html)
- [CIS Benchmarks](https://www.cisecurity.org/cis-benchmarks/)
- [NIST Cybersecurity Framework](https://www.nist.gov/cyberframework)

## Document Control

- **Version**: 2.0
- **Date**: 2025-09-24
- **Author**: John Wiegley, Claude Opus
- **Review Cycle**: Weekly during implementation, monthly thereafter
- **Next Review**: Start of Phase 1 implementation

---

*This PRD is a living document and will be updated as implementation
progresses and new requirements are identified.*
