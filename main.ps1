param(
    [string]$InputJsonPath,
    [int]$BatchSize,
    [string]$SystemPromptFilePath,
    [string]$ApiKey
)

# =========================
# Config file loading (config.yml)
# =========================

function Load-ConfigFromYaml {
    param(
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{}
    }

    $result = @{}

    try {
        $lines = Get-Content -LiteralPath $Path -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to read config file '$Path': $($_.Exception.Message)"
        return @{}
    }

    foreach ($line in $lines) {
        $trim = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trim)) { continue }
        if ($trim.StartsWith("#")) { continue }

        $idx = $trim.IndexOf(":")
        if ($idx -lt 0) { continue }

        $key = $trim.Substring(0, $idx).Trim()
        $value = $trim.Substring($idx + 1).Trim()

        if (-not $key) { continue }

        if ([string]::IsNullOrWhiteSpace($value)) {
            $parsed = ""
        }
        elseif ($value -match '^[+-]?\d+$') {
            $parsed = [int]$value
        }
        elseif ($value -match '^(?i:true|false)$') {
            $parsed = [bool]$value
        }
        else {
            $parsed = $value.Trim('"').Trim("'")
        }

        $result[$key] = $parsed
    }

    return $result
}

# =========================
# Configuration Section
# =========================

$ConfigPath = Join-Path $PSScriptRoot "config.yml"
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "config.yml not found at $ConfigPath. Create it with required keys: MAX_RETRIES, MAX_BATCH_FAILURES, REQUEST_TIMEOUT_SECONDS, INITIAL_BACKOFF_SECONDS, MAX_REQUEST_BYTES, API_ENDPOINT, DEFAULT_BATCH_SIZE, MODEL_NAME, API_KEY."
}
$Config = Load-ConfigFromYaml -Path $ConfigPath

$RequiredKeys = @("MAX_RETRIES", "MAX_BATCH_FAILURES", "REQUEST_TIMEOUT_SECONDS", "INITIAL_BACKOFF_SECONDS", "MAX_REQUEST_BYTES", "API_ENDPOINT", "DEFAULT_BATCH_SIZE", "MODEL_NAME", "API_KEY")
foreach ($key in $RequiredKeys) {
    if (-not $Config.ContainsKey($key)) {
        throw "config.yml is missing required key: $key"
    }
}

$MAX_RETRIES = [int]$Config["MAX_RETRIES"]
$MAX_BATCH_FAILURES = [int]$Config["MAX_BATCH_FAILURES"]
$REQUEST_TIMEOUT_SECONDS = [int]$Config["REQUEST_TIMEOUT_SECONDS"]
$INITIAL_BACKOFF_SECONDS = [int]$Config["INITIAL_BACKOFF_SECONDS"]
$MAX_REQUEST_BYTES = [int]$Config["MAX_REQUEST_BYTES"]
$API_ENDPOINT = [string]$Config["API_ENDPOINT"]
$DEFAULT_BATCH_SIZE = [int]$Config["DEFAULT_BATCH_SIZE"]
$MODEL_NAME = [string]$Config["MODEL_NAME"]
$ApiKey = [string]$Config["API_KEY"]

# Optional test mode:
# - If > 0, process only the first N batches and exit early.
# - If 0 or empty, run normally for all batches.
$TestBatches = 0
if ($Config.ContainsKey("TEST_BATCHES")) {
    $tb = $Config["TEST_BATCHES"]
    if ([string]::IsNullOrWhiteSpace([string]$tb)) {
        $TestBatches = 0
    }
    else {
        $TestBatches = [int]$tb
        if ($TestBatches -lt 0) {
            throw "TEST_BATCHES must be >= 0."
        }
    }
}
# Directories
$InputDirectory = Join-Path $PSScriptRoot "input"
$OutputDirectory = Join-Path $PSScriptRoot "output"
$PromptsDirectory = Join-Path $PSScriptRoot "prompts"

# Output / checkpoint paths are set later once the input file is known
$OutputJsonlPath = $null
$CheckpointPath = $null

