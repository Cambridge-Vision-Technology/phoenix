"""
Traces Phoenix records itself keep references to page images, not the images.

The playground and the experiment runner build ``models.Trace`` objects directly instead
of going through span ingestion, so ``MediaOffloadingBulkInserter`` never sees them, and
each run would otherwise store a full copy of every image it sent.

A new test file on purpose (see .claude/rules/fork-ownership.md).
"""

import base64
import hashlib
import json
from typing import Any

import pytest
from sqlalchemy import select

from phoenix.db import models
from phoenix.server.api.helpers import span_media
from phoenix.server.api.helpers.db_trace_media import offload_db_trace_media
from phoenix.server.types import DbSessionFactory
from phoenix.trace.attributes import get_attribute_value
from tests.unit.media_store_fixtures import isolated_media_store  # noqa: F401

PNG = b"\x89PNG\r\n\x1a\n" + bytes(range(256)) * 200
PNG_B64 = base64.b64encode(PNG).decode()
SHA256 = hashlib.sha256(PNG).hexdigest()
REFERENCE = f"phoenix://media/{SHA256}"


def openai_request() -> str:
    return json.dumps(
        {
            "input": [
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "input_image",
                            "detail": "auto",
                            "image_url": f"data:image/png;base64,{PNG_B64}",
                        },
                        {"type": "input_text", "text": "Transcribe this page."},
                    ],
                }
            ]
        }
    )


def gemini_request() -> str:
    part = {"inline_data": {"mime_type": "image/png", "data": PNG_B64}}
    return json.dumps({"contents": [{"role": "user", "parts": [part, {"text": "Transcribe."}]}]})


def trace_with_input(input_value: str) -> models.Trace:
    span = models.Span(attributes={"input": {"value": input_value}, "llm": {"model_name": "m"}})
    return models.Trace(spans=[span])


def stored_input(trace: models.Trace) -> Any:
    return get_attribute_value(trace.spans[0].attributes, "input.value")


@pytest.fixture
def offload(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv(span_media.ENV_PHOENIX_SPAN_MEDIA_OFFLOAD, "true")


@pytest.mark.usefixtures("isolated_media_store")
class TestOffloadDbTraceMedia:
    @pytest.mark.usefixtures("offload")
    @pytest.mark.parametrize("request_body", [openai_request(), gemini_request()])
    async def test_image_bytes_become_a_reference(
        self, db: DbSessionFactory, request_body: str
    ) -> None:
        trace = trace_with_input(request_body)
        await offload_db_trace_media(db, [trace])

        value = stored_input(trace)
        assert PNG_B64 not in value
        assert REFERENCE in value
        assert "Transcribe" in value
        assert get_attribute_value(trace.spans[0].attributes, "llm.model_name") == "m"

    @pytest.mark.usefixtures("offload")
    async def test_stored_image_is_recorded_and_kept_from_the_sweeper(
        self, db: DbSessionFactory
    ) -> None:
        await offload_db_trace_media(db, [trace_with_input(openai_request())])

        async with db() as session:
            row = await session.scalar(select(models.MediaFile).filter_by(sha256=SHA256))
        assert row is not None
        assert row.referenced_at is not None

    @pytest.mark.usefixtures("offload")
    async def test_a_store_failure_keeps_the_image_inline(
        self, db: DbSessionFactory, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        async def failing_put(*_: Any, **__: Any) -> Any:
            raise OSError("store is down")

        monkeypatch.setattr(span_media, "put_media", failing_put)
        request_body = openai_request()
        trace = trace_with_input(request_body)

        await offload_db_trace_media(db, [trace])

        assert stored_input(trace) == request_body

    async def test_nothing_changes_when_offloading_is_off(self, db: DbSessionFactory) -> None:
        request_body = openai_request()
        trace = trace_with_input(request_body)

        await offload_db_trace_media(db, [trace])

        assert stored_input(trace) == request_body

    @pytest.mark.usefixtures("offload")
    async def test_every_span_in_every_trace_is_rewritten(self, db: DbSessionFactory) -> None:
        traces = [trace_with_input(openai_request()), trace_with_input(gemini_request())]

        await offload_db_trace_media(db, traces)

        assert all(PNG_B64 not in stored_input(trace) for trace in traces)
