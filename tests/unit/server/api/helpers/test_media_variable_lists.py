"""
A media variable can hold a list, so one prompt serves inputs of any length.

A new test file on purpose (see .claude/rules/fork-ownership.md).
"""

from typing import Any

import pytest

from phoenix.server.api.exceptions import BadRequest
from phoenix.server.api.helpers.message_media import (
    MediaContentBlock,
    TextContentBlock,
    format_message_content,
)
from phoenix.utilities.template_formatters import MustacheTemplateFormatter

ONE = "phoenix://media/" + "a" * 64
TWO = "phoenix://media/" + "b" * 64
THREE = "phoenix://media/" + "c" * 64


def _format(value: Any, *, kind: str = "image") -> list[Any]:
    content: list[Any] = [
        TextContentBlock(type="text", text="before"),
        MediaContentBlock(type="media", kind=kind, variable="pages"),  # type: ignore[typeddict-item]
        TextContentBlock(type="text", text="after {{word}}"),
    ]
    result = format_message_content(
        content,
        template_formatter=MustacheTemplateFormatter(),
        template_variables={"pages": value, "word": "end"},
    )
    assert isinstance(result, list)
    return result


def _urls(blocks: list[Any]) -> list[str]:
    return [block["url"] for block in blocks if block["type"] == "media"]


class TestMediaVariableLists:
    def test_each_item_becomes_a_block_in_order(self) -> None:
        assert _urls(_format([TWO, ONE, THREE])) == [TWO, ONE, THREE]

    def test_items_stay_at_the_variables_position(self) -> None:
        blocks = _format([ONE, TWO])
        assert [block["type"] for block in blocks] == ["text", "media", "media", "text"]
        assert blocks[0]["text"] == "before"
        assert blocks[3]["text"] == "after end"

    def test_the_same_image_can_repeat(self) -> None:
        assert _urls(_format([ONE, ONE])) == [ONE, ONE]

    def test_a_long_list_keeps_every_item(self) -> None:
        pages = [f"phoenix://media/{index:064x}" for index in range(250)]
        assert _urls(_format(pages)) == pages

    def test_a_single_value_still_works(self) -> None:
        assert _urls(_format(ONE)) == [ONE]

    def test_a_file_list_keeps_its_kind(self) -> None:
        blocks = _format([ONE, TWO], kind="file")
        assert [block["kind"] for block in blocks if block["type"] == "media"] == ["file", "file"]

    @pytest.mark.parametrize("value", [None, "", "  ", [], [None], ["", "  "]])
    def test_nothing_supplied_drops_the_slot(self, value: Any) -> None:
        assert _urls(_format(value)) == []

    def test_empty_items_are_skipped(self) -> None:
        assert _urls(_format([ONE, None, "", TWO])) == [ONE, TWO]

    @pytest.mark.parametrize("value", [7, {"url": ONE}, [ONE, 7], [ONE, {"url": TWO}], [[ONE]]])
    def test_anything_else_is_an_error_not_a_silent_drop(self, value: Any) -> None:
        with pytest.raises(BadRequest, match="pages"):
            _format(value)