# API key from config.yml

# Built-in internal system prompt (sourced from prompts/default.txt)
$DefaultInternalPromptPath = Join-Path $PromptsDirectory "default.txt"
if (-not (Test-Path -LiteralPath $DefaultInternalPromptPath)) {
    throw "Required internal prompt file not found: $DefaultInternalPromptPath"
}
try {
    $InternalSystemPrompt = Get-Content -LiteralPath $DefaultInternalPromptPath -Raw -ErrorAction Stop
}
catch {
    throw "Failed to read internal prompt file '$DefaultInternalPromptPath': $($_.Exception.Message)"
}


# =========================
# Utility / Logging
# =========================

function Write-LogInfo {
    param([string]$Message)
    Write-Host "[INFO ] $Message"
}

function Write-LogWarn {
    param([string]$Message)
    Write-Warning "[WARN ] $Message"
}

function Write-LogError {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}


# =========================
# Validation & Input
# =========================

function Validate-JsonFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Input file does not exist: $Path"
    }

    if ([System.IO.Path]::GetExtension($Path).ToLower() -ne ".json") {
        throw "Input file must have .json extension: $Path"
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    }
    catch {
        throw "Failed to read file '$Path': $($_.Exception.Message)"
    }

    try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "File '$Path' does not contain valid JSON: $($_.Exception.Message)"
    }

    if (-not ($parsed -is [System.Collections.IEnumerable])) {
        throw "Top-level JSON must be an array of objects."
    }

    return $parsed
}

function Get-SystemPrompt {
    param(
        [string]$SystemPromptFilePath
    )

    Write-LogInfo "System prompt configuration:"
    Write-Host "1) Choose a prompt file from the 'prompts' directory"
    Write-Host "2) Type/paste the system prompt directly"
    Write-Host "3) Use only the internal default system prompt (no user prompt)"
    $choice = Read-Host "Select option (1, 2, or 3)"

    $userPrompt = ""

    switch ($choice) {
        "1" {
            if (-not (Test-Path -LiteralPath $PromptsDirectory)) {
                throw "Prompts directory not found: $PromptsDirectory"
            }

            $promptFiles = Get-ChildItem -LiteralPath $PromptsDirectory -Filter "*.txt" -File | Sort-Object Name
            if (-not $promptFiles -or $promptFiles.Count -eq 0) {
                throw "No .txt prompt files found in $PromptsDirectory"
            }

            Write-Host "Available prompt files:"
            for ($i = 0; $i -lt $promptFiles.Count; $i++) {
                $index = $i + 1
                Write-Host ("{0}) {1}" -f $index, $promptFiles[$i].Name)
            }

            $selection = Read-Host "Select prompt file by number"
            if (-not [int]::TryParse($selection, [ref]$null)) {
                throw "Invalid selection for prompt file: must be an integer."
            }
            $selIndex = [int]$selection
            if ($selIndex -lt 1 -or $selIndex -gt $promptFiles.Count) {
                throw "Prompt file selection out of range."
            }

            $chosen = $promptFiles[$selIndex - 1]

            try {
                $userPrompt = Get-Content -LiteralPath $chosen.FullName -Raw -ErrorAction Stop
            }
            catch {
                throw "Failed to read system prompt file '$($chosen.FullName)': $($_.Exception.Message)"
            }
        }
        "2" {
            Write-Host "Type/paste your system prompt below. End with an empty line."
            $lines = @()
            while ($true) {
                $line = Read-Host
                if ([string]::IsNullOrWhiteSpace($line)) { break }
                $lines += $line
            }
            $userPrompt = ($lines -join [Environment]::NewLine)
        }
        "3" {
            $userPrompt = ""
            Write-LogInfo "No user system prompt supplied. Using only internal system prompt."
        }
        default {
            throw "Invalid choice for system prompt option: $choice"
        }
    }

    return $userPrompt
}


# =========================
# Checkpointing
# =========================

