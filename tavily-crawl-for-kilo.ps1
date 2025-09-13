[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$Url,

    [Parameter(Mandatory = $true)]
    [string]$FolderName,

    [Parameter(Mandatory = $false)]
    [string]$Instructions,

    [Parameter(Mandatory = $false)]
    [int]$MaxDepth = 1,

    [Parameter(Mandatory = $false)]
    [ValidateSet("basic", "advanced")]
    [string]$ExtractDepth = "advanced",

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [switch]$Async = $false,

    [Parameter(Mandatory = $false)]
    [switch]$AutoPoll,

    [Parameter(Mandatory = $false)]
    [switch]$Process,

    [Parameter(Mandatory = $false)]
    [string]$OutputDir
)

# --- Configuration ---
$ApiUrl = "https://api.tavily.com/crawl"

# BaseDir priority: OutputDir param > TAVILY_BASEDIR env > Current Location > PSScriptRoot
$BaseDir = if ($OutputDir) {
    $OutputDir
} elseif ($env:TAVILY_BASEDIR) {
    $env:TAVILY_BASEDIR
} elseif ((Get-Location).Path) {
    (Get-Location).Path
} else {
    $PSScriptRoot
}

$StateDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) ".kilocode"
$KeyPoolFile = Join-Path $StateDir "tavily_keypool.json"
$JobsFile = Join-Path $StateDir "tavily_jobs.json"
$LogFile = Join-Path $StateDir "tavily.log"

# Backup keys (dev only)
$ApiKeys = "11111111111111111111111111111111,222222222222222222222222222222,333333333333333333333333333,44444444444444444444444444444444444444"

# Poll config for async
$MaxJobRetries = 10
$InitialPollIntervalSec = 3
$MaxPollIntervalSec = 60

# --- Logging ---
function Write-Log {
    param ([string]$Message)
    $Timestamp = (Get-Date).ToUniversalTime().ToString("o")
    "[$Timestamp] $Message" | Out-File -FilePath $LogFile -Append -Encoding utf8
}

# --- ApiKeyPool Functions ---
function Get-ApiKeyPoolState {
    if (Test-Path $KeyPoolFile) {
        try {
            return Get-Content $KeyPoolFile -Raw | ConvertFrom-Json
        }
        catch {
            Write-Log "Warning: Failed to read keypool file $KeyPoolFile. Resetting to empty."
            return $null
        }
    }
    return $null
}

function Set-ApiKeyPoolState {
    param ([Parameter(Mandatory = $true)] $State)
    $TempFile = "$KeyPoolFile.tmp"
    try {
        $State | ConvertTo-Json -Depth 5 | Out-File -FilePath $TempFile -Encoding utf8
        Move-Item -Path $TempFile -Destination $KeyPoolFile -Force
    }
    catch {
        Write-Log "Error: Failed to write keypool file. Error: $_"
    }
}

