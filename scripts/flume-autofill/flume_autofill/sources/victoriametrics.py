"""VictoriaMetrics query client (Prometheus-compatible HTTP API).

We use `/api/v1/query_range` because the cross-check needs per-minute
samples over a multi-day window, which is exactly the matrix shape VM
returns from a range query.
"""
from __future__ import annotations

from datetime import datetime, timezone

import requests


class VMSource:
    """Read-only VictoriaMetrics client used by Phases 2 and 3."""

    def __init__(self, base_url: str) -> None:
        self._base = base_url.rstrip("/")

    def query_range(
        self,
        metric: str,
        start: datetime,
        end: datetime,
        step: str = "60s",
    ) -> list[tuple[datetime, float]]:
        """Return (timestamp_utc, value) pairs from a PromQL/MetricsQL range query.

        Flattens all matched series into a single time-sorted list. The
        cross-check always queries a single entity, so multiple-series
        results would indicate a query mistake; we still tolerate them by
        concatenating.
        """
        resp = requests.get(
            f"{self._base}/api/v1/query_range",
            params={
                "query": metric,
                "start": int(start.timestamp()),
                "end": int(end.timestamp()),
                "step": step,
            },
            timeout=60,
        )
        resp.raise_for_status()
        data = resp.json()["data"]
        if not data.get("result"):
            return []
        out: list[tuple[datetime, float]] = []
        for serie in data["result"]:
            for ts, val in serie.get("values", []):
                out.append(
                    (
                        datetime.fromtimestamp(int(ts), tz=timezone.utc),
                        float(val),
                    )
                )
        out.sort(key=lambda r: r[0])
        return out

    @staticmethod
    def vm_entity_id(entity_id: str) -> str:
        """Strip the HA `<domain>.` prefix for VM lookup.

        The HA InfluxDB integration writes only the entity name (post-dot
        segment) into VM's `entity_id` label, with the domain captured
        separately in the `domain` label. So `sensor.flume_x_current` becomes
        `entity_id="flume_x_current", domain="sensor"` in VM.
        """
        return entity_id.split(".", 1)[1] if "." in entity_id else entity_id

    def query_flume_current(
        self, entity_id: str, start: datetime, end: datetime
    ) -> list[tuple[datetime, float]]:
        """Convenience: pull a single HA-entity GPM series at 1-minute resolution."""
        vm_id = self.vm_entity_id(entity_id)
        return self.query_range(
            metric=f'last_over_time({{entity_id="{vm_id}"}}[1m])',
            start=start,
            end=end,
            step="60s",
        )
