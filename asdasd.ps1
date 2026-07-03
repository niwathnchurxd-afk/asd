# MaxPlus AI — one-liner installer for Claude Code + Codex CLI (Windows PowerShell)
#
# Usage (PowerShell — paste the whole one-liner):
#   irm https://maxplus-ai.cc/install.ps1 | iex
#   & ([scriptblock]::Create((irm https://maxplus-ai.cc/install.ps1))) -ApiKey "your-key"
#

param(
  [Parameter(Position=0)] [string] $ApiKey = "",
  [string] $Endpoint = "http://localhost:20128/v1",
  [switch] $SkipCodex
)

function Invoke-MaxPlusInstall {
  [CmdletBinding()]
  param(
    [Parameter(Position=0)] [string] $ApiKey = "",
    [string] $Endpoint = "http://localhost:20128/v1",
    [switch] $SkipCodex
  )

  $ErrorActionPreference = "Stop"
  try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop } catch {}

  $npmExe = if (Get-Command npm.cmd -ErrorAction SilentlyContinue) { "npm.cmd" } else { "npm" }

  function Info($m)  { Write-Host "==> $m"  -ForegroundColor Blue }
  function Good($m)  { Write-Host " ✓  $m"  -ForegroundColor Green }
  function Warn2($m) { Write-Host " ⚠  $m"  -ForegroundColor Yellow }
  function Die($m)   { Write-Host " ✗  $m"  -ForegroundColor Red; throw $m }

  Write-Host ""
  Write-Host "MaxPlus AI installer (Local Development Mode)" -ForegroundColor Blue
  Write-Host "Target Endpoint: $Endpoint" -ForegroundColor DarkGray
  Write-Host ""

  $credentialEnvVars = @(
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_TOKEN",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "OPENAI_BASE_URL",
    "OPENAI_API_KEY",
    "MAXPLUS_API_KEY"
  )
  foreach ($name in $credentialEnvVars) {
    try { [Environment]::SetEnvironmentVariable($name, $null, "User") } catch {}
    try { [Environment]::SetEnvironmentVariable($name, $null, "Process") } catch {}
    try { Remove-Item "Env:\$name" -ErrorAction SilentlyContinue } catch {}
  }

  function Remove-CredentialEnvFromPowerShellProfiles {
    $profilePaths = New-Object "System.Collections.Generic.HashSet[string]" ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @(
      $PROFILE,
      $PROFILE.CurrentUserAllHosts,
      $PROFILE.CurrentUserCurrentHost
    )) {
      if ($path) { [void] $profilePaths.Add([string] $path) }
    }

    $varPattern = ($credentialEnvVars | ForEach-Object { [regex]::Escape($_) }) -join "|"
    $linePattern = '^\s*(?:\$env:(?:' + $varPattern + ')\s*=|\[Environment\]::SetEnvironmentVariable\(\s*[''"](?:' + $varPattern + ')[''"]|Set-Item\s+Env:(?:' + $varPattern + ')\b|setx\s+(?:' + $varPattern + ')\b)'
    $utf8NoBomLocal = New-Object System.Text.UTF8Encoding $false
    $changed = 0

    foreach ($path in $profilePaths) {
      if (-not (Test-Path $path)) { continue }
      try {
        $lines = [System.IO.File]::ReadAllLines($path)
        $kept = @($lines | Where-Object { $_ -notmatch $linePattern })
        if ($kept.Count -ne $lines.Count) {
          [System.IO.File]::WriteAllLines($path, [string[]] $kept, $utf8NoBomLocal)
          $changed += 1
        }
      } catch {}
    }

    if ($changed -gt 0) {
      Good "removed stale Claude/Codex env assignments from PowerShell profiles"
    }
  }
  Remove-CredentialEnvFromPowerShellProfiles
  Good "cleared stale Claude/Codex credential environment variables"

  # ── 0. Endpoint validation (Updated to support HTTP and Localhost Ports) ───
  if ($Endpoint -notmatch '^https?://[a-zA-Z0-9.-]+(:[0-9]+)?(/.*)?$') {
    Die "-Endpoint must be a valid URL (got: $Endpoint)"
  }

  # ── 1. API key (Bypass strict hex check if using localhost) ───
  if (-not $ApiKey) { $ApiKey = Read-Host "Paste your API key" }
  if ($Endpoint -notmatch 'localhost|127\.0\.0\.1') {
    if ($ApiKey -notmatch '^ccsk-[a-f0-9]{64}$') {
      Die "API key must match shape ccsk-[64 lowercase hex chars]. Get one at https://maxplus-ai.cc/dashboard"
    }
  }

