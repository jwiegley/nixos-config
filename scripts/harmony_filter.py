# /etc/litellm/harmony_filter.py
# Custom LiteLLM guardrail to strip Harmony format analysis channel from gpt-oss models

import re
import logging
from typing import Any, Optional, List

import litellm
from litellm._logging import verbose_proxy_logger
from litellm.caching.caching import DualCache
from litellm.integrations.custom_guardrail import CustomGuardrail
from litellm.proxy._types import UserAPIKeyAuth
from litellm.types.guardrails import GuardrailEventHooks

# Set up logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


class HarmonyResponseFilter(CustomGuardrail):
    """
    Guardrail that strips the <|channel|>analysis content from gpt-oss model responses,
    leaving only the <|channel|>final content.
    """

    def __init__(self, **kwargs):
        super().__init__(
            guardrail_name="harmony_filter",
            supported_event_hooks=[GuardrailEventHooks.post_call],
            event_hook=GuardrailEventHooks.post_call,
            default_on=True,  # Run on ALL requests by default
            **kwargs
        )
        logger.info("HarmonyResponseFilter guardrail initialized with default_on=True")

    def _should_filter(self, model: str) -> bool:
        """Check if this model uses Harmony format."""
        if not model:
            return False
        return "gpt-oss" in model.lower()

    def _strip_harmony_analysis(self, content: str) -> str:
        """Extract only the final channel content from Harmony format.

        Handles three cases:
        1. Both analysis and final channels present -> return only final content
        2. Only analysis channel present (truncated) -> return empty or truncated note
        3. Only final channel present -> return its content
        """
        if not content:
            return content

        # Look for <|channel|>final<|message|> marker
        final_marker = "<|channel|>final<|message|>"
        final_idx = content.find(final_marker)

        if final_idx != -1:
            logger.info("Found final channel marker, extracting final content")
            # Extract content after the final marker
            content = content[final_idx + len(final_marker):]
            # Strip trailing <|end|> or <|return|> markers
            content = re.sub(r'<\|(end|return)\|>.*', '', content, flags=re.DOTALL)
            return content.strip()

        # No final marker found - check if we have analysis channel (truncated response)
        analysis_marker = "<|channel|>analysis<|message|>"
        if analysis_marker in content:
            logger.info("Only analysis channel found (likely truncated), returning empty")
            # Response was truncated during analysis phase - no actual answer available
            # Return a message indicating the response was incomplete
            return "[Response truncated - model was still analyzing]"

        # No Harmony markers at all, return as-is
        return content.strip()

    async def async_post_call_success_hook(
        self,
        data: dict,
        user_api_key_dict: UserAPIKeyAuth,
        response,
    ):
        """
        Runs on response from LLM API call.
        Strips Harmony analysis channel from gpt-oss model responses.
        """
        try:
            model = data.get("model", "")
            logger.info(f"async_post_call_success_hook called for model: {model}")

            if self._should_filter(model):
                if isinstance(response, litellm.ModelResponse):
                    for choice in response.choices:
                        if isinstance(choice, litellm.Choices):
                            if (
                                choice.message.content
                                and isinstance(choice.message.content, str)
                                and "<|channel|>" in choice.message.content
                            ):
                                logger.info(f"Filtering Harmony content for {model}")
                                original_len = len(choice.message.content)
                                choice.message.content = self._strip_harmony_analysis(
                                    choice.message.content
                                )
                                logger.info(f"Filtered: {original_len} -> {len(choice.message.content)} chars")
        except Exception as e:
            logger.error(f"Error in HarmonyResponseFilter: {e}", exc_info=True)

        # Return the modified response
        return response


# Create the guardrail instance
harmony_filter = HarmonyResponseFilter()
