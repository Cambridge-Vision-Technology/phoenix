"""
The Google provider uses Vertex AI when configured, and never falls back to an API key.

A new test file on purpose (see .claude/rules/fork-ownership.md).
"""

from typing import Any

import pytest
from pydantic import SecretStr

from phoenix.db.types.model_provider import ModelProvider
from phoenix.server.api.helpers import playground_clients
from phoenix.server.api.helpers.google_vertex import (
    ENV_PHOENIX_GOOGLE_VERTEX_LOCATION,
    ENV_PHOENIX_GOOGLE_VERTEX_PROJECT,
    vertex_client_kwargs,
)
from phoenix.server.api.input_types.GenerativeCredentialInput import GenerativeCredentialInput
from phoenix.server.types import DbSessionFactory


class TestVertexClientKwargs:
    def test_unset_means_the_gemini_api(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.delenv(ENV_PHOENIX_GOOGLE_VERTEX_PROJECT, raising=False)
        assert vertex_client_kwargs() is None

    def test_blank_project_means_the_gemini_api(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv(ENV_PHOENIX_GOOGLE_VERTEX_PROJECT, "  ")
        assert vertex_client_kwargs() is None

    def test_location_defaults_to_global(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv(ENV_PHOENIX_GOOGLE_VERTEX_PROJECT, "p")
        monkeypatch.delenv(ENV_PHOENIX_GOOGLE_VERTEX_LOCATION, raising=False)
        assert vertex_client_kwargs() == {"vertexai": True, "project": "p", "location": "global"}

    def test_explicit_location(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv(ENV_PHOENIX_GOOGLE_VERTEX_PROJECT, "p")
        monkeypatch.setenv(ENV_PHOENIX_GOOGLE_VERTEX_LOCATION, "us-central1")
        assert vertex_client_kwargs() == {
            "vertexai": True,
            "project": "p",
            "location": "us-central1",
        }


class _RecordingClient:
    """Stands in for ``google.genai.Client``, recording how it was constructed."""

    calls: list[dict[str, Any]] = []

    def __init__(self, **kwargs: Any) -> None:
        type(self).calls.append(kwargs)
        self.aio = self

    async def __aenter__(self) -> "_RecordingClient":
        return self

    async def __aexit__(self, *_: Any) -> None:
        return None


@pytest.fixture
def recording_client(monkeypatch: pytest.MonkeyPatch) -> type[_RecordingClient]:
    _RecordingClient.calls = []
    monkeypatch.setattr("google.genai.client.Client", _RecordingClient)
    return _RecordingClient


class TestGooglePlaygroundClient:
    async def _opened_client_kwargs(
        self,
        db: DbSessionFactory,
        recording: type[_RecordingClient],
        credentials: list[GenerativeCredentialInput],
    ) -> dict[str, Any]:
        async with db() as session:
            client = await playground_clients.get_playground_client(
                model_provider=ModelProvider.GOOGLE,
                model_name="gemini-3-flash-preview",
                session=session,
                decrypt=lambda value: value,
                credentials=credentials,
            )
        async with client._client_factory():
            pass
        return recording.calls[-1]

    async def test_vertex_needs_no_api_key(
        self,
        db: DbSessionFactory,
        monkeypatch: pytest.MonkeyPatch,
        recording_client: type[_RecordingClient],
    ) -> None:
        monkeypatch.setenv(ENV_PHOENIX_GOOGLE_VERTEX_PROJECT, "p")
        monkeypatch.delenv("GEMINI_API_KEY", raising=False)
        monkeypatch.delenv("GOOGLE_API_KEY", raising=False)
        kwargs = await self._opened_client_kwargs(db, recording_client, [])
        assert kwargs == {"vertexai": True, "project": "p", "location": "global"}

    async def test_vertex_ignores_a_supplied_api_key(
        self,
        db: DbSessionFactory,
        monkeypatch: pytest.MonkeyPatch,
        recording_client: type[_RecordingClient],
    ) -> None:
        monkeypatch.setenv(ENV_PHOENIX_GOOGLE_VERTEX_PROJECT, "p")
        credential = GenerativeCredentialInput(env_var_name="GEMINI_API_KEY", value=SecretStr("k"))
        kwargs = await self._opened_client_kwargs(db, recording_client, [credential])
        assert "api_key" not in kwargs
        assert kwargs["vertexai"] is True

    async def test_without_vertex_the_api_key_is_used(
        self,
        db: DbSessionFactory,
        monkeypatch: pytest.MonkeyPatch,
        recording_client: type[_RecordingClient],
    ) -> None:
        monkeypatch.delenv(ENV_PHOENIX_GOOGLE_VERTEX_PROJECT, raising=False)
        credential = GenerativeCredentialInput(env_var_name="GEMINI_API_KEY", value=SecretStr("k"))
        kwargs = await self._opened_client_kwargs(db, recording_client, [credential])
        assert kwargs == {"api_key": "k"}
