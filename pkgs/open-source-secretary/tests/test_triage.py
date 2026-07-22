import json
import responses
from oss_secretary.triage import (build_prompt, parse_and_validate,
                                   deterministic_order, triage)
from oss_secretary.models import ThreadDelta, AwaitingBundle, AttentionItem
from tests.test_delta import _t, OWNERS
from tests.test_github import _cfg


def _d(node="I_1", n=3, change="new"):
    t = _t(node=node, n=n)
    return ThreadDelta(t, change, AwaitingBundle(False, False, False, 1.0, "NONE"))


def test_build_prompt_wraps_untrusted_and_lists_ids():
    prompt, ids = build_prompt([_d()], [], budget=12000)
    assert "<UNTRUSTED_INPUT>" in prompt
    assert "gh:jwiegley/foo#3" in ids


def test_parse_validate_drops_unknown_ids():
    raw = json.dumps({"attention": [
        {"id": "gh:jwiegley/foo#3", "severity": "serious", "one_line": "crash"},
        {"id": "gh:evil/x#1", "severity": "serious", "one_line": "nope"}], "notes": ""})
    items = parse_and_validate(raw, {"gh:jwiegley/foo#3"})
    assert [i.id for i in items] == ["gh:jwiegley/foo#3"]


def test_parse_validate_raises_on_garbage():
    import pytest
    with pytest.raises(ValueError):
        parse_and_validate("not json", {"x"})


@responses.activate
def test_triage_falls_back_on_http_error():
    responses.add(responses.POST, "http://10.99.1.2:8080/v1/chat/completions", status=500)
    items, banner = triage(_cfg(), [_d()], [])
    assert banner is not None and "unavailable" in banner.lower()
    assert items and items[0].id == "gh:jwiegley/foo#3"   # deterministic fallback