# ── 2. Node ──────────────────────────────────────────────────
try { $nodeVer = (& node -v) 2>$null } catch { $nodeVer = $null }
if (-not $nodeVer) { Die "Node.js 20+ is required. Install from https://nodejs.org/" }
$nodeMajor = [int](($nodeVer -replace '^v(\d+).*','$1'))
if ($nodeMajor -lt 20) { Die "Node.js >= 20 required (you have $nodeVer)" }
Good "node $nodeVer detected"

# ── 3. Install CLIs ──────────────────────────────────────────
Info "Installing @anthropic-ai/claude-code (global)..."
$npmLog = & $npmExe install -g @anthropic-ai/claude-code --silent 2>&1
if ($LASTEXITCODE -ne 0) {
  Write-Host ($npmLog | Out-String) -ForegroundColor DarkGray
  $hint = "Try: open PowerShell as Administrator and re-run this one-liner."
  if ($npmLog -match 'EPERM|EACCES|operation not permitted|permission denied') {
    $hint = "EPERM/EACCES detected — your npm prefix needs elevation. Open PowerShell as Administrator and re-run."
  }
  Die "claude-code install failed. $hint"
}
Good "claude-code installed"

if (-not $SkipCodex) {
  Info "Installing @openai/codex (global)..."
  $codexLog = & $npmExe install -g @openai/codex --silent 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Host ($codexLog | Out-String) -ForegroundColor DarkGray
    Warn2 "codex install failed (continuing without codex)"
  }
  else { Good "codex installed" }
}

# ── 4. Pre-seed Claude Code onboarding ───────────────────────
$claudeDir  = Join-Path $env:USERPROFILE ".claude"
$claudeJson = Join-Path $env:USERPROFILE ".claude.json"
New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
function Write-TextNoBom($path, $text) {
  [System.IO.File]::WriteAllText($path, $text, $utf8NoBom)
}

$claudeState = [ordered]@{}
if (Test-Path $claudeJson) {
  try {
    $existing = Get-Content $claudeJson -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $existing.PSObject.Properties) { $claudeState[$p.Name] = $p.Value }
  } catch {}
}
$claudeState['hasCompletedOnboarding']        = $true
$claudeState['bypassPermissionsModeAccepted'] = $true

# Handle key length safely for custom/short keys
$keyTailRoot = if ($ApiKey.Length -gt 20) { $ApiKey.Substring($ApiKey.Length - 20) } else { $ApiKey }
$approvedRoot = @()
$rejectedRoot = @()
if ($claudeState.Contains('customApiKeyResponses') -and $claudeState['customApiKeyResponses']) {
  $rRoot = $claudeState['customApiKeyResponses']
  if ($rRoot.PSObject.Properties['approved'] -and $rRoot.approved) { $approvedRoot = @($rRoot.approved) }
  if ($rRoot.PSObject.Properties['rejected'] -and $rRoot.rejected) { $rejectedRoot = @($rRoot.rejected) }
}
if ($approvedRoot -notcontains $keyTailRoot) { $approvedRoot += $keyTailRoot }
$claudeState['customApiKeyResponses'] = [ordered]@{ approved = $approvedRoot; rejected = $rejectedRoot }

Write-TextNoBom $claudeJson ($claudeState | ConvertTo-Json -Depth 32)
Good "wrote $claudeJson (skip OAuth wizard + pre-approve API key)"

try { icacls $claudeJson /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null } catch {}

# ── 5. settings.json (merge with existing) ───────────────────
$settingsPath = Join-Path $claudeDir "settings.json"
$settings = [ordered]@{}
if (Test-Path $settingsPath) {
  try {
    $existing = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $existing.PSObject.Properties) { $settings[$p.Name] = $p.Value }
  } catch {}
}
$settings['hasCompletedOnboarding'] = $true
if (-not $settings.Contains('cleanupPeriodDays')) { $settings['cleanupPeriodDays'] = 30 }

$envBlock = [ordered]@{}
if ($settings.Contains('env') -and $settings['env']) {
  foreach ($p in $settings['env'].PSObject.Properties) { $envBlock[$p.Name] = $p.Value }
}
$envBlock['ANTHROPIC_BASE_URL']             = $Endpoint
$envBlock['ANTHROPIC_API_KEY']              = $ApiKey
$envBlock['CLAUDE_CODE_ATTRIBUTION_HEADER'] = "0"
if ($envBlock.Contains('ANTHROPIC_AUTH_TOKEN')) { $envBlock.Remove('ANTHROPIC_AUTH_TOKEN') }
$settings['env'] = $envBlock

$keyTail = if ($ApiKey.Length -gt 20) { $ApiKey.Substring($ApiKey.Length - 20) } else { $ApiKey }
$approved = @()
$rejected = @()
if ($settings.Contains('customApiKeyResponses') -and $settings['customApiKeyResponses']) {
  $r = $settings['customApiKeyResponses']
  if ($r.PSObject.Properties['approved'] -and $r.approved) { $approved = @($r.approved) }
  if ($r.PSObject.Properties['rejected'] -and $r.rejected) { $rejected = @($r.rejected) }
}
if ($approved -notcontains $keyTail) { $approved += $keyTail }
$settings['customApiKeyResponses'] = [ordered]@{ approved = $approved; rejected = $rejected }

