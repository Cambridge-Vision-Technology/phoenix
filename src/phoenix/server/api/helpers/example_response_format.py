"""
A dataset example's own response format, overriding its prompt's for that example's runs.

A prompt version holds one response format, but some applications build the schema per
request: the fields being asked about differ from call to call. Evaluating such a call with
one shared schema tests a looser contract than production uses, so an example can carry its
own under :data:`EXAMPLE_RESPONSE_FORMAT_KEY` in its metadata.

Metadata rather than input because input fills template variables and a response format is
not prompt text. The key is namespaced because existing datasets, including ones built from
traces, may already hold a ``response_format`` of their own, and that must not start changing
how they run.

A malformed value raises rather than falling back to the prompt's format. A silent fallback
would produce a run that looks fine but was held to a different contract from the one the
example asked for.

Fork-owned; see .claude/rules/fork-ownership.md.
"""

from collections.abc import Mapping
from typing import Any, Optional

from pydantic import ValidationError

from phoenix.db.types.prompts import PromptResponseFormat, PromptResponseFormatRootModel

EXAMPLE_RESPONSE_FORMAT_KEY = "phoenix_response_format"
"""The metadata key holding an example's response format, in the REST API's prompt shape."""


def example_response_format(
    metadata: Optional[Mapping[str, Any]],
    prompt_response_format: Optional[PromptResponseFormat],
) -> Optional[PromptResponseFormat]:
    """
    The response format a run of this example should use.

    Args:
        metadata: The example's metadata.
        prompt_response_format: The response format of the prompt being run.

    Returns:
        The example's response format if it has one, otherwise the prompt's.

    Raises:
        ValueError: The example has a response format that is not valid.
    """
    value = (metadata or {}).get(EXAMPLE_RESPONSE_FORMAT_KEY)
    if value is None:
        return prompt_response_format
    try:
        return PromptResponseFormatRootModel.model_validate(value).root
    except ValidationError as error:
        problems = "; ".join(
            f"{'.'.join(str(part) for part in item['loc'])}: {item['msg']}"
            for item in error.errors()
        )
        raise ValueError(
            f"Invalid {EXAMPLE_RESPONSE_FORMAT_KEY} in dataset example metadata: {problems}"
        ) from error
