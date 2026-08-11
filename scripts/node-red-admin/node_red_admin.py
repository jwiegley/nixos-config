#!/usr/bin/env python3
"""Bounded, secret-safe access to the local Node-RED flow Admin API.

This helper is for a trusted administrator and authorized flow author.  It
keeps the service token out of the caller's process and output, but ``flow
get`` intentionally returns the complete selected flow and is not a content
sandbox.
"""

from __future__ import annotations

import contextlib
import ctypes
import http.client
import json
import math
import os
import re
import resource
import signal
import socket
import ssl
import stat
import sys
import time
from collections.abc import Iterator
from pathlib import Path
from typing import Any


RUN_DIRECTORY = Path("/run")
SECRETS_NAME = "secrets"
TOKEN_NAME = "node-red-admin-token"
TRUSTED_UID = 0
CA_FILE = Path("/etc/ssl/certs/ca-bundle.crt")
LOOPBACK_HOST = "127.0.0.1"
TLS_SERVER_NAME = "nodered.vulcan.lan"
TLS_PORT = 443
IO_TIMEOUT_SECONDS = 10
TOTAL_TIMEOUT_SECONDS = 15
MAX_TOKEN_BYTES = 4096
MAX_INPUT_BYTES = 1024 * 1024
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
MAX_OUTPUT_BYTES = 1024 * 1024
FLOW_ID_RE = re.compile(r"[0-9a-f]{1,32}(?:\.[0-9a-f]{1,32})?\Z")

USAGE = """usage:
  node-red-admin flows get
  node-red-admin flow get FLOW_ID
  node-red-admin flow put FLOW_ID < flow.json
"""


class CallerError(Exception):
    """Invalid invocation or request body."""


class OperationalError(Exception):
    """Credential, transport, or upstream response failure."""


class DeadlineExceeded(OperationalError):
    """The hard total lifecycle deadline expired."""


class _LoopbackHTTPSConnection(http.client.HTTPSConnection):
    """Authenticate the nginx vhost while pinning transport to loopback."""

    def connect(self) -> None:
        raw_socket = socket.create_connection(
            (LOOPBACK_HOST, self.port),
            self.timeout,
        )
        try:
            self.sock = self._context.wrap_socket(
                raw_socket,
                server_hostname=self.host,
            )
        except BaseException:
            raw_socket.close()
            raise


def _deadline_exceeded(_signum: int, _frame: object) -> None:
    raise DeadlineExceeded("operation timed out")


@contextlib.contextmanager
def _operation_deadline() -> Iterator[None]:
    previous_timer = signal.setitimer(signal.ITIMER_REAL, 0)
    previous_handler = signal.signal(signal.SIGALRM, _deadline_exceeded)
    started = time.monotonic()
    try:
        signal.setitimer(signal.ITIMER_REAL, TOTAL_TIMEOUT_SECONDS)
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)
        if previous_timer[0] > 0:
            elapsed = time.monotonic() - started
            remaining = max(previous_timer[0] - elapsed, 0.000001)
            signal.setitimer(
                signal.ITIMER_REAL,
                remaining,
                previous_timer[1],
            )


def _disable_core_dumps() -> None:
    try:
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        libc = ctypes.CDLL(None, use_errno=True)
        prctl = libc.prctl
        prctl.argtypes = [
            ctypes.c_int,
            ctypes.c_ulong,
            ctypes.c_ulong,
            ctypes.c_ulong,
            ctypes.c_ulong,
        ]
        prctl.restype = ctypes.c_int
        if prctl(4, 0, 0, 0, 0) != 0 or prctl(3, 0, 0, 0, 0) != 0:
            raise OSError(ctypes.get_errno(), "prctl")
    except (AttributeError, OSError, ValueError) as error:
        raise OperationalError("cannot disable core dumps") from error


def _valid_flow_id(value: object) -> bool:
    return isinstance(value, str) and FLOW_ID_RE.fullmatch(value) is not None