function Load-Checkpoint {
    param(
        [string]$CheckpointPath
    )

    if (-not (Test-Path -LiteralPath $CheckpointPath)) {
        return $null
    }

    try {
        $content = Get-Content -LiteralPath $CheckpointPath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($content)) {
            return $null
        }
        $cp = $content | ConvertFrom-Json -ErrorAction Stop
        return $cp
    }
    catch {
        Write-LogWarn "Failed to load checkpoint: $($_.Exception.Message). Ignoring existing checkpoint."
        return $null
    }
}

function Save-Checkpoint {
    param(
        [string]$CheckpointPath,
        [int]$LastBatchCompleted,
        [int]$TotalBatches
    )

    $cp = [pscustomobject]@{
        lastBatchCompleted = $LastBatchCompleted
        totalBatches       = $TotalBatches
        timestamp          = (Get-Date).ToString("o")
    }

    try {
        $json = $cp | ConvertTo-Json -Depth 5
        $json | Set-Content -LiteralPath $CheckpointPath -Encoding UTF8
    }
    catch {
        Write-LogWarn "Failed to save checkpoint: $($_.Exception.Message)"
    }
}


# =========================
# AI Invocation & Retry
# =========================

function Invoke-AIRequest {
    param(
        [string]$InternalPrompt,
        [string]$UserPrompt,
        [string]$TaskId,
        [System.Collections.IEnumerable]$BatchObjects
    )

    if (-not $ApiKey) {
        throw "API key is not set. Ensure API_KEY is defined in config.yml."
    }

    $headers = @{
        "Authorization" = "Bearer $ApiKey"
        "Content-Type"  = "application/json"
    }

    $taskBody = @{
        system_prompts = @(
            $InternalPrompt
        )
        user_prompt    = $UserPrompt
        task           = @{
            task_id = $TaskId
            objects = @()
        }
    }

    foreach ($obj in $BatchObjects) {
        $taskBody.task.objects += $obj
    }

    $taskJson = $taskBody | ConvertTo-Json -Depth 20

    $messages = New-Object System.Collections.Generic.List[object]
    $messages.Add(@{
            role    = "system"
            content = $InternalPrompt
        })

    if ($UserPrompt) {
        $messages.Add(@{
                role    = "system"
                content = $UserPrompt
            })
    }

    $messages.Add(@{
            role    = "user"
            content = $taskJson
        })

    $requestBody = @{
        model           = $MODEL_NAME
        response_format = @{
            type = "json_object"
        }
        messages        = $messages
    }

    foreach ($obj in $BatchObjects) {
        # already added to $taskBody above; nothing needed here
    }

    $jsonBody = $requestBody | ConvertTo-Json -Depth 20

    # Rough payload size guardrail
    $byteCount = [System.Text.Encoding]::UTF8.GetByteCount($jsonBody)
    if ($byteCount -gt $MAX_REQUEST_BYTES) {
        throw "Request payload for $TaskId is too large ($byteCount bytes > $MAX_REQUEST_BYTES bytes). Use a smaller batch size."
    }

    $invokeParams = @{
        Uri         = $API_ENDPOINT
        Method      = 'POST'
        Headers     = $headers
        Body        = $jsonBody
        TimeoutSec  = $REQUEST_TIMEOUT_SECONDS
        ErrorAction = 'Stop'
    }

    try {
        $response = Invoke-RestMethod @invokeParams
    }
    catch {
        # This will be handled as retryable or not by the retry wrapper
        throw $_
    }

    if (-not $response) {
        throw "AI response is null or empty."
    }

    if (-not $response.choices -or -not $response.choices[0] -or
        -not $response.choices[0].message -or -not $response.choices[0].message.content) {
        throw "AI response does not contain a valid chat completion message."
    }

    $contentJson = $response.choices[0].message.content

    try {
        $parsed = $contentJson | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "AI response content is not valid JSON: $($_.Exception.Message)"
    }

    if (-not ($parsed.PSObject.Properties.Name -contains "task_id" -and
            $parsed.PSObject.Properties.Name -contains "objects")) {
        throw "AI response JSON does not contain required 'task_id' and 'objects' properties."
    }

    if ($parsed.task_id -ne $TaskId) {
        throw "AI response task_id '$($parsed.task_id)' does not match request task_id '$TaskId'."
    }

    $objects = $parsed.objects
    if (-not ($objects -is [System.Collections.IEnumerable])) {
        throw "AI response 'objects' must be an array."
    }

    # Ensure returned object count matches batch
    $inputCount = ($BatchObjects | Measure-Object).Count
    $outputCount = ($objects | Measure-Object).Count
    if ($inputCount -ne $outputCount) {
        throw "AI response object count ($outputCount) does not match input batch size ($inputCount)."
    }

    return $objects
}

