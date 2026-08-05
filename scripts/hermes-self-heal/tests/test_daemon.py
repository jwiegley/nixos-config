import daemon
import pytest


def test_allowlist_is_exactly_the_authorized_actions():
    """Guard test: ACTION_ALLOWLIST must exactly match the spec.

    If this ever fails, the sudoers entries in
    modules/services/hermes-self-heal.nix likely need to be updated in
    lockstep — and so does the Hermes self-heal spec.
    """
    assert daemon.ACTION_ALLOWLIST == (
        "restart_microvm",
        "restart_mcp",
        "restage_secrets",
        "reset_credential_pool",
        "restart_health_check",
    )


def test_webhook_port_is_9098():
    assert daemon.WEBHOOK_PORT == 9098


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


def test_correlation_key_groups_distinct_alerts_in_same_bucket():
    """Distinct alerts of one outage that fire in the same time bucket
    correlate into a single incident."""
    a = {"alert_name": "HermesAskFailing", "vm_active_enter_ts": 1000, "starts_at": 5000}
    b = {"alert_name": "HermesApiServerDown", "vm_active_enter_ts": 1000, "starts_at": 5000}
    assert daemon.correlation_key(a) == daemon.correlation_key(b)


def test_correlation_key_same_across_self_inflicted_vm_restart():
    """restart_microvm changes vm_active_enter_ts; the correlation key must NOT
    change with it, or the same firing episode is re-tracked as a new incident
    on every restart and the attempt counter never reaches the stuck threshold
    (the identical latent runaway that hit OpenClaw 2026-07-22)."""
    a = {"alert_name": "HermesAskFailing", "vm_active_enter_ts": 1000, "starts_at": 5000}
    b = {"alert_name": "HermesAskFailing", "vm_active_enter_ts": 2000, "starts_at": 5000}
    assert daemon.correlation_key(a) == daemon.correlation_key(b)


def test_new_incident_starts_in_progress():
    inc = daemon.new_incident({"alert_name": "HermesAskFailing",
                               "vm_active_enter_ts": 1000})
    assert inc["status"] == "in_progress"
    assert inc["attempts"] == []
    assert inc["alerts"] == ["HermesAskFailing"]


def test_next_attempt_n_starts_at_one():
    inc = daemon.new_incident({"alert_name": "HermesAskFailing", "vm_active_enter_ts": 1000})
    assert daemon.next_attempt_n(inc) == 1


def test_next_attempt_n_increments():
    inc = daemon.new_incident({"alert_name": "HermesAskFailing", "vm_active_enter_ts": 1000})
    inc["attempts"].append({"action": "restart_microvm", "by": "deterministic"})
    assert daemon.next_attempt_n(inc) == 2


def test_should_escalate_after_three_attempts():
    inc = daemon.new_incident({"alert_name": "HermesAskFailing", "vm_active_enter_ts": 1000})
    assert not daemon.should_escalate(inc)
    inc["attempts"].extend([{}, {}, {}])
    assert daemon.should_escalate(inc)


def test_state_round_trip(tmp_path):
    state = {"active": {"k": {"status": "in_progress", "attempts": []}}, "history": []}
    p = tmp_path / "incidents.json"
    daemon.save_state(p, state)
    assert daemon.load_state(p) == state


def test_load_state_returns_empty_when_file_missing(tmp_path):
    p = tmp_path / "does-not-exist.json"
    assert daemon.load_state(p) == {"active": {}, "history": []}


def test_action_map_deterministic_first_attempts():
    """Spec §6.2 — verify the deterministic-first-attempt map exactly."""
    assert daemon.ACTION_MAP == {
        "HermesAskFailing":             "restart_microvm",
        "HermesApiServerDown":          "restart_microvm",
        "HermesDiscordZombieSuspected":   "restart_microvm",
        "HermesDiscordPostSelfHealRestart": "restart_microvm",
        "HermesMcpBridgeDown":            "restart_mcp",
        "HermesHealthCheckStale":       "restart_health_check",
    }


def test_first_attempt_action_returns_none_for_unknown_alert():
    """Divergence from OpenClaw: NO default fallback. Spec §6.2 explicit decision."""
    assert daemon.first_attempt_action("SomeNewAlertNobodyMapped") is None


def test_first_attempt_action_returns_action_for_known_alert():
    assert daemon.first_attempt_action("HermesAskFailing") == "restart_microvm"


