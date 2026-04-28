# LiteLLM bug: Anthropic→Responses-API converter misorders `function_call` and assistant message text

**Title to use when filing:** Anthropic `/v1/messages` → OpenAI Responses API: `function_call` items emitted before assistant message text, causing 400 from upstream when the assistant turn has both text and `tool_use`

**Repository:** https://github.com/BerriAI/litellm
**Affected version:** 1.82.3 (Docker image `ghcr.io/berriai/litellm:main-stable`, observed 2026-04-27)
**Endpoint:** `POST /v1/messages` (Anthropic spec) routed to a model whose `litellm_params.model` is `openai/<name>` and whose upstream serves `/v1/responses` (OpenAI Responses API)

## Summary

When LiteLLM's Anthropic→Responses-API converter encounters an assistant message containing **both** a text block and a `tool_use` block in the same turn (e.g., the assistant says "I'll check the quote." and emits a `tool_use(get_quote)` in the same response), the converter emits the `function_call` item **before** the assistant `message` item in the Responses API `input` array. Downstream proxies that convert the Responses API back to Anthropic format (e.g., to call Anthropic itself) then see the conversation as

```
assistant(tool_use)
assistant(text)
user(tool_result)
```

instead of the original

```
assistant(text + tool_use)
user(tool_result)
```

The intervening `assistant(text)` item breaks Anthropic's "every `tool_use` block must have a corresponding `tool_result` block in the **next** message" rule, and Anthropic returns:

```
400 invalid_request_error
messages.1: `tool_use` ids were found without `tool_result` blocks immediately after: <ids>
```

LiteLLM surfaces this to the caller as a `BadRequestError`/`OpenAIException` wrapping the upstream payload.

## Root cause

`litellm/llms/anthropic/experimental_pass_through/responses_adapters/transformation.py`,
in `LiteLLMAnthropicToResponsesAPIAdapter.translate_messages_to_responses_input`, the assistant branch (around lines 137–178 in 1.82.3):

```python
elif isinstance(content, list):
    asst_parts: List[Dict[str, Any]] = []
    for block in content:
        if not isinstance(block, dict):
            continue
        btype = block.get("type")
        if btype == "text":
            asst_parts.append(
                {"type": "output_text", "text": block.get("text", "")}
            )
        elif btype == "tool_use":
            # tool_use becomes a top-level function_call item
            input_items.append(                                # ← emitted EAGERLY
                {
                    "type": "function_call",
                    "call_id": block.get("id", ""),
                    "name": block.get("name", ""),
                    "arguments": json.dumps(block.get("input", {})),
                }
            )
        elif btype == "thinking":
            ...
            asst_parts.append(...)
    if asst_parts:
        input_items.append(                                    # ← emitted LATE
            {
                "type": "message",
                "role": "assistant",
                "content": asst_parts,
            }
        )
```

For a single Anthropic assistant turn whose content is `[text, tool_use]`, the resulting `input_items` are:

```
[..., function_call, message(text)]
```

The semantically equivalent Responses-API ordering is `[..., message(text), function_call]` — the assistant's narration precedes the tool call it triggered.

The same shape exists in the **user** branch (around lines 87–132): `tool_result` blocks are appended to `input_items` immediately while user `text`/`image` blocks are accumulated in `user_parts` and appended afterward. We have not observed a 400 from this path because user messages with mixed `text` + `tool_result` content are rare in practice, but the misorder is symmetric and worth fixing in the same change.

## Reproduction

A minimal request that fails on a `hera/`-style upstream and succeeds on a direct `anthropic/` route:

