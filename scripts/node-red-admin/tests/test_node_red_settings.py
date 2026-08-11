from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest


SETTINGS_PATH = Path(__file__).parents[3] / "config" / "node-red-settings.js"
ADMIN_PASSWORD_DIAGNOSTIC = (
    "CRITICAL: Node-RED admin password secret is unavailable or invalid."
)
API_TOKENS_DIAGNOSTIC = "CRITICAL: Node-RED API token secret is unavailable or invalid."
SENTINELS = (
    "PASSWORD_READ_SENTINEL",
    "INVALID_PASSWORD_SENTINEL",
    "TOKEN_READ_SENTINEL",
    "MALFORMED_TOKEN_SENTINEL",
)

HARNESS = r"""
const Module = require('module');
const originalLoad = Module._load;
const mode = process.argv[1];
const settingsPath = process.argv[2];
const bcrypt = '$2a$08$' + 'A'.repeat(53);

const fakeFs = {
  readFileSync(path, encoding) {
    if (encoding !== 'utf8') throw new Error('unexpected encoding');
    if (path.endsWith('/admin-username')) return 'admin\n';
    if (path.endsWith('/admin-password-hash')) {
      if (mode === 'password-unreadable') throw new Error('PASSWORD_READ_SENTINEL');
      if (mode === 'password-empty') return '';
      if (mode === 'password-invalid') return 'INVALID_PASSWORD_SENTINEL';
      return bcrypt + '\n';
    }
    if (path.endsWith('/api-tokens')) {
      if (mode === 'tokens-unreadable') throw new Error('TOKEN_READ_SENTINEL');
      if (mode === 'tokens-malformed') return '{"token":"MALFORMED_TOKEN_SENTINEL"';
      if (mode === 'tokens-invalid-shape') return '{"token":"synthetic"}';
      return '[{"token":"synthetic-api-token","description":"test"}]';
    }
    throw new Error('unexpected path');
  }
};

Module._load = function(request, parent, isMain) {
  if (request === 'fs') return fakeFs;
  return originalLoad.call(this, request, parent, isMain);
};
delete process.env.PORT;
const errors = [];
console.error = (...args) => errors.push(args.map(String).join(' '));

try {
  const settings = require(settingsPath);
  process.stdout.write(JSON.stringify({
    ok: true,
    errors,
    uiHost: settings.uiHost,
    uiPort: settings.uiPort,
    adminAuth: settings.adminAuth && {
      type: settings.adminAuth.type,
      users: settings.adminAuth.users
    }
  }));
} catch (error) {
  process.stdout.write(JSON.stringify({
    ok: false,
    errors,
    message: error instanceof Error ? error.message : 'non-error failure'
  }));
  process.exitCode = 1;
}
"""


def run_settings(mode: str) -> subprocess.CompletedProcess[str]:
    node = shutil.which("node")
    assert node is not None, "node must be present in the focused test closure"
    return subprocess.run(
        [node, "-e", HARNESS, mode, str(SETTINGS_PATH)],
        check=False,
        capture_output=True,
        text=True,
        timeout=5,
    )


def test_settings_start_with_valid_secrets_and_privileged_fallback() -> None:
    completed = run_settings("valid")
    assert completed.returncode == 0
    assert completed.stderr == ""
    result = json.loads(completed.stdout)
    assert result == {
        "ok": True,
        "errors": [],
        "uiHost": "127.0.0.1",
        "uiPort": 844,
        "adminAuth": {
            "type": "credentials",
            "users": [
                {
                    "username": "admin",
                    "password": "$2a$08$" + "A" * 53,
                    "permissions": "*",
                }
            ],
        },
    }


@pytest.mark.parametrize(
    "mode",
    ["password-unreadable", "password-empty", "password-invalid"],
)
def test_settings_fail_startup_when_admin_password_is_unusable(mode: str) -> None:
    completed = run_settings(mode)
    assert completed.returncode == 1
    assert completed.stderr == ""
    result = json.loads(completed.stdout)
    assert result == {
        "ok": False,
        "errors": [ADMIN_PASSWORD_DIAGNOSTIC],
        "message": ADMIN_PASSWORD_DIAGNOSTIC,
    }
    assert all(sentinel not in completed.stdout for sentinel in SENTINELS)


@pytest.mark.parametrize(
    "mode",
    ["tokens-unreadable", "tokens-malformed", "tokens-invalid-shape"],
)
def test_settings_fail_startup_with_fixed_token_diagnostic(mode: str) -> None:
    completed = run_settings(mode)
    assert completed.returncode == 1
    assert completed.stderr == ""
    result = json.loads(completed.stdout)
    assert result == {
        "ok": False,
        "errors": [API_TOKENS_DIAGNOSTIC],
        "message": API_TOKENS_DIAGNOSTIC,
    }
    assert all(sentinel not in completed.stdout for sentinel in SENTINELS)
