"""
A dataset of images, a prompt with an image variable, and an experiment, through the real server.

The provider here decodes each PNG it receives and answers with the word written into that PNG. A
run's output is therefore only right if the exact image for that example reached the provider, so
this fails if an image is dropped, corrupted, or attached to the wrong example.

A new test file on purpose (see .claude/rules/fork-ownership.md).
"""

from __future__ import annotations

import base64
import json
import struct
import threading
import zlib
from collections.abc import Iterator
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from secrets import token_hex
from typing import Any

import httpx2
import pytest

from tests.integration._helpers import _AppInfo, _parse_apollo_multipart_response

SUBSCRIPTION = """
subscription Run($input: ChatCompletionOverDatasetInput!) {
    chatCompletionOverDataset(input: $input) {
        __typename
        ... on ChatCompletionSubscriptionExperiment { experiment { id } }
        ... on ChatCompletionSubscriptionError { message }
    }
}
"""
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
WORD_KEY = b"word\x00"
WORDS = ("HERON", "LANTERN")
PROMPT_TEXT = "Read the word in this image."
NO_IMAGE = "NO-IMAGE-RECEIVED"


def _chunk(tag: bytes, data: bytes) -> bytes:
    crc = struct.pack(">I", zlib.crc32(tag + data))
    return struct.pack(">I", len(data)) + tag + data + crc


def _png_with_word(word: str) -> bytes:
    """A valid one-pixel PNG with the word written into a text chunk."""
    header = struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)
    return (
        PNG_SIGNATURE
        + _chunk(b"IHDR", header)
        + _chunk(b"tEXt", WORD_KEY + word.encode())
        + _chunk(b"IDAT", zlib.compress(b"\x00\xff\xff\xff"))
        + _chunk(b"IEND", b"")
    )


def _read_word(png: bytes) -> str:
    """The inverse of :func:`_png_with_word`. Raises if the bytes are not intact."""
    assert png.startswith(PNG_SIGNATURE)
    position = len(PNG_SIGNATURE)
    while position < len(png):
        (length,) = struct.unpack(">I", png[position : position + 4])
        tag = png[position + 4 : position + 8]
        data = png[position + 8 : position + 8 + length]
        (crc,) = struct.unpack(">I", png[position + 8 + length : position + 12 + length])
        assert crc == zlib.crc32(tag + data)
        if tag == b"tEXt" and data.startswith(WORD_KEY):
            return data[len(WORD_KEY) :].decode()
        position += 12 + length
    raise AssertionError("no word in the image")


def _answer_from(body: dict[str, Any]) -> str:
    """Reads the image in the last user turn, if it comes first and the prompt text follows."""
    messages = body.get("messages") or body.get("input") or []
    content = [m for m in messages if m.get("role") == "user"][-1]["content"]
    if isinstance(content, str) or len(content) != 2 or content[1].get("text") != PROMPT_TEXT:
        return NO_IMAGE
    image = content[0].get("image_url")
    url = image["url"] if isinstance(image, dict) else image
    if not url or not url.startswith("data:image/png;base64,"):
        return NO_IMAGE
    return _read_word(base64.b64decode(url.split(",", 1)[1]))