```python
# /tmp/multitool-probe.py
import json
import urllib.error
import urllib.request

URL = "http://127.0.0.1:4000/v1/messages"
HEADERS = {
    "Authorization": "Bearer sk-...",
    "Content-Type": "application/json",
    "anthropic-version": "2023-06-01",
}

BODY = {
    "model": "<your-openai-routed-model>",     # fails
    # "model": "anthropic/claude-opus-4-7",   # this succeeds
    "max_tokens": 200,
    "tools": [
        {
            "name": "get_quote",
            "description": "Get a stock quote",
            "input_schema": {
                "type": "object",
                "properties": {"symbol": {"type": "string"}},
                "required": ["symbol"],
            },
        }
    ],
    "messages": [
        {"role": "user", "content": "Tell me about AAPL."},
        {
            "role": "assistant",
            "content": [
                {"type": "text", "text": "I'll check AAPL."},
                {
                    "type": "tool_use",
                    "id": "toolu_test_solo",
                    "name": "get_quote",
                    "input": {"symbol": "AAPL"},
                },
            ],
        },
        {
            "role": "user",
            "content": [
                {
                    "type": "tool_result",
                    "tool_use_id": "toolu_test_solo",
                    "content": [{"type": "text", "text": "AAPL price: $267"}],
                }
            ],
        },
    ],
}

req = urllib.request.Request(
    URL, data=json.dumps(BODY).encode(), headers=HEADERS, method="POST"
)
try:
    print(urllib.request.urlopen(req, timeout=60).read().decode()[:300])
except urllib.error.HTTPError as e:
    print(f"HTTP {e.code}\n{e.read().decode()[:500]}")
```

## Expected vs actual

**Expected (and what `anthropic/claude-opus-4-7` returns):** HTTP 200, model produces a synthesis turn building on the tool result.

**Actual (with `openai/`-routed model):**

```
HTTP 400
{
  "error": {
    "message": "litellm.BadRequestError: OpenAIException -
      {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",
      \"message\":\"messages.1: `tool_use` ids were found without `tool_result`
      blocks immediately after: toolu_test_solo. Each `tool_use` block must
      have a corresponding `tool_result` block in the next message.\"},
      \"request_id\":\"req_...\"}.
      Received Model Group=<model>",
    ...
  }
}
```

The same error fires when the assistant turn has multiple parallel `tool_use` blocks alongside text — three IDs instead of one in the rejection.

## Suggested fix

Append the assistant message **before** any of its `function_call` children. Either restructure the loop to gather `function_call` items into a local list and flush them after the assistant message, or pre-scan the content list once for the message item and once for the call items:

```python
elif isinstance(content, list):
    asst_parts: List[Dict[str, Any]] = []
    pending_function_calls: List[Dict[str, Any]] = []
    for block in content:
        if not isinstance(block, dict):
            continue
        btype = block.get("type")
        if btype == "text":
            asst_parts.append(
                {"type": "output_text", "text": block.get("text", "")}
            )
        elif btype == "tool_use":
            pending_function_calls.append(
                {
                    "type": "function_call",
                    "call_id": block.get("id", ""),
                    "name": block.get("name", ""),
                    "arguments": json.dumps(block.get("input", {})),
                }
            )
        elif btype == "thinking":
            thinking_text = block.get("thinking", "")
            if thinking_text:
                asst_parts.append(
                    {"type": "output_text", "text": thinking_text}
                )
    if asst_parts:
        input_items.append(
            {
                "type": "message",
                "role": "assistant",
                "content": asst_parts,
            }
        )
    input_items.extend(pending_function_calls)
```

The user branch has the same shape (`tool_result` appended eagerly while `user_parts` are accumulated); applying the equivalent fix there closes the symmetric edge case before it bites.

## Suggested regression test

A unit test against `LiteLLMAnthropicToResponsesAPIAdapter.translate_messages_to_responses_input` that feeds an assistant turn with `[text, tool_use]` content and asserts that `input_items` ends with `[message(role=assistant), function_call]` in that order — not the reverse. Mirror the test for the user-side `[text, tool_result]` case.

## Workaround (for users hitting this today)

Constrain the chat agent (via system prompt) to:

1. Call at most one tool per response, and
2. Emit the `tool_use` with **no** preamble text in the same response.

This keeps each tool-calling assistant message a single `tool_use` block with no text, so the converter's misorder never produces a misplaced `assistant(text)` between `function_call` and `function_call_output`. We are running with this workaround in production while waiting for the upstream fix.
