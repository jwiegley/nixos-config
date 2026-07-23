import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import daemon
import pytest

def test_allowlist_is_exactly_the_authorized_actions():
    assert daemon.ACTION_ALLOWLIST == (
        "restart_microvm",
        "doctor_fix",
        "prune_stale_plugin_deps",
        "restage_secrets",
        "restart_canary",
        "restart_mcporter_check",
    )

def test_validate_action_accepts_allowlisted():
    for a in daemon.ACTION_ALLOWLIST:
        assert daemon.validate_action(a) == a

def test_validate_action_rejects_unknown():
    with pytest.raises(daemon.ActionRejectedError):
        daemon.validate_action("rm_rf_slash")

def test_validate_action_rejects_with_args():
    with pytest.raises(daemon.ActionRejectedError):
        daemon.validate_action("restart_microvm; rm -rf /")

def test_validate_action_rejects_path_traversal():
    with pytest.raises(daemon.ActionRejectedError):
        daemon.validate_action("../../bin/sh")


import time

def test_correlation_key_groups_distinct_alerts_in_same_bucket():
    """Multiple distinct alerts of one outage that fire in the same time
    bucket correlate into a single incident."""
    a = {"alert_name": "OpenClawDiscordWsDown", "vm_active_enter_ts": 1000, "starts_at": 5000}
    b = {"alert_name": "OpenClawDiscordPluginMissing", "vm_active_enter_ts": 1000, "starts_at": 5000}
    assert daemon.correlation_key(a) == daemon.correlation_key(b)

def test_correlation_key_same_across_self_inflicted_vm_restart():
    """A restart_microvm remediation changes vm_active_enter_ts. The
    correlation key must NOT change with it — otherwise the same firing
    episode is re-tracked as a brand-new incident on every restart and the
    attempt counter never reaches the stuck threshold (root cause of the
    2026-07-22 unbounded restart storm). Same alert + same startsAt bucket
    stays one incident regardless of the VM boot timestamp."""
    a = {"alert_name": "OpenClawHttpHealthDown", "vm_active_enter_ts": 1000, "starts_at": 5000}
    b = {"alert_name": "OpenClawHttpHealthDown", "vm_active_enter_ts": 2000, "starts_at": 5000}
    assert daemon.correlation_key(a) == daemon.correlation_key(b)

def test_attempt_n_starts_at_one_for_new_incident():
    inc = daemon.new_incident({"alert_name": "OpenClawDiscordWsDown",
                               "vm_active_enter_ts": 1000})
    assert daemon.next_attempt_n(inc) == 1

def test_attempt_n_increments_with_recorded_attempts():
    inc = daemon.new_incident({"alert_name": "OpenClawDiscordWsDown",
                               "vm_active_enter_ts": 1000})
    inc["attempts"].append({"action": "restart_microvm", "result": "ok"})
    assert daemon.next_attempt_n(inc) == 2

def test_should_escalate_after_three_attempts():
    inc = daemon.new_incident({"alert_name": "OpenClawDiscordWsDown",
                               "vm_active_enter_ts": 1000})
    inc["attempts"] = [{"x": 1}, {"x": 2}, {"x": 3}]
    assert daemon.should_escalate(inc) is True

def test_should_not_escalate_at_attempt_three():
    inc = daemon.new_incident({"alert_name": "OpenClawDiscordWsDown",
                               "vm_active_enter_ts": 1000})
    inc["attempts"] = [{"x": 1}, {"x": 2}]
    assert daemon.should_escalate(inc) is False

def test_correlation_separates_after_five_minutes_even_with_same_vm_ts():
    a = {"alert_name": "OpenClawDiscordWsDown", "vm_active_enter_ts": 1000,
         "starts_at": 5000}
    b = {"alert_name": "OpenClawDiscordWsDown", "vm_active_enter_ts": 1000,
         "starts_at": 5400}  # 400 s later, well past 5-min window
    assert daemon.correlation_key(a, window_s=300) != daemon.correlation_key(b, window_s=300)


