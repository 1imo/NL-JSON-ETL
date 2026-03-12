## JSON → AI Transform ETL (PowerShell)

This repository contains a PowerShell-based ETL tool that sends JSON objects to an AI API in batches, applies a system prompt–driven transformation, and writes crash-safe, resumable output.

The script is designed for **developer data transformation** workflows and **LLM dataset generation**, with SRE-friendly behaviour: retries, checkpoints, and incremental output.

---

### Features

- **JSON input validation**
  - Verifies file exists, is `.json`, and contains valid JSON.
  - Requires top-level JSON to be an **array of objects**.

- **System prompt control**
  - Built-in internal system prompt that defines the transformation contract.
  - Optional **user system prompt**:
    - Choose from `.txt` files in the `prompts` directory (e.g. `prompts/default.txt`).
    - Typed/pasted directly into the terminal.
    - Or skipped (internal prompt only).

- **Batching**
  - Sends objects to the AI in batches (user-defined batch size).
  - Each batch is wrapped in:
    - `task_id` (e.g. `batch_3`)
    - `objects` (array of JSON objects to transform)

- **Robust AI interaction**
  - Exponential backoff retries with configurable limits.
  - Handles transient HTTP errors and timeouts.
  - Validates AI responses:
    - Response is JSON.
    - Contains `task_id` and `objects`.
    - `task_id` matches the request.
    - Number of returned objects matches the input batch.

- **Crash-safe, resumable output**
  - Writes incremental **JSONL** (`transformed_output.jsonl`) as it goes.
  - Maintains a checkpoint (`transform_checkpoint.json`) with:
    - `lastBatchCompleted`
    - `totalBatches`
  - On restart, you can **resume from the last completed batch** or start fresh.
  - After all batches complete, converts JSONL to final pretty-printed JSON:
    - `transformed_output_YYYYMMDD_HHMMSS.json`

- **Logging & observability**
  - Human-readable progress logs:
    - batches, retries, failures, totals, final output path.

---

### Prerequisites

- **PowerShell**
  - Windows PowerShell 5.1+ or PowerShell 7+.
- **Network access** to your AI API endpoint.
- **API key**
  - Either:
    - Set environment variable: `AI_API_KEY` or `OPENAI_API_KEY`
    - Or pass `-ApiKey` when running the script.

---

### Configuration

Configuration is read from `config.yml` only. The script throws if the file is missing or any required key is absent (no fallback defaults).

#### Config file (`config.yml`)

Place a `config.yml` file next to `main.ps1` with all required keys. Example:

```yaml
MAX_RETRIES: 5
MAX_BATCH_FAILURES: 3
REQUEST_TIMEOUT_SECONDS: 60
INITIAL_BACKOFF_SECONDS: 2
MAX_REQUEST_BYTES: 800000

# OpenAI Chat Completions endpoint (kept as a generic API_ENDPOINT variable)
API_ENDPOINT: https://api.openai.com/v1/chat/completions

DEFAULT_BATCH_SIZE: 10

# OpenAI model to use for transformations
MODEL_NAME: gpt-4.1-mini
```

Supported keys:

- **Reliability**
  - `MAX_RETRIES` – maximum retries per batch.
  - `MAX_BATCH_FAILURES` – stop after this many failed batches.
  - `REQUEST_TIMEOUT_SECONDS` – per-request timeout (seconds).
  - `INITIAL_BACKOFF_SECONDS` – initial delay for exponential backoff (seconds).

- **Payload guardrail**
  - `MAX_REQUEST_BYTES` – rough maximum request payload size in bytes.

- **API**
  - `API_ENDPOINT` – URL of your AI API (by default, this is set up for the OpenAI Chat Completions API).
  - `DEFAULT_BATCH_SIZE` – batch size if user does not specify.
  - `MODEL_NAME` – model name used in the chat completions request (e.g. `gpt-4.1-mini`).

If `config.yml` is missing or any required key is absent, the script throws an error and exits.

---

### Request / Response Contract

For each batch, the script sends a JSON payload like:

{
  "system_prompts": [
    "<internal system prompt text>"
  ],
  "user_prompt": "<optional user prompt text>",
  "task": {
    "task_id": "batch_3",
    "objects": [
      { /* object 1 */ },
      { /* object 2 */ }
    ]
  }
}
