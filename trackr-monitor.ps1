<#
    Trackr opening monitor (multi-page)
    -----------------------------------
    Polls one or more Trackr programmes pages and sends an ntfy notification
    ONLY when a programme's application transitions to "open" (a bank's
    application opening up). Every other change -- notes, closing-date edits,
    new "not-open" rows, rows going "closed", renames -- is tracked but never
    notified.

    Each page ("tracker") in config.json has its own params, its own ntfy topic,
    and its own baseline state file (state-<name>.json), so pages never blast
    each other's alerts and each seeds silently on first run.

    "Open" mirrors the Trackr site's exact rule:
        not-open : no openingDate, or openingDate is in the future
        closed   : closingDate exists and its end-of-day has passed
        open     : otherwise (openingDate has passed and not yet closed)
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [switch]$DryRun,      # print notifications instead of sending them
    [switch]$Reset,       # discard saved state and re-seed baselines
    [string]$Only         # optional: only process the tracker with this name
)

$ErrorActionPreference = 'Stop'
$dir     = $PSScriptRoot
$logFile = Join-Path $dir 'monitor.log'

function Log([string]$msg) {
    $line = ('{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $msg)
    try { Add-Content -Path $logFile -Value $line -Encoding utf8 } catch { }
    Write-Host $line
}

$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

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

function Send-Ntfy($p, $server, $topic, $label) {
    # Title header must be latin-1 safe -> keep ASCII; rich text goes in the body.
    $title = ('{0}: application OPEN' -f $p.company.name)
    $lines = @($p.name)
    if (-not [string]::IsNullOrWhiteSpace($p.closingDate)) {
        $lines += ('Closes: ' + ([DateTimeOffset]::Parse($p.closingDate)).ToString('d MMM yyyy'))
    }
    $lines += ("Opened on the Trackr - $label")
    $body = ($lines -join "`n")

    $headers = @{ Title = $title; Priority = 'high'; Tags = 'rotating_light,briefcase' }
    if (-not [string]::IsNullOrWhiteSpace($p.url)) { $headers['Click'] = $p.url }

    if ($DryRun) {
        Write-Host "--- would notify [$topic] ---`nTitle: $title`n$body`nClick: $($p.url)`n"
        return
    }
    Invoke-RestMethod -Uri "$server/$topic" -Method Post `
        -Body ([Text.Encoding]::UTF8.GetBytes($body)) -Headers $headers -TimeoutSec 30 | Out-Null
}

# --- process each tracker ---------------------------------------------------
foreach ($t in $cfg.trackers) {
    if ($Only -and $t.name -ne $Only) { continue }

    $server = if ($env:NTFY_SERVER) { $env:NTFY_SERVER } elseif ($t.ntfyServer) { $t.ntfyServer } else { 'https://ntfy.sh' }
    # Topic comes from the env var named by the tracker (a GitHub secret), or an
    # inline ntfyTopic for local use.
    $topic = $null
    if ($t.ntfyTopicEnv) { $topic = [Environment]::GetEnvironmentVariable($t.ntfyTopicEnv) }
    if ([string]::IsNullOrWhiteSpace($topic) -and $t.ntfyTopic) { $topic = $t.ntfyTopic }

    if ([string]::IsNullOrWhiteSpace($topic) -and -not $DryRun) {
        Log "[$($t.name)] SKIP: no ntfy topic (env $($t.ntfyTopicEnv) unset)"
        continue
    }

    $stateFile = Join-Path $dir ("state-{0}.json" -f $t.name)

    # fetch
    $query = @{ region = $t.region; industry = $t.industry; season = $t.season; type = $t.type }
    try {
        $programmes = Invoke-RestMethod -Uri "$($cfg.apiBase)/programmes" -Method Get -Body $query -TimeoutSec 30
    }
    catch {
        Log "[$($t.name)] FETCH ERROR: $($_.Exception.Message)"
        continue   # don't let one page's failure abort the others / the state commit
    }
    if ($null -eq $programmes) { Log "[$($t.name)] FETCH ERROR: empty response"; continue }

    # previous state
    $prevMap  = @{}
    $firstRun = $true
    if ((Test-Path $stateFile) -and -not $Reset) {
        $firstRun = $false
        foreach ($e in (Get-Content $stateFile -Raw | ConvertFrom-Json)) { $prevMap[$e.id] = $e.status }
    }

    # diff
    $newState = New-Object System.Collections.Generic.List[object]
    $opened   = New-Object System.Collections.Generic.List[object]
    foreach ($p in $programmes) {
        $status = Get-ProgrammeStatus $p
        $newState.Add([pscustomobject]@{ id = $p.id; status = $status; company = $p.company.name; name = $p.name })
        if ($status -eq 'open') {
            $wasOpen = $prevMap.ContainsKey($p.id) -and $prevMap[$p.id] -eq 'open'
            if (-not $firstRun -and -not $wasOpen) { $opened.Add($p) }
        }
    }

    # notify
    $label = if ($t.label) { $t.label } else { $t.name }
    foreach ($p in $opened) {
        try { Send-Ntfy $p $server $topic $label; Log "[$($t.name)] NOTIFY opened -> ${topic}: $($p.company.name) - $($p.name)" }
        catch { Log "[$($t.name)] NTFY ERROR for $($p.company.name): $($_.Exception.Message)" }
    }

    # persist
    $newState | ConvertTo-Json -Depth 4 | Set-Content -Path $stateFile -Encoding utf8
    $openCount = ($newState | Where-Object { $_.status -eq 'open' }).Count
    if ($firstRun) {
        Log "[$($t.name)] Baseline seeded: $($newState.Count) programmes, $openCount currently open (no alerts sent)."
    } else {
        Log "[$($t.name)] Checked $($newState.Count) programmes, $openCount open, $($opened.Count) newly opened."
    }
}