function Retry-WithExponentialBackoff {
    param(
        [scriptblock]$Operation,
        [string]$Description
    )

    $attempt = 0
    $delay = $INITIAL_BACKOFF_SECONDS

    while ($true) {
        $attempt++

        try {
            return & $Operation
        }
        catch {
            $err = $_
            $statusCode = $null

            if ($err.Exception -and $err.Exception.Response -and $err.Exception.Response.StatusCode) {
                $statusCode = [int]$err.Exception.Response.StatusCode
            }

            $isTimeout = $err.Exception -and $err.Exception.Message -like "*The operation has timed out*"

            $retryableStatusCodes = @(429, 500, 502, 503, 504)

            $shouldRetry = $false
            if ($statusCode -and $retryableStatusCodes -contains $statusCode) {
                $shouldRetry = $true
            }
            elseif ($isTimeout) {
                $shouldRetry = $true
            }
            else {
                # Treat JSON-shape / validation errors here as retryable by higher level logic
                # if the caller decides so. For now, treat unknown failures as retryable up to MAX_RETRIES.
                $shouldRetry = $true
            }

            if (-not $shouldRetry -or $attempt -ge $MAX_RETRIES) {
                Write-LogError "Operation '$Description' failed on attempt $attempt. Error: $($err.Exception.Message)"
                throw
            }

            Write-LogWarn "Retry $attempt for '$Description' in $delay seconds. Error: $($err.Exception.Message)"
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min($delay * 2, 600) # cap delay at 10 minutes
        }
    }
}


# =========================
# Output Writing
# =========================

function Write-OutputJsonLine {
    param(
        [Parameter(Mandatory=$true)]$Object,
        [Parameter(Mandatory=$true)][string]$Path
    )

    try {
        $jsonLine = $Object | ConvertTo-Json -Depth 20 -Compress
        Add-Content -LiteralPath $Path -Value $jsonLine
    }
    catch {
        throw "Failed to write output JSON line: $($_.Exception.Message)"
    }
}

function Write-FinalOutputJson {
    param(
        [Parameter(Mandatory=$true)][string]$JsonlPath,
        [Parameter(Mandatory=$true)][string]$FinalFileName
    )

    if (-not (Test-Path -LiteralPath $JsonlPath)) {
        throw "JSONL file not found: $JsonlPath"
    }

    $lines = Get-Content -LiteralPath $JsonlPath -ErrorAction Stop
    $objects = @()
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $obj = $line | ConvertFrom-Json -ErrorAction Stop
            $objects += $obj
        }
        catch {
            Write-LogWarn "Skipping invalid JSON line in '$JsonlPath': $($_.Exception.Message)"
        }
    }

    $finalPath = Join-Path $OutputDirectory $FinalFileName

    $objects | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $finalPath -Encoding UTF8

    Write-LogInfo "Final output written to: $finalPath"
    return $finalPath
}


# =========================
# Batch Processing Orchestration
# =========================