function Get-NextApiKey {
    $envKeysStr = $env:TAVILY_API_KEY
    if ([string]::IsNullOrEmpty($envKeysStr)) {
        if ([string]::IsNullOrEmpty($ApiKeys)) {
            throw "Environment variable TAVILY_API_KEY not set, and script ApiKeys is empty. Please set keys."
        }
        $keys = $ApiKeys.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    } else {
        $keys = $envKeysStr.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
    if ($keys.Count -eq 0) {
        throw "No valid API keys found."
    }

    $state = Get-ApiKeyPoolState
    $envKeySet = New-Object System.Collections.Generic.HashSet[string]
    foreach ($k in $keys) { $envKeySet.Add($k) | Out-Null }

    $stateKeys = if ($state -and $state.keys) { $state.keys | ForEach-Object { $_.key } } else { @() }
    $stateKeySet = New-Object System.Collections.Generic.HashSet[string]
    foreach ($k in $stateKeys) { $stateKeySet.Add($k) | Out-Null }

    if (-not $state -or $state.keys.Count -ne $keys.Count -or -not $envKeySet.SetEquals($stateKeySet)) {
        Write-Log "Resetting ApiKeyPool state (keys changed)."
        $state = @{
            currentIndex = 0
            keys = $keys | ForEach-Object {
                [PSCustomObject]@{
                    key = $_
                    active = $true
                    errorCount = 0
                    maxErrors = 5
                }
            }
        }
        Set-ApiKeyPoolState -State $state
    }

    $activeKeys = $state.keys | Where-Object { $_.active }
    if ($activeKeys.Count -eq 0) {
        return $null
    }

    $index = $state.currentIndex % $activeKeys.Count
    $keyConfig = $activeKeys[$index]
    $state.currentIndex = ($state.currentIndex + 1) % $activeKeys.Count
    Set-ApiKeyPoolState -State $state
    return $keyConfig
}

function Mark-ApiKeyError {
    param ([string]$Key)
    $state = Get-ApiKeyPoolState
    if (-not $state) { return }
    $keyConfig = $state.keys | Where-Object { $_.key -eq $Key }
    if ($keyConfig) {
        $keyConfig.errorCount++
        if ($keyConfig.errorCount -ge $keyConfig.maxErrors) {
            $keyConfig.active = $false
            Write-Log "Disabling key due to multiple errors: $($Key.Substring(0, 8))..."
        }
        Set-ApiKeyPoolState -State $state
    }
}

function Mark-ApiKeySuccess {
    param ([string]$Key)
    $state = Get-ApiKeyPoolState
    if (-not $state) { return }
    $keyConfig = $state.keys | Where-Object { $_.key -eq $Key }
    if ($keyConfig -and $keyConfig.errorCount -gt 0) {
        $keyConfig.errorCount = 0
        Set-ApiKeyPoolState -State $state
    }
}

# --- Jobs State for Async State Machine ---
function Get-JobsState {
    if (Test-Path $JobsFile) {
        try {
            $content = Get-Content $JobsFile -Raw
            $jobs = $content | ConvertFrom-Json
            return @($jobs)
        }
        catch {
            Write-Log "Warning: Failed to read jobs file $JobsFile. Starting fresh."
            return @()
        }
    }
    return @()
}

function Set-JobsState {
    param ([Parameter(Mandatory = $true)] $Jobs)
    $TempFile = "$JobsFile.tmp"
    try {
        $Jobs | ConvertTo-Json -Depth 5 | Out-File -FilePath $TempFile -Encoding utf8
        Move-Item -Path $TempFile -Destination $JobsFile -Force
    }
    catch {
        Write-Log "Error: Failed to write jobs file. Error: $_"
    }
}

# --- Start Crawl Job Sync ---
function Start-CrawlJob-Sync {
    Write-Verbose "Starting synchronous crawl job: $Url"

    $bodyHash = @{
        url = $Url
        max_depth = $MaxDepth
        extract_depth = $ExtractDepth
    }
    if (-not [string]::IsNullOrWhiteSpace($Instructions)) {
        $bodyHash.instructions = $Instructions
    }
    $bodyJson = $bodyHash | ConvertTo-Json -Depth 3

    $requestId = $null
    $response = $null

    if ($DryRun) {
        Write-Verbose "DryRun: Simulating key trial (no state update)"
        Write-Log "DryRun: Simulated key trial for '$Url' (no state machine update)"
        $requestId = "dryrun-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
        $response = @{
            base_url = $Url
            results = @(
                @{
                    url = $Url
                    raw_content = "# Simulated Content from $Url`n`nFake raw_content in DryRun mode for Tavily Crawl (synchronous test for processor.ps1)."
                },
                @{
                    url = "$Url/subpage"
                    raw_content = "## Subpage Simulation`nAdditional fake content for testing per-result MD files."
                }
            )
            response_time = [math]::Round((Get-Random -Minimum 5 -Maximum 30), 2)
            request_id = $requestId
        }
        Write-Log "DryRun: Simulated synchronous crawl for '$Url'. Fake ID: $requestId"
        Write-Host "DRY RUN: Simulated complete. Fake ID: $requestId (2 results)"
    } else {
        $triedKeys = @()
        do {
            $keyConfig = Get-NextApiKey
            if (-not $keyConfig) {
                throw "No active API keys available."
            }
            $triedKeys += $keyConfig.key.Substring(0, 8) + "..."
            $key = $keyConfig.key
            Write-Verbose "Trying key $($keyConfig.key.Substring(0, 8))... "

            $headers = @{
                "Content-Type" = "application/json; charset=utf-8"
                "Authorization" = "Bearer $key"
            }

            try {
                $responseText = Invoke-TavilyApi -Method "Post" -Headers $headers -Body $bodyJson
                $response = $responseText
                $requestId = $response.request_id
                Mark-ApiKeySuccess -Key $key
                Write-Log "Synchronous crawl success: '$Url' (key $($key.Substring(0,8))...). ID: $requestId"
                break
            }
            catch {
                Mark-ApiKeyError -Key $key
                $errMsg = $_.Exception.Message
                if ($_.Exception.Response) {
                    $statusCode = $_.Exception.Response.StatusCode.value__
                    $errMsg += " - Status: $statusCode"
                }
                Write-Log "Key failed $($triedKeys[-1]) (attempt $($triedKeys.Count)). Error: $errMsg"
                if ($triedKeys.Count -ge (Get-ApiKeyPoolState).keys.Where({ $_.active }).Count) {
                    throw "All keys failed: $($triedKeys -join ', '). Last error: $errMsg"
                }
            }
        } while ($true)
    }

    # Save to Temp
    $DocsDir = Join-Path $BaseDir ".Docs"
    $TempDir = Join-Path $DocsDir "Temp"
    if (-not (Test-Path $DocsDir)) { New-Item -Path $DocsDir -ItemType Directory -Force | Out-Null }
    if (-not (Test-Path $TempDir)) { New-Item -Path $TempDir -ItemType Directory -Force | Out-Null }

    $resultPath = Join-Path $TempDir "$requestId.json"
    $tempResultPath = "$resultPath.tmp"
    $response | ConvertTo-Json -Depth 10 | Out-File -FilePath $tempResultPath -Encoding utf8
    Move-Item -Path $tempResultPath -Destination $resultPath -Force

    Write-Host "Sync crawl completed. ID: $requestId. Saved to: $resultPath"
    Write-Log "Synchronous crawl done: '$Url'. Saved to $resultPath"

    return $requestId, $resultPath
}

# --- Start Crawl Job Async ---
function Start-CrawlJob-Async {
    Write-Verbose "Starting async crawl job: $Url"

    $bodyHash = @{
        url = $Url
        max_depth = $MaxDepth
        extract_depth = $ExtractDepth
    }
    if (-not [string]::IsNullOrWhiteSpace($Instructions)) {
        $bodyHash.instructions = $Instructions
    }
    $bodyJson = $bodyHash | ConvertTo-Json -Depth 3

    $requestId = $null

    if ($DryRun) {
        Write-Verbose "DryRun Async: Simulating key trial (no state update)"
        Write-Log "DryRun Async: Simulated key trial for '$Url' (no state machine update)"
        $requestId = "dryrun-async-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
        Write-Log "DryRun Async: Simulated POST for '$Url'. Fake ID: $requestId"
        Write-Host "DRY RUN ASYNC: Fake ID: $requestId (added to jobs state)"
    } else {
        $keyConfig = Get-NextApiKey
        if (-not $keyConfig) { throw "No active keys for async POST." }
        $key = $keyConfig.key
        $headers = @{ "Content-Type" = "application/json; charset=utf-8"; "Authorization" = "Bearer $key" }

        try {
            $responseText = Invoke-TavilyApi -Method "Post" -Headers $headers -Body $bodyJson
            $response = $responseText
            $requestId = $response.request_id
            Mark-ApiKeySuccess -Key $key
            Write-Log "Async POST success: '$Url' (key $($key.Substring(0,8))...). ID: $requestId"
        }
        catch {
            Mark-ApiKeyError -Key $key
            throw "Async POST failed: $($_.Exception.Message)"
        }
    }

    # Add to state machine
    $jobs = Get-JobsState
    $newJob = [PSCustomObject]@{
        request_id = $requestId
        url = $Url
        params = $bodyHash
        status = "pending"
        last_updated = (Get-Date).ToUniversalTime().ToString("o")
        attempts = 0
        note = if ($DryRun) { "DryRun Async Pending" } else { "Pending" }
        result_path = $null
    }
    $jobs += $newJob
    Set-JobsState -Jobs $jobs

    Write-Verbose "Async job added to state machine: $requestId"
    return $requestId
}

# --- Poll Jobs (State Machine) ---
function Poll-Jobs {
    param ([switch]$DryRun)

    Write-Verbose "Polling state machine for pending/processing jobs"

    $jobs = Get-JobsState
    $pendingJobs = $jobs | Where-Object { $_.status -in @("pending", "processing") }
    if ($pendingJobs.Count -eq 0) {
        Write-Host "No pending/processing jobs."
        return
    }

    Write-Host "Polling $($pendingJobs.Count) job(s)."

    # Loop until no more pending/processing jobs or max retries exceeded
    while ($pendingJobs.Count -gt 0) {
        foreach ($job in $pendingJobs) {
            $requestId = $job.request_id
            $attempts = $job.attempts + 1

            if ($attempts -gt $MaxJobRetries) {
                $job.status = "failed"
                $job.note = "Max retries exceeded"
                $job.attempts = $attempts
                $job.last_updated = (Get-Date).ToUniversalTime().ToString("o")
                Write-Log "Job $requestId failed after $attempts attempts."
                continue
            }

            $pollInterval = [Math]::Min($InitialPollIntervalSec * [Math]::Pow(2, $attempts - 1), $MaxPollIntervalSec)
            if (-not $DryRun) { Start-Sleep -Seconds $pollInterval } else { Write-Verbose "DryRun: Simulate delay ${pollInterval}s" }

            Write-Verbose "Polling $requestId (attempt $attempts)"

            if ($DryRun) {
                $newStatus = if ($attempts -eq 1) { "processing" } elseif ($attempts -eq 2) { "completed" } else { "processing" }
                $job.status = $newStatus
                $job.attempts = $attempts
                $job.last_updated = (Get-Date).ToUniversalTime().ToString("o")
                $job.note = "DryRun: $newStatus (attempt $attempts)"

                if ($newStatus -eq "completed") {
                    $tempDir = Join-Path $BaseDir ".Docs/Temp"
                    if (-not (Test-Path $tempDir)) { New-Item -Path $tempDir -ItemType Directory -Force | Out-Null }
                    $resultFile = Join-Path $tempDir "$requestId.json"
                    $tempFile = "$resultFile.tmp"
                    $fakeResponse = @{ base_url = $job.url; results = @(
                        @{ url = $job.url; raw_content = "Fake async content 1" },
                        @{ url = "$($job.url)/sub"; raw_content = "Fake async content 2" }
                    ); response_time = 10.5; request_id = $requestId }
                    $fakeResponse | ConvertTo-Json -Depth 10 | Out-File -FilePath $tempFile -Encoding utf8
                    Move-Item -Path $tempFile -Destination $resultFile -Force
                    $job.result_path = $resultFile
                    $job.note += "; Fake result saved"
                    Write-Host "DryRun: Job $requestId completed. Fake saved to $resultFile"
                }
                continue
            }

            $keyConfig = Get-NextApiKey
            if (-not $keyConfig) {
                $job.note = "No key for poll (attempt $attempts)"
                $job.attempts = $attempts
                continue
            }
            $key = $keyConfig.key
            $pollUrl = "$ApiUrl`?request_id=$requestId"
            $headers = @{ "Authorization" = "Bearer $key" }

            try {
                $statusResponseText = Invoke-TavilyApi -Method "Get" -Headers $headers -RequestId $requestId
                $statusResponse = $statusResponseText
                if ($statusResponse.status) {
                    $newStatus = $statusResponse.status
                } else {
                    $newStatus = "unknown"
                }
                Mark-ApiKeySuccess -Key $key

                $job.status = $newStatus
                $job.attempts = $attempts
                $job.last_updated = (Get-Date).ToUniversalTime().ToString("o")

                if ($newStatus -eq "completed") {
                    $tempDir = Join-Path $BaseDir ".Docs/Temp"
                    if (-not (Test-Path $tempDir)) { New-Item -Path $tempDir -ItemType Directory -Force | Out-Null }
                    $resultFile = Join-Path $tempDir "$requestId.json"
                    $tempFile = "$resultFile.tmp"
                    $statusResponse | ConvertTo-Json -Depth 10 | Out-File -FilePath $tempFile -Encoding utf8
                    Move-Item -Path $tempFile -Destination $resultFile -Force
                    $job.result_path = $resultFile
                    Write-Host "Job $requestId completed. Saved to $resultFile"
                } elseif ($newStatus -eq "processing") {
                    $job.note = "Processing (attempt $attempts)"
                } elseif ($newStatus -eq "failed") {
                    $job.status = "failed"
                    if ($statusResponse.error) {
                        $job.note = $statusResponse.error
                    } else {
                        $job.note = "Failed (attempt $attempts)"
                    }
                } else {
                    $job.note = "Status: $newStatus"
                }
            }
            catch {
                Mark-ApiKeyError -Key $key
                $job.attempts = $attempts
                $job.note = "Poll error: $($_.Exception.Message)"
            }
        }

        Set-JobsState -Jobs $jobs
        $jobs = Get-JobsState  # Refresh after update
        $pendingJobs = $jobs | Where-Object { $_.status -in @("pending", "processing") }
        if ($DryRun -and $pendingJobs.Count -eq 0) { break }  # DryRun: Stop after simulation
        Write-Log "State machine poll cycle complete. Remaining pending: $($pendingJobs.Count)"
    }
}

# --- Tavily API Call with UTF-8 Encoding ---
function Invoke-TavilyApi {
    param (
        [string]$Method = "Post",
        [hashtable]$Headers,
        [string]$Body = $null,
        [string]$RequestId = $null  # For GET poll
    )
    $requestUri = if ($Method -eq "Get" -and $RequestId) { "$ApiUrl`?request_id=$RequestId" } else { $ApiUrl }
    $request = [System.Net.HttpWebRequest]::Create($requestUri)
    $request.Method = $Method
    $request.ContentType = $Headers["Content-Type"]
    $request.Headers.Add("Authorization", $Headers["Authorization"])
    if ($Body) {
        $request.ContentLength = $Body.Length
        $stream = $request.GetRequestStream()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
    }
    $response = $request.GetResponse()
    $responseStream = $response.GetResponseStream()
    $reader = New-Object System.IO.StreamReader($responseStream, [System.Text.Encoding]::UTF8)
    $responseText = $reader.ReadToEnd()
    $reader.Close()
    $responseStream.Close()
    $response.Close()
    return $responseText | ConvertFrom-Json
}

# --- Slug Generation from Processor ---
function Get-SlugFromUrl {
    param ([string]$Url, [string]$Content)
    $baseSlug = ($Url -split '/')[-1] -replace '\.(html|htm)$', ''
    if ([string]::IsNullOrWhiteSpace($baseSlug)) { $baseSlug = 'index' }
    if ([string]::IsNullOrEmpty($Content)) {
        $contentHash = "empty"
    } else {
        $md5 = [System.Security.Cryptography.MD5]::Create()
        $hashBytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Content.Substring(0, [Math]::Min(100, $Content.Length))))
        $contentHash = ($hashBytes | ForEach-Object { $_.ToString('x2') }) -join ''
        $md5.Dispose()
    }
    return "${baseSlug}_${($contentHash.Substring(0,8))}.md"
}

