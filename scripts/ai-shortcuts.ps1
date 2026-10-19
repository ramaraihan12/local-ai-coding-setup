<#
  ai-shortcuts.ps1 - short commands for the PowerShell profile (pwsh 7 and Windows PowerShell 5.1).

  Load it from $PROFILE:
    $s = '<clone>\scripts\ai-shortcuts.ps1'; if (Test-Path -LiteralPath $s) { . $s }

  It only defines functions: nothing starts, nothing is printed, nothing autostarts. Commands: ai-on, ai-fast,
  ai-off, ai-status, ai-pi, ai-help. Arguments pass straight through to the start-*.ps1 and pi-local.ps1
  scripts. A name that is already taken by another command is skipped with a warning.

  The functions find the scripts folder through $MyInvocation.MyCommand.ScriptBlock.File, because $script:
  variables are empty when a function is called from another script.
#>

& {
    param([string]$Self)

    $defs = [ordered]@{}

    # --- Helpers ----------------------------------------------------------------------------------
    $defs['Get-LocalAiScript'] = {
        param([string]$Name)
        Join-Path (Split-Path -Parent $MyInvocation.MyCommand.ScriptBlock.File) $Name
    }

    $defs['Test-LocalAiHealth'] = {
        param([int]$Port = 8080)
        $ProgressPreference = 'SilentlyContinue'
        try {
            $r = Invoke-WebRequest "http://127.0.0.1:$Port/health" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            return ($r.StatusCode -eq 200)
        } catch { return $false }
    }

    # $true when the argument list contains the switch -Name (or a prefix of it such as -Dry, like PowerShell binding)
    $defs['Test-LocalAiSwitch'] = {
        param([object[]]$ArgList, [string]$Name)
        foreach ($a in @($ArgList)) {
            if ("$a" -match '^-([A-Za-z]+):?$' -and $Name.StartsWith($Matches[1], [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
        return $false
    }

    # Model file name from /props (model_path), falling back to the id in /v1/models. $null when unreadable.
    $defs['Get-LocalAiModel'] = {
        param([int]$Port = 8080)
        $ProgressPreference = 'SilentlyContinue'
        try {
            $p = Invoke-RestMethod "http://127.0.0.1:$Port/props" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
            if ($p.model_path) { return [IO.Path]::GetFileNameWithoutExtension([string]$p.model_path) }
        } catch {}
        try {
            $m = Invoke-RestMethod "http://127.0.0.1:$Port/v1/models" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
            $ids = (@($m.data) | ForEach-Object { $_.id }) -join ', '
            if ($ids) { return $ids }
        } catch {}
        return $null
    }

    # Wait for /health = 200 (max $TimeoutSec), then print "AI ready" or a hint on timeout.
    $defs['Wait-LocalAiReady'] = {
        param([string]$Fallback, [int]$Port = 8080, [int]$TimeoutSec = 180)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Write-Host "Waiting for :$Port (max $TimeoutSec s) " -NoNewline
        $ok = $false
        while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
            if (Test-LocalAiHealth $Port) { $ok = $true; break }
            Write-Host '.' -NoNewline
            Start-Sleep -Seconds 3
        }
        $t = [int]$sw.Elapsed.TotalSeconds
        if ($ok) {
            Write-Host " OK ($t s)"
            $m = Get-LocalAiModel $Port
            if (-not $m) { $m = "preset $Fallback" }
            Write-Host "AI ready: $m on :$Port - type ai-pi in a project folder." -ForegroundColor Green
        } else {
            Write-Host " timeout ($t s)"
            Write-Host "Server :$Port is not ready. Check ai-status and the server window (FAILED / OOM / port in use?)." -ForegroundColor Yellow
            Write-Host "Cancel everything with ai-off." -ForegroundColor Yellow
        }
    }

    # --- Commands ---------------------------------------------------------------------------------
    # ai-on [start-agent args]: agent mode (FIM on CPU + gemma on :8080), waits until ready.
    $defs['ai-on'] = {
        $a = $args
        $dry = Test-LocalAiSwitch $a 'DryRun'
        if (-not $dry -and (Test-LocalAiHealth 8080)) {
            Write-Host "AI already running on :8080 ($(Get-LocalAiModel 8080)). To switch models: ai-off first." -ForegroundColor Yellow
            return
        }
        & (Get-LocalAiScript 'start-agent.ps1') @a
        if ($dry) { return }
        $preset = 'gemma'
        for ($i = 0; $i -lt $a.Count - 1; $i++) {
            if ("$($a[$i])" -match '^-pre') { $preset = "$($a[$i + 1])" }
        }
        Wait-LocalAiReady $preset
    }

    # ai-fast [start-fast args]: fast mode (FIM on CPU + Qwen3.5-9B on :8080); -Ollama = the 9B through Ollama.
    $defs['ai-fast'] = {
        $a = $args
        $dry = Test-LocalAiSwitch $a 'DryRun'
        $ollama = Test-LocalAiSwitch $a 'Ollama'
        if (-not $dry -and -not $ollama -and (Test-LocalAiHealth 8080)) {
            Write-Host "AI already running on :8080 ($(Get-LocalAiModel 8080)). To switch models: ai-off first." -ForegroundColor Yellow
            return
        }
        & (Get-LocalAiScript 'start-fast.ps1') @a
        if ($dry) { return }
        if ($ollama) {
            Write-Host "Fast mode (Ollama): use ai-pi -Fast in a project folder." -ForegroundColor Green
            return
        }
        Wait-LocalAiReady 'qwen9b'
    }

    # ai-off: stop everything (llama-server + Ollama models and app), print VRAM.
    $defs['ai-off'] = {
        & (Get-LocalAiScript 'stop-ai.ps1') -All
    }

    $defs['ai-status'] = {
        & (Get-LocalAiScript 'status-ai.ps1')
    }

    # ai-pi [pi args]: local Pi in the current folder; every argument is passed on as is.
    $defs['ai-pi'] = {
        & (Get-LocalAiScript 'pi-local.ps1') @args
    }

    $defs['ai-help'] = {
        Write-Host 'Local AI shortcuts (no autostart; start by hand, ai-off before gaming)' -ForegroundColor Green
        Write-Host '  ai-on [args]     agent mode: FIM on CPU (:8012) + gemma (:8080), waits until ready'
        Write-Host '                   e.g. ai-on -FimGpu | ai-on -Preset qwen36 | ai-on -DryRun'
        Write-Host '  ai-fast [args]   fast mode: FIM on CPU + Qwen3.5-9B on :8080 (ai-fast -Ollama = through Ollama)'
        Write-Host '  ai-pi [args]     Pi (terminal agent) in the current folder, local model'
        Write-Host '                   e.g. ai-pi | ai-pi -c | ai-pi -p "Summarize this repo" | ai-pi -Fast | ai-pi --thinking off'
        Write-Host '                   ai-pi -Lite = leaner (no skills/MCP) | inside Pi: /research <question>, /docs <library> <question>'
        Write-Host '                   permissions: risky commands (git push, ssh, rm -rf, migrate:fresh, .env, ...) ask first;'
        Write-Host '                   with -p they are blocked. Log ~/.pi/agent/gate.log. Off: $env:PI_GATE=''off'' (automated runs only)'
        Write-Host '  ai-status        :8080/:8012, Ollama, VRAM, RAM'
        Write-Host '  ai-off           stop everything (llama-server + Ollama), print VRAM (should be 0 MiB)'
        Write-Host '  ai-help          this list'
        Write-Host "Scripts: $(Split-Path -Parent $MyInvocation.MyCommand.ScriptBlock.File)" -ForegroundColor DarkGray
    }

    # --- Install into the global scope without overwriting names someone else already uses -------
    foreach ($n in $defs.Keys) {
        $alias = Get-Item -LiteralPath "Alias:$n" -ErrorAction SilentlyContinue
        if ($alias) {
            Write-Warning "local-ai: alias '$n' already exists (-> $($alias.Definition)); function $n not installed."
            continue
        }
        $fn = Get-Item -LiteralPath "Function:$n" -ErrorAction SilentlyContinue
        if ($fn -and $fn.ScriptBlock.File -ne $Self) {
            Write-Warning "local-ai: function '$n' already exists (from '$($fn.ScriptBlock.File)'); not overwritten."
            continue
        }
        Set-Item -Path "Function:global:$n" -Value $defs[$n]
    }
} $PSCommandPath