function Process-Batches {
    param(
        [System.Collections.IEnumerable]$JsonArray,
        [int]$BatchSize,
        [string]$UserPrompt,
        [string]$FinalOutputFileName,
        [int]$TestBatches,
        [string]$OutputJsonlPath,
        [string]$CheckpointPath
    )

    $items = @()
    foreach ($item in $JsonArray) {
        if (-not ($item -is [pscustomobject] -or $item -is [hashtable])) {
            Write-LogWarn "Encountered non-object item in JSON array; it will still be processed."
        }
        $items += $item
    }

    $totalObjects = $items.Count
    if ($totalObjects -eq 0) {
        Write-LogWarn "Input JSON array is empty. Nothing to process."
        return
    }

    if (-not $BatchSize -or $BatchSize -le 0) {
        $BatchSize = $DEFAULT_BATCH_SIZE
    }

    Write-LogInfo "Total objects: $totalObjects"
    Write-LogInfo "Batch size: $BatchSize"

    # Checkpoint / resume
    $startAfterBatchNumber = 0
    if ($TestBatches -gt 0) {
        # Test mode: don't resume from previous runs; start fresh.
        Remove-Item -LiteralPath $CheckpointPath -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $OutputJsonlPath -ErrorAction SilentlyContinue
    }
    else {
        $checkpoint = Load-Checkpoint -CheckpointPath $CheckpointPath
        if ($checkpoint -and (Test-Path -LiteralPath $OutputJsonlPath)) {
            Write-LogInfo "Checkpoint found. Last completed batch: $($checkpoint.lastBatchCompleted)"
            $resumeChoice = Read-Host "Resume from checkpoint? (y/n)"
            if ($resumeChoice -eq "y") {
                $startAfterBatchNumber = [int]$checkpoint.lastBatchCompleted
                Write-LogInfo "Resuming after batch $startAfterBatchNumber."
            }
            else {
                Remove-Item -LiteralPath $CheckpointPath -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $OutputJsonlPath -ErrorAction SilentlyContinue
            }
        }
        else {
            Remove-Item -LiteralPath $CheckpointPath -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $OutputJsonlPath -ErrorAction SilentlyContinue
        }
    }

    $failedBatches = 0
    $processedObjects = 0
    $processedBatchesThisRun = 0

    $totalBatches = [int][Math]::Ceiling($totalObjects / $BatchSize)

    for ($batchNumber = 1; $batchNumber -le $totalBatches; $batchNumber++) {
        if ($batchNumber -le $startAfterBatchNumber) {
            continue
        }

        $startIndex = ($batchNumber - 1) * $BatchSize
        $count = [Math]::Min($BatchSize, $totalObjects - $startIndex)
        $batch = $items[$startIndex..($startIndex + $count - 1)]

        $displayStart = $processedObjects + 1
        $displayEnd = $processedObjects + $count
        Write-LogInfo "Processing batch $batchNumber/$totalBatches (objects $displayStart–$displayEnd)"

        $taskId = "batch_$batchNumber"
        $operation = {
            Invoke-AIRequest -InternalPrompt $InternalSystemPrompt -UserPrompt $UserPrompt -TaskId $taskId -BatchObjects $batch
        }

        try {
            $resultObjects = Retry-WithExponentialBackoff -Operation $operation -Description "AI request for $taskId"
        }
        catch {
            $failedBatches++
            Write-LogError "Batch $batchNumber/$totalBatches failed after $MAX_RETRIES attempts. Failed batches so far: $failedBatches"
            if ($failedBatches -ge $MAX_BATCH_FAILURES) {
                Write-LogError "Stopping: maximum batch failures ($MAX_BATCH_FAILURES) reached."
                break
            }
            else {
                continue
            }
        }

        foreach ($obj in $resultObjects) {
            Write-OutputJsonLine -Object $obj -Path $OutputJsonlPath
        }

        $processedObjects += $count

        Save-Checkpoint -CheckpointPath $CheckpointPath -LastBatchCompleted $batchNumber -TotalBatches $totalBatches

        $processedBatchesThisRun++
        if ($TestBatches -gt 0 -and $processedBatchesThisRun -ge $TestBatches) {
            Write-LogInfo "TEST_BATCHES limit reached ($TestBatches batches). Exiting early."
            break
        }

        Write-LogInfo "Batch $batchNumber/$totalBatches completed (processed $count objects). Progress: $processedObjects/$totalObjects objects."
    }

    Write-LogInfo "Batch processing finished."
    Write-LogInfo "Total processed objects: $processedObjects"
    Write-LogInfo "Failed batches: $failedBatches"

    if ($processedObjects -gt 0 -and (Test-Path -LiteralPath $OutputJsonlPath)) {
        $finalPath = Write-FinalOutputJson -JsonlPath $OutputJsonlPath -FinalFileName $FinalOutputFileName
        Write-LogInfo "Completed successfully. Final output file: $finalPath"
    }
    else {
        Write-LogWarn "No output generated."
    }
}


