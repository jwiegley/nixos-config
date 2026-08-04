import subprocess
from unittest.mock import MagicMock

from conftest import load_report_module

m = load_report_module()









def test_ssh_probe_skips_without_key():
    out = m.ssh_probe(None, "host@1.2.3.4", [{"label": "x", "kind": "curl", "url": "http://x"}])
    assert out["skipped"] is True
    assert out["results"] == {}