import json

def test_state_load_returns_default_on_missing_file(tmp_path):
    path = tmp_path / "incidents.json"
    state = daemon.load_state(path)
    assert state == {"active": {}, "history": []}

def test_state_roundtrip(tmp_path):
    path = tmp_path / "incidents.json"
    state = {"active": {"k": {"x": 1}}, "history": [{"y": 2}]}
    daemon.save_state(path, state)
    assert daemon.load_state(path) == state


def test_action_map_each_alert_maps_to_known_action_or_wait():
    for action in daemon.ACTION_MAP.values():
        assert action in daemon.ACTION_ALLOWLIST or action == "wait_60s"

def test_action_map_covers_expected_alerts():
    for a in (
        "OpenClawDiscordWsDown", "OpenClawHttpHealthDown",
        "OpenClawGatewayReadyStale", "OpenClawDiscordPluginMissing",
        "OpenClawPluginInitFailuresPresent", "OpenClawMicroVMDown",
    ):
        assert a in daemon.ACTION_MAP


def test_run_action_invokes_sudo_with_exact_path(monkeypatch):
    calls = []
    def fake_run(cmd, capture_output, text, timeout):
        calls.append(cmd)
        class R: returncode = 0; stdout = '{"ok": true}'; stderr = ""
        return R()
    monkeypatch.setattr(daemon.subprocess, "run", fake_run)
    result = daemon.run_action("restart_microvm")
    assert calls == [[
        "sudo", "-n",
        "/etc/nixos/scripts/openclaw-self-heal/actions/restart_microvm",
    ]]
    assert result["ok"] is True

def test_run_action_rejects_non_allowlisted(monkeypatch):
    monkeypatch.setattr(daemon.subprocess, "run",
                        lambda *a, **k: (_ for _ in ()).throw(AssertionError("must not call")))
    with pytest.raises(daemon.ActionRejectedError):
        daemon.run_action("rm_rf_slash")

def test_run_action_handles_nonjson_output(monkeypatch):
    def fake_run(cmd, capture_output, text, timeout):
        class R: returncode = 0; stdout = "not json"; stderr = ""
        return R()
    monkeypatch.setattr(daemon.subprocess, "run", fake_run)
    result = daemon.run_action("restart_microvm")
    assert result["ok"] is False
    assert "non-json" in result["notes"].lower()


def test_render_prompt_includes_alert_and_attempts():
    inc = daemon.new_incident({"alert_name": "OpenClawDiscordWsDown",
                               "vm_active_enter_ts": 1000,
                               "starts_at": 5000})
    inc["alerts"] = ["OpenClawDiscordWsDown"]
    inc["attempts"] = [{"action": "restart_microvm", "by": "deterministic",
                        "result": "ok"}]
    msgs = daemon.render_prompt(inc, metrics={"x": 1}, err_log_tail="oops",
                                out_log_tail="hi")
    assert any("restart_microvm" in m["content"] for m in msgs)
    assert any("OpenClawDiscordWsDown" in m["content"] for m in msgs)
    assert msgs[0]["role"] == "system"

def test_render_prompt_redacts_discord_token_pattern():
    inc = daemon.new_incident({"alert_name": "OpenClawDiscordWsDown",
                               "vm_active_enter_ts": 1, "starts_at": 1})
    tok = "DISCORD_TOKEN_REDACTED"
    msgs = daemon.render_prompt(inc, metrics={}, err_log_tail=f"got token={tok}",
                                out_log_tail="")
    joined = " ".join(m["content"] for m in msgs)
    assert tok not in joined
    assert "[REDACTED]" in joined


