"""
Inline media on traces Phoenix records itself, moved to the media store before they are saved.

The playground and the experiment runner build ``models.Trace`` objects directly rather
than going through span ingestion, so :class:`MediaOffloadingBulkInserter` never sees
them. Each run's ``input.value`` holds the whole provider request, so without this every
run stores another full copy of every image it sent, on top of the one in the media store.

The rewrite, the store handling and the ``PHOENIX_SPAN_MEDIA_OFFLOAD`` switch are
:class:`SpanMediaOffloader`'s, so both paths behave the same. In particular, whatever
cannot be stored stays inline.

Called before the trace's own transaction opens: uploads must not hold a connection, and
the runner persists a run under a short deadline.
"""

import logging
from collections.abc import Iterable
from dataclasses import dataclass
from typing import Any, Mapping, cast

from phoenix.db import models
from phoenix.server.api.helpers.span_media import SpanMediaOffloader, get_env_span_media_offload
from phoenix.server.types import DbSessionFactory
from phoenix.trace.schemas import Span

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class _Context:
    span_id: str


@dataclass(frozen=True)
class _OffloadableSpan:
    """The two fields of an ingested span that :class:`SpanMediaOffloader` reads."""

    context: _Context
    attributes: Mapping[str, Any]


async def offload_db_trace_media(db: DbSessionFactory, traces: Iterable[models.Trace]) -> None:
    """
    Replace inline media in the spans of unsaved traces with stored references.

    Never raises: a trace that cannot be rewritten is saved with its media inline, because
    losing a run's trace would be worse than storing it at full size.

    Args:
        db: Session factory for the short transaction recording stored media.
        traces: The traces about to be saved. Their spans are updated in place.
    """
    if not get_env_span_media_offload():
        return
    offloader = SpanMediaOffloader(db)
    for trace in traces:
        for db_span in trace.spans:
            try:
                await _offload_span(offloader, db_span)
            except Exception:
                logger.exception("Failed to offload media from a recorded span; keeping it inline")


async def _offload_span(offloader: SpanMediaOffloader, db_span: models.Span) -> None:
    span = cast(
        Span,
        _OffloadableSpan(context=_Context(span_id=db_span.span_id), attributes=db_span.attributes),
    )
    candidates = offloader.candidates(span)
    if candidates:
        db_span.attributes = dict((await offloader.offload(span, candidates)).attributes)
