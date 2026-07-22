import json
import pytest
import responses
from oss_secretary.triage import build_prompt, parse_and_validate, triage
from oss_secretary.models import ThreadDelta, AwaitingBundle, NotificationItem
from tests.test_delta import _t
from tests.test_github import _cfg

HERMES = "http://10.99.1.2:8080/v1/chat/completions"


def _d(node="I_1", n=3, change="new"):
    t = _t(node=node, n=n)
    return ThreadDelta(t, change, AwaitingBundle(False, False, False, 1.0, "NONE"))


def _reply(content):
    return {"choices": [{"message": {"content": content}}]}


def test_build_prompt_wraps_untrusted_and_lists_ids():
    prompt, ids, omitted = build_prompt([_d()], [], budget=12000)
    assert "<UNTRUSTED_INPUT>" in prompt
    assert "gh:jwiegley/foo#3" in ids
    assert omitted == 0


def test_parse_validate_drops_unknown_ids():
    raw = json.dumps({"attention": [
        {"id": "gh:jwiegley/foo#3", "severity": "serious", "one_line": "crash"},
        {"id": "gh:evil/x#1", "severity": "serious", "one_line": "nope"}], "notes": ""})
    items = parse_and_validate(raw, {"gh:jwiegley/foo#3"})
    assert [i.id for i in items] == ["gh:jwiegley/foo#3"]


def test_parse_validate_raises_on_garbage():
    with pytest.raises(ValueError):
        parse_and_validate("not json", {"x"})


@responses.activate
def test_triage_falls_back_on_http_error():
    responses.add(responses.POST, HERMES, status=500)
    items, banner, omitted = triage(_cfg(hermes_url=HERMES), [_d()], [])
    assert banner is not None and "unavailable" in banner.lower()
    assert items and items[0].id == "gh:jwiegley/foo#3"   # deterministic fallback


@responses.activate
def test_triage_empty_result_is_valid_not_fallback():
    # A successful parse with zero attention items means "nothing urgent" —
    # it must NOT flood §1 with every delta via the fallback path.
    responses.add(responses.POST, HERMES,
                  json=_reply('{"attention":[],"notes":"quiet day"}'), status=200)
    items, banner, omitted = triage(_cfg(hermes_url=HERMES), [_d(), _d(node="I_2", n=2)], [])
    assert items == []
    assert banner is None


@responses.activate
def test_triage_invalid_output_falls_back():
    responses.add(responses.POST, HERMES, json=_reply("not json at all"), status=200)
    items, banner, omitted = triage(_cfg(hermes_url=HERMES), [_d()], [])
    assert banner is not None and "invalid" in banner.lower()
    assert items and items[0].id == "gh:jwiegley/foo#3"


def test_notifications_counted_against_budget():
    notifs = [NotificationItem("github", "o/r", "Issue", "t" * 80, "mention",
                               "u", "2026", True) for _ in range(200)]
    prompt, ids, omitted = build_prompt([], notifs, budget=40)
    assert omitted > 0                          # some notifications dropped
    assert "omitted from triage" in prompt      # and the drop is disclosed