# =========================
# Main Entry
# =========================

function Main {
    # Ensure standard directories exist
    if (-not (Test-Path -LiteralPath $InputDirectory)) {
        New-Item -ItemType Directory -Path $InputDirectory -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $PromptsDirectory)) {
        New-Item -ItemType Directory -Path $PromptsDirectory -Force | Out-Null
    }

    # Ask for input JSON path if not supplied; otherwise, list files from input directory
    if (-not $InputJsonPath) {
        $inputFiles = Get-ChildItem -LiteralPath $InputDirectory -Filter "*.json" -File | Sort-Object Name
        if (-not $inputFiles -or $inputFiles.Count -eq 0) {
            throw "No .json files found in input directory: $InputDirectory"
        }

        Write-Host "Available input JSON files in '$InputDirectory':"
        for ($i = 0; $i -lt $inputFiles.Count; $i++) {
            $index = $i + 1
            Write-Host ("{0}) {1}" -f $index, $inputFiles[$i].Name)
        }

        $selection = Read-Host "Select input JSON file by number"
        if (-not [int]::TryParse($selection, [ref]$null)) {
            throw "Invalid selection for input file: must be an integer."
        }
        $selIndex = [int]$selection
        if ($selIndex -lt 1 -or $selIndex -gt $inputFiles.Count) {
            throw "Input file selection out of range."
        }

        $chosenInput = $inputFiles[$selIndex - 1]
        $InputJsonPath = $chosenInput.FullName
    }

    # Derive per-run output paths based on chosen input file name (also used by checkpointing)
    $inputFileName = [System.IO.Path]::GetFileName($InputJsonPath)
    $OutputJsonlPath = Join-Path $OutputDirectory ("{0}.jsonl" -f $inputFileName)
    $CheckpointPath  = Join-Path $OutputDirectory ("{0}.checkpoint.json" -f $inputFileName)
    # Load and validate JSON (full array in memory)
    $jsonArray = Validate-JsonFile -Path $InputJsonPath

    # Ask for batch size if not supplied
    if (-not $BatchSize -or $BatchSize -le 0) {
        $BatchSizeInput = Read-Host "Enter batch size (number of objects per request) [default: $DEFAULT_BATCH_SIZE]"
        if ([string]::IsNullOrWhiteSpace($BatchSizeInput)) {
            $BatchSize = $DEFAULT_BATCH_SIZE
        }
        else {
            if (-not [int]::TryParse($BatchSizeInput, [ref]$null)) {
                throw "Invalid batch size input: must be an integer."
            }
            $BatchSize = [int]$BatchSizeInput
            if ($BatchSize -le 0) {
                throw "Batch size must be positive."
            }
        }
    }

    # Get user system prompt (or empty)
    $userPrompt = Get-SystemPrompt -SystemPromptFilePath $SystemPromptFilePath

    Process-Batches -JsonArray $jsonArray -BatchSize $BatchSize -UserPrompt $userPrompt -FinalOutputFileName $inputFileName -TestBatches $TestBatches -OutputJsonlPath $OutputJsonlPath -CheckpointPath $CheckpointPath
}

try { Main } catch {
    Write-LogError "Fatal error: $($_.Exception.Message)"
    exit 1
}