def test_call_litellm_returns_parsed_action(monkeypatch):
    def fake_post(url, headers, data, timeout):
        class R:
            status = 200
            def read(self): return json.dumps({"choices":[{"message":{"content":'{"action": "doctor_fix", "reason": "stale"}'}}]}).encode()
        return R()
    monkeypatch.setattr(daemon, "_http_post_json", fake_post)
    monkeypatch.setenv("LITELLM_KEY", "x")
    out = daemon.call_litellm([{"role":"system","content":"x"}], model="hera/Qwen3.6-27B")
    assert out == {"action": "doctor_fix", "reason": "stale"}


def test_handle_payload_runs_first_attempt_action(monkeypatch, tmp_path):
    monkeypatch.setattr(daemon, "STATE_PATH", tmp_path / "incidents.json")
    monkeypatch.setattr(daemon, "current_metrics", lambda: {"openclaw_microvm_active_enter_timestamp_seconds": 9999})
    ran = []
    monkeypatch.setattr(daemon, "run_action", lambda name: ran.append(name) or {"ok": True})
    monkeypatch.setattr(daemon, "probe_clear", lambda inc: True)
    monkeypatch.setattr(daemon, "_kick_canary", lambda: None)        # hermetic: don't sudo during pytest
    monkeypatch.setattr(daemon, "emit_synthetic_alert", lambda *a, **k: None)
    monkeypatch.setattr(daemon.time, "sleep", lambda *_: None)       # hermetic: don't actually sleep 15 s
    payload = {"alerts": [{"status":"firing", "labels":{"alertname":"OpenClawDiscordWsDown","service":"openclaw"},
                          "startsAt":"2026-05-05T18:30:00Z"}]}
    daemon.handle_alertmanager_payload(payload)
    assert ran == ["restart_microvm"]


def test_write_heartbeat_emits_required_metrics(tmp_path):
    out = tmp_path / "openclaw_self_heal.prom"
    daemon.write_heartbeat(out_path=out, active_count=2, action_counts={"restart_microvm": 5})
    text = out.read_text()
    for k in ("openclaw_self_heal_last_heartbeat_seconds",
              "openclaw_self_heal_active_incidents",
              "openclaw_self_heal_attempts_total"):
        assert k in text


def test_emit_synthetic_alert_acted(monkeypatch):
    sent = []
    monkeypatch.setattr(daemon, "_http_post_json",
                        lambda url, headers, data, timeout: sent.append((url, json.loads(data))) or type("R", (), {"read": lambda self: b""})())
    daemon.emit_synthetic_alert("OpenClawSelfHealActed",
                                {"action": "restart_microvm", "alert": "OpenClawDiscordWsDown"})
    assert sent
    url, payload = sent[0]
    assert "/api/v2/alerts" in url
    assert payload[0]["labels"]["alertname"] == "OpenClawSelfHealActed"


# ---- incident eviction (sweep_resolved) ----
# Regression coverage for the bug where resolved incidents were never moved
# out of state["active"] and accumulated without bound (25 stale entries
# observed 2026-06-08). sweep_resolved archives aged resolved incidents to
# history while retaining recent ones for same-episode de-duplication.

def _resolved_inc(resolved_ts, attempts=None):
    return {
        "first_seen_ts": resolved_ts,
        "status": "resolved",
        "resolved_ts": resolved_ts,
        "attempts": attempts if attempts is not None else [{"action": "restart_microvm"}],
    }


def test_sweep_resolved_archives_aged_resolved():
    now = 1_000_000
    state = {"active": {"k1": _resolved_inc(now - daemon.RESOLVED_RETENTION_S - 1)},
             "history": []}
    assert daemon.sweep_resolved(state, now=now) == 1
    assert "k1" not in state["active"]
    assert len(state["history"]) == 1
    assert state["history"][0]["status"] == "resolved"


def test_sweep_resolved_retains_recent_resolved_for_dedup():
    """A just-resolved incident stays in active so repeat sends of the same
    firing episode (same correlation key) are de-duped, not re-triggered."""
    now = 1_000_000
    state = {"active": {"k1": _resolved_inc(now - 60)}, "history": []}
    assert daemon.sweep_resolved(state, now=now) == 0
    assert "k1" in state["active"]
    assert state["history"] == []


