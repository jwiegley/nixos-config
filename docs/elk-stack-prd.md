# Product Requirements Document: ELK Stack Implementation for NixOS

## Document Information
- **Version**: 1.0
- **Date**: 2025-01-30
- **Author**: System Architecture Team
- **Status**: Draft

## 1. Executive Summary

### 1.1 Purpose
Implement a comprehensive log aggregation, monitoring, and analysis solution using the ELK (Elasticsearch, Logstash, Kibana) stack on the NixOS system "vulcan" to centralize log management and provide actionable insights from system and application logs.

### 1.2 Objectives
- Centralize all system logs from journald, services, and applications
- Provide real-time log search and analysis capabilities
- Create visualizations and dashboards for operational insights
- Establish log retention and lifecycle management policies
- Integrate with existing Prometheus/Grafana monitoring infrastructure

## 2. Background and Context

### 2.1 Current State
- **Operating System**: NixOS unstable (state version 25.05)
- **Host**: vulcan (x86_64 Linux on Apple T2 hardware)
- **Existing Monitoring**: Prometheus + Grafana stack
- **Container Platform**: Podman with Quadlet for systemd integration
- **Certificate Authority**: step-ca for TLS certificate management
- **Storage**: ZFS filesystem with automated snapshots and replication

### 2.2 Problem Statement
Currently, logs are distributed across:
- systemd-journald (system services)
- Individual application log files
- Container logs in Podman
- Database logs (PostgreSQL)
- Web server logs (nginx)

This fragmentation makes it difficult to:
- Correlate events across services
- Perform root cause analysis
- Maintain compliance with log retention requirements
- Search historical logs efficiently

### 2.3 Constraints
- **Kibana Availability**: No native NixOS package available (removed due to licensing)
- **Elasticsearch Version**: Limited to 7.17.27 (last Apache 2.0 licensed version)
- **Resource Limitations**: Must coexist with existing services
- **Security Requirements**: All services must use TLS with step-ca certificates

## 3. Requirements

### 3.1 Functional Requirements

#### 3.1.1 Log Collection
- **FR-1**: Collect logs from systemd-journald for all system services
- **FR-2**: Ingest nginx access and error logs
- **FR-3**: Capture PostgreSQL query and error logs
- **FR-4**: Collect Podman container logs
- **FR-5**: Support custom application log formats
- **FR-6**: Maintain log source attribution and timestamps

#### 3.1.2 Log Processing
- **FR-7**: Parse and structure log data into standardized fields
- **FR-8**: Enrich logs with GeoIP data for web traffic
- **FR-9**: Extract and index key-value pairs from structured logs
- **FR-10**: Support multi-line log aggregation (stack traces)

#### 3.1.3 Storage and Retention
- **FR-11**: Store logs with configurable retention periods:
  - System logs: 30 days
  - Application logs: 90 days
  - Security logs: 365 days
- **FR-12**: Implement index lifecycle management (ILM)
- **FR-13**: Compress older indices to save storage
- **FR-14**: Automatic cleanup of expired logs

#### 3.1.4 Search and Analysis
- **FR-15**: Full-text search across all log fields
- **FR-16**: Time-based filtering and aggregation
- **FR-17**: Support for complex queries using Lucene syntax
- **FR-18**: Real-time log streaming

#### 3.1.5 Visualization
- **FR-19**: Pre-built dashboards for common log patterns
- **FR-20**: Custom visualization creation capabilities
- **FR-21**: Alert creation based on log patterns
- **FR-22**: Export capabilities for reports

### 3.2 Non-Functional Requirements

#### 3.2.1 Performance
- **NFR-1**: Ingest minimum 1000 logs/second
- **NFR-2**: Search response time < 3 seconds for 30-day window
- **NFR-3**: Dashboard load time < 5 seconds

#### 3.2.2 Security
- **NFR-4**: All external endpoints must use TLS
- **NFR-5**: Authentication required for Kibana access
- **NFR-6**: Elasticsearch restricted to localhost only
- **NFR-7**: Log data encryption at rest

#### 3.2.3 Availability
- **NFR-8**: 99.9% uptime for log ingestion
- **NFR-9**: Automatic service recovery on failure
- **NFR-10**: No data loss during service restarts

#### 3.2.4 Scalability
- **NFR-11**: Support growth to 100GB of logs/month
- **NFR-12**: Ability to add cluster nodes in future

## 4. Technical Architecture

### 4.1 Component Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Log Sources                          │
├──────────────┬────────────┬───────────┬────────────────┤
│ systemd      │   nginx    │ PostgreSQL│    Podman      │
│ journald     │   logs     │   logs    │   containers   │
└──────┬───────┴─────┬──────┴────┬──────┴────────┬───────┘
       │             │           │               │
       └─────────────┴───────────┴───────────────┘
                             │
                    ┌────────▼────────┐
                    │    Filebeat     │ (NixOS Service)
                    │   (Collector)   │
                    └────────┬────────┘
                             │ Port 5044
                    ┌────────▼────────┐
                    │    Logstash     │ (NixOS Service)
                    │   (Processor)   │
                    └────────┬────────┘
                             │ Port 9200
                    ┌────────▼────────┐
                    │  Elasticsearch  │ (NixOS Service)
                    │    (Storage)    │
                    └────────┬────────┘
                             │ Port 9200
                    ┌────────▼────────┐
                    │     Kibana      │ (Podman Container)
                    │ (Visualization) │
                    └────────┬────────┘
                             │ Port 5601
                    ┌────────▼────────┐
                    │   nginx proxy   │ (TLS Termination)
                    │                 │
                    └─────────────────┘