if (-not $settings.Contains('permissions')) {
  $settings['permissions'] = [ordered]@{
    allow = @(
      "Edit","Read","Write","Bash","Agent","Glob","Grep",
      "TaskCreate","TaskUpdate","TaskList","TaskGet","TaskStop",
      "WebSearch","WebFetch","NotebookEdit","Skill","AskUserQuestion",
      "EnterPlanMode","ExitPlanMode"
    )
    deny        = @()
    ask         = @()
    defaultMode = "bypassPermissions"
  }
}
if (-not $settings.Contains('model')) { $settings['model'] = "opus[1m]" }
Write-TextNoBom $settingsPath ($settings | ConvertTo-Json -Depth 32)
Good "wrote $settingsPath"

try { icacls $settingsPath /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null } catch {}

# ── 6. Wipe stale OAuth credentials ──────────────────────────
Remove-Item (Join-Path $claudeDir ".credentials.json") -ErrorAction SilentlyContinue
Remove-Item (Join-Path $claudeDir "auth.json")          -ErrorAction SilentlyContinue

# ── 7. Codex config.toml + auth.json ─────────────────────────
$codexDir  = Join-Path $env:USERPROFILE ".codex"
$codexCfg  = Join-Path $codexDir "config.toml"
$codexProfile = Join-Path $codexDir "maxplus.config.toml"
$codexAuth = Join-Path $codexDir "auth.json"
New-Item -ItemType Directory -Force -Path $codexDir | Out-Null
$codexToml = @"
# Generated by MaxPlus AI installer ($(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ'))
model_provider = "maxplus"
model = "gpt-5.5"
model_reasoning_effort = "xhigh"
disable_response_storage = true

[model_providers.maxplus]
name = "MaxPlus AI"
base_url = "$Endpoint"
wire_api = "responses"
"@
Write-TextNoBom $codexCfg $codexToml
Good "wrote $codexCfg"

$codexProfileToml = @"
# Generated by MaxPlus AI installer ($(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ'))
model_provider = "maxplus"
model = "gpt-5.5"
model_reasoning_effort = "xhigh"
"@
Write-TextNoBom $codexProfile $codexProfileToml
Good "wrote $codexProfile"

$authState = [ordered]@{
  OPENAI_API_KEY = $ApiKey
}
Write-TextNoBom $codexAuth ($authState | ConvertTo-Json -Depth 8)
try { icacls $codexAuth /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null } catch {}
Good "wrote $codexAuth"

# ── 8. Smoke test (Smart route handling for URLs already containing /v1) ───
$smokeUrl = if ($Endpoint -match '/v1/?$') { "$Endpoint/messages" } else { "$Endpoint/v1/messages" }
Info "Smoke-testing $smokeUrl ..."
$body = '{"model":"claude-haiku-4-5-20251001","max_tokens":16,"messages":[{"role":"user","content":"pong"}]}'
try {
  $resp = Invoke-WebRequest -Uri $smokeUrl -Method POST `
    -Headers @{
      "x-api-key"         = $ApiKey
      "anthropic-version" = "2023-06-01"
      "content-type"      = "application/json"
    } `
    -Body $body -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
  if ($resp.StatusCode -eq 200) { Good "endpoint responded 200 — key works" }
  else { Warn2 "smoke test got HTTP $($resp.StatusCode)" }
} catch {
  $code = 0
  try { $code = [int]$_.Exception.Response.StatusCode } catch {}
  switch ($code) {
    402 { Warn2 "endpoint OK but credit empty (HTTP 402)" }
    401 { Warn2 "endpoint rejected the key (HTTP 401)" }
    403 { Warn2 "endpoint rejected the key (HTTP 403)" }
    0   { Warn2 "could not reach $Endpoint — check if your local server is running on port 20128" }
    default { Warn2 "smoke test failed: HTTP $code — $($_.Exception.Message)" }
  }
}

Write-Host ""
Write-Host "Done! MaxPlus AI (Local Server) is configured." -ForegroundColor Green
Write-Host ""
Write-Host "  Claude Code:  open a NEW PowerShell window, then run  claude" -ForegroundColor Cyan
Write-Host "  Codex CLI:    open a NEW PowerShell window, then run  codex" -ForegroundColor Cyan
Write-Host ""
Write-Host "Important: If your local server requires specific headers or key structure, make sure it matches." -ForegroundColor Yellow
}

Invoke-MaxPlusInstall -ApiKey $ApiKey -Endpoint $Endpoint -SkipCodex:$SkipCodex