def _contains_token(value: Any, token: str) -> bool:
    if isinstance(value, str):
        return token in value
    if isinstance(value, list):
        return any(_contains_token(item, token) for item in value)
    if isinstance(value, dict):
        return any(
            _contains_token(key, token) or _contains_token(item, token)
            for key, item in value.items()
        )
    return False


def _secure_directory(metadata: os.stat_result) -> bool:
    return (
        stat.S_ISDIR(metadata.st_mode)
        and metadata.st_uid == TRUSTED_UID
        and stat.S_IMODE(metadata.st_mode) & 0o022 == 0
    )


def _read_token() -> str:
    # sops-nix generation directories are intentionally traverse-only for
    # identities outside its keys group.  O_PATH holds a race-resistant
    # descriptor for known-name openat/fstatat operations without requiring
    # directory read permission.
    directory_flags = os.O_PATH | os.O_DIRECTORY | os.O_CLOEXEC
    token_flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK | os.O_NOCTTY
    run_fd = secrets_fd = token_fd = -1
    try:
        run_fd = os.open(
            RUN_DIRECTORY,
            directory_flags | os.O_NOFOLLOW,
        )
        if not _secure_directory(os.fstat(run_fd)):
            raise OperationalError("admin credential path invalid")

        link_metadata = os.stat(
            SECRETS_NAME,
            dir_fd=run_fd,
            follow_symlinks=False,
        )
        if not stat.S_ISLNK(link_metadata.st_mode) or link_metadata.st_uid != TRUSTED_UID:
            raise OperationalError("admin credential path invalid")

        # Following this root-owned generation link is the normal sops-nix
        # layout.  Holding the resulting directory descriptor keeps a later
        # generation rotation from changing the object opened below.
        secrets_fd = os.open(SECRETS_NAME, directory_flags, dir_fd=run_fd)
        if not _secure_directory(os.fstat(secrets_fd)):
            raise OperationalError("admin credential path invalid")

        entry_metadata = os.stat(
            TOKEN_NAME,
            dir_fd=secrets_fd,
            follow_symlinks=False,
        )
        if stat.S_ISLNK(entry_metadata.st_mode):
            if entry_metadata.st_uid != TRUSTED_UID:
                raise OperationalError("admin credential path invalid")
        elif not stat.S_ISREG(entry_metadata.st_mode):
            raise OperationalError("admin credential path invalid")

        # Do not use O_NOFOLLOW here: sops-nix may expose a root-owned final
        # symlink.  Trust comes from the protected directory and link owner;
        # authority and mode are checked on the opened descriptor itself.
        token_fd = os.open(TOKEN_NAME, token_flags, dir_fd=secrets_fd)
        metadata = os.fstat(token_fd)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_gid != os.getegid()
            or stat.S_IMODE(metadata.st_mode) != 0o400
            or metadata.st_nlink != 1
        ):
            raise OperationalError("admin credential ownership invalid")
        raw = os.read(token_fd, MAX_TOKEN_BYTES + 2)
    except OperationalError:
        raise
    except OSError as error:
        raise OperationalError("admin credential unavailable") from error
    finally:
        for descriptor in (token_fd, secrets_fd, run_fd):
            if descriptor >= 0:
                try:
                    os.close(descriptor)
                except OSError:
                    pass

    if raw.endswith(b"\n"):
        token_bytes = raw[:-1]
    else:
        token_bytes = raw
    if (
        not 1 <= len(token_bytes) <= MAX_TOKEN_BYTES
        or len(raw) > MAX_TOKEN_BYTES + 1
        or b"\n" in token_bytes
        or any(byte < 0x21 or byte > 0x7E for byte in token_bytes)
    ):
        raise OperationalError("admin credential invalid")
    return token_bytes.decode("ascii")


def _reject_json_constant(_value: str) -> None:
    raise ValueError("non-finite JSON number")


def _strict_json_float(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed):
        raise ValueError("non-finite JSON number")
    return parsed


