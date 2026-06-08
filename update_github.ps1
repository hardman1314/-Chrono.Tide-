# ChronoTide Open Source - One-Click GitHub Update Script
#
# Usage:
#   .\update_github.ps1 [-Message "your commit message"] [-DryRun]
#
# Prerequisites:
#   - Git installed and in PATH
#   - GitHub account logged in (git credential configured)
#
# What this script does:
#   1. Auto-resolves merge conflicts (keeps our version)
#   2. Stages all changes (new + modified)
#   3. Creates commit with timestamped message
#   4. Pushes to GitHub

param(
    [string]$Message = "",
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = "Continue"
$ProjectRoot = $PSScriptRoot

if ($ProjectRoot -eq "") { $ProjectRoot = "." }

Push-Location $ProjectRoot

# ============================================================
# Color helpers
# ============================================================
function Write-Step($n, $t, $total) {
    Write-Host ""
    Write-Host ("[$n/$total] $t") -ForegroundColor Cyan
}

function Write-OK($t) { Write-Host "  OK: $t" -ForegroundColor Green }
function Write-Warn($t) { Write-Host "  WARN: $t" -ForegroundColor Yellow }
function Write-Fail($t) { Write-Host "  FAIL: $t" -ForegroundColor Red }

# ============================================================
# Step 0: Pre-flight checks
# ============================================================
Write-Step 0 "Pre-flight checks" 5

# Check git installed
$gitVersion = git --version 2>&1
if (-not $gitVersion) {
    Write-Fail "Git not found. Please install Git first."
    Pop-Location; exit 1
}
Write-OK "Git found: $gitVersion"

# Check we're inside a git repo
$gitDir = Test-Path ".git"
if (-not $gitDir) {
    Write-Fail "Not a git repository. Run 'git init' first."
    Pop-Location; exit 1
}
Write-OK "Git repository detected"

# Check remote configured
$remote = git remote get-url origin 2>&1
if (-not $remote) {
    Write-Fail "No 'origin' remote configured. Add one with: git remote add origin <url>"
    Pop-Location; exit 1
}
# Hide token in display
$displayRemote = $remote -replace '(https?://)[^@]+(@)', '$1***$2'
Write-OK "Remote: $displayRemote"

# ============================================================
# Step 1: Resolve any merge conflicts
# ============================================================
Write-Step 1 "Resolving conflicts" 5

$conflictFiles = @()
$status = git status --porcelain 2>&1
foreach ($line in ($status -split "`n")) {
    if ($line -match '^(UU|AA|DU|UD|UA|AU)\s') {
        $conflictFiles += $line -replace '^\S+\s+'
    }
}

if ($conflictFiles.Count -gt 0) {
    Write-Warn "Found $($conflictFiles.Count) conflicted file(s):"
    foreach ($f in $conflictFiles) {
        Write-Host "       - $f" -ForegroundColor DarkGray
        # Accept ours (the open source version)
        $prevEA = $ErrorActionPreference
        $ErrorActionPreference = "SilentlyContinue"
        git checkout --ours "$f" | Out-Null
        git add "$f" | Out-Null
        $ErrorActionPreference = $prevEA
        Write-OK "Resolved: $f (kept local version)"
    }
} else {
    Write-OK "No merge conflicts"
}

# ============================================================
# Step 2: Stage all changes
# ============================================================
Write-Step 2 "Staging changes" 5

# Stage all tracked and new files
git add -A 2>&1 | Out-Null

# Check what's staged
$staged = git diff --cached --name-only 2>&1
$stagedList = @($staged -split "`n" | Where-Object { $_.Trim() -ne "" })

if ($stagedList.Count -eq 0) {
    Write-Warn "Nothing to commit. Working tree is clean."
    Pop-Location; exit 0
}

Write-OK "Staged $($stagedList.Count) file(s)"
foreach ($f in $stagedList) {
    Write-Host "       + $f" -ForegroundColor DarkGray
}

# ============================================================
# Step 3: Create commit
# ============================================================
Write-Step 3 "Creating commit" 5

if ($Message -eq "") {
    # Auto-generate message with date and change summary
    $dateStr = Get-Date -Format "yyyy-MM-dd HH:mm"
    $added = ($stagedList | Where-Object { $_ -match '^"?[^"]*"$' }).Count
    $modified = ($stagedList | Where-Object { $_ -match '^"?M?"' }).Count
    $Message = "update: ${dateStr} | files changed: $($stagedList.Count)"
}

if ($DryRun) {
    Write-Warn "[DRY RUN] Would commit with message:"
    Write-Host "       `"$Message`"" -ForegroundColor White
} else {
    git commit -m $Message 2>&1 | Out-Null
    $commitHash = git rev-parse --short HEAD 2>&1
    Write-OK "Committed: $commitHash - $Message"
}

# ============================================================
# Step 4: Push to GitHub
# ============================================================
Write-Step 4 "Pushing to GitHub" 5

if ($DryRun) {
    Write-Warn "[DRY RUN] Would push to origin/main"
} else {
    $pushResult = git push origin main 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-OK "Pushed to GitHub successfully"
    } else {
        # If push fails due to non-fast-forward, try force push if -Force flag
        if ($Force) {
            Write-Warn "Normal push failed, trying force push..."
            git push origin main --force 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-OK "Force pushed to GitHub"
            } else {
                Write-Fail "Force push also failed"
                Pop-Location; exit 1
            }
        } else {
            Write-Fail "Push failed. Use -Force to force push, or pull first."
            Write-Host "       Error: $pushResult" -ForegroundColor DarkRed
            Pop-Location; exit 1
        }
    }
}

# ============================================================
# Step 5: Summary
# ============================================================
Write-Step 5 "Summary" 5

$currentBranch = git branch --show-current 2>&1
$latestCommit = git log --oneline -1 2>&1
$latestTime = git log -1 --format="%ai" 2>&1

Write-Host ""
Write-Host ("=" * 50) -ForegroundColor Green
Write-Host "  Branch : $currentBranch" -ForegroundColor White
Write-Host "  Commit : $latestCommit" -ForegroundColor White
Write-Host "  Time   : $latestTime" -ForegroundColor White
Write-Host "  Files  : $($stagedList.Count)" -ForegroundColor White
Write-Host ("=" * 50) -ForegroundColor Green
Write-Host ""

Pop-Location
