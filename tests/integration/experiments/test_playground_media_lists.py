"""
One prompt runs over examples with different numbers of images, through a real server.

The provider decodes every image it receives and answers with their words in order, so a run's
output is only right if each page arrived intact, in order, and none was dropped.

A new test file on purpose (see .claude/rules/fork-ownership.md).
"""

from __future__ import annotations

import base64
import json
import threading
from collections.abc import Iterator
from http.server import ThreadingHTTPServer
from secrets import token_hex
from typing import Any

import httpx2
import pytest

from tests.integration._helpers import _AppInfo, _parse_apollo_multipart_response

from .test_playground_media import SUBSCRIPTION, _png_with_word, _read_word, _VisionProvider


def _words_from(body: dict[str, Any]) -> str:
    content = [m for m in body["input"] if m.get("role") == "user"][-1]["content"]
    if isinstance(content, str):
        return "NO-IMAGES"
    words = []
    for part in content:
        if part["type"] == "input_image":
            words.append(_read_word(base64.b64decode(part["image_url"].split(",", 1)[1])))
    return " ".join(words)


class _ReadsEveryPage(_VisionProvider):
    def do_POST(self) -> None:
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        self._stream_responses(body["model"], _words_from(body))


@pytest.fixture
def _provider_url() -> Iterator[str]:
    server = ThreadingHTTPServer(("127.0.0.1", 0), _ReadsEveryPage)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{server.server_address[1]}/v1"
    server.shutdown()
    thread.join(timeout=5)


async def test_one_prompt_reads_every_page_of_documents_of_any_length(
    _app: _AppInfo,
    _provider_url: str,
) -> None:
    documents = [[f"PAGE{n}A{i}" for i in range(n)] for n in (1, 3, 40)]
    documents.append([])
    async with httpx2.AsyncClient(base_url=_app.base_url, timeout=180) as client:
        inputs = []
        for number, words in enumerate(documents):
            pages = []
            for word in words:
                uploaded = await client.post(
                    "/v1/media",
                    files={"file": (f"{word}.png", _png_with_word(word), "image/png")},
                )
                uploaded.raise_for_status()
                pages.append(f"phoenix://media/{uploaded.json()['data']['sha256']}")
            inputs.append({"pages": pages, "document": number})
        created = await client.post(
            "/v1/datasets/upload?sync=true",
            json={
                "action": "create",
                "name": f"read-every-page-{token_hex(4)}",
                "inputs": inputs,
                "outputs": [{"words": " ".join(words)} for words in documents],
                "metadata": [{} for _ in inputs],
            },
        )
        created.raise_for_status()
        dataset_id = created.json()["data"]["dataset_id"]
        examples = await client.get(f"/v1/datasets/{dataset_id}/examples")
        examples.raise_for_status()
        expected = {
            example["id"]: example["output"]["words"]
            for example in examples.json()["data"]["examples"]
        }
        variables = {
            "input": {
                "promptVersion": {
                    "templateFormat": "MUSTACHE",
                    "template": {
                        "messages": [
                            {
                                "role": "USER",
                                "content": [
                                    {"imageVariable": {"variable": "pages"}},
                                    {"text": {"text": "Read every page."}},
                                ],
                            }
                        ]
                    },
                    "invocationParameters": {"openai": {}},
                    "modelProvider": "OPENAI",
                    "modelName": "gpt-test",
                },
                "connectionConfig": {"baseUrl": _provider_url, "openaiApiType": "RESPONSES"},
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
        assert not errors
        assert experiment_id
        response = await client.get(f"/v1/experiments/{experiment_id}/runs")
        response.raise_for_status()
        runs = response.json()["data"]

    assert {run["dataset_example_id"] for run in runs} == set(expected)
    for run in runs:
        want = expected[run["dataset_example_id"]]
        stored = json.dumps(run["output"])
        assert (want or "NO-IMAGES") in stored