def test_sweep_resolved_never_archives_in_progress_or_stuck():
    now = 1_000_000
    old = now - daemon.RESOLVED_RETENTION_S - 1
    state = {
        "active": {
            "ip": {"status": "in_progress", "first_seen_ts": old, "attempts": []},
            "st": {"status": "stuck", "first_seen_ts": old, "attempts": []},
        },
        "history": [],
    }
    assert daemon.sweep_resolved(state, now=now) == 0
    assert set(state["active"]) == {"ip", "st"}
    assert state["history"] == []


def test_sweep_resolved_falls_back_to_first_seen_ts_for_legacy():
    """Legacy resolved incidents (pre-fix) have no resolved_ts; age off
    first_seen_ts. This is how the pre-existing stale backlog clears on the
    first sweep after deploy."""
    now = 1_000_000
    inc = {"status": "resolved",
           "first_seen_ts": now - daemon.RESOLVED_RETENTION_S - 1,
           "attempts": []}
    state = {"active": {"legacy": inc}, "history": []}
    assert daemon.sweep_resolved(state, now=now) == 1
    assert "legacy" not in state["active"]


def test_sweep_resolved_caps_history():
    now = 1_000_000
    old = now - daemon.RESOLVED_RETENTION_S - 1
    state = {
        "active": {f"k{i}": _resolved_inc(old) for i in range(5)},
        "history": [{"status": "resolved", "attempts": []}
                    for _ in range(daemon.HISTORY_MAX)],
    }
    daemon.sweep_resolved(state, now=now)
    assert len(state["history"]) == daemon.HISTORY_MAX
    assert state["active"] == {}


def test_sweep_resolved_preserves_attempt_total():
    """Moving resolved active->history must not change the active+history
    attempt total that heartbeat_loop sums for
    openclaw_self_heal_attempts_total."""
    now = 1_000_000
    old = now - daemon.RESOLVED_RETENTION_S - 1
    state = {
        "active": {
            "a": _resolved_inc(old, attempts=[{"action": "restart_microvm"}]),
            "b": _resolved_inc(old, attempts=[{"action": "doctor_fix"}]),
        },
        "history": [{"attempts": [{"action": "restart_microvm"}]}],
    }

    def total(s):
        return sum(len(i.get("attempts", []))
                   for i in list(s["active"].values()) + s["history"])

    before = total(state)
    daemon.sweep_resolved(state, now=now)
    assert total(state) == before == 3


# ---- orphaned-incident reconciliation (reconcile_orphans) ----
# Regression coverage for the 2026-07-03 orphan: the host rebooted 14 s after
# a restart_microvm attempt, killing the daemon inside its 15 s
# pre-verification sleep. The incident was saved as in_progress and could
# never resolve: resolution only happens via the post-action probe (resolved
# webhooks are skipped), no future webhook matches the old
# vm_active_enter_ts correlation key, and sweep_resolved only archives
# resolved incidents — so it surfaced as a phantom "1 active self-heal
# incident" in every nightly report.

_NOW = 1_000_000


def _orphan_inc(status="in_progress", vm_ts=1000,
                first_seen=_NOW - 7200, attempt_ts=_NOW - 7100):
    return {
        "first_seen_ts": first_seen,
        "vm_active_enter_ts": vm_ts,
        "alerts": ["OpenClawHttpHealthDown"],
        "attempts": [{"ts": attempt_ts, "action": "restart_microvm",
                      "by": "deterministic", "ok": True,
                      "notes": "microvm restarted"}],
        "status": status,
        "next_eligible_ts": None,
    }