def _strict_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON object key")
        value[key] = item
    return value


def _decode_json(raw: bytes, error_message: str) -> Any:
    try:
        return json.loads(
            raw,
            object_pairs_hook=_strict_json_object,
            parse_constant=_reject_json_constant,
            parse_float=_strict_json_float,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise OperationalError(error_message) from error


def _encode_json(value: Any, error_message: str) -> bytes:
    try:
        return json.dumps(
            value,
            ensure_ascii=True,
            allow_nan=False,
            separators=(",", ":"),
        ).encode("ascii")
    except (TypeError, ValueError, UnicodeEncodeError) as error:
        raise OperationalError(error_message) from error


def _reject_token_bytes(raw: bytes, token: str) -> None:
    if token.encode("ascii") in raw:
        raise OperationalError("refusing secret-bearing data")


def _decode_response(body: bytes, token: str) -> Any:
    _reject_token_bytes(body, token)
    value = _decode_json(body, "Node-RED returned invalid JSON")
    if _contains_token(value, token):
        raise OperationalError("refusing secret-bearing data")
    normalized = _encode_json(value, "Node-RED returned invalid JSON")
    _reject_token_bytes(normalized, token)
    return value


def _emit_json(value: Any, token: str) -> None:
    if _contains_token(value, token):
        raise OperationalError("refusing secret-bearing data")
    encoded = _encode_json(value, "response is not valid JSON")
    _reject_token_bytes(encoded, token)
    if len(encoded) + 1 > MAX_OUTPUT_BYTES:
        raise OperationalError("response exceeds output limit")
    sys.stdout.buffer.write(encoded + b"\n")
    sys.stdout.buffer.flush()


def _read_input(token: str) -> tuple[dict[str, Any], bytes]:
    try:
        raw = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
    except OSError as error:
        raise OperationalError("cannot read input") from error
    if len(raw) > MAX_INPUT_BYTES:
        raise CallerError("input exceeds 1048576 bytes")
    try:
        _reject_token_bytes(raw, token)
        value = _decode_json(raw, "input must be one strict JSON object")
    except OperationalError as error:
        raise CallerError(str(error)) from error
    if not isinstance(value, dict):
        raise CallerError("input must be one strict JSON object")
    if _contains_token(value, token):
        raise CallerError("input rejected")
    try:
        encoded = _encode_json(value, "input must be one strict JSON object")
        _reject_token_bytes(encoded, token)
    except OperationalError as error:
        raise CallerError(str(error)) from error
    if len(encoded) > MAX_INPUT_BYTES:
        raise CallerError("input exceeds 1048576 bytes")
    return value, encoded


def _tls_context() -> ssl.SSLContext:
    try:
        metadata = CA_FILE.stat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != TRUSTED_UID
            or stat.S_IMODE(metadata.st_mode) & 0o022
        ):
            raise OperationalError("system CA bundle ownership invalid")
        return ssl.create_default_context(cafile=str(CA_FILE))
    except OperationalError:
        raise
    except (OSError, ssl.SSLError) as error:
        raise OperationalError("system CA bundle unavailable") from error


def _request(
    token: str,
    method: str,
    path: str,
    body: bytes | None = None,
) -> tuple[int, bytes]:
    headers = {
        "Accept": "application/json",
        "Authorization": f"Bearer {token}",
        "Host": TLS_SERVER_NAME,
    }
    if body is not None:
        headers["Content-Type"] = "application/json"

    connection = _LoopbackHTTPSConnection(
        TLS_SERVER_NAME,
        TLS_PORT,
        timeout=IO_TIMEOUT_SECONDS,
        context=_tls_context(),
    )
    try:
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        response_body = response.read(MAX_RESPONSE_BYTES + 1)
    except OperationalError:
        raise
    except (OSError, http.client.HTTPException) as error:
        raise OperationalError("Node-RED request failed") from error
    finally:
        connection.close()

    if len(response_body) > MAX_RESPONSE_BYTES:
        raise OperationalError("Node-RED response exceeds 8388608 bytes")
    return response.status, response_body