```

### 4.2 Technology Stack

| Component | Technology | Version | Deployment Method |
|-----------|------------|---------|------------------|
| Search Engine | Elasticsearch | 7.17.27 | NixOS Service |
| Log Processor | Logstash | 7.17.x | NixOS Service |
| Log Shipper | Filebeat | 7.17.x | NixOS Service |
| Visualization | Kibana | 7.17.x | Podman Container |
| Reverse Proxy | nginx | Latest | NixOS Service |
| TLS Certificates | step-ca | Latest | NixOS Service |

### 4.3 Network Architecture

- **Elasticsearch**: 127.0.0.1:9200 (localhost only)
- **Logstash Beats Input**: 127.0.0.1:5044
- **Kibana**: 127.0.0.1:5601 → nginx proxy → https://kibana.vulcan.lan
- **Container Network**: Podman network 10.88.0.0/16

## 5. Implementation Plan

### 5.1 Module Structure

```
/etc/nixos/modules/
├── services/
│   ├── elk-stack.nix              # Main ELK configuration
│   ├── elasticsearch.nix          # Elasticsearch service config
│   ├── logstash.nix              # Logstash pipelines
│   └── filebeat.nix              # Filebeat inputs
├── containers/
│   └── kibana-quadlet.nix        # Kibana container definition
└── monitoring/
    └── alerts/
        └── elk.yaml               # ELK-specific Prometheus alerts
```

### 5.2 Configuration Details

#### 5.2.1 Elasticsearch Configuration
```nix
services.elasticsearch = {
  enable = true;
  package = pkgs.elasticsearch;
  dataDir = "/var/lib/elasticsearch";
  listenAddress = "127.0.0.1";
  port = 9200;
  extraJavaOptions = [ "-Xms2g" "-Xmx2g" ];
  extraConf = ''
    cluster.name: vulcan-logs
    node.name: vulcan-node1
    path.repo: ["/var/backup/elasticsearch"]
    indices.query.bool.max_clause_count: 4096
  '';
};
```

#### 5.2.2 Logstash Pipeline Configuration
```ruby
input {
  beats {
    port => 5044
    host => "127.0.0.1"
  }
}

filter {
  # Parse systemd fields
  if [systemd] {
    mutate {
      rename => {
        "systemd.unit" => "service_name"
        "systemd.priority" => "log_level"
      }
    }
  }

  # Parse nginx logs
  if [service_name] == "nginx" {
    grok {
      match => {
        "message" => "%{COMBINEDAPACHELOG}"
      }
    }
    geoip {
      source => "clientip"
    }
  }
}

output {
  elasticsearch {
    hosts => ["localhost:9200"]
    index => "logs-%{[service_name]}-%{+YYYY.MM.dd}"
  }
}
```

#### 5.2.3 Filebeat Input Configuration
```yaml
filebeat.inputs:
- type: journald
  id: systemd-input
  paths: ["/var/log/journal"]

- type: log
  paths:
    - /var/log/nginx/access.log
  fields:
    service_name: nginx
    log_type: access

