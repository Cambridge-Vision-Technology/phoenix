"""
Route the built-in Google provider through Vertex AI rather than the Gemini API.

Set ``PHOENIX_GOOGLE_VERTEX_PROJECT`` to turn this on. Requests then authenticate with
Application Default Credentials, and any Gemini API key is ignored: a deployment that
chose Vertex for its data-handling terms must not silently fall back to another service
because someone pasted a key into the playground.

Fork-owned; read here rather than in ``phoenix.config``, which is upstream's.
"""

from os import getenv
from typing import Any, Optional

ENV_PHOENIX_GOOGLE_VERTEX_PROJECT = "PHOENIX_GOOGLE_VERTEX_PROJECT"
"""The Google Cloud project to call Vertex AI in. Unset means the Gemini API."""

ENV_PHOENIX_GOOGLE_VERTEX_LOCATION = "PHOENIX_GOOGLE_VERTEX_LOCATION"
"""The Vertex AI location. Defaults to ``global``, where preview Gemini models are served."""

VERTEX_RATE_LIMIT_CREDENTIAL = "vertex-application-default-credentials"
"""Stands in for an API key when grouping Vertex requests for rate limiting."""


def vertex_client_kwargs() -> Optional[dict[str, Any]]:
    """
    Arguments for ``google.genai.Client`` when Vertex AI is configured.

    Returns:
        The client arguments, or None when the Gemini API should be used.
    """
    project = (getenv(ENV_PHOENIX_GOOGLE_VERTEX_PROJECT) or "").strip()
    if not project:
        return None
    location = (getenv(ENV_PHOENIX_GOOGLE_VERTEX_LOCATION) or "").strip() or "global"
    return {"vertexai": True, "project": project, "location": location}