def _require_status(status: int, allowed: set[int]) -> None:
    if status not in allowed:
        raise OperationalError(f"Node-RED returned HTTP {status}")


def _validate_flow(value: Any, expected_id: str) -> dict[str, Any]:
    if (
        not isinstance(value, dict)
        or value.get("id") != expected_id
        or not _valid_flow_id(value.get("id"))
        or not isinstance(value.get("nodes"), list)
        or ("configs" in value and not isinstance(value["configs"], list))
    ):
        raise OperationalError("Node-RED returned an invalid flow")
    return value


def _list_flows(token: str) -> None:
    status, body = _request(token, "GET", "/flows")
    _require_status(status, {200})
    value = _decode_response(body, token)
    nodes = value.get("flows") if isinstance(value, dict) else value
    if not isinstance(nodes, list):
        raise OperationalError("Node-RED returned an invalid flow list")

    flows: list[dict[str, str]] = []
    seen_ids: set[str] = set()
    for node in nodes:
        if not isinstance(node, dict) or node.get("type") != "tab":
            continue
        flow_id = node.get("id")
        label = node.get("label", "")
        if (
            not _valid_flow_id(flow_id)
            or not isinstance(label, str)
            or flow_id in seen_ids
        ):
            raise OperationalError("Node-RED returned an invalid flow list")
        seen_ids.add(flow_id)
        flows.append({"id": flow_id, "label": label})
    _emit_json({"flows": flows}, token)


def _get_flow(token: str, flow_id: str) -> None:
    status, body = _request(token, "GET", f"/flow/{flow_id}")
    _require_status(status, {200})
    flow = _validate_flow(_decode_response(body, token), flow_id)
    _emit_json(flow, token)


def _put_flow(token: str, flow_id: str) -> None:
    value, body = _read_input(token)
    try:
        flow = _validate_flow(value, flow_id)
    except OperationalError as error:
        raise CallerError("input must match FLOW_ID and contain nodes") from error
    status, response_body = _request(token, "PUT", f"/flow/{flow_id}", body)
    _require_status(status, {200, 204})
    if response_body:
        _decode_response(response_body, token)
    _emit_json({"ok": True, "id": flow["id"]}, token)


def _parse_command(argv: list[str]) -> tuple[str, str | None]:
    if argv == ["flows", "get"]:
        return "flows-get", None
    if len(argv) == 3 and argv[0] == "flow" and argv[1] in {"get", "put"}:
        if not _valid_flow_id(argv[2]):
            raise CallerError("invalid FLOW_ID")
        return f"flow-{argv[1]}", argv[2]
    raise CallerError("invalid command")


def _write_error(message: str, *, usage: bool, token: str | None) -> None:
    output = f"node-red-admin: {message}\n" + (USAGE if usage else "")
    if token is None or token not in output:
        sys.stderr.write(output)
        sys.stderr.flush()


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    token: str | None = None
    exit_code = 1
    try:
        with _operation_deadline():
            try:
                command, flow_id = _parse_command(args)
                _disable_core_dumps()
                token = _read_token()
                if command == "flows-get":
                    _list_flows(token)
                elif command == "flow-get":
                    assert flow_id is not None
                    _get_flow(token, flow_id)
                else:
                    assert command == "flow-put"
                    assert flow_id is not None
                    _put_flow(token, flow_id)
            except DeadlineExceeded:
                raise
            except CallerError as error:
                exit_code = 2
                _write_error(str(error), usage=True, token=token)
                return exit_code
            except OperationalError as error:
                _write_error(str(error), usage=False, token=token)
                return exit_code
            except Exception:
                _write_error("unexpected failure", usage=False, token=token)
                return exit_code
            return 0
    except DeadlineExceeded:
        return exit_code
    except Exception:
        # A closed or otherwise unusable error stream must not outlive the
        # operation or replace its already selected exit meaning.
        return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
