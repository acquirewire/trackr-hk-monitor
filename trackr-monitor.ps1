<#
    Trackr opening monitor
    -----------------------
    Polls the Trackr programmes API for a given tracker page and sends an ntfy
    notification ONLY when a programme's application transitions to "open"
    (i.e. a bank's application opens up). Any other change on the site -- notes,
    closing-date edits, new "not-open" rows, rows going "closed", renames -- is
    tracked but never notified.

    "Open" is computed with the exact same rule the Trackr website uses:
        not-open : no openingDate, or openingDate is in the future
        closed   : closingDate exists and its end-of-day has passed
        open     : otherwise (openingDate has passed and not yet closed)

    First run seeds a baseline silently (no alert blast for already-open rows).
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [switch]$DryRun,      # print notifications instead of sending them
    [switch]$Reset        # discard saved state and re-seed baseline
)

$ErrorActionPreference = 'Stop'
$dir       = $PSScriptRoot
$stateFile = Join-Path $dir 'state.json'
$logFile   = Join-Path $dir 'monitor.log'

function Log([string]$msg) {
    $line = ('{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $msg)
    try { Add-Content -Path $logFile -Value $line -Encoding utf8 } catch { }
    Write-Host $line
}

# --- config -----------------------------------------------------------------
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
# Environment variables win over config.json (used by CI / GitHub Actions secrets).
$ntfyServer = if ($env:NTFY_SERVER) { $env:NTFY_SERVER } else { $cfg.ntfyServer }
$ntfyTopic  = if ($env:NTFY_TOPIC)  { $env:NTFY_TOPIC }  else { $cfg.ntfyTopic }
if (($null -eq $ntfyTopic -or $ntfyTopic -eq 'REPLACE_WITH_YOUR_TOPIC') -and -not $DryRun) {
    Log 'ERROR: ntfy topic not set (env NTFY_TOPIC or config.json)'
    throw 'Set NTFY_TOPIC (env) or ntfyTopic (config.json) before running, or use -DryRun.'
}

# --- fetch ------------------------------------------------------------------
$query = @{ region = $cfg.region; industry = $cfg.industry; season = $cfg.season; type = $cfg.type }
try {
    $programmes = Invoke-RestMethod -Uri "$($cfg.apiBase)/programmes" -Method Get -Body $query -TimeoutSec 30
}
catch {
    Log "FETCH ERROR: $($_.Exception.Message)"
    exit 1
}
if ($null -eq $programmes) { Log 'FETCH ERROR: empty response'; exit 1 }

# --- status computation (mirrors the Trackr site) ---------------------------
$nowUtc = [DateTimeOffset]::UtcNow
function Get-ProgrammeStatus($p) {
    if ([string]::IsNullOrWhiteSpace($p.openingDate)) { return 'not-open' }
    $open = [DateTimeOffset]::Parse($p.openingDate, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
    if ($open -gt $nowUtc) { return 'not-open' }
    if (-not [string]::IsNullOrWhiteSpace($p.closingDate)) {
        # end-of-day of the closing date (UTC midnight + 1 day)
        $close = [DateTimeOffset]::Parse($p.closingDate, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).Date.AddDays(1)
        if ([DateTimeOffset]::new($close, [TimeSpan]::Zero) -le $nowUtc) { return 'closed' }
    }
    return 'open'
}

# --- previous state ---------------------------------------------------------
$prevMap  = @{}
$firstRun = $true
if ((Test-Path $stateFile) -and -not $Reset) {
    $firstRun = $false
    foreach ($e in (Get-Content $stateFile -Raw | ConvertFrom-Json)) { $prevMap[$e.id] = $e.status }
}

# --- diff -------------------------------------------------------------------
$newState = New-Object System.Collections.Generic.List[object]
$opened   = New-Object System.Collections.Generic.List[object]

foreach ($p in $programmes) {
    $status = Get-ProgrammeStatus $p
    $newState.Add([pscustomobject]@{
        id      = $p.id
        status  = $status
        company = $p.company.name
        name    = $p.name
    })
    if ($status -eq 'open') {
        $wasOpen = $prevMap.ContainsKey($p.id) -and $prevMap[$p.id] -eq 'open'
        if (-not $firstRun -and -not $wasOpen) { $opened.Add($p) }
    }
}

# --- notify -----------------------------------------------------------------
function Send-Ntfy($p) {
    # Title header must be latin-1 safe -> keep ASCII; rich text goes in the body.
    $title = ('{0}: application OPEN' -f $p.company.name)
    $lines = @($p.name)
    if (-not [string]::IsNullOrWhiteSpace($p.closingDate)) {
        $lines += ('Closes: ' + ([DateTimeOffset]::Parse($p.closingDate)).ToString('d MMM yyyy'))
    }
    $lines += 'Opened on the Trackr - Hong Kong Finance, Summer Internships'
    $body = ($lines -join "`n")

    $headers = @{ Title = $title; Priority = 'high'; Tags = 'rotating_light,briefcase' }
    if (-not [string]::IsNullOrWhiteSpace($p.url)) { $headers['Click'] = $p.url }

    if ($DryRun) {
        Write-Host "--- would notify ---`nTitle: $title`n$body`nClick: $($p.url)`n"
        return
    }
    Invoke-RestMethod -Uri "$ntfyServer/$ntfyTopic" -Method Post `
        -Body ([Text.Encoding]::UTF8.GetBytes($body)) -Headers $headers -TimeoutSec 30 | Out-Null
}

foreach ($p in $opened) {
    try { Send-Ntfy $p; Log "NOTIFY opened: $($p.company.name) - $($p.name)" }
    catch { Log "NTFY ERROR for $($p.company.name): $($_.Exception.Message)" }
}

# --- persist ----------------------------------------------------------------
$newState | ConvertTo-Json -Depth 4 | Set-Content -Path $stateFile -Encoding utf8

$openCount = ($newState | Where-Object { $_.status -eq 'open' }).Count
if ($firstRun) {
    Log "Baseline seeded: $($newState.Count) programmes, $openCount currently open (no alerts sent)."
} else {
    Log "Checked $($newState.Count) programmes, $openCount open, $($opened.Count) newly opened."
}
