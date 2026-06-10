# pod.ps1 - spawn/manage containerized agent browsers (agent pods)
#
#   .\pod.ps1 up <name> [-Cookies <profile>] [-Worktree <path>]
#   .\pod.ps1 down <name> | .\pod.ps1 down -All
#   .\pod.ps1 ls
#   .\pod.ps1 url <name>
#
# Each pod = one Chromium container: CDP on a unique localhost port (agent-browser,
# Playwright MCP, watchconsole all attach to it), noVNC web viewer so you can watch.
#
# NOTE: keep this file ASCII-only. PowerShell 5.1 reads BOM-less files as ANSI and
# multi-byte characters can corrupt string parsing.

param(
    [Parameter(Position = 0)]
    [ValidateSet("up", "down", "ls", "url", "build", "help")]
    [string]$Cmd = "help",

    [Parameter(Position = 1)]
    [string]$Name,

    [string]$Cookies,
    [string]$Worktree,
    [switch]$All
)

$ErrorActionPreference = "Stop"
$Image = "agent-pod:latest"
$Label = "agent-pod"
$CdpBase = 9222   # pod N gets 9222+N (pod 1 -> 9223); 9222 stays your real Brave
$WebBase = 7900   # pod N gets 7900+N
$RepoRoot = $PSScriptRoot

function Get-Pods {
    # No quoted keys in the go-template: PowerShell 5.1 mangles embedded quotes
    # when passing args to native exes. Index is derived from the published CDP port.
    $out = docker ps -a --filter "label=$Label" --format "{{.Names}}|{{.Ports}}|{{.Status}}"
    $pods = @()
    foreach ($line in $out) {
        if (-not $line) { continue }
        $parts = $line -split "\|"
        if ($parts[1] -notmatch "127\.0\.0\.1:(\d+)->9222/tcp") { continue }
        $cdp = [int]$Matches[1]
        $index = $cdp - $CdpBase
        $pods += [pscustomobject]@{
            Name   = $parts[0] -replace "^agent-pod-", ""
            Index  = $index
            Cdp    = $cdp
            Watch  = "http://localhost:$($WebBase + $index)/vnc.html?autoconnect=true" + "&resize=scale"
            Status = $parts[2]
        }
    }
    return $pods
}

function Wait-Cdp([int]$Port) {
    for ($i = 0; $i -lt 60; $i++) {
        try {
            Invoke-WebRequest -Uri "http://127.0.0.1:$Port/json/version" -UseBasicParsing -TimeoutSec 2 | Out-Null
            return $true
        } catch {
            Start-Sleep -Milliseconds 500
        }
    }
    return $false
}

switch ($Cmd) {

    "build" {
        docker build -t $Image $RepoRoot
        break
    }

    "up" {
        if (-not $Name) { throw "Usage: pod.ps1 up [name] -Cookies [profile] -Worktree [path]" }
        $existing = Get-Pods | Where-Object { $_.Name -eq $Name }
        if ($existing) { throw "Pod '$Name' already exists (status: $($existing.Status)). Use 'pod.ps1 down $Name' first." }

        # Image present?
        $img = docker images -q $Image
        if (-not $img) {
            Write-Host "Image not built yet - building..."
            docker build -t $Image $RepoRoot
        }

        # First free index 1..50
        $used = @(Get-Pods | ForEach-Object { $_.Index })
        $index = 0
        foreach ($i in 1..50) {
            if ($used -notcontains $i) { $index = $i; break }
        }
        if ($index -eq 0) { throw "No free pod slot (1..50 all used)." }
        $cdp = $CdpBase + $index
        $web = $WebBase + $index

        docker run -d `
            --name "agent-pod-$Name" `
            --label "$Label=true" `
            --label "$Label.index=$index" `
            --shm-size=1g `
            --restart unless-stopped `
            -p "127.0.0.1:${cdp}:9222" `
            -p "127.0.0.1:${web}:7900" `
            $Image | Out-Null

        Write-Host "Waiting for CDP on $cdp..."
        if (-not (Wait-Cdp $cdp)) {
            docker logs "agent-pod-$Name" --tail 30
            throw "Pod started but CDP never came up on $cdp. Logs above."
        }

        # Cookies: inject into the default browser context (covers Playwright MCP
        # etc). agent-browser uses its own isolated context, so the state file
        # path also goes into pod.json for `agent-browser state load`.
        $stateFile = $null
        if ($Cookies) {
            $stateFile = Join-Path $RepoRoot "cookie-profiles\$Cookies.json"
            if (-not (Test-Path $stateFile)) { throw "No cookie profile at $stateFile. Run cookies.mjs export first." }
            node "$RepoRoot\cookies.mjs" load --profile $Cookies --port $cdp
        }

        $watch = "http://localhost:$web/vnc.html?autoconnect=true" + "&resize=scale"

        # Bind to worktree
        if ($Worktree) {
            $claudeDir = Join-Path $Worktree ".claude"
            if (-not (Test-Path $claudeDir)) { New-Item -ItemType Directory -Path $claudeDir | Out-Null }
            $pod = @{ name = $Name; cdp = $cdp; watch = $watch }
            if ($stateFile) { $pod.state = $stateFile }
            $podJson = $pod | ConvertTo-Json
            [System.IO.File]::WriteAllText((Join-Path $claudeDir "pod.json"), $podJson)
            Write-Host "Bound to worktree: $(Join-Path $claudeDir 'pod.json')"
        }

        Write-Host ""
        Write-Host "Pod '$Name' is up." -ForegroundColor Green
        Write-Host "  CDP:    127.0.0.1:$cdp"
        Write-Host "  Drive:  agent-browser --session $Name --cdp $cdp open <url>"
        if ($stateFile) {
            Write-Host "  Auth:   agent-browser --session $Name --cdp $cdp state load $stateFile"
        }
        Write-Host "  Watch:  $watch"
        break
    }

    "down" {
        if ($All) {
            $names = Get-Pods | ForEach-Object { "agent-pod-$($_.Name)" }
            if ($names) { docker rm -f $names | Out-Null; Write-Host "All pods removed." }
            else { Write-Host "No pods." }
        } elseif ($Name) {
            docker rm -f "agent-pod-$Name" | Out-Null
            Write-Host "Pod '$Name' removed."
        } else {
            throw "Usage: pod.ps1 down [name] OR pod.ps1 down -All"
        }
        break
    }

    "ls" {
        $pods = Get-Pods
        if (-not $pods) { Write-Host "No pods. Your real Brave stays on CDP 9222."; break }
        $pods | Format-Table Name, Cdp, Watch, Status -AutoSize
        break
    }

    "url" {
        if (-not $Name) { throw "Usage: pod.ps1 url [name]" }
        $pod = Get-Pods | Where-Object { $_.Name -eq $Name }
        if (-not $pod) { throw "No pod named '$Name'." }
        Write-Host $pod.Watch
        break
    }

    default {
        Write-Host @"
agent-pods - containerized browsers for parallel Claude Code sessions

  pod.ps1 build                                      build the image
  pod.ps1 up [name] -Cookies [p] -Worktree [dir]     spawn pod (CDP + watch URL)
  pod.ps1 ls                                         list pods + ports
  pod.ps1 url [name]                                 print watch URL
  pod.ps1 down [name] | down -All                    remove pod(s)

Port 9222 is reserved for your real local browser. Pods get 9223+.
"@
    }
}