# --- Process Temp Files from Processor ---
function Process-TempFiles {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FolderName
    )

    $DocsDir = Join-Path $BaseDir ".Docs"
    $TargetDir = Join-Path $DocsDir $FolderName
    $TempDir = Join-Path $DocsDir "Temp"

    try {
        if (-not (Test-Path $DocsDir)) { New-Item -Path $DocsDir -ItemType Directory -Force | Out-Null }
        if (-not (Test-Path $TargetDir)) { New-Item -Path $TargetDir -ItemType Directory -Force | Out-Null }
        
        if (-not (Test-Path $TempDir) -or ((Get-ChildItem $TempDir | Where-Object { $_.Name -like "*.json" }).Count -eq 0)) {
            Write-Host "No JSON files to process in .Docs/Temp."
            return
        }

        $jsonFiles = Get-ChildItem -Path $TempDir | Where-Object { $_.Name -like "*.json" }
        Write-Host "Processing $($jsonFiles.Count) JSON files for folder '$FolderName'..."
        Write-Log "Started processing $($jsonFiles.Count) Temp JSON files for '$FolderName'."

        foreach ($file in $jsonFiles) {
            try {
                $response = Get-Content $file.FullName -Raw -Encoding utf8 | ConvertFrom-Json
                $results = $response.results
                if (-not $results -or $results.Count -eq 0) {
                    Write-Warning "Skipping $($file.Name): No results."
                    continue
                }

                foreach ($result in $results) {
                    $slug = Get-SlugFromUrl -Url $result.url -Content $result.raw_content
                    $mdPath = Join-Path $TargetDir $slug
                    $tempMdPath = "$mdPath.tmp"

                    $mdContent = "# $($result.url)`n`n$($result.raw_content)"
                    $mdContent | Out-File -FilePath $tempMdPath -Encoding utf8
                    Move-Item -Path $tempMdPath -Destination $mdPath -Force

                    Write-Host "Created MD in '$FolderName': $slug (from $($result.url))"
                }

                Write-Log "Completed $($file.Name) -> $($results.Count) MD files into '$FolderName'."
            }
            catch {
                Write-Error "Failed to process $($file.Name): $_"
                Write-Log "Error: $($file.Name) - $_"
            }
        }

        # Clear Temp
        Remove-Item -Path "$TempDir\*" -Force -ErrorAction SilentlyContinue
        Write-Host ".Docs/Temp cleared."
        Write-Log "Temp cleared. Processing done."
    }
    catch {
        Write-Error "Processor error: $_"
        Write-Log "Unhandled error: $_"
        exit 1
    }
}

