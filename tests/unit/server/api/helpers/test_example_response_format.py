"""
An example's response format overrides its prompt's, and a bad one fails instead of falling back.

A new test file on purpose (see .claude/rules/fork-ownership.md).
"""

from typing import Any

import pytest

from phoenix.db.types.prompts import (
    PromptResponseFormatJSONSchema,
    PromptResponseFormatJSONSchemaDefinition,
)
from phoenix.server.api.helpers.example_response_format import (
    EXAMPLE_RESPONSE_FORMAT_KEY,
    example_response_format,
)

PROMPT_FORMAT = PromptResponseFormatJSONSchema(
    type="json_schema",
    json_schema=PromptResponseFormatJSONSchemaDefinition(
        name="prompt",
        schema={"type": "object"},  # type: ignore[call-arg]
    ),
)
EXAMPLE_FORMAT: dict[str, Any] = {
    "type": "json_schema",
    "json_schema": {
        "name": "example",
        "schema": {"type": "object", "properties": {"a": {"type": "string"}}},
        "strict": True,
    },
}


class TestExampleResponseFormat:
    @pytest.mark.parametrize("metadata", [None, {}, {"other": 1}])
    def test_without_one_the_prompts_is_used(self, metadata: Any) -> None:
        assert example_response_format(metadata, PROMPT_FORMAT) is PROMPT_FORMAT

    def test_without_either_there_is_none(self) -> None:
        assert example_response_format({}, None) is None

    def test_the_examples_overrides_the_prompts(self) -> None:
        metadata = {EXAMPLE_RESPONSE_FORMAT_KEY: EXAMPLE_FORMAT}
        result = example_response_format(metadata, PROMPT_FORMAT)
        assert result is not None
        assert result.json_schema.name == "example"
        assert result.json_schema.strict is True
        assert result.json_schema.schema_ == EXAMPLE_FORMAT["json_schema"]["schema"]

    def test_it_applies_when_the_prompt_has_none(self) -> None:
        result = example_response_format({EXAMPLE_RESPONSE_FORMAT_KEY: EXAMPLE_FORMAT}, None)
        assert result is not None
        assert result.json_schema.name == "example"

    def test_an_unnamespaced_key_is_ignored(self) -> None:
        """A dataset built from traces may already hold a `response_format` of its own."""
        assert example_response_format({"response_format": "x"}, PROMPT_FORMAT) is PROMPT_FORMAT

    @pytest.mark.parametrize(
        "value",
        [
            "not an object",
            {},
            {"type": "something_else", "json_schema": {"name": "x"}},
            {"type": "json_schema"},
            {"type": "json_schema", "json_schema": {"schema": {}}},
        ],
    )
    def test_a_malformed_one_fails_rather_than_falling_back(self, value: Any) -> None:
        with pytest.raises(ValueError, match=EXAMPLE_RESPONSE_FORMAT_KEY):
            example_response_format({EXAMPLE_RESPONSE_FORMAT_KEY: value}, PROMPT_FORMAT)