class _VisionProvider(BaseHTTPRequestHandler):
    """Speaks just enough of OpenAI's streaming Chat Completions and Responses APIs."""

    def log_message(self, format: str, *args: Any) -> None:
        pass

    def do_POST(self) -> None:
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        answer = _answer_from(body)
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        if self.path.endswith("/responses"):
            self._stream_responses(body["model"], answer)
        else:
            self._stream_chat(body["model"], answer)

    def _send(self, event: dict[str, Any]) -> None:
        prefix = f"event: {event['type']}\n" if "type" in event else ""
        self.wfile.write(f"{prefix}data: {json.dumps(event)}\n\n".encode())

    def _stream_chat(self, model: str, answer: str) -> None:
        chunk = {"id": "c", "object": "chat.completion.chunk", "created": 1, "model": model}
        delta = {"role": "assistant", "content": answer}
        self._send({**chunk, "choices": [{"index": 0, "delta": delta, "finish_reason": None}]})
        self._send({**chunk, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
        self.wfile.write(b"data: [DONE]\n\n")

    def _stream_responses(self, model: str, answer: str) -> None:
        text = {"type": "output_text", "text": answer, "annotations": []}
        item = {
            "id": "m",
            "type": "message",
            "role": "assistant",
            "status": "completed",
            "content": [text],
        }
        response = {
            "id": "r",
            "object": "response",
            "created_at": 1,
            "status": "completed",
            "model": model,
            "output": [item],
            "parallel_tool_calls": False,
            "tool_choice": "auto",
            "tools": [],
        }
        position = {"item_id": "m", "output_index": 0, "content_index": 0}
        events: list[dict[str, Any]] = [
            {
                "type": "response.created",
                "response": {**response, "status": "in_progress", "output": []},
            },
            {
                "type": "response.output_item.added",
                "output_index": 0,
                "item": {**item, "status": "in_progress", "content": []},
            },
            {
                "type": "response.content_part.added",
                **position,
                "part": {**text, "text": ""},
            },
            {"type": "response.output_text.delta", **position, "delta": answer, "logprobs": []},
            {"type": "response.output_text.done", **position, "text": answer, "logprobs": []},
            {"type": "response.content_part.done", **position, "part": text},
            {"type": "response.output_item.done", "output_index": 0, "item": item},
            {"type": "response.completed", "response": response},
        ]
        for number, event in enumerate(events):
            self._send({**event, "sequence_number": number})


@pytest.fixture
def _provider_url() -> Iterator[str]:
    server = ThreadingHTTPServer(("127.0.0.1", 0), _VisionProvider)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{server.server_address[1]}/v1"
    server.shutdown()
    thread.join(timeout=5)


async def _publish_prompt(client: httpx2.AsyncClient) -> dict[str, Any]:
    name = f"read-the-word-{token_hex(4)}"
    content = [
        {"type": "image", "image": {"variable": "page"}},
        {"type": "text", "text": PROMPT_TEXT},
    ]
    response = await client.post(
        "/v1/prompts",
        json={
            "prompt": {"name": name},
            "version": {
                "model_provider": "OPENAI",
                "model_name": "gpt-test",
                "template_type": "CHAT",
                "template_format": "MUSTACHE",
                "invocation_parameters": {"type": "openai", "openai": {}},
                "template": {"type": "chat", "messages": [{"role": "user", "content": content}]},
            },
        },
    )
    response.raise_for_status()
    latest = await client.get(f"/v1/prompts/{name}/latest")
    latest.raise_for_status()
    version: dict[str, Any] = latest.json()["data"]
    return version


async def _publish_dataset(client: httpx2.AsyncClient) -> tuple[str, dict[str, str]]:
    """Returns the dataset's id, and each example's expected word by example id."""
    inputs = []
    for word in WORDS:
        response = await client.post(
            "/v1/media", files={"file": (f"{word}.png", _png_with_word(word), "image/png")}
        )
        response.raise_for_status()
        inputs.append(
            {"page": f"phoenix://media/{response.json()['data']['sha256']}", "word": word}
        )
    response = await client.post(
        "/v1/datasets/upload?sync=true",
        json={
            "action": "create",
            "name": f"read-the-word-{token_hex(4)}",
            "inputs": inputs,
            "outputs": [{"word": item["word"]} for item in inputs],
            "metadata": [{} for _ in inputs],
        },
    )
    response.raise_for_status()
    dataset_id = response.json()["data"]["dataset_id"]
    examples = await client.get(f"/v1/datasets/{dataset_id}/examples")
    examples.raise_for_status()
    expected = {
        example["id"]: example["output"]["word"] for example in examples.json()["data"]["examples"]
    }
    return dataset_id, expected


def _subscription_part(part: dict[str, Any]) -> dict[str, Any]:
    if part["type"] == "image":
        return {"imageVariable": {"variable": part["image"]["variable"]}}
    return {"text": {"text": part["text"]}}


async def _run_experiment(
    client: httpx2.AsyncClient,
    prompt: dict[str, Any],
    dataset_id: str,
    provider_url: str,
    api_type: str,
) -> str:
    messages = [
        {"role": "USER", "content": [_subscription_part(part) for part in message["content"]]}
        for message in prompt["template"]["messages"]
    ]
    variables = {
        "input": {
            "promptVersion": {
                "templateFormat": "MUSTACHE",
                "template": {"messages": messages},
                "invocationParameters": {"openai": {}},
                "modelProvider": "OPENAI",
                "modelName": prompt["model_name"],
            },
            "connectionConfig": {"baseUrl": provider_url, "openaiApiType": api_type},
            "credentials": [{"envVarName": "OPENAI_API_KEY", "value": "test-key"}],
            "repetitions": 1,
            "datasetId": dataset_id,
            "evaluators": [],
            "streamModelOutput": True,
        }
    }
    experiment_id: str | None = None
    errors: list[Any] = []
    async with client.stream(
        "POST",
        "/graphql",
        json={"query": SUBSCRIPTION, "variables": variables},
        headers={
            "Accept": "multipart/mixed;boundary=graphql;subscriptionSpec=1.0,application/json",
        },
    ) as response:
        response.raise_for_status()
        async for payload in _parse_apollo_multipart_response(response):
            inner = payload.get("payload", payload) or {}
            errors.extend(inner.get("errors") or [])
            data = (inner.get("data") or {}).get("chatCompletionOverDataset")
            if not data:
                continue
            if data["__typename"] == "ChatCompletionSubscriptionError":
                errors.append(data["message"])
            elif data["__typename"] == "ChatCompletionSubscriptionExperiment":
                experiment_id = data["experiment"]["id"]
    assert not errors
    assert experiment_id
    return experiment_id


@pytest.mark.parametrize("api_type", ["CHAT_COMPLETIONS", "RESPONSES"])
async def test_an_experiment_reads_the_image_of_each_example(
    _app: _AppInfo,
    _provider_url: str,
    api_type: str,
) -> None:
    async with httpx2.AsyncClient(base_url=_app.base_url, timeout=120) as client:
        prompt = await _publish_prompt(client)
        dataset_id, expected = await _publish_dataset(client)

        experiment_id = await _run_experiment(client, prompt, dataset_id, _provider_url, api_type)

        response = await client.get(f"/v1/experiments/{experiment_id}/runs")
        response.raise_for_status()
        runs = response.json()["data"]

    assert {run["dataset_example_id"] for run in runs} == set(expected)
    for run in runs:
        assert run["error"] is None
        word = expected[run["dataset_example_id"]]
        other = next(item for item in WORDS if item != word)
        stored = json.dumps(run["output"])
        assert word in stored
        assert other not in stored
        assert NO_IMAGE not in stored