def test_first_attempt_action_does_NOT_default_for_HermesApiKeyMissing():
    """HermesApiKeyMissing routes here because it has service=hermes-mcp,
    but no allowlisted action can fix a SOPS plumbing failure — defaulting
    would consume the AI tier and end at stuck."""
    assert daemon.first_attempt_action("HermesApiKeyMissing") is None


def test_redact_discord_token():
    # Fixture assembled at runtime: a Discord-token-SHAPED literal in a tracked
    # file trips GitHub push protection, which silently broke the Gitea->GitHub
    # mirror for 10+ days (found 2026-07-28). The previous fixture was a real
    # 2019-era bot token and has been rotated. redact() matches shape only.
    seg0 = "N" + "0" * 23
    fake = ".".join((seg0, "A" * 6, "z" * 27))
    out = daemon.redact(f"Bot is online with token {fake} OK")
    assert seg0 not in out
    assert "[REDACTED]" in out


def test_redact_anthropic_key():
    out = daemon.redact("loaded sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz1234567890")
    assert "sk-ant" not in out
    assert "[REDACTED]" in out


def test_redact_bearer():
    out = daemon.redact("Authorization: Bearer eyJhbGciOiJIUzI1NiIs.abc.def")
    assert "eyJhbGc" not in out
    assert "[REDACTED]" in out


def test_redact_generic_token_assignment():
    out = daemon.redact("config: api_key=sk-proj-xxxxxxxxxxx, password=hunter2")
    assert "sk-proj" not in out
    assert "hunter2" not in out


def test_redact_preserves_non_secret_text():
    s = "Discord WS connected, 12 events received in last 60s"
    assert daemon.redact(s) == s


def test_run_action_rejects_non_allowlisted(monkeypatch):
    with pytest.raises(daemon.ActionRejectedError):
        daemon.run_action("rm_rf_slash")


def test_run_action_parses_last_line_as_json(monkeypatch):
    import subprocess

    class FakeResult:
        returncode = 0
        stdout = 'some chatter\n{"ok": true, "notes": "did it"}\n'
        stderr = ""

    def fake_run(*a, **kw):
        return FakeResult()

    monkeypatch.setattr(subprocess, "run", fake_run)
    result = daemon.run_action("restart_microvm")
    assert result == {"ok": True, "notes": "did it"}


def test_run_action_handles_timeout(monkeypatch):
    import subprocess

    def fake_run(*a, **kw):
        raise subprocess.TimeoutExpired(cmd="x", timeout=240)

    monkeypatch.setattr(subprocess, "run", fake_run)
    result = daemon.run_action("restart_microvm", timeout_s=240)
    assert result == {"ok": False, "notes": "action timed out", "duration_s": 240}


def test_run_action_handles_non_json_output(monkeypatch):
    import subprocess

    class FakeResult:
        returncode = 1
        stdout = "raw error text not json\n"
        stderr = "bad stuff happened"

    monkeypatch.setattr(subprocess, "run", lambda *a, **kw: FakeResult())
    result = daemon.run_action("restart_microvm")
    assert result["ok"] is False
    assert "non-json" in result["notes"]


def test_call_litellm_raises_unreachable_without_key(monkeypatch):
    monkeypatch.delenv(daemon.LLM_GATEWAY_KEY_ENV, raising=False)
    with pytest.raises(daemon.GatewayUnreachable):
        daemon.call_litellm([{"role": "user", "content": "test"}])


def test_call_litellm_returns_parsed_json(monkeypatch):
    import json as _json

    monkeypatch.setenv(daemon.LLM_GATEWAY_KEY_ENV, "test-key")

    class FakeResp:
        def read(self):
            return _json.dumps({
                "choices": [{"message": {"content": _json.dumps(
                    {"action": "restart_microvm", "reason": "stub"})}}]
            }).encode()

    def fake_post(url, headers, data, timeout):
        return FakeResp()

    monkeypatch.setattr(daemon, "_http_post_json", fake_post)
    result = daemon.call_litellm([{"role": "user", "content": "x"}])
    assert result == {"action": "restart_microvm", "reason": "stub"}


def test_call_litellm_raises_unreachable_on_non_json(monkeypatch):
    monkeypatch.setenv(daemon.LLM_GATEWAY_KEY_ENV, "test-key")

    class FakeResp:
        def read(self):
            import json as _json
            return _json.dumps({"choices": [{"message": {"content": "not json"}}]}).encode()

    monkeypatch.setattr(daemon, "_http_post_json", lambda *a, **kw: FakeResp())
    with pytest.raises(daemon.GatewayUnreachable):
        daemon.call_litellm([{"role": "user", "content": "x"}])


