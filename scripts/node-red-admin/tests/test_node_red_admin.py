from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import signal
import ssl
import stat
import subprocess
import sys
import time
from pathlib import Path
from types import ModuleType

import pytest


MODULE_PATH = Path(__file__).parents[1] / "node_red_admin.py"
REPO_ROOT = Path(__file__).parents[3]
CONTRACT_PATH = os.environ.get("NODE_RED_ADMIN_CONTRACT")
TOKEN = "synthetic-node-red-admin-token"
FLOW_ID = "0123456789abcdef"
LEGACY_FLOW_ID = "91ad451.f6e52b8"
VALID_DIGEST = "sha256:" + "0" * 64


class Stdin:
    def __init__(self, value: bytes):
        self.buffer = io.BytesIO(value)


class Stdout:
    def __init__(self):
        self.buffer = io.BytesIO()


@pytest.fixture
def admin(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> ModuleType:
    spec = importlib.util.spec_from_file_location("node_red_admin", MODULE_PATH)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    run_directory = tmp_path / "run"
    generation = run_directory / "secrets.d" / "1"
    generation.mkdir(parents=True)
    run_directory.chmod(0o700)
    generation.chmod(0o700)
    (run_directory / "secrets").symlink_to(Path("secrets.d") / "1")
    token_path = generation / module.TOKEN_NAME
    token_path.write_bytes(TOKEN.encode() + b"\n")
    token_path.chmod(0o400)

    monkeypatch.setattr(module, "RUN_DIRECTORY", run_directory)
    monkeypatch.setattr(module, "TRUSTED_UID", os.geteuid())
    monkeypatch.setattr(module, "_disable_core_dumps", lambda: None)
    module._test_generation = generation
    module._test_token_path = token_path
    return module


def install_response(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    *,
    status: int,
    body: bytes = b"",
) -> list[dict[str, object]]:
    return install_responses(admin, monkeypatch, [(status, body)])


def install_responses(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    responses: list[tuple[int, bytes]],
) -> list[dict[str, object]]:
    calls: list[dict[str, object]] = []

    class Response:
        def __init__(self, status: int, body: bytes):
            self.status = status
            self.body = body

        def read(self, limit: int) -> bytes:
            return self.body[:limit]

    class Connection:
        def __init__(self, host: str, port: int, *, timeout: int, context: object):
            calls.append(
                {
                    "host": host,
                    "port": port,
                    "timeout": timeout,
                    "closed": False,
                }
            )
            assert context is tls_context

        def request(
            self,
            method: str,
            path: str,
            *,
            body: bytes | None = None,
            headers: dict[str, str] | None = None,
        ) -> None:
            calls[-1].update(
                {
                    "method": method,
                    "path": path,
                    "body": body,
                    "headers": headers,
                }
            )

        def getresponse(self) -> Response:
            return Response(*responses[len(calls) - 1])

        def close(self) -> None:
            calls[-1]["closed"] = True

    tls_context = object()
    monkeypatch.setattr(admin, "_tls_context", lambda: tls_context)
    monkeypatch.setattr(admin, "_LoopbackHTTPSConnection", Connection)
    return calls


def put_envelope(
    admin: ModuleType,
    flow: dict[str, object],
    *,
    base_flow: dict[str, object] | None = None,
) -> dict[str, object]:
    return {
        "baseDigest": admin._flow_digest(flow if base_flow is None else base_flow),
        "flow": flow,
    }


def install_put_response(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    flow: dict[str, object],
    *,
    status: int,
    body: bytes = b"",
    current_flow: dict[str, object] | None = None,
) -> list[dict[str, object]]:
    current = flow if current_flow is None else current_flow
    return install_responses(
        admin,
        monkeypatch,
        [
            (200, json.dumps(current).encode()),
            (status, body),
        ],
    )


@pytest.mark.parametrize(
    "argv",
    [
        [],
        ["-h"],
        ["--help"],
        ["list"],
        ["flows"],
        ["flows", "get", FLOW_ID],
        ["flow", "get"],
        ["flow", "put", FLOW_ID, "extra"],
        ["flow", "delete", FLOW_ID],
        ["flow", "create"],
        ["POST", "/flows"],
    ],
)
def test_only_three_command_shapes_exist(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    argv: list[str],
) -> None:
    monkeypatch.setattr(
        admin,
        "_read_token",
        lambda: pytest.fail("invalid commands must not read the token"),
    )
    assert admin.main(argv) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err.endswith(admin.USAGE)
    assert captured.err.startswith("node-red-admin: ")


@pytest.mark.parametrize(
    "flow_id",
    [
        "0",
        "f" * 32,
        "0.1",
        "a" * 32 + "." + "b" * 32,
        FLOW_ID,
        LEGACY_FLOW_ID,
    ],
)
def test_flow_id_boundary_accepts_only_lowercase_hex(
    admin: ModuleType,
    flow_id: str,
) -> None:
    assert admin._parse_command(["flow", "get", flow_id]) == (
        "flow-get",
        flow_id,
    )


@pytest.mark.parametrize(
    "flow_id",
    [
        "",
        "g",
        "A",
        "F" * 16,
        "f" * 33,
        ".a",
        "a.",
        "a..b",
        "a.b.c",
        "../flows",
        "a/credentials",
        "a%2fb",
        "a-b",
        " a",
    ],
)
def test_flow_id_boundary_rejects_path_and_legacy_mutants(
    admin: ModuleType,
    flow_id: str,
) -> None:
    with pytest.raises(admin.CallerError):
        admin._parse_command(["flow", "get", flow_id])


def test_flows_get_uses_fixed_tls_and_emits_only_tab_metadata(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    response = [
        {"id": FLOW_ID, "type": "tab", "label": "Office", "info": "private"},
        {
            "id": "aaaaaaaaaaaaaaaa",
            "type": "inject",
            "password": "ordinary-flow-data",
        },
    ]
    calls = install_response(
        admin,
        monkeypatch,
        status=200,
        body=json.dumps(response).encode(),
    )

    assert admin.main(["flows", "get"]) == 0
    captured = capsys.readouterr()
    assert captured.out == '{"flows":[{"id":"0123456789abcdef","label":"Office"}]}\n'
    assert captured.err == ""
    assert calls == [
        {
            "host": "nodered.vulcan.lan",
            "port": 443,
            "timeout": 10,
            "closed": True,
            "method": "GET",
            "path": "/flows",
            "body": None,
            "headers": {
                "Accept": "application/json",
                "Authorization": f"Bearer {TOKEN}",
                "Host": "nodered.vulcan.lan",
            },
        }
    ]


def test_tls_connection_dials_only_loopback_and_uses_sni(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[tuple[object, ...]] = []

    class RawSocket:
        def close(self) -> None:
            calls.append(("close",))

    class Context:
        def wrap_socket(self, sock: object, *, server_hostname: str) -> object:
            calls.append(("tls", sock, server_hostname))
            return tls_socket

    raw_socket = RawSocket()
    tls_socket = object()
    monkeypatch.setattr(
        admin.socket,
        "create_connection",
        lambda address, timeout: calls.append(("tcp", address, timeout)) or raw_socket,
    )
    connection = admin._LoopbackHTTPSConnection(
        admin.TLS_SERVER_NAME,
        admin.TLS_PORT,
        timeout=admin.IO_TIMEOUT_SECONDS,
        context=Context(),
    )
    connection.connect()

    assert calls == [
        ("tcp", ("127.0.0.1", 443), 10),
        ("tls", raw_socket, "nodered.vulcan.lan"),
    ]
    assert connection.sock is tls_socket


def test_tls_context_uses_fixed_trusted_ca_and_hostname_verification(
    admin: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    expected_path = "/etc/ssl/certs/ca-bundle.crt"
    assert admin.CA_FILE == Path(expected_path)
    ca_file = tmp_path / "ca-bundle.crt"
    ca_file.write_text("synthetic CA")
    ca_file.chmod(0o444)
    metadata = ca_file.stat()

    class FixedCAPath:
        def stat(self) -> os.stat_result:
            return metadata

        def __str__(self) -> str:
            return expected_path

    class Context:
        check_hostname = True
        verify_mode = ssl.CERT_REQUIRED

    calls: list[str] = []
    context = Context()
    monkeypatch.setattr(admin, "CA_FILE", FixedCAPath())
    monkeypatch.setattr(
        admin.ssl,
        "create_default_context",
        lambda *, cafile: calls.append(cafile) or context,
    )
    result = admin._tls_context()
    assert result is context
    assert calls == [expected_path]
    assert result.check_hostname is True
    assert result.verify_mode == ssl.CERT_REQUIRED


@pytest.mark.parametrize("invalid", ["owner", "writable"])
def test_tls_context_rejects_untrusted_ca_metadata(
    admin: ModuleType,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    invalid: str,
) -> None:
    ca_file = tmp_path / "ca-bundle.crt"
    ca_file.write_text("synthetic CA")
    ca_file.chmod(0o444)
    values = list(ca_file.stat())
    if invalid == "owner":
        values[stat.ST_UID] = admin.TRUSTED_UID + 1
    else:
        values[stat.ST_MODE] |= 0o020
    metadata = os.stat_result(values)

    class CAPath:
        def stat(self) -> os.stat_result:
            return metadata

    monkeypatch.setattr(admin, "CA_FILE", CAPath())
    monkeypatch.setattr(
        admin.ssl,
        "create_default_context",
        lambda **_kwargs: pytest.fail("untrusted CA must not be loaded"),
    )
    with pytest.raises(admin.OperationalError, match="ownership invalid"):
        admin._tls_context()


@pytest.mark.parametrize("flow_id", [FLOW_ID, LEGACY_FLOW_ID])
def test_full_get_output_round_trips_to_put_without_losing_fields(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    flow_id: str,
) -> None:
    flow = {
        "id": flow_id,
        "label": "Office",
        "nodes": [{"id": "a", "type": "inject", "wires": [[]]}],
        "configs": [{"id": "b", "type": "server-state-changed"}],
        "env": [{"name": "Temperature", "value": "78"}],
        "info": "authorized sensitive flow content",
    }
    install_response(
        admin,
        monkeypatch,
        status=200,
        body=json.dumps(flow, indent=2).encode(),
    )
    assert admin.main(["flow", "get", flow_id]) == 0
    get_output = capsys.readouterr()
    envelope = json.loads(get_output.out)
    assert list(envelope) == ["baseDigest", "flow"]
    assert envelope["baseDigest"] == admin._flow_digest(flow)
    assert envelope["flow"] == flow
    assert get_output.err == ""

    monkeypatch.setattr(sys, "stdin", Stdin(get_output.out.encode()))
    calls = install_put_response(admin, monkeypatch, flow, status=204)
    assert admin.main(["flow", "put", flow_id]) == 0
    put_output = capsys.readouterr()
    assert put_output.out == f'{{"ok":true,"id":"{flow_id}"}}\n'
    assert put_output.err == ""
    assert calls[0]["method"] == "GET"
    assert calls[0]["path"] == f"/flow/{flow_id}"
    assert calls[1]["method"] == "PUT"
    assert calls[1]["path"] == f"/flow/{flow_id}"
    assert json.loads(calls[1]["body"]) == flow


def test_flow_digest_is_sha256_of_canonical_strict_json(admin: ModuleType) -> None:
    first = {"nodes": [], "label": "\N{LATIN SMALL LETTER E WITH ACUTE}", "id": FLOW_ID}
    reordered = {
        "id": FLOW_ID,
        "label": "\N{LATIN SMALL LETTER E WITH ACUTE}",
        "nodes": [],
    }
    canonical = '{"id":"0123456789abcdef","label":"\\u00e9","nodes":[]}'.encode()
    expected = "sha256:" + hashlib.sha256(canonical).hexdigest()
    assert admin._flow_digest(first) == expected
    assert admin._flow_digest(reordered) == expected


@pytest.mark.parametrize(
    "status,body",
    [
        (200, b'{"id":"0123456789abcdef"}'),
        (204, b""),
    ],
)
def test_put_accepts_exact_success_statuses(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    status: int,
    body: bytes,
) -> None:
    flow = {"id": FLOW_ID, "nodes": [], "configs": []}
    monkeypatch.setattr(
        sys,
        "stdin",
        Stdin(json.dumps(put_envelope(admin, flow)).encode()),
    )
    install_put_response(admin, monkeypatch, flow, status=status, body=body)
    assert admin.main(["flow", "put", FLOW_ID]) == 0
    assert capsys.readouterr().out == '{"ok":true,"id":"0123456789abcdef"}\n'


def test_put_rejects_stale_selected_flow_without_writing(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    predecessor = {"id": FLOW_ID, "nodes": [], "label": "before"}
    edited = {"id": FLOW_ID, "nodes": [], "label": "my edit"}
    conflicting = {"id": FLOW_ID, "nodes": [], "label": "other writer"}
    monkeypatch.setattr(
        sys,
        "stdin",
        Stdin(
            json.dumps(
                put_envelope(admin, edited, base_flow=predecessor),
            ).encode()
        ),
    )
    calls = install_response(
        admin,
        monkeypatch,
        status=200,
        body=json.dumps(conflicting).encode(),
    )

    assert admin.main(["flow", "put", FLOW_ID]) == 1
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err == "node-red-admin: selected flow changed; fetch again\n"
    assert [(call["method"], call["path"]) for call in calls] == [
        ("GET", f"/flow/{FLOW_ID}")
    ]


@pytest.mark.parametrize(
    "status,body",
    [
        (200, b""),
        (200, b"[]"),
        (200, b"{}"),
        (200, b'{"id":"different"}'),
        (200, b'{"id":"0123456789abcdef","id":"0123456789abcdef"}'),
        (204, b"\n"),
        (204, b"{}"),
    ],
)
def test_put_rejects_invalid_success_response(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    status: int,
    body: bytes,
) -> None:
    flow = {"id": FLOW_ID, "nodes": []}
    monkeypatch.setattr(
        sys,
        "stdin",
        Stdin(json.dumps(put_envelope(admin, flow)).encode()),
    )
    calls = install_put_response(
        admin,
        monkeypatch,
        flow,
        status=status,
        body=body,
    )
    assert admin.main(["flow", "put", FLOW_ID]) == 1
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err.startswith("node-red-admin: ")
    assert calls[-1]["method"] == "PUT"


@pytest.mark.parametrize("status", [200, 204, 206, 301, 307, 400, 500])
def test_get_requires_exact_200(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    status: int,
) -> None:
    expected = status == 200
    body = json.dumps({"id": FLOW_ID, "nodes": [], "configs": []}).encode()
    install_response(admin, monkeypatch, status=status, body=body)
    assert admin.main(["flow", "get", FLOW_ID]) == (0 if expected else 1)
    captured = capsys.readouterr()
    if not expected:
        assert captured.out == ""
        assert captured.err == f"node-red-admin: Node-RED returned HTTP {status}\n"


@pytest.mark.parametrize("status", [202, 301, 307, 400, 500])
def test_put_rejects_redirects_and_non_success_statuses(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    status: int,
) -> None:
    flow = {"id": FLOW_ID, "nodes": []}
    monkeypatch.setattr(
        sys,
        "stdin",
        Stdin(json.dumps(put_envelope(admin, flow)).encode()),
    )
    install_put_response(
        admin,
        monkeypatch,
        flow,
        status=status,
        body=b'{"ignored":true}',
    )
    assert admin.main(["flow", "put", FLOW_ID]) == 1
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err == f"node-red-admin: Node-RED returned HTTP {status}\n"


@pytest.mark.parametrize(
    "body",
    [
        b"[]",
        b"not-json",
        b'{"id":"' + FLOW_ID.encode() + b'","nodes":[]}',
        b'{"baseDigest":"bad","flow":{"id":"' + FLOW_ID.encode() + b'","nodes":[]}}',
        b'{"baseDigest":"'
        + VALID_DIGEST.encode()
        + b'","flow":{"id":"different","nodes":[]}}',
        b'{"baseDigest":"'
        + VALID_DIGEST.encode()
        + b'","flow":{"id":"'
        + FLOW_ID.encode()
        + b'","nodes":{}}}',
        b'{"baseDigest":"'
        + VALID_DIGEST.encode()
        + b'","flow":{"id":"'
        + FLOW_ID.encode()
        + b'","nodes":[],"configs":{}}}',
        b'{"baseDigest":"'
        + VALID_DIGEST.encode()
        + b'","flow":{"id":"'
        + FLOW_ID.encode()
        + b'","nodes":[]},"extra":true}',
        b'{"baseDigest":"'
        + VALID_DIGEST.encode()
        + b'","flow":{"id":"'
        + FLOW_ID.encode()
        + b'","nodes":[]}}{}',
        b'{"baseDigest":"'
        + VALID_DIGEST.encode()
        + b'","flow":{"id":"'
        + FLOW_ID.encode()
        + b'","nodes":[]}} trailing',
    ],
)
def test_put_rejects_invalid_input_before_http(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    body: bytes,
) -> None:
    monkeypatch.setattr(sys, "stdin", Stdin(body))
    monkeypatch.setattr(
        admin,
        "_request",
        lambda *_args, **_kwargs: pytest.fail("HTTP must not be attempted"),
    )
    assert admin.main(["flow", "put", FLOW_ID]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err.endswith(admin.USAGE)


@pytest.mark.parametrize("constant", ["NaN", "Infinity", "-Infinity", "1e400"])
def test_strict_json_rejects_non_finite_put_numbers(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    constant: str,
) -> None:
    body = (
        f'{{"baseDigest":"{VALID_DIGEST}","flow":'
        f'{{"id":"{FLOW_ID}","nodes":[],"value":{constant}}}}}'
    ).encode()
    monkeypatch.setattr(sys, "stdin", Stdin(body))
    monkeypatch.setattr(
        admin,
        "_request",
        lambda *_args, **_kwargs: pytest.fail("HTTP must not be attempted"),
    )
    assert admin.main(["flow", "put", FLOW_ID]) == 2


@pytest.mark.parametrize("constant", ["NaN", "Infinity", "-Infinity", "1e400"])
def test_strict_json_rejects_non_finite_get_numbers(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    constant: str,
) -> None:
    body = f'{{"id":"{FLOW_ID}","nodes":[],"value":{constant}}}'.encode()
    install_response(admin, monkeypatch, status=200, body=body)
    assert admin.main(["flow", "get", FLOW_ID]) == 1


def test_deep_caller_json_is_normalized_to_exit_two(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    depth = sys.getrecursionlimit() + 100
    body = (
        f'{{"baseDigest":"{VALID_DIGEST}","flow":{{"id":"{FLOW_ID}","nodes":'.encode()
        + b"[" * depth
        + b"]" * depth
        + b"}}"
    )
    monkeypatch.setattr(sys, "stdin", Stdin(body))
    monkeypatch.setattr(
        admin,
        "_request",
        lambda *_args, **_kwargs: pytest.fail("HTTP must not be attempted"),
    )
    assert admin.main(["flow", "put", FLOW_ID]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err.endswith(admin.USAGE)
    assert "Recursion" not in captured.err


@pytest.mark.parametrize("stage", ["token-traversal", "encode"])
def test_deep_decoded_input_recursion_is_a_caller_error(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    stage: str,
) -> None:
    nested: object = []
    for _ in range(sys.getrecursionlimit() + 100):
        nested = [nested]
    value = {
        "baseDigest": VALID_DIGEST,
        "flow": {"id": FLOW_ID, "nodes": nested},
    }
    monkeypatch.setattr(sys, "stdin", Stdin(b"{}"))
    monkeypatch.setattr(admin, "_decode_json", lambda *_args: value)
    if stage == "encode":
        monkeypatch.setattr(admin, "_contains_token", lambda *_args: False)
        monkeypatch.setattr(
            admin.json,
            "dumps",
            lambda *_args, **_kwargs: (_ for _ in ()).throw(RecursionError()),
        )
    monkeypatch.setattr(
        admin,
        "_request",
        lambda *_args, **_kwargs: pytest.fail("HTTP must not be attempted"),
    )
    assert admin.main(["flow", "put", FLOW_ID]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err.endswith(admin.USAGE)
    assert "Recursion" not in captured.err


def test_deep_upstream_json_is_normalized_to_operational_failure(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    depth = sys.getrecursionlimit() + 100
    body = f'{{"id":"{FLOW_ID}","nodes":'.encode() + b"[" * depth + b"]" * depth + b"}"
    install_response(admin, monkeypatch, status=200, body=body)
    assert admin.main(["flow", "get", FLOW_ID]) == 1
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err == "node-red-admin: JSON nesting is too deep\n"
    assert "Recursion" not in captured.err


@pytest.mark.parametrize("direction", ["get-value", "get-key", "put-value", "put-key"])
def test_escaped_runtime_token_is_rejected_recursively(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    direction: str,
) -> None:
    escaped = "\\u0073" + TOKEN[1:]
    if direction.endswith("key"):
        extra = f'"outer":{{"items":[{{"{escaped}":"value"}}]}}'
    else:
        extra = f'"outer":{{"items":[{{"note":"{escaped}"}}]}}'
    flow_body = f'{{"id":"{FLOW_ID}","nodes":[],{extra}}}'
    body = flow_body.encode()
    if direction.startswith("get"):
        install_response(admin, monkeypatch, status=200, body=body)
        result = admin.main(["flow", "get", FLOW_ID])
        expected_exit = 1
    else:
        body = (f'{{"baseDigest":"{VALID_DIGEST}","flow":{flow_body}}}').encode()
        monkeypatch.setattr(sys, "stdin", Stdin(body))
        monkeypatch.setattr(
            admin,
            "_request",
            lambda *_args, **_kwargs: pytest.fail("HTTP must not be attempted"),
        )
        result = admin.main(["flow", "put", FLOW_ID])
        expected_exit = 2
    assert result == expected_exit
    captured = capsys.readouterr()
    assert captured.out == ""
    assert TOKEN not in captured.err


def test_literal_runtime_token_is_rejected_in_put_raw_bytes(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    flow = {"id": FLOW_ID, "nodes": [], "note": TOKEN}
    body = json.dumps(put_envelope(admin, flow)).encode()
    monkeypatch.setattr(sys, "stdin", Stdin(body))
    monkeypatch.setattr(
        admin,
        "_request",
        lambda *_args, **_kwargs: pytest.fail("HTTP must not be attempted"),
    )
    assert admin.main(["flow", "put", FLOW_ID]) == 2
    captured = capsys.readouterr()
    assert TOKEN not in captured.out + captured.err


def test_token_in_successful_put_response_is_rejected(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    flow = {"id": FLOW_ID, "nodes": []}
    monkeypatch.setattr(
        sys,
        "stdin",
        Stdin(json.dumps(put_envelope(admin, flow)).encode()),
    )
    escaped = "\\u0073" + TOKEN[1:]
    install_put_response(
        admin,
        monkeypatch,
        flow,
        status=200,
        body=f'{{"id":"{FLOW_ID}","{escaped}":true}}'.encode(),
    )
    assert admin.main(["flow", "put", FLOW_ID]) == 1
    captured = capsys.readouterr()
    assert captured.out == ""
    assert TOKEN not in captured.err


def test_input_raw_and_normalized_limits(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    flow = {"id": FLOW_ID, "nodes": []}
    minimal = json.dumps(
        put_envelope(admin, flow),
        separators=(",", ":"),
    ).encode()
    exact = minimal + b" " * (admin.MAX_INPUT_BYTES - len(minimal))
    monkeypatch.setattr(sys, "stdin", Stdin(exact))
    install_put_response(admin, monkeypatch, flow, status=204)
    assert admin.main(["flow", "put", FLOW_ID]) == 0

    monkeypatch.setattr(sys, "stdin", Stdin(exact + b" "))
    assert admin.main(["flow", "put", FLOW_ID]) == 2

    expanded_flow = {
        "id": FLOW_ID,
        "nodes": [],
        "label": "é" * (admin.MAX_INPUT_BYTES // 5),
    }
    raw = json.dumps(
        put_envelope(admin, expanded_flow),
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode()
    assert len(raw) < admin.MAX_INPUT_BYTES
    monkeypatch.setattr(sys, "stdin", Stdin(raw))
    assert admin.main(["flow", "put", FLOW_ID]) == 2


def test_upstream_read_limit_exact_and_plus_one(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    install_response(
        admin, monkeypatch, status=200, body=b"x" * admin.MAX_RESPONSE_BYTES
    )
    assert admin.main(["flows", "get"]) == 1
    assert "invalid JSON" in capsys.readouterr().err

    install_response(
        admin,
        monkeypatch,
        status=200,
        body=b"x" * (admin.MAX_RESPONSE_BYTES + 1),
    )
    assert admin.main(["flows", "get"]) == 1
    assert capsys.readouterr().err == (
        "node-red-admin: Node-RED response exceeds 8388608 bytes\n"
    )


def test_final_output_limit_counts_newline(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    exact_stdout = Stdout()
    monkeypatch.setattr(sys, "stdout", exact_stdout)
    exact_payload = "x" * (admin.MAX_OUTPUT_BYTES - len('{"x":""}') - 1)
    admin._emit_json({"x": exact_payload}, TOKEN)
    assert len(exact_stdout.buffer.getvalue()) == admin.MAX_OUTPUT_BYTES

    with pytest.raises(admin.OperationalError, match="output limit"):
        admin._emit_json({"x": exact_payload + "x"}, TOKEN)


def test_lone_surrogates_are_ascii_escaped(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    response = [{"id": FLOW_ID, "type": "tab", "label": "\ud800"}]
    install_response(
        admin,
        monkeypatch,
        status=200,
        body=json.dumps(response).encode(),
    )
    assert admin.main(["flows", "get"]) == 0
    captured = capsys.readouterr()
    assert "\\ud800" in captured.out


@pytest.mark.parametrize(
    "raw",
    [
        b"",
        b"token\r\n",
        b" token\n",
        b"token \n",
        b"token\n\n",
        b"token\x00",
        b"x" * 4097,
        b"x" * 4097 + b"\n",
    ],
)
def test_token_format_is_exact(
    admin: ModuleType,
    raw: bytes,
) -> None:
    admin._test_token_path.chmod(0o600)
    admin._test_token_path.write_bytes(raw)
    admin._test_token_path.chmod(0o400)
    with pytest.raises(admin.OperationalError):
        admin._read_token()


def test_sops_generation_and_optional_final_symlink_are_accepted(
    admin: ModuleType,
) -> None:
    assert admin._read_token() == TOKEN
    admin._test_token_path.unlink()
    target = admin._test_generation / "target-token"
    target.write_bytes(TOKEN.encode())
    target.chmod(0o400)
    admin._test_token_path.symlink_to(target.name)
    assert admin._read_token() == TOKEN


def test_execute_only_sops_directories_support_known_secret_name(
    admin: ModuleType,
) -> None:
    admin.RUN_DIRECTORY.chmod(0o111)
    admin._test_generation.chmod(0o111)
    try:
        assert admin._read_token() == TOKEN
    finally:
        admin.RUN_DIRECTORY.chmod(0o700)
        admin._test_generation.chmod(0o700)


def test_wrong_sops_link_owner_is_rejected(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    real_stat = admin.os.stat

    def wrong_owner(path: object, *args: object, **kwargs: object) -> os.stat_result:
        metadata = real_stat(path, *args, **kwargs)
        if path == admin.SECRETS_NAME and kwargs.get("follow_symlinks") is False:
            values = list(metadata)
            values[stat.ST_UID] = admin.TRUSTED_UID + 1
            return os.stat_result(values)
        return metadata

    monkeypatch.setattr(admin.os, "stat", wrong_owner)
    with pytest.raises(admin.OperationalError, match="path invalid"):
        admin._read_token()


@pytest.mark.parametrize("field", [stat.ST_UID, stat.ST_GID])
def test_wrong_opened_token_owner_or_group_is_rejected(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    field: int,
) -> None:
    real_fstat = admin.os.fstat
    calls = 0

    def wrong_identity(descriptor: int) -> os.stat_result:
        nonlocal calls
        calls += 1
        metadata = real_fstat(descriptor)
        if calls == 3:
            values = list(metadata)
            values[field] += 1
            return os.stat_result(values)
        return metadata

    monkeypatch.setattr(admin.os, "fstat", wrong_identity)
    with pytest.raises(admin.OperationalError, match="ownership invalid"):
        admin._read_token()


def test_descriptor_metadata_rejects_mode_and_non_regular_entry(
    admin: ModuleType,
) -> None:
    admin._test_token_path.chmod(0o440)
    with pytest.raises(admin.OperationalError, match="ownership invalid"):
        admin._read_token()

    admin._test_token_path.unlink()
    os.mkfifo(admin._test_token_path)
    with pytest.raises(admin.OperationalError, match="path invalid"):
        admin._read_token()


def test_mutable_sops_generation_is_rejected(admin: ModuleType) -> None:
    admin._test_generation.chmod(0o770)
    with pytest.raises(admin.OperationalError, match="path invalid"):
        admin._read_token()


def test_open_directory_descriptor_defeats_generation_retarget(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    generation_two = admin.RUN_DIRECTORY / "secrets.d" / "2"
    generation_two.mkdir()
    generation_two.chmod(0o700)
    replacement = generation_two / admin.TOKEN_NAME
    replacement.write_bytes(b"different-synthetic-token\n")
    replacement.chmod(0o400)
    real_open = admin.os.open
    rotated = False

    def racing_open(path: object, flags: int, *args: object, **kwargs: object) -> int:
        nonlocal rotated
        if path == admin.TOKEN_NAME and not rotated:
            rotated = True
            link = admin.RUN_DIRECTORY / admin.SECRETS_NAME
            link.unlink()
            link.symlink_to(Path("secrets.d") / "2")
        return real_open(path, flags, *args, **kwargs)

    monkeypatch.setattr(admin.os, "open", racing_open)
    assert admin._read_token() == TOKEN


def test_total_deadline_interrupts_blocked_input(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    read_fd, write_fd = os.pipe()
    reader = os.fdopen(read_fd, "rb", buffering=0)
    monkeypatch.setattr(sys, "stdin", type("PipeStdin", (), {"buffer": reader})())
    monkeypatch.setattr(admin, "TOTAL_TIMEOUT_SECONDS", 0.03)
    try:
        assert admin.main(["flow", "put", FLOW_ID]) == 1
    finally:
        os.close(write_fd)
        reader.close()
    assert capsys.readouterr().err == ""


def test_total_deadline_interrupts_slow_peer(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setattr(admin, "TOTAL_TIMEOUT_SECONDS", 0.03)
    monkeypatch.setattr(admin, "_list_flows", lambda _token: time.sleep(1))
    assert admin.main(["flows", "get"]) == 1
    assert capsys.readouterr().err == ""


def test_total_deadline_interrupts_blocked_output_flush(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    class SlowBuffer:
        def write(self, value: bytes) -> int:
            return len(value)

        def flush(self) -> None:
            time.sleep(1)

    monkeypatch.setattr(
        sys,
        "stdout",
        type("SlowStdout", (), {"buffer": SlowBuffer()})(),
    )
    monkeypatch.setattr(admin, "TOTAL_TIMEOUT_SECONDS", 0.03)
    monkeypatch.setattr(
        admin,
        "_list_flows",
        lambda token: admin._emit_json({"flows": []}, token),
    )
    assert admin.main(["flows", "get"]) == 1
    assert capsys.readouterr().err == ""


def test_total_deadline_interrupts_blocked_error_flush(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class SlowStderr:
        def write(self, value: str) -> int:
            return len(value)

        def flush(self) -> None:
            time.sleep(1)

    monkeypatch.setattr(sys, "stderr", SlowStderr())
    monkeypatch.setattr(admin, "TOTAL_TIMEOUT_SECONDS", 0.03)

    started = time.monotonic()
    assert admin.main(["--help"]) == 2
    assert time.monotonic() - started < 0.5

    def fail_after_token(_token: str) -> None:
        raise admin.OperationalError("fixed operational failure")

    monkeypatch.setattr(admin, "_list_flows", fail_after_token)
    started = time.monotonic()
    assert admin.main(["flows", "get"]) == 1
    assert time.monotonic() - started < 0.5


def test_deadline_restores_prior_handler_and_timer(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    previous_handler = signal.getsignal(signal.SIGALRM)
    signal.setitimer(signal.ITIMER_REAL, 2)
    monkeypatch.setattr(admin, "_list_flows", lambda _token: None)
    try:
        assert admin.main(["flows", "get"]) == 0
        remaining = signal.getitimer(signal.ITIMER_REAL)[0]
        assert 0 < remaining <= 2
        assert signal.getsignal(signal.SIGALRM) == previous_handler
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)


def test_core_and_dumpable_controls_run_before_token_read(
    tmp_path: Path,
) -> None:
    spec = importlib.util.spec_from_file_location("node_red_admin_core", MODULE_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    calls: list[tuple[object, ...]] = []

    class Prctl:
        argtypes: object = None
        restype: object = None

        def __call__(self, operation: int, *args: int) -> int:
            calls.append(("prctl", operation, *args))
            return 0

    class Libc:
        prctl = Prctl()

    module.resource.setrlimit = lambda limit, value: calls.append(
        ("rlimit", limit, value)
    )
    module.ctypes.CDLL = lambda *_args, **_kwargs: Libc()
    module._disable_core_dumps()
    assert calls == [
        ("rlimit", module.resource.RLIMIT_CORE, (0, 0)),
        ("prctl", 4, 0, 0, 0, 0),
        ("prctl", 3, 0, 0, 0, 0),
    ]


def test_main_hardens_process_before_reading_token(
    admin: ModuleType,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[str] = []
    monkeypatch.setattr(admin, "_disable_core_dumps", lambda: calls.append("disable"))
    monkeypatch.setattr(
        admin,
        "_read_token",
        lambda: calls.append("read-token") or TOKEN,
    )
    monkeypatch.setattr(admin, "_list_flows", lambda _token: calls.append("request"))
    assert admin.main(["flows", "get"]) == 0
    assert calls == ["disable", "read-token", "request"]


def test_implementation_has_no_child_or_tempfile_path() -> None:
    source = MODULE_PATH.read_text()
    assert "subprocess" not in source
    assert "tempfile" not in source
    assert "curl" not in source
    assert "urllib" not in source
    assert 'LOOPBACK_HOST = "127.0.0.1"' in source
    assert 'TLS_SERVER_NAME = "nodered.vulcan.lan"' in source
    assert "TLS_PORT = 443" in source
    assert "IO_TIMEOUT_SECONDS = 10" in source
    assert "TOTAL_TIMEOUT_SECONDS = 15" in source
    assert '"POST"' not in source
    assert '"DELETE"' not in source


@pytest.mark.skipif(CONTRACT_PATH is None, reason="requires evaluated Nix contract")
def test_evaluated_vulcan_contract() -> None:
    contract = json.loads(Path(CONTRACT_PATH).read_text())
    assert contract["port"] == 844
    assert contract["sysctl"] == 1024
    assert contract["upstreams"] == ["127.0.0.1:844"]
    assert contract["ambientCapabilities"] == ["CAP_NET_BIND_SERVICE"]
    assert contract["capabilityBoundingSet"] == ["CAP_NET_BIND_SERVICE"]
    assert contract["secret"] == {
        "group": "node-red-admin",
        "mode": "0400",
        "owner": "node-red-admin",
    }
    assert contract["user"] == {
        "group": "node-red-admin",
        "isSystemUser": True,
    }
    assert contract["sudo"]["users"] == ["johnw"]
    assert contract["sudo"]["runAs"] == "node-red-admin:node-red-admin"
    assert contract["sudo"]["command"] == contract["backend"]
    assert set(contract["sudo"]["options"]) == {
        "NOPASSWD",
        "NOSETENV",
        "NOLOG_INPUT",
        "NOLOG_OUTPUT",
    }
    assert contract["alertmanagerUrl"] == "http://127.0.0.1:844/alert"
    assert contract["blackboxTarget"] == "http://127.0.0.1:844/alert"
    assert contract["prometheusTarget"] == "localhost:844"


@pytest.mark.skipif(CONTRACT_PATH is None, reason="requires built Nix package")
def test_built_backend_is_exact_and_ignores_hostile_environment(tmp_path: Path) -> None:
    contract = json.loads(Path(CONTRACT_PATH).read_text())
    backend = Path(contract["backend"])
    frontend = Path(contract["frontend"])
    source = Path(contract["source"])

    assert stat.S_IMODE(source.stat().st_mode) & 0o111 == 0
    assert source.read_text() == MODULE_PATH.read_text()
    backend_text = backend.read_text()
    assert backend_text.startswith(f"#!{contract['bash']}/bin/bash -p\n")
    assert (
        f"exec {contract['coreutils']}/bin/env -i LC_ALL=C "
        f'{contract["python"]}/bin/python3 -I -B {source} "$@"\n'
        in backend_text.replace("\\\n  ", "")
    )
    assert frontend.read_text() == (
        f"#!{contract['bash']}/bin/bash -p\n"
        "exec /run/wrappers/bin/sudo -n -u node-red-admin -g node-red-admin -- "
        f'{backend} "$@"\n'
    )

    marker = tmp_path / "hostile-environment-ran"
    bash_env = tmp_path / "bash-env"
    bash_env.write_text(f"touch {marker}\n")
    python_path = tmp_path / "python-path"
    python_path.mkdir()
    (python_path / "sitecustomize.py").write_text(
        f"from pathlib import Path\nPath({str(marker)!r}).write_text('site')\n"
    )
    startup = tmp_path / "startup.py"
    startup.write_text(
        f"from pathlib import Path; Path({str(marker)!r}).write_text('startup')\n"
    )
    hostile = {
        "BASH_ENV": str(bash_env),
        "ENV": str(bash_env),
        "PYTHONPATH": str(python_path),
        "PYTHONSTARTUP": str(startup),
        "PYTHONINSPECT": "1",
        "PYTHONWARNINGS": "error",
        "PATH": str(tmp_path),
        "LC_ALL": "C.UTF-8",
    }
    completed = subprocess.run(
        [backend, "--help"],
        env=hostile,
        check=False,
        capture_output=True,
        text=True,
        timeout=5,
    )
    assert completed.returncode == 2
    assert completed.stdout == ""
    assert completed.stderr == "node-red-admin: invalid command\n" + (
        "usage:\n"
        "  node-red-admin flows get\n"
        "  node-red-admin flow get FLOW_ID\n"
        "  node-red-admin flow put FLOW_ID < flow.json\n"
    )
    assert not marker.exists()
    assert TOKEN not in completed.stdout + completed.stderr


def test_settings_and_every_maintained_port_consumer_use_privileged_port() -> None:
    active_paths = [
        "config/node-red-settings.js",
        "modules/services/node-red.nix",
        "modules/services/blackbox-monitoring.nix",
        "modules/services/alertmanager.nix",
        "modules/monitoring/alerts/meta-monitoring.yaml",
        "modules/monitoring/services/node-red-exporter.nix",
        "docs/ports.txt",
    ]
    active = "\n".join((REPO_ROOT / path).read_text() for path in active_paths)
    settings = (REPO_ROOT / "config/node-red-settings.js").read_text()
    assert "uiPort: process.env.PORT || 844" in settings
    assert 'uiHost: "127.0.0.1"' in settings
    # The only retained active-file 1880 text is the explicitly historical
    # 2026-07-27 observation in the alert-rule comment.
    assert active.count("1880") == 1
    assert 'instance="http://127.0.0.1:1880/alert"} == 1' in active
    assert 'probe_success{instance=~"https?://127\\\\.0\\\\.0\\\\.1:844' in active


def test_repo_wide_maintained_sources_have_no_1880_consumer() -> None:
    allowed = {
        (
            Path("modules/monitoring/alerts/meta-monitoring.yaml"),
            '# instance="http://127.0.0.1:1880/alert"} == 1. This candidate moves the',
        )
    }
    found: set[tuple[Path, str]] = set()
    for root_name in ("config", "hosts", "modules", "scripts", "tests"):
        for path in (REPO_ROOT / root_name).rglob("*"):
            if not path.is_file() or path.resolve() == Path(__file__).resolve():
                continue
            try:
                lines = path.read_text().splitlines()
            except UnicodeDecodeError:
                continue
            relative = path.relative_to(REPO_ROOT)
            found.update((relative, line.strip()) for line in lines if "1880" in line)
    assert found == allowed
