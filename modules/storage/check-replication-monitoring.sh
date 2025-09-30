#!/usr/bin/env bash

echo "=== ZFS Replication Monitoring Status ==="
echo ""

echo "1. Checking syncoid services..."
for service in syncoid-rpool-home syncoid-rpool-nix syncoid-rpool-root; do
  if systemctl is-active --quiet "$service.timer"; then
    echo "  ✓ $service.timer is active"
  else
    echo "  ✗ $service.timer is not active"
  fi
done

echo ""
echo "2. Checking Prometheus monitoring..."
if systemctl is-active --quiet prometheus; then
  echo "  ✓ Prometheus is running"
else
  echo "  ✗ Prometheus is not running"
fi

echo ""
echo "3. Checking AlertManager..."
if systemctl is-active --quiet alertmanager 2>/dev/null; then
  echo "  ✓ AlertManager is running"
else
  echo "  ✗ AlertManager is not yet running (will start after nixos-rebuild switch)"
fi

echo ""
echo "4. Checking Grafana..."
if systemctl is-active --quiet grafana; then
  echo "  ✓ Grafana is running"
  echo "     Access at: https://grafana.vulcan.lan"
else
  echo "  ✗ Grafana is not running"
fi

echo ""
echo "To apply the new monitoring configuration, run:"
echo "  sudo nixos-rebuild switch --flake .#vulcan"
echo ""
echo "After applying, you can:"
echo "  - Check replication status: check-zfs-replication"
echo "  - View active alerts: curl -s localhost:9090/api/v1/alerts | jq"
echo "  - Test email alerts: systemctl start zfs-replication-alert@test"
echo "  - Trigger manual replication: systemctl start zfs-replication-manual"
echo "  - View Grafana dashboard: https://grafana.vulcan.lan (ZFS Replication Monitoring)"