def test_render_prompt_includes_all_five_actions_in_system():
    inc = {"alerts": ["HermesAskFailing"], "attempts": []}
    messages = daemon.render_prompt(inc, {}, "", "")
    system = messages[0]["content"]
    for action in daemon.ACTION_ALLOWLIST:
        assert action in system


def test_render_prompt_includes_redacted_log_tails():
    inc = {"alerts": ["HermesAskFailing"], "attempts": []}
    err = "ERROR Bearer eyJhbGc.abc.def"
    out = "INFO connected"
    messages = daemon.render_prompt(inc, {}, err, out)
    user = messages[1]["content"]
    assert "eyJhbGc" not in user
    assert "INFO connected" in user


def test_render_prompt_lists_prior_attempts():
    inc = {
        "alerts": ["HermesAskFailing"],
        "attempts": [{"action": "restart_microvm", "by": "deterministic", "ok": False}],
    }
    messages = daemon.render_prompt(inc, {"hermes_api_server_ok": 0.0}, "", "")
    user = messages[1]["content"]
    assert "restart_microvm" in user
    assert "deterministic" in user
    assert "hermes_api_server_ok=0.0" in user


def test_current_metrics_parses_textfile(monkeypatch, tmp_path):
    metrics_file = tmp_path / "hermes_health.prom"
    metrics_file.write_text(
        "# HELP some helper\n"
        "# TYPE foo gauge\n"
        "hermes_api_server_ok 1\n"
        "hermes_mcp_ask_hermes_ok 0\n"
        "hermes_discord_last_event_age_seconds 423.5\n"
    )
    monkeypatch.setattr(daemon, "HERMES_HEALTH_PROM", str(metrics_file))
    m = daemon.current_metrics()
    assert m["hermes_api_server_ok"] == 1.0
    assert m["hermes_mcp_ask_hermes_ok"] == 0.0
    assert m["hermes_discord_last_event_age_seconds"] == 423.5


def test_current_metrics_returns_empty_when_missing(monkeypatch, tmp_path):
    monkeypatch.setattr(daemon, "HERMES_HEALTH_PROM", str(tmp_path / "missing.prom"))
    assert daemon.current_metrics() == {}


def test_probe_clear_true_when_ask_ok_is_one(monkeypatch):
    monkeypatch.setattr(daemon, "current_metrics",
                        lambda: {"hermes_mcp_ask_hermes_ok": 1.0})
    assert daemon.probe_clear({}) is True


def test_probe_clear_false_when_ask_ok_is_zero(monkeypatch):
    monkeypatch.setattr(daemon, "current_metrics",
                        lambda: {"hermes_mcp_ask_hermes_ok": 0.0})
    assert daemon.probe_clear({}) is False


def test_probe_clear_false_when_metric_missing(monkeypatch):
    monkeypatch.setattr(daemon, "current_metrics", lambda: {})
    assert daemon.probe_clear({}) is False


def test_microvm_active_enter_ts_parses_systemctl_output(monkeypatch):
    import subprocess

    def fake_check_output(cmd, **kw):
        # Real format: "<weekday> 2026-05-20 13:42:01 PDT"
        # We strip the weekday before parsing, so its value doesn't matter.
        return "Wed 2026-05-20 13:42:01 PDT\n"

    monkeypatch.setattr(subprocess, "check_output", fake_check_output)
    ts = daemon.microvm_active_enter_ts()
    # Just assert it's a positive int — exact value depends on the test
    # host's TZ, and we just need monotonicity.
    assert isinstance(ts, int)
    assert ts > 0


def test_microvm_active_enter_ts_returns_zero_on_error(monkeypatch):
    import subprocess

    def fake_check_output(cmd, **kw):
        raise subprocess.CalledProcessError(1, cmd)

    monkeypatch.setattr(subprocess, "check_output", fake_check_output)
    assert daemon.microvm_active_enter_ts() == 0


def test_microvm_active_enter_ts_returns_zero_on_unparseable(monkeypatch):
    import subprocess
    monkeypatch.setattr(subprocess, "check_output",
                        lambda cmd, **kw: "n/a\n")
    assert daemon.microvm_active_enter_ts() == 0


