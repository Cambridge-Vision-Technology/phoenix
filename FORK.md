# Fork features

What this fork adds to Phoenix for running prompts that take images or files, and how to use and
deploy those features. For the Python client, see
[`packages/phoenix-client/PROMPT_MANAGEMENT.md`](packages/phoenix-client/PROMPT_MANAGEMENT.md).

This is a fork-owned document. Upstream Phoenix does not have these features.

## Images and files in prompts and datasets

A prompt can have image and file parts. A part either stores a fixed file, or names a variable that
each run fills in. Both the Playground and experiments support them.

Upload a file to get a reference, then use that reference in a dataset example:

```python
import httpx

client = httpx.Client(base_url="http://localhost:6006")

with open("page.png", "rb") as file:
    uploaded = client.post("/v1/media", files={"file": ("page.png", file, "image/png")})
uploaded.raise_for_status()
reference = f"phoenix://media/{uploaded.json()['data']['sha256']}"
```

Files are stored once per unique content, so uploading the same file again costs nothing.

### Passing several images to one variable

A media variable holds one reference or a list of references. Use a list when the number of images
varies between examples, for example the pages of documents of different lengths. One prompt then
serves every example.

The prompt needs only one image part:

```python
content = [
    {"type": "image", "image": {"variable": "pages"}},
    {"type": "text", "text": "Summarize this document."},
]
```

Each example supplies as many images as it needs:

```python
response = client.post(
    "/v1/datasets/upload?sync=true",
    json={
        "action": "create",
        "name": "documents",
        "inputs": [
            {"pages": [reference]},
            {"pages": [reference, reference, reference]},
        ],
        "outputs": [{}, {}],
        "metadata": [{}, {}],
    },
)
response.raise_for_status()
```

Each item becomes its own image, in list order, at the position of the variable in the prompt.

| Value of the variable | Result |
| --- | --- |
| One reference | One image |
| A list of references | One image per item, in order |
| Missing, `null`, blank, or an empty list | No image. The rest of the prompt still runs |
| A blank or `null` item in a list | That item is skipped |
| Anything else, including a number or an object in a list | That run fails with an error |

File variables work the same way.

Limits:

- Lists work for runs over a dataset. The manual media input in the Playground takes one file when no
  dataset is selected.
- The Python client helpers `to_openai` and `to_genai` do not accept lists. They raise
  `MediaResolutionError`.
- All of the images go in one request to the model. Very long lists can reach the provider's limit
  on request size.

## A response format for each dataset example

A prompt holds one response format. If your application builds a schema per request, set
`phoenix_response_format` in the metadata of an example. Runs of that example then use it instead of
the format of the prompt. Examples without the key use the format of the prompt.

```python
response_format = {
    "type": "json_schema",
    "json_schema": {
        "name": "answers",
        "schema": {
            "type": "object",
            "properties": {"city": {"type": "string"}},
            "required": ["city"],
            "additionalProperties": False,
        },
        "strict": True,
    },
}

response = client.post(
    "/v1/datasets/upload?sync=true",
    json={
        "action": "create",
        "name": "per-example-schemas",
        "inputs": [{"question": "Where is the office?"}, {"question": "When does it open?"}],
        "outputs": [{}, {}],
        "metadata": [{"phoenix_response_format": response_format}, {}],
    },
)
response.raise_for_status()
```

- The value has the same shape as `response_format` on a prompt version in the REST API.
- If the value is not valid, that run fails with an error and does not call the model. It does not
  fall back to the format of the prompt.
- The Playground marks these examples with an **Own response format** tag. If you edit the format of
  the prompt in the Playground, the change does not apply to those examples.
- The key applies only to runs over a dataset. Other metadata, including a key named
  `response_format`, has no effect.

## Collapsing the evaluator summary in the compare grid

With many evaluators, the summary in the header of the experiment compare grid can fill the screen.
Use the **Evaluators** arrow in a column header to hide or show the summary. The setting applies to
all columns and stays in effect when you return to the page.

## Deployment settings

| Variable | Default | Purpose |
| --- | --- | --- |
| `PHOENIX_GOOGLE_VERTEX_PROJECT` | Not set | Sends the built-in Google provider to Vertex AI in this project. See below |
| `PHOENIX_GOOGLE_VERTEX_LOCATION` | `global` | The Vertex AI location |
| `PHOENIX_SPAN_MEDIA_OFFLOAD` | `false` | Set to `true` to move inline media out of spans and into the media store |
| `PHOENIX_MEDIA_GCS_BUCKET` | Not set | Stores media in this Google Cloud Storage bucket instead of the local filesystem |
| `PHOENIX_MEDIA_GCS_PREFIX` | `media/` | The object name prefix in that bucket |
| `PHOENIX_MEDIA_LOCAL_DIR` | `media` in the working directory | Where the filesystem backend stores media |
| `PHOENIX_MAX_MEDIA_BYTES` | 20 MiB | The largest single file you can upload |
| `PHOENIX_MEDIA_ORPHAN_GRACE_PERIOD_HOURS` | `24` | How long unreferenced media is kept before it can be deleted |

Before you deploy:

- **Keep media on persistent storage.** Media bytes are not in the database. Use a bucket or a
  persistent volume. On a container's own filesystem, media is lost when the container stops.
- **Turn on `PHOENIX_SPAN_MEDIA_OFFLOAD` if you run image experiments.** If it is off, each run
  stores a full copy of every image it sends in its trace. It is off by default because it needs the
  persistent storage above.
- **Know what Vertex AI mode does.** When `PHOENIX_GOOGLE_VERTEX_PROJECT` is set, requests use
  Application Default Credentials, for example through `GOOGLE_APPLICATION_CREDENTIALS`. Phoenix
  ignores any Gemini API key, including one entered in the Playground. Requests therefore cannot
  fall back to the Gemini API.
