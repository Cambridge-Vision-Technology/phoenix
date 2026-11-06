"""
A dataset example's own response format reaches the provider, through a real server.

A new test file on purpose (see .claude/rules/fork-ownership.md).
"""

from __future__ import annotations

import json
import threading
from collections.abc import Iterator
from http.server import ThreadingHTTPServer
from secrets import token_hex
from typing import Any

import httpx2
import pytest

from tests.integration._helpers import _AppInfo, _parse_apollo_multipart_response

from .test_playground_media import SUBSCRIPTION, _VisionProvider

KEY = "phoenix_response_format"


def _format(name: str, field: str) -> dict[str, Any]:
    schema = {"type": "object", "properties": {field: {"type": "string"}}, "required": [field]}
    return {"type": "json_schema", "json_schema": {"name": name, "schema": schema, "strict": False}}


def _sent_schema_name(body: dict[str, Any]) -> str | None:
    """The response format's name, in either OpenAI API's request shape."""
    chat = (body.get("response_format") or {}).get("json_schema") or {}
    responses = (body.get("text") or {}).get("format") or {}
    name = chat.get("name") or responses.get("name")
    return str(name) if name else None


class _RecordingProvider(_VisionProvider):
    requests: list[dict[str, Any]] = []

    def do_POST(self) -> None:
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        type(self).requests.append(body)
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        answer = str(_sent_schema_name(body))
        if self.path.endswith("/responses"):
            self._stream_responses(body["model"], answer)
        else:
            self._stream_chat(body["model"], answer)


@pytest.fixture
def _provider_url() -> Iterator[str]:
    _RecordingProvider.requests = []
    server = ThreadingHTTPServer(("127.0.0.1", 0), _RecordingProvider)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{server.server_address[1]}/v1"
    server.shutdown()
    thread.join(timeout=5)


async def _run(
    client: httpx2.AsyncClient,
    metadata: list[dict[str, Any]],
    provider_url: str,
    api_type: str,
) -> tuple[list[dict[str, Any]], list[Any]]:
    """Runs one experiment and returns its stored runs and any stream errors."""
    response = await client.post(
        "/v1/datasets/upload?sync=true",
        json={
            "action": "create",
            "name": f"per-example-format-{token_hex(4)}",
            "inputs": [{"question": f"q{index}"} for index in range(len(metadata))],
            "outputs": [{} for _ in metadata],
            "metadata": metadata,
        },
    )
    response.raise_for_status()
    variables = {
        "input": {
            "promptVersion": {
                "templateFormat": "MUSTACHE",
                "template": {
                    "messages": [{"role": "USER", "content": [{"text": {"text": "{{question}}"}}]}]
                },
                "invocationParameters": {"openai": {}},
                "modelProvider": "OPENAI",
                "modelName": "gpt-test",
                "responseFormat": {
                    "type": "json_schema",
                    "jsonSchema": {"name": "from_prompt", "schema": {"type": "object"}},
                },
            },
            "connectionConfig": {"baseUrl": provider_url, "openaiApiType": api_type},
            "credentials": [{"envVarName": "OPENAI_API_KEY", "value": "test-key"}],
            "repetitions": 1,
            "datasetId": response.json()["data"]["dataset_id"],
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
    ) as stream:
        stream.raise_for_status()
        async for payload in _parse_apollo_multipart_response(stream):
            inner = payload.get("payload", payload) or {}
            errors.extend(inner.get("errors") or [])
            data = (inner.get("data") or {}).get("chatCompletionOverDataset")
            if not data:
                continue
            if data["__typename"] == "ChatCompletionSubscriptionError":
                errors.append(data["message"])
            elif data["__typename"] == "ChatCompletionSubscriptionExperiment":
                experiment_id = data["experiment"]["id"]
    assert experiment_id
    runs = await client.get(f"/v1/experiments/{experiment_id}/runs")
    runs.raise_for_status()
    return runs.json()["data"], errors


@pytest.mark.parametrize("api_type", ["CHAT_COMPLETIONS", "RESPONSES"])
async def test_each_example_is_held_to_its_own_response_format(
    _app: _AppInfo,
    _provider_url: str,
    api_type: str,
) -> None:
    metadata: list[dict[str, Any]] = [
        {KEY: _format("from_example_one", "a")},
        {KEY: _format("from_example_two", "b")},
        {"unrelated": "metadata"},
    ]
    async with httpx2.AsyncClient(base_url=_app.base_url, timeout=120) as client:
        runs, errors = await _run(client, metadata, _provider_url, api_type)

    assert not errors
    assert len(runs) == 3
    sent = sorted(str(_sent_schema_name(body)) for body in _RecordingProvider.requests)
    assert sent == ["from_example_one", "from_example_two", "from_prompt"]


async def test_a_malformed_response_format_fails_that_example_without_calling_the_model(
    _app: _AppInfo,
    _provider_url: str,
) -> None:
    metadata: list[dict[str, Any]] = [
        {KEY: {"type": "not_a_format"}},
        {KEY: _format("from_example", "a")},
    ]
    async with httpx2.AsyncClient(base_url=_app.base_url, timeout=120) as client:
        runs, errors = await _run(client, metadata, _provider_url, "CHAT_COMPLETIONS")

    assert any(KEY in str(error) for error in errors)
    assert sorted(str(_sent_schema_name(body)) for body in _RecordingProvider.requests) == [
        "from_example"
    ]
    failed = [run for run in runs if run["error"]]
    assert len(failed) == 1
    assert KEY in failed[0]["error"]