def test_reconcile_resolves_in_progress_superseded_by_vm_restart():
    state = {"active": {"k": _orphan_inc()}, "history": []}
    n = daemon.reconcile_orphans(state, now=_NOW, vm_ts=2000,
                                 probe=lambda inc: True)
    assert n == 1
    inc = state["active"]["k"]
    assert inc["status"] == "resolved"
    assert inc["resolved_ts"] == _NOW
    assert inc["resolved_by"] == "orphan_reconcile"


def test_reconcile_leaves_same_boot_incident():
    """Same VM boot as the incident: it may still be the live episode
    (repeat sends of the same firing alert match its correlation key)."""
    state = {"active": {"k": _orphan_inc(vm_ts=2000)}, "history": []}
    n = daemon.reconcile_orphans(state, now=_NOW, vm_ts=2000,
                                 probe=lambda inc: True)
    assert n == 0
    assert state["active"]["k"]["status"] == "in_progress"


def test_reconcile_requires_probe_clear():
    """VM restarted but the service is still unhealthy: do not fabricate a
    resolution; the live episode will re-fire under a new correlation key."""
    state = {"active": {"k": _orphan_inc()}, "history": []}
    n = daemon.reconcile_orphans(state, now=_NOW, vm_ts=2000,
                                 probe=lambda inc: False)
    assert n == 0
    assert state["active"]["k"]["status"] == "in_progress"


def test_reconcile_skips_recent_activity():
    """An incident with activity inside ORPHAN_MIN_QUIET_S may be an
    in-flight remediation in the webhook thread; leave it alone."""
    state = {"active": {"k": _orphan_inc(attempt_ts=_NOW - 60)}, "history": []}
    n = daemon.reconcile_orphans(state, now=_NOW, vm_ts=2000,
                                 probe=lambda inc: True)
    assert n == 0
    assert state["active"]["k"]["status"] == "in_progress"


def test_reconcile_resolves_orphaned_stuck_and_records_prior_status():
    """stuck incidents leak the same way (nothing ever touches them again);
    once the VM has restarted past one and the probe is clear, archive it."""
    state = {"active": {"k": _orphan_inc(status="stuck")}, "history": []}
    n = daemon.reconcile_orphans(state, now=_NOW, vm_ts=2000,
                                 probe=lambda inc: True)
    assert n == 1
    inc = state["active"]["k"]
    assert inc["status"] == "resolved"
    assert inc["resolved_by"] == "orphan_reconcile"
    assert inc["resolved_from_status"] == "stuck"


def test_reconcile_ignores_already_resolved():
    state = {"active": {"k": _resolved_inc(_NOW - 60)}, "history": []}
    n = daemon.reconcile_orphans(state, now=_NOW, vm_ts=2000,
                                 probe=lambda inc: True)
    assert n == 0
    assert "resolved_by" not in state["active"]["k"]


def test_reconcile_failsafe_on_unknown_vm_ts():
    """If the current VM boot timestamp is unknown (canary textfile missing),
    we cannot prove the VM restarted past the incident: touch nothing."""
    state = {"active": {"k": _orphan_inc()}, "history": []}
    n = daemon.reconcile_orphans(state, now=_NOW, vm_ts=0,
                                 probe=lambda inc: True)
    assert n == 0
    assert state["active"]["k"]["status"] == "in_progress"


def test_reconcile_defaults_read_live_metrics(monkeypatch):
    """Default wiring: vm_ts comes from the canary gauge and probe from
    probe_clear, so heartbeat_tick needs no explicit plumbing."""
    monkeypatch.setattr(
        daemon, "current_metrics",
        lambda: {"openclaw_microvm_active_enter_timestamp_seconds": 2000.0,
                 "openclaw_discord_ws_connected": 1.0})
    state = {"active": {"k": _orphan_inc()}, "history": []}
    n = daemon.reconcile_orphans(state, now=_NOW)
    assert n == 1
    assert state["active"]["k"]["status"] == "resolved"


def test_reconciled_incident_archives_after_retention():
    """A reconciled orphan flows through the normal lifecycle: retained in
    active for RESOLVED_RETENTION_S, then swept to history."""
    state = {"active": {"k": _orphan_inc()}, "history": []}
    daemon.reconcile_orphans(state, now=_NOW, vm_ts=2000,
                             probe=lambda inc: True)
    assert daemon.sweep_resolved(state, now=_NOW) == 0
    assert daemon.sweep_resolved(
        state, now=_NOW + daemon.RESOLVED_RETENTION_S) == 1
    assert state["active"] == {}
    assert state["history"][0]["resolved_by"] == "orphan_reconcile"


def test_heartbeat_tick_persists_reconciliation(tmp_path, monkeypatch):
    """The heartbeat tick — not just webhook arrival — must reconcile, sweep,
    and PERSIST, so orphans clear even when no openclaw alert ever fires
    again (the 2026-07-03 orphan sat for 3 days precisely because state
    maintenance only ran inside handle_alertmanager_payload)."""
    state_path = tmp_path / "incidents.json"
    monkeypatch.setattr(daemon, "STATE_PATH", state_path)
    monkeypatch.setattr(
        daemon, "current_metrics",
        lambda: {"openclaw_microvm_active_enter_timestamp_seconds": 2000.0,
                 "openclaw_discord_ws_connected": 1.0})
    heartbeats = []
    monkeypatch.setattr(daemon, "write_heartbeat",
                        lambda **kw: heartbeats.append(kw))
    daemon.save_state(state_path, {"active": {"k": _orphan_inc()},
                                   "history": []})
    daemon.heartbeat_tick()
    persisted = daemon.load_state(state_path)
    assert persisted["active"]["k"]["status"] == "resolved"
    assert persisted["active"]["k"]["resolved_by"] == "orphan_reconcile"
    assert heartbeats and heartbeats[0]["active_count"] == 0


# ---- circuit breaker (recent_action_count) ----
# Regression coverage for the 2026-07-22 unbounded restart storm. The
# remediation for OpenClawHttpHealthDown is restart_microvm, which resets the
# alert's 600 s warmup gate; the alert resolves after each restart and re-fires
# ~11 min later with a fresh startsAt, so every episode is a new single-attempt
# incident and the per-incident attempts>=3 stuck check never trips. The
# breaker counts real actions taken across ALL incidents in a rolling window
# and stops acting once the budget is spent (72 restarts / 48 stranded
# incidents observed before the fix).


def test_recent_action_count_sums_real_actions_in_window():
    now = 1_000_000
    state = {
        "active": {
            "a": {"attempts": [{"ts": now - 10, "action": "restart_microvm"},
                               {"ts": now - 20, "action": "doctor_fix"}]},
        },
        "history": [
            {"attempts": [{"ts": now - 30, "action": "restart_microvm"}]},
        ],
    }
    assert daemon.recent_action_count(state, now=now) == 3


def test_recent_action_count_ignores_aged_out_and_placeholder_attempts():
    now = 1_000_000
    state = {
        "active": {
            "old":         {"attempts": [{"ts": now - daemon.CIRCUIT_WINDOW_S - 1,
                                          "action": "restart_microvm"}]},
            "placeholder": {"attempts": [{"ts": now - 5, "action": "none"}]},
            "no_action":   {"attempts": [{"ts": now - 5, "action": None}]},
            "recent":      {"attempts": [{"ts": now - 5, "action": "restart_microvm"}]},
        },
        "history": [],
    }
    assert daemon.recent_action_count(state, now=now) == 1


def test_handle_payload_circuit_breaker_stops_after_budget(monkeypatch, tmp_path):
    """Once CIRCUIT_MAX_ATTEMPTS real remediations have happened in the window,
    a further firing alert is NOT acted on — it is marked stuck and pages
    OpenClawSelfHealStuck instead of triggering yet another restart. This is
    the direct regression guard for the unbounded restart storm."""
    state_path = tmp_path / "incidents.json"
    monkeypatch.setattr(daemon, "STATE_PATH", state_path)
    monkeypatch.setattr(
        daemon, "current_metrics",
        lambda: {"openclaw_microvm_active_enter_timestamp_seconds": 9999})
    now = int(time.time())
    # Pre-spend the budget: CIRCUIT_MAX_ATTEMPTS recent restarts across prior
    # (now-stranded) episodes, each a distinct incident as the storm produced.
    seed = {
        "active": {
            f"ep{i}": {"status": "in_progress", "first_seen_ts": now - 100,
                       "vm_active_enter_ts": 1000 + i,
                       "alerts": ["OpenClawHttpHealthDown"],
                       "attempts": [{"ts": now - 10 * (i + 1),
                                     "action": "restart_microvm",
                                     "by": "deterministic", "ok": True}]}
            for i in range(daemon.CIRCUIT_MAX_ATTEMPTS)
        },
        "history": [],
    }
    daemon.save_state(state_path, seed)

    ran = []
    monkeypatch.setattr(daemon, "run_action", lambda name: ran.append(name) or {"ok": True})
    monkeypatch.setattr(daemon, "probe_clear", lambda inc: False)
    monkeypatch.setattr(daemon, "_kick_canary", lambda: None)
    emitted = []
    monkeypatch.setattr(daemon, "emit_synthetic_alert",
                        lambda name, ann, **k: emitted.append(name))
    monkeypatch.setattr(daemon.time, "sleep", lambda *_: None)

    # A NEW firing episode (fresh startsAt bucket -> a new incident) arrives.
    payload = {"alerts": [{"status": "firing",
                           "labels": {"alertname": "OpenClawHttpHealthDown",
                                      "service": "openclaw"},
                           "startsAt": "2026-07-22T10:00:00Z"}]}
    daemon.handle_alertmanager_payload(payload)

    assert ran == []  # breaker prevented another restart
    assert "OpenClawSelfHealStuck" in emitted
    persisted = daemon.load_state(state_path)
    stuck = [i for i in persisted["active"].values()
             if i.get("stuck_reason") == "circuit_breaker"]
    assert stuck, "the new episode must be recorded stuck via the breaker"


def test_handle_payload_acts_when_budget_available(monkeypatch, tmp_path):
    """Below the budget, the breaker does not interfere — a single fresh
    incident still gets its deterministic first-attempt remediation."""
    state_path = tmp_path / "incidents.json"
    monkeypatch.setattr(daemon, "STATE_PATH", state_path)
    monkeypatch.setattr(
        daemon, "current_metrics",
        lambda: {"openclaw_microvm_active_enter_timestamp_seconds": 9999})
    now = int(time.time())
    # One prior recent action — still under CIRCUIT_MAX_ATTEMPTS.
    seed = {
        "active": {
            "ep0": {"status": "resolved", "first_seen_ts": now - 100,
                    "resolved_ts": now - 90,
                    "alerts": ["OpenClawHttpHealthDown"],
                    "attempts": [{"ts": now - 90, "action": "restart_microvm",
                                  "by": "deterministic", "ok": True}]},
        },
        "history": [],
    }
    daemon.save_state(state_path, seed)

    ran = []
    monkeypatch.setattr(daemon, "run_action", lambda name: ran.append(name) or {"ok": True})
    monkeypatch.setattr(daemon, "probe_clear", lambda inc: True)
    monkeypatch.setattr(daemon, "_kick_canary", lambda: None)
    monkeypatch.setattr(daemon, "emit_synthetic_alert", lambda *a, **k: None)
    monkeypatch.setattr(daemon.time, "sleep", lambda *_: None)

    payload = {"alerts": [{"status": "firing",
                           "labels": {"alertname": "OpenClawHttpHealthDown",
                                      "service": "openclaw"},
                           "startsAt": "2026-07-22T11:30:00Z"}]}
    daemon.handle_alertmanager_payload(payload)
    assert ran == ["restart_microvm"]
