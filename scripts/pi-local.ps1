<#
  pi-local.ps1 - run the Pi coding agent with local models ONLY.
    default : llamacpp/local          (llama-server http://127.0.0.1:8080, start-agent.ps1)
    -Fast   : ollama/qwen3.5-9b:iq4xs (Ollama http://127.0.0.1:11434; the Ollama app is started through
              Explorer when it isn't running - lib-ollama.ps1)
  Every other argument goes to `pi` untouched (working directory = current directory).

  Skills (set in ~/.pi/agent/settings.json, copy of configs/pi/settings.json):
    default : ONLY 9 Superpowers skills (package git:github.com/obra/superpowers@v7.0.0, filtered in
              "packages") + the using-superpowers bootstrap in EVERY request (stable prefix) from the
              ~/.pi/agent/extensions/superpowers-filtered.ts extension. ~/.agents/skills (shared with
              other tools, ~3.9K tokens) is switched off with "skills": ["!**/.agents/skills/**"].
    -Skills : all of them = --skill <package>/skills (15 Superpowers v7 skills) + --skill ~/.agents/skills
              (the rest; duplicate names from older copies lose -> collision warning, not doubled).
    -Lite   : lean mode for quick tasks = --no-skills --no-mcp + PI_SUPERPOWERS=0 (the wrapper skips the
              bootstrap). Built-in tools and AGENTS.md stay; /research and /docs need MCP, so use the
              default mode for those. First request ~2.4K vs ~6.5K tokens (chars/4).
  MCP: ~/.pi/agent/mcp.json (copy of configs/pi/mcp.json), direct exposure:
    context7 : library docs (remote). CONTEXT7_API_KEY is NOT hidden; when it is empty in this process it
               is read from the User environment. Still empty: yellow warning + a " " value for the pi
               process only (Pi rejects a header with an empty variable; Context7 accepts "Bearer" without
               a token as anonymous, with a lower rate limit).
    web      : search + fetch_content, one local Python process (~80-105 MB): duckduckgo-mcp-server 0.7.0
               (uv tool) + ~/.pi/agent/mcp-servers/web_search.py (search through ddgs; fetch capped at
               16K characters, local/private addresses refused).
    Sessions get --exclude-tools list_mcp_resources,list_mcp_resource_templates,read_mcp_resource
    (both servers advertise "resources" but have none; drop this once one of them does).
  Prompt templates: /research <question> (step-by-step web research with a notes file under research/) and
    /docs <library> <question> (forces Context7). Files: ~/.pi/agent/prompts/ (copy of configs/pi/prompts/).
  Permission gate (every mode, including -Lite/-Fast): ~/.pi/agent/extensions/permission-gate.ts
    (copy of configs/pi/extensions/, tests: node tests/permission-gate.test.mjs).
    Before a tool runs: risky bash/powershell (outbound network: git push, ssh/scp, gh writes, curl sending
    data, curl|sh, iex; destructive: rm -r/-f, Remove-Item -Recurse, git reset --hard/clean -f; database:
    migrate:fresh/rollback, db:wipe, --force, DROP/TRUNCATE; secrets: .ssh, env, $..KEY; system: sudo,
    registry, Startup, setx, schtasks, global installs) and write/edit outside the working folder or to
    .env*/.ssh/profile/Startup/.git/hooks/.pi -> TUI: Deny / Allow once / Allow this pattern for this
    session. Without a UI (-p, --mode json) it is BLOCKED and the model is told to ask the user.
    Decision log: ~/.pi/agent/gate.log. Turn it off ONLY for automated harnesses in a throwaway clone:
    $env:PI_GATE = 'off' before running this script (the launcher prints a yellow warning).

  Examples:
    .\pi-local.ps1
    .\pi-local.ps1 -Fast
    .\pi-local.ps1 -Lite                       # no skills/bootstrap/MCP (quick tasks)
    .\pi-local.ps1 -Skills                     # every skill (full Superpowers + ~/.agents/skills)
    .\pi-local.ps1 mcp list                    # check the context7 + web connections (no model server check)
    .\pi-local.ps1 --no-mcp                    # no MCP for one run
    .\pi-local.ps1 -c                          # continue the last session (pi --continue)
    .\pi-local.ps1 -p "Summarize this repo"    # one shot, no TUI
    .\pi-local.ps1 --list-models               # no server check

  Notes:
    - Deliberately NO param() block, so pi's short flags (-c, -p, -r ...) are not captured by PowerShell
      (it binds unique prefixes, so -s would become -Skills). Only the exact words "-Fast", "-Skills" and
      "-Lite" are ours.
    - While pi runs: PI_OFFLINE=1, PI_SKIP_VERSION_CHECK=1, PI_TELEMETRY=0, and every cloud credential
      (*_API_KEY except CONTEXT7_API_KEY, Anthropic/Copilot/HF/AWS tokens) is hidden from the pi process
      (and from any bash command the model runs). All of it is restored when pi exits. PI_OFFLINE does
      not block MCP (Context7 stays connected).
#>

$ErrorActionPreference = 'Stop'

$fast = $false
$skills = $false
$lite = $false
$piArgs = New-Object System.Collections.Generic.List[string]
foreach ($a in $args) {
    if ("$a" -ieq '-Fast') { $fast = $true }
    elseif ("$a" -ieq '-Skills') { $skills = $true }
    elseif ("$a" -ieq '-Lite') { $lite = $true }
    else { $piArgs.Add("$a") }
}
if ($lite -and $skills) {
    Write-Host 'Warning: -Lite ignores -Skills.' -ForegroundColor Yellow
    $skills = $false
}

if ($fast) {
    $provider = 'ollama'
    $model    = 'qwen3.5-9b:iq4xs'
    $label    = 'Ollama :11434 (qwen3.5-9b:iq4xs)'
    $hint     = 'start-fast.ps1'
} else {
    $provider = 'llamacpp'
    $model    = 'local'
    $label    = 'llama-server :8080 (local)'
    $hint     = 'start-agent.ps1'
}

if (-not (Get-Command pi -ErrorAction SilentlyContinue)) {
    Write-Host 'Command `pi` not found. Install the Pi coding agent first (npm i -g ...).' -ForegroundColor Red
    exit 1
}

# Arguments that need no server or pick their own model.
$noServer   = @('--list-models', '-h', '--help', '-v', '--version', '--export')
$modelFlags = @('--model', '--provider', '--models', '--list-models')
$needServer = $true
$addModel   = $true
$addSkills  = $skills
$noMcp      = $lite -or ($piArgs -contains '--no-mcp')
foreach ($a in $piArgs) {
    if ($noServer -contains $a) { $needServer = $false }
    if ($modelFlags -contains $a) { $addModel = $false }
}
$subCmd = if ($piArgs.Count -gt 0 -and @('install', 'remove', 'uninstall', 'update', 'list', 'config', 'auth', 'mcp') -contains $piArgs[0]) { $piArgs[0] } else { '' }
if ($subCmd) {
    $needServer = $false
    $addModel = $false
    $addSkills = $false
}
# Context7 matters for sessions (which need a server) and for `pi mcp ...`.
$useMcp = (-not $noMcp) -and ($needServer -or $subCmd -eq 'mcp')

if ($needServer) {
    $up = $false
    $state = 'off'
    if ($fast) {
        # Ollama never autostarts: start it on demand (through Explorer, max 30 s).
        . (Join-Path $PSScriptRoot 'lib-ollama.ps1')
        if (Start-OllamaOnDemand 30) {
            $up = $true
            try {
                $tags = Invoke-RestMethod "$OllamaUrl/api/tags" -UseBasicParsing -TimeoutSec 3
                if (-not (@($tags.models) | Where-Object { $_.name -eq $model })) {
                    Write-Host "Warning: model '$model' is not in Ollama (ollama list)." -ForegroundColor Yellow
                }
            } catch {}
        } else {
            $state = 'failed to start'
        }
    } else {
        try {
            $r = Invoke-WebRequest 'http://127.0.0.1:8080/health' -UseBasicParsing -TimeoutSec 3
            if ($r.StatusCode -eq 200) { $up = $true }
        } catch {
            $resp = $_.Exception.Response
            if ($resp -and [int]$resp.StatusCode -eq 503) { $state = 'still loading the model' }
        }
    }
    if (-not $up) {
        Write-Host "Server $label is not ready ($state)." -ForegroundColor Yellow
        Write-Host "Start it first: $(Join-Path $PSScriptRoot $hint)   (check: status-ai.ps1)" -ForegroundColor Yellow
        exit 1
    }
}

$finalArgs = New-Object System.Collections.Generic.List[string]
if ($addModel) { $finalArgs.AddRange([string[]]@('--provider', $provider, '--model', $model)) }
if ($addSkills) {
    # Order matters: the Superpowers package first, so its version wins over older copies in ~/.agents/skills.
    $spSkills = Join-Path $env:USERPROFILE '.pi\agent\git\github.com\obra\superpowers\skills'
    if (Test-Path -LiteralPath $spSkills) { $finalArgs.AddRange([string[]]@('--skill', $spSkills)) }
    else { Write-Host "Warning: Superpowers package not found ($spSkills)." -ForegroundColor Yellow }
    $finalArgs.AddRange([string[]]@('--skill', (Join-Path $env:USERPROFILE '.agents\skills')))
}
if ($lite -and -not $subCmd) {
    # The bootstrap is switched off through PI_SUPERPOWERS=0 (see $setEnv); other extensions stay on.
    foreach ($f in '--no-skills', '--no-mcp') { if (-not ($piArgs -contains $f)) { $finalArgs.Add($f) } }
}
# context7 and web advertise the "resources" capability (with 0 resources) -> Pi adds 3 resource tools
# (~1.9K characters per request). Drop them, unless the user passed --exclude-tools themselves.
if ($needServer -and -not $noMcp -and -not ($piArgs -contains '--exclude-tools' -or $piArgs -contains '-xt')) {
    $finalArgs.AddRange([string[]]@('--exclude-tools', 'list_mcp_resources,list_mcp_resource_templates,read_mcp_resource'))
}
$finalArgs.AddRange([string[]]$piArgs.ToArray())

# Environment for the pi process only: no automatic network calls, no telemetry, no cloud credentials
# (except CONTEXT7_API_KEY for the Context7 MCP server).
$setEnv = @{ PI_OFFLINE = '1'; PI_SKIP_VERSION_CHECK = '1'; PI_TELEMETRY = '0' }
if ($lite) { $setEnv['PI_SUPERPOWERS'] = '0' }
$keepKeys = @('CONTEXT7_API_KEY')
$hideExact = @('ANTHROPIC_OAUTH_TOKEN', 'ANTHROPIC_AUTH_TOKEN', 'COPILOT_GITHUB_TOKEN', 'HF_TOKEN',
    'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN', 'AWS_BEARER_TOKEN_BEDROCK',
    'GOOGLE_APPLICATION_CREDENTIALS', 'LLAMA_BASE_URL', 'LLAMA_API_KEY')
$saved = @{}
foreach ($name in @(Get-ChildItem Env: | ForEach-Object { $_.Name })) {
    if ($keepKeys -contains $name) { continue }
    if ($name -match '_API_KEY$' -or $hideExact -contains $name) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
}
foreach ($k in $setEnv.Keys) {
    if (-not $saved.ContainsKey($k)) { $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process') }
    [Environment]::SetEnvironmentVariable($k, $setEnv[$k], 'Process')
}
# Context7: mcp.json uses "Bearer ${CONTEXT7_API_KEY}". A terminal opened before the key was set doesn't
# see it yet -> read it from the User environment. If it's still empty Pi can't resolve the header (the
# context7 server shows as "failed"), so set " " for the pi process: the header goes out as "Bearer",
# which Context7 treats as anonymous.
$c7 = [Environment]::GetEnvironmentVariable('CONTEXT7_API_KEY', 'Process')
if ([string]::IsNullOrWhiteSpace($c7)) {
    $saved['CONTEXT7_API_KEY'] = $c7
    $c7 = [Environment]::GetEnvironmentVariable('CONTEXT7_API_KEY', 'User')
    if ([string]::IsNullOrWhiteSpace($c7)) {
        $c7 = ' '
        if ($useMcp) { Write-Host 'Warning: CONTEXT7_API_KEY is empty - Context7 runs anonymously (lower rate limit).' -ForegroundColor Yellow }
    }
    [Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $c7, 'Process')
}
$c7 = $null

$code = 0
try {
    $skTxt = if ($lite) { 'lite mode: no skills/bootstrap/MCP' }
             elseif ($addSkills) { 'skills: all (-Skills) + MCP' }
             else { 'skills: superpowers + MCP (-Lite = leaner)' }
    if ($addModel) { Write-Host "pi -> $provider/$model  [$label]  $skTxt" -ForegroundColor DarkGray }
    if ($needServer -and "$env:PI_GATE" -match '^\s*(off|0|false|no|disabled?)\s*$') {
        Write-Host "Warning: PI_GATE=$env:PI_GATE - permission gate is OFF (risky commands run without asking)." -ForegroundColor Yellow
    }
    $piCmdArgs = $finalArgs.ToArray()
    & pi @piCmdArgs
    $code = $LASTEXITCODE
} finally {
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
}
exit $code