# --- Main Logic ---
try {
    if (-not (Test-Path $StateDir)) { New-Item -Path $StateDir -ItemType Directory -Force | Out-Null }

    $DocsDir = Join-Path $BaseDir ".Docs"
    $TempDir = Join-Path $DocsDir "Temp"
    if (-not (Test-Path $DocsDir)) { New-Item -Path $DocsDir -ItemType Directory -Force | Out-Null }
    if (-not (Test-Path $TempDir)) { New-Item -Path $TempDir -ItemType Directory -Force | Out-Null }

    if ($Process) {
        Process-TempFiles -FolderName $FolderName
        return
    }

    if ([string]::IsNullOrWhiteSpace($Url)) {
        throw "-Url is required when not in -Process mode."
    }

    $requestId = if ($Async) { Start-CrawlJob-Async } else { Start-CrawlJob-Sync }

    if ($AutoPoll -and $Async) {
        Poll-Jobs -DryRun:$DryRun
    } elseif ($Async) {
        Write-Output "Async job started: $requestId. Use -AutoPoll or run Poll-Jobs manually."
    } else {
        Write-Output "Sync job completed: $requestId."
    }

    # Auto-process Temp if not in -Process mode
    if (-not $Process) {
        $jsonFiles = Get-ChildItem -Path $TempDir -Filter "*.json" -ErrorAction SilentlyContinue
        if ($jsonFiles.Count -gt 0) {
            Write-Host "Auto-processing $($jsonFiles.Count) Temp files..."
            Process-TempFiles -FolderName $FolderName
        }
    }
}
catch {
    Write-Log "Error: $_"
    Write-Error "Error: $_"
    exit 1

}

Write-Log "Script finished."