def test_emit_synthetic_alert_shape(monkeypatch):
    captured = {}

    def fake_post(url, headers, data, timeout):
        captured["url"] = url
        captured["data"] = data

        class R:
            def read(self):
                return b""
        return R()

    monkeypatch.setattr(daemon, "_http_post_json", fake_post)
    daemon.emit_synthetic_alert(
        "HermesSelfHealActed",
        {"action": "restart_microvm", "alert": "HermesAskFailing"},
        severity="info",
    )

    import json as _json
    body = _json.loads(captured["data"])
    assert body[0]["labels"]["alertname"] == "HermesSelfHealActed"
    assert body[0]["labels"]["service"] == "hermes-self-heal"  # NOT hermes-*
    assert body[0]["labels"]["severity"] == "info"
    assert "/api/v2/alerts" in captured["url"]


# ---- incident eviction (sweep_resolved) ----
# Regression coverage for the bug where resolved incidents were never moved
# out of state["active"] and accumulated without bound (20 stale entries
# observed 2026-05-28). sweep_resolved archives aged resolved incidents to
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
    """Legacy resolved incidents (pre-fix) have no resolved_ts; age off first_seen_ts."""
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
    attempt total that heartbeat_loop sums for hermes_self_heal_attempts_total."""
    now = 1_000_000
    old = now - daemon.RESOLVED_RETENTION_S - 1
    state = {
        "active": {
            "a": _resolved_inc(old, attempts=[{"action": "restart_microvm"}]),
            "b": _resolved_inc(old, attempts=[{"action": "restart_mcp"}]),
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
# Mirror of the openclaw fix for the 2026-07-03 orphan class: a daemon
# interrupted between acting and its 15 s pre-verification sleep leaves the
# incident in_progress forever — resolution only happens via the post-action
# probe (resolved webhooks are skipped), no future webhook matches the old
# vm_active_enter_ts correlation key, and sweep_resolved only archives
# resolved incidents. Hermes shares the code path verbatim.

_NOW = 1_000_000


def _orphan_inc(status="in_progress", vm_ts=1000,
                first_seen=_NOW - 7200, attempt_ts=_NOW - 7100):
    return {
        "first_seen_ts": first_seen,
        "vm_active_enter_ts": vm_ts,
        "alerts": ["HermesApiServerDown"],
        "attempts": [{"ts": attempt_ts, "action": "restart_microvm",
                      "by": "deterministic", "ok": True}],
        "status": status,
        "next_eligible_ts": None,
    }


def test_reconcile_resolves_in_progress_superseded_by_vm_restart():
    state = {"active": {"k": _orphan_inc()}, "history": []}
    n = daemon.reconcile_orphans(state, now=_NOW, vm_ts=2000,
                                 probe=lambda inc, not_before=0.0: True)
    assert n == 1
    inc = state["active"]["k"]
    assert inc["status"] == "resolved"
    assert inc["resolved_ts"] == _NOW
    assert inc["resolved_by"] == "orphan_reconcile"


def test_reconcile_leaves_same_boot_incident():
    state = {"active": {"k": _orphan_inc(vm_ts=2000)}, "history": []}
    n = daemon.reconcile_orphans(state, now=_NOW, vm_ts=2000,
                                 probe=lambda inc, not_before=0.0: True)
    assert n == 0
    assert state["active"]["k"]["status"] == "in_progress"


def test_reconcile_requires_probe_clear():
    state = {"active": {"k": _orphan_inc()}, "history": []}
    n = daemon.reconcile_orphans(state, now=_NOW, vm_ts=2000,
                                 probe=lambda inc, not_before=0.0: False)
    assert n == 0
    assert state["active"]["k"]["status"] == "in_progress"


def test_reconcile_skips_recent_activity():
    state = {"active": {"k": _orphan_inc(attempt_ts=_NOW - 60)}, "history": []}
    n = daemon.reconcile_orphans(state, now=_NOW, vm_ts=2000,
                                 probe=lambda inc, not_before=0.0: True)
    assert n == 0
    assert state["active"]["k"]["status"] == "in_progress"


def test_reconcile_resolves_orphaned_stuck_and_records_prior_status():
    state = {"active": {"k": _orphan_inc(status="stuck")}, "history": []}
    n = daemon.reconcile_orphans(state, now=_NOW, vm_ts=2000,
                                 probe=lambda inc, not_before=0.0: True)
    assert n == 1
    inc = state["active"]["k"]
    assert inc["status"] == "resolved"
    assert inc["resolved_from_status"] == "stuck"


def test_reconcile_failsafe_on_unknown_vm_ts():
    """microvm_active_enter_ts() returns 0 on any systemctl parse failure;
    we then cannot prove the VM restarted past the incident: touch nothing."""
    state = {"active": {"k": _orphan_inc()}, "history": []}
    n = daemon.reconcile_orphans(state, now=_NOW, vm_ts=0,
                                 probe=lambda inc, not_before=0.0: True)
    assert n == 0
    assert state["active"]["k"]["status"] == "in_progress"


def test_reconcile_defaults_read_systemd_and_health_metrics(monkeypatch):
    """Default wiring diverges from openclaw: vm_ts comes from systemd
    (microvm_active_enter_ts), the probe from hermes_mcp_ask_hermes_ok."""
    monkeypatch.setattr(daemon, "microvm_active_enter_ts", lambda: 2000)
    monkeypatch.setattr(daemon, "current_metrics",
                        lambda: {"hermes_mcp_ask_hermes_ok": 1.0})
    state = {"active": {"k": _orphan_inc()}, "history": []}
    n = daemon.reconcile_orphans(state, now=_NOW)
    assert n == 1
    assert state["active"]["k"]["status"] == "resolved"


def test_reconciled_incident_archives_after_retention():
    state = {"active": {"k": _orphan_inc()}, "history": []}
    daemon.reconcile_orphans(state, now=_NOW, vm_ts=2000,
                             probe=lambda inc, not_before=0.0: True)
    assert daemon.sweep_resolved(state, now=_NOW) == 0
    assert daemon.sweep_resolved(
        state, now=_NOW + daemon.RESOLVED_RETENTION_S) == 1
    assert state["active"] == {}
    assert state["history"][0]["resolved_by"] == "orphan_reconcile"


def test_heartbeat_tick_persists_reconciliation(tmp_path, monkeypatch):
    """The heartbeat tick — not just webhook arrival — must reconcile, sweep,
    and PERSIST, so orphans clear even when no hermes alert ever fires
    again."""
    state_path = tmp_path / "incidents.json"
    monkeypatch.setattr(daemon, "STATE_PATH", state_path)
    monkeypatch.setattr(daemon, "microvm_active_enter_ts", lambda: 2000)
    monkeypatch.setattr(daemon, "current_metrics",
                        lambda: {"hermes_mcp_ask_hermes_ok": 1.0})
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


def test_recent_action_count_ignores_skipped_preflight():
    """A declined restart must not burn the circuit-breaker budget.

    restart_microvm's upstream-model preflight records
    {action: "restart_microvm", ok: false, skipped: true} when the gateway
    cannot serve the model. No remediation happened. Counting those would let
    an upstream outage trip the breaker on the daemon correctly refusing to
    act, which marks the incident stuck and emits a 4h synthetic critical.
    """
    now = 1_000_000
    state = {
        "active": {
            "k": {
                "status": "in_progress",
                "attempts": [
                    {"ts": now - 10, "action": "restart_microvm",
                     "ok": False, "skipped": True},
                    {"ts": now - 20, "action": "restart_microvm",
                     "ok": False, "skipped": True},
                    {"ts": now - 30, "action": "restart_microvm",
                     "ok": False, "skipped": True},
                    {"ts": now - 40, "action": "restart_microvm", "ok": True},
                ],
            }
        },
        "history": [],
    }
    # Only the one real restart counts, so the breaker stays clear.
    assert daemon.recent_action_count(state, now=now) == 1
    assert daemon.recent_action_count(state, now=now) < daemon.CIRCUIT_MAX_ATTEMPTS


def test_recent_action_count_still_counts_real_actions():
    """Guard the other direction: real actions must still trip the breaker."""
    now = 1_000_000
    state = {
        "active": {
            "k": {
                "status": "in_progress",
                "attempts": [
                    {"ts": now - 10, "action": "restart_microvm", "ok": True},
                    {"ts": now - 20, "action": "restart_mcp", "ok": True},
                    {"ts": now - 30, "action": "restage_secrets", "ok": True},
                ],
            }
        },
        "history": [],
    }
    assert daemon.recent_action_count(state, now=now) == 3
    assert daemon.recent_action_count(state, now=now) >= daemon.CIRCUIT_MAX_ATTEMPTS
