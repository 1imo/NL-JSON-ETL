## JSON batch transformer ( PowerShell )

This repo contains a PowerShell script that:

- Reads a JSON file containing a top‑level array of objects.
- Processes the objects in batches via an HTTP AI API.
- Writes out:
  - A JSONL file with results as they arrive.
  - A final JSON array file when all batches are done.
- Supports checkpoints so you can resume after failures.

The script is intended for data transformation / ETL workflows where an LLM applies a prompt‑driven transformation to each object.

---

### Layout

- `main.ps1` – PowerShell entrypoint.
- `config.yml` – required configuration.
- `input/` – put input `.json` files here.
- `output/` – batch and final outputs.
- `prompts/` – prompt `.txt` files.
  - `default.txt` – internal system prompt used by default.

---

### Requirements

- **PowerShell**
  - Windows PowerShell 5.1+ or PowerShell 7+.
- **Network access** to your AI API endpoint.
- **API key**
  - Configured in `config.yml` (see below).

The script runs locally; it does not install any external PowerShell modules.

---

### Configuration ( `config.yml` )

`config.yml` lives next to `main.ps1`. Most keys are required. If the file is missing or any required key is absent, the script will exit with an error.

Example:

```yaml
MAX_RETRIES: 5
MAX_BATCH_FAILURES: 3
REQUEST_TIMEOUT_SECONDS: 60
INITIAL_BACKOFF_SECONDS: 2
MAX_REQUEST_BYTES: 800000

# HTTP endpoint for your AI API
API_ENDPOINT: https://api.openai.com/v1/chat/completions

DEFAULT_BATCH_SIZE: 10

# Optional test mode: if > 0, only process the first N batches and then exit.
# Set to 0 (or leave empty) for normal full runs.
TEST_BATCHES: 0

# Model identifier used by the API
MODEL_NAME: gpt-4.1-mini

# API key used for authentication
API_KEY: your-api-key-goes-here
```

Meaning of keys:

- **Reliability**
  - `MAX_RETRIES`: max retries per batch request.
  - `MAX_BATCH_FAILURES`: stop completely after this many failed batches.
  - `REQUEST_TIMEOUT_SECONDS`: HTTP request timeout.
  - `INITIAL_BACKOFF_SECONDS`: starting delay for exponential backoff.

- **Testing**
  - `TEST_BATCHES` (optional):
    - `0` or empty: run all batches (default behavior).
    - `> 0`: process only the first N batches, then exit early.
    - In test mode, the script ignores any existing checkpoint/output for that input and starts fresh from batch 1.

- **Payload limits**
  - `MAX_REQUEST_BYTES`: soft limit on request size ( in bytes ). Larger payloads cause the script to fail fast and ask you to lower batch size.

- **API**
  - `API_ENDPOINT`: URL of the AI HTTP endpoint.
  - `DEFAULT_BATCH_SIZE`: default number of objects per request.
  - `MODEL_NAME`: model identifier to send to the API.
  - `API_KEY`: bearer token used in the `Authorization` header.

---

### How it works (high level)

1. You pick an input file from `input/` (e.g. `input/data.json`).
2. The script:
   - Loads the JSON file into memory.
   - Checks that the top‑level value is an array.
3. You choose a batch size (or accept the default from `config.yml`).
4. You choose a prompt source:
   - Select a `.txt` file from `prompts/`, or
   - Paste a prompt directly, or
   - Skip and use the internal default prompt only.
5. The script splits the array into batches and, for each batch:
   - Sends a request to the AI API with:
     - An internal system prompt (from `prompts/default.txt`).
     - The optional user prompt.
     - A `task` object containing:
       - `task_id` – e.g. `"batch_3"`.
       - `objects` – the batch of JSON objects.
   - Expects the API to return JSON of the form:
     ```json
     {
       "task_id": "batch_3",
       "objects": [ /* transformed objects */ ]
     }
     ```
   - Verifies:
     - `task_id` matches.
     - `objects` is an array.
     - The number of returned objects matches the batch size.
   - Writes transformed objects to a JSONL file as they arrive.
   - Updates a checkpoint file.

6. When all batches complete, it builds a final JSON array file from the JSONL file.

---

### Files produced

Given an input file `input/data.json`, outputs go to `output/`:

- During processing:
  - `output/data.json.jsonl`
    - One transformed object per line (JSON Lines).
  - `output/data.json.checkpoint.json`
    - Stores `lastBatchCompleted` and `totalBatches` (currently `totalBatches` is informational).

- Final result:
  - `output/data.json`
    - JSON array of all transformed objects.

You can safely delete the `.jsonl` and `.checkpoint.json` files once you are happy with the final JSON.

---

### Running the script

From the repo root:

```powershell
# PowerShell 7+
pwsh ./main.ps1
# or Windows PowerShell
powershell.exe -File .\main.ps1
```

Interactive flow:

1. **Input file selection**
   - The script lists `.json` files under `input/`.
   - You pick one by number.

2. **Batch size**
   - Prompt:  
     `Enter batch size (number of objects per request) [default: <DEFAULT_BATCH_SIZE>]`
   - Press Enter to use the default, or type a positive integer.

3. **Prompt selection**

   You’ll see:

   ```text
   [INFO ] System prompt configuration:
   1) Choose a prompt file from the 'prompts' directory
   2) Type/paste the system prompt directly
   3) Use only the internal default system prompt (no user prompt)
   ```

   - Option `1`: select from `.txt` files in `prompts/`.
   - Option `2`: paste a multi-line prompt (finish with an empty line).
   - Option `3`: use only the internal prompt (`prompts/default.txt`).

4. **Checkpoint / resume**

   If there is an existing `.jsonl` + checkpoint for this input:

   - The script shows last completed batch and asks:
     `Resume from checkpoint? (y/n)`
   - `y`: continues from the next batch.
   - `n`: deletes the old JSONL + checkpoint and starts over.

5. **Processing**

   For each batch you’ll see logs like:

   ```text
   [INFO ] Processing batch 3/20 (objects 41–60)
   [WARN ] Retry 1 for 'AI request for batch_3' in 2 seconds. Error: ...
   [INFO ] Batch 3/20 completed (processed 20 objects). Progress: 60/400 objects.
   ```

6. **Completion**

   At the end:

   ```text
   [INFO ] Batch processing finished.
   [INFO ] Total processed objects: <N>
   [INFO ] Failed batches: <F>
   [INFO ] Final output written to: output/data.json
   ```

---

### Error handling and retries

- For each batch request:
  - The script retries up to `MAX_RETRIES` times using exponential backoff.
  - Retryable failures include:
    - HTTP 429, 500, 502, 503, 504.
    - Request timeouts.
    - Invalid or mismatched JSON in the AI response.
- If a batch keeps failing after `MAX_RETRIES`:
  - The batch is counted as failed.
  - When `MAX_BATCH_FAILURES` is reached, the script stops.

---

### Assumptions and limitations

- Input must be a **JSON file with a top-level array**:
  - e.g.
    ```json
    [
      { "id": 1, "text": "..." },
      { "id": 2, "text": "..." }
    ]
    ```
- The script currently:
  - Loads the entire JSON array into memory.
  - Is not optimized for multi‑GB files.
- The API must:
  - Accept the `task` structure (`task_id`, `objects`).
  - Return the matching `task_id` and same-count `objects` array.

If you need to handle extremely large inputs, consider pre-splitting the JSON into smaller files or converting to JSON Lines and adapting the script accordingly.
