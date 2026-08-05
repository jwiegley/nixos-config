"""The memory write-filter blocks probe traffic and spares real messages.

This pins BEHAVIOUR, not structure. It does not care how many patterns exist,
what they look like, or what order they are in -- it reads whatever
`write_filter.patterns` currently holds in hermes-vm.nix and asks only the two
questions the operator actually asked for:

  1. do these probe shapes stay out of the memory store, and
  2. do these ordinary messages still get remembered?

So editing, reordering, merging or replacing the patterns by hand is fine and
will not fail this suite, as long as those two answers stay the same. If a new
probe shape shows up in the store, add the string to DROP and widen a pattern
until it passes.

Why it exists: the plugin compiles each pattern in a try/except and, on
re.error, LOGS AND DROPS IT (qdrant.py _write_filter_rules). A typo therefore
disables a rule silently -- the config still looks right, the build still
succeeds, and the only evidence is a debug line inside the VM. Here a bad
regex fails loudly instead.

The matcher below is a deliberate mirror of the deployed one (qdrant.py
_is_ignored): re.IGNORECASE on every pattern, `search` against the raw text.
If that plugin changes, this mirror has to change with it.
"""
import pathlib
import re

import pytest

NIX = pathlib.Path(__file__).resolve().parents[1] / "hermes-vm.nix"


def _scan(text, start):
    """Return the bracketed region beginning at `start`, ignoring brackets that
    appear inside Nix strings or comments."""
    depth = 0
    i = start
    while i < len(text):
        c = text[i]
        if c == '"':
            i += 1
            while i < len(text) and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
        elif c == "#":
            while i < len(text) and text[i] != "\n":
                i += 1
        elif c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
            if depth == 0:
                return text[start : i + 1]
        i += 1
    raise AssertionError("unterminated patterns list in hermes-vm.nix")


def _literals(block):
    """Every Nix string literal in `block`, unescaped. Comments are skipped --
    the pattern list has commentary containing quoted examples, and those are
    not patterns."""
    out = []
    i = 0
    while i < len(block):
        c = block[i]
        if c == "#":
            while i < len(block) and block[i] != "\n":
                i += 1
        elif c == '"':
            i += 1
            buf = []
            while i < len(block) and block[i] != '"':
                if block[i] == "\\":
                    buf.append({"n": "\n", "t": "\t", "r": "\r"}.get(block[i + 1], block[i + 1]))
                    i += 2
                else:
                    buf.append(block[i])
                    i += 1
            out.append("".join(buf))
            i += 1
        else:
            i += 1
    return out


def _patterns():
    text = NIX.read_text()
    wf = text.index("write_filter")
    start = text.index("patterns = [", wf) + len("patterns = ")
    return _literals(_scan(text, start))


RAW = _patterns()
# Compile the way the plugin does. Unlike the plugin, a bad regex is fatal here.
COMPILED = [re.compile(p, re.IGNORECASE) for p in RAW]


def blocked(text):
    return any(p.search(text) for p in COMPILED)


# Probe traffic. Every one of these was seen in the wild or is a near neighbour
# of something that was; the HERMES_OK family reached the store on 2026-08-05.
DROP = [
    "Reply with exactly HERMES_OK",
    "Reply with exactly: HERMES_OK",
    "Reply only with HERMES_OK",
    "Reply with exactly: HERMES_PI_OK",
    "HERMES_OK",
    "HERMES_OK\n",
    "  HERMES_OK  ",
    "HERMES_PI_OK",
    "Reply with the single word ACK and nothing else.",
    "Reply with the single word ROVER and nothing else. /no_think",
    "ACK",
    "ACK.",
    "ROVER",
    "OK",
    "Reply with exactly HERMES_OK\n",
    "REPLY WITH EXACTLY HERMES_OK",
    "check this [nomem]",
    "ignore [no-memory] this",
]

# Real messages. These must survive -- a filter that eats them is worse than no
# filter. The first two matter most: they open with the same two words as a
# probe and are saved only by the absence of an ALL-CAPS token.
KEEP = [
    "Reply with your thoughts on the pool heater",
    "Reply with a summary of today's alerts when you get a chance",
    "Reply with the details you found about the Nest eco setpoint bug",
    "What did the backup do last night?",
    "Can you reply with the current pool temperature?",
    "The washer finished. Should I move the laundry?",
    "ok sounds good",
    "Ok",
    "Sure thing",
    "HERMES_OK is the token the probe uses -- please remember that for later",
    "I got an ACK from the device but nothing happened afterward",
]


def test_patterns_were_found():
    """Guard against the extractor silently returning nothing, which would make
    every DROP case below fail and every KEEP case vacuously pass."""
    assert RAW, f"no write_filter patterns extracted from {NIX}"


@pytest.mark.parametrize("text", DROP)
def test_probe_traffic_is_blocked(text):
    assert blocked(text), f"probe traffic would be stored: {text!r}"


@pytest.mark.parametrize("text", KEEP)
def test_real_messages_are_kept(text):
    assert not blocked(text), f"real message would be dropped: {text!r}"


def test_filter_is_exchange_scoped_in_the_plugin():
    """The prompt and its one-word reply arrive as one exchange, and the plugin
    condemns both when either matches. Assert the halves independently anyway:
    relying on the pairing would leave a bare token unfiltered if a probe ever
    sends one on its own -- which is exactly how HERMES_OK got in."""
    assert blocked("Reply with exactly HERMES_OK")
    assert blocked("HERMES_OK")