- type: log
  paths:
    - /var/log/postgresql/*.log
  fields:
    service_name: postgresql
  multiline.pattern: '^\d{4}-\d{2}-\d{2}'
  multiline.negate: true
  multiline.match: after

output.logstash:
  hosts: ["localhost:5044"]
```

#### 5.2.4 Kibana Container (Quadlet)
```ini
[Unit]
Description=Kibana Container
After=network-online.target elasticsearch.service
Wants=network-online.target

[Container]
Image=docker.elastic.co/kibana/kibana:7.17.27
Network=podman
PublishPort=127.0.0.1:5601:5601
Environment=ELASTICSEARCH_HOSTS=http://host.containers.internal:9200
Environment=SERVER_HOST=0.0.0.0
Environment=SERVER_NAME=kibana.vulcan.lan
Volume=/etc/kibana/kibana.yml:/usr/share/kibana/config/kibana.yml:ro
HealthCheck="/usr/share/kibana/bin/kibana-health"
HealthCheckInterval=30s
HealthCheckRetries=3

[Service]
Restart=always
RestartSec=10
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
```

### 5.3 Storage Requirements

| Component | Storage Path | Initial Size | Growth Rate | Retention |
|-----------|-------------|--------------|-------------|-----------|
| Elasticsearch Data | /var/lib/elasticsearch | 10GB | 3GB/month | Variable by index |
| Elasticsearch Backups | /var/backup/elasticsearch | 5GB | 1GB/month | 7 days |
| Logstash Queue | /var/lib/logstash | 1GB | Static | N/A |
| Filebeat Registry | /var/lib/filebeat | 100MB | Minimal | N/A |

### 5.4 Integration Points

#### 5.4.1 Prometheus Integration
- Add elasticsearch_exporter for metrics collection
- Create Grafana dashboard for ELK stack health
- Configure alerts for:
  - Elasticsearch cluster health status
  - Log ingestion rate anomalies
  - Disk space utilization

#### 5.4.2 Backup Integration
- Add Elasticsearch snapshots to Restic backup configuration
- Include Kibana saved objects in backup routine
- Test restore procedures

## 6. Security Considerations

### 6.1 Network Security
- Elasticsearch bound to localhost only
- Kibana accessed only through nginx reverse proxy
- All external access requires TLS

### 6.2 Authentication & Authorization
- Initial deployment with nginx basic auth
- Future migration to Elasticsearch native security
- Role-based access control (RBAC) for Kibana

### 6.3 Data Protection
- Logs stored on encrypted ZFS dataset
- Regular snapshots via ZFS
- Backup to remote location via Restic

## 7. Monitoring and Alerting

### 7.1 Key Metrics
- Elasticsearch cluster health (green/yellow/red)
- Index size and document count
- Log ingestion rate (logs/second)
- Search query performance (p95 latency)
- Disk space utilization

### 7.2 Alert Conditions
- Cluster health != green for > 5 minutes
- Disk usage > 80%
- Log ingestion rate drop > 50%
- Failed authentication attempts > 10/minute

## 8. Success Criteria

### 8.1 Technical Success
- [ ] All log sources successfully ingesting
- [ ] Search queries return results in < 3 seconds
- [ ] 30 days of logs accessible
- [ ] Zero data loss during normal operations

### 8.2 Operational Success
- [ ] Reduced MTTR for incident investigation by 50%
- [ ] Automated log retention management
- [ ] Self-service log access for authorized users
- [ ] Integration with existing monitoring

## 9. Risks and Mitigations

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| Elasticsearch memory pressure | High | Medium | Set JVM heap limits, monitor usage |
| Disk space exhaustion | High | Medium | Implement ILM, monitor disk usage |
| Kibana container instability | Medium | Low | Use Quadlet with auto-restart |
| Log parsing failures | Medium | Medium | Implement dead letter queue |
| Performance degradation | Medium | Low | Index optimization, shard management |

## 10. Implementation Timeline

### Phase 1: Foundation (Week 1)
- [ ] Create NixOS modules structure
- [ ] Deploy Elasticsearch service
- [ ] Configure storage and backups

### Phase 2: Log Pipeline (Week 2)
- [ ] Configure Logstash pipelines
- [ ] Deploy Filebeat with basic inputs
- [ ] Test log flow end-to-end

### Phase 3: Visualization (Week 3)
- [ ] Deploy Kibana container via Quadlet
- [ ] Configure nginx reverse proxy with TLS
- [ ] Import standard dashboards

### Phase 4: Integration (Week 4)
- [ ] Integrate with Prometheus monitoring
- [ ] Configure alerts
- [ ] Performance tuning
- [ ] Documentation

## 11. Testing Strategy

### 11.1 Unit Testing
- Validate individual Logstash filters
- Test Filebeat input configurations
- Verify Elasticsearch mappings

### 11.2 Integration Testing
- End-to-end log flow verification
- Search and query performance
- Dashboard loading and visualization

### 11.3 Load Testing
- Simulate 1000 logs/second ingestion
- Concurrent search query handling
- Storage growth projection

## 12. Documentation Requirements

- Installation and configuration guide
- Troubleshooting procedures
- Query examples and patterns
- Dashboard creation tutorial
- Backup and restore procedures

## 13. Maintenance Considerations

### 13.1 Regular Tasks
- Weekly: Review cluster health and performance
- Monthly: Analyze storage usage and growth
- Quarterly: Update index templates and mappings
- Annually: Review retention policies

### 13.2 Upgrade Path
- Plan for migration to Elasticsearch 8.x when licensing permits
- Container-based deployment for easier upgrades
- Version pinning in Nix configuration

## 14. Cost-Benefit Analysis

### 14.1 Benefits
- Centralized log management
- Faster incident resolution
- Compliance with audit requirements
- Proactive issue detection
- Knowledge retention through saved searches

### 14.2 Resource Costs
- ~4GB RAM for Elasticsearch
- ~1GB RAM for Logstash
- ~512MB RAM for Kibana
- ~15GB initial disk space
- ~3GB/month storage growth

## 15. Appendices

### A. Reference Documentation
- [Elasticsearch 7.17 Documentation](https://www.elastic.co/guide/en/elasticsearch/reference/7.17/)
- [NixOS Services Manual](https://nixos.org/manual/nixos/stable/)
- [Podman Quadlet Documentation](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)

### B. Configuration Templates
Available in `/etc/nixos/modules/services/elk-templates/`

### C. Troubleshooting Guide
Common issues and resolutions documented in operational runbook

---

## Document Approval

| Role | Name | Date | Signature |
|------|------|------|-----------|
| System Administrator | | | |
| Security Officer | | | |
| Operations Manager | | | |

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-01-30 | System Architecture Team | Initial draft |