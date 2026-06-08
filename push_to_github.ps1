# ChronoTide Open Source - One-Click GitHub Update Script
#
# Usage:
#   .\push_to_github.ps1
#   .\push_to_github.ps1 -Message "fix: some bug"
#   .\push_to_github.ps1 -DryRun          # preview only, no actual push
#
# Requirements:
#   - Git installed and logged into GitHub
#   - Run from chrono-tide-opensource directory

param(
    [string]$Message = "",
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$RepoRoot = $PSScriptRoot
if (-not $RepoRoot) { $RepoRoot = "." }

# ─── Colors ───
function Write-Step($text)  { Write-Host ("`n" + "=" * 50) -ForegroundColor Cyan; Write-Host "  $text" -ForegroundColor Cyan; Write-Host ("=" * 50) -ForegroundColor Cyan }
function Write-OK($text)     { Write-Host "  [OK]    $text" -ForegroundColor Green }
function Write-Warn($text)   { Write-Host "  [WARN]  $text" -ForegroundColor Yellow }
function Write-Fail($text)   { Write-Host "  [FAIL]  $text" -ForegroundColor Red; return $false }
function Write-Info($text)   { Write-Host "  [INFO]  $text" -ForegroundColor White }

# ============================================================
# STEP 0: Pre-flight Checks
# ============================================================
Write-Step "STEP 0/5: Environment Check"

# Check git
$gitVersion = git --version 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "Git not found. Please install Git first."; exit 1 }
Write-OK "Git: $gitVersion"

# Check we're inside a git repo
Push-Location $RepoRoot
$isGitRepo = git rev-parse --is-inside-work-tree 2>$null
if ($LASTEXITCODE -ne 0) { Pop-Location; Write-Fail "Not a git repository."; exit 1 }
Pop-Location
Write-OK "Git repository: $RepoRoot"

# Check remote
Push-Location $RepoRoot
$remoteUrl = git config --get remote.origin.url 2>$null
if (-not $remoteUrl) { Pop-Location; Write-Fail "No remote 'origin' configured."; exit 1 }

# Mask token in URL for display
$displayUrl = $remoteUrl -replace '(https?://)[^@]+(@)', '$1***$2'
Write-OK "Remote origin: $displayUrl"

# Check network connectivity to github.com
try {
    $test = Test-NetConnection -ComputerName github.com -Port 443 -WarningAction SilentlyContinue -ErrorAction Stop
    if ($test.TcpTestSucceeded) { Write-OK "Network: GitHub reachable" }
    else { Write-Warn "Network: Cannot reach github.com (port 443)" }
} catch {
    Write-Warn "Network check failed, will try anyway..."
}

# ============================================================
# STEP 1: Show Current Status
# ============================================================
Write-Step "STEP 1/5: Current Status"

Push-Location $RepoRoot

$currentBranch = git branch --show-current
Write-Info "Branch: $currentBranch"

$statusOutput = git status --short
if (-not $statusOutput) {
    Write-Warn "Working tree is clean - nothing to commit."
    if (-not $Force) {
        Write-Info "Use -Force to skip commit and just push."
        Pop-Location
        exit 0
    }
} else {
    $fileCount = ($statusOutput | Measure-Object).Count
    Write-Info "Changed files: $fileCount"
    Write-Info ""
    foreach ($line in ($statusOutput)) {
        $statusChar = $line.Substring(0, 1)
        $filePath = $line.Substring(3)
        switch ($statusChar) {
            'M' { Write-Host "       Modified : $filePath" -ForegroundColor Yellow }
            'A' { Write-Host "       Added    : $filePath" -ForegroundColor Green }
            'D' { Write-Host "       Deleted  : $filePath" -ForegroundColor Red }
            '?' { Write-Host "       Untracked: $filePath" -ForegroundColor DarkGray }
            default { Write-Host "       Changed  : $filePath" -ForegroundColor White }
        }
    }
}

# Show recent commits
Write-Info ""
Write-Info "Recent commits:"
git log --oneline -5 | ForEach-Object { Write-Host "       $_" }

# ============================================================
# STEP 2: Stage & Commit
# ============================================================
Write-Step "STEP 2/5: Stage & Commit"

if ($statusOutput) {
    # Auto-generate commit message if not provided
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $now = Get-Date
        $dateStr = $now.ToString("yyyy-MM-dd HH:mm")
        $addedFiles = git diff --name-only --diff-filter=A 2>$null
        $modifiedFiles = git diff --name-only --diff-filter=M 2>$null
        $deletedFiles = git diff --name-only --diff-filter=D 2>$null

        $parts = @()
        if ($addedFiles)  { $parts += "+$($addedFiles.Count)add" }
        if ($modifiedFiles){ $parts += "$($modifiedFiles.Count)mod" }
        if ($deletedFiles) { $parts += "-$($deletedFiles.Count)del" }

        $changeSummary = if ($parts.Count -gt 0) { $parts -join ',' } else { 'update' }
        $Message = "chore: sync opensource [$dateStr] ($changeSummary)"
    }

    Write-Info "Commit message: $Message"
    Write-Info ""

    # Stage all changes
    git add -A 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Pop-Location; Write-Fail "git add failed"; exit 1 }
    Write-OK "All changes staged"

    # Commit
    git commit -m $Message 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Pop-Location; Write-Fail "git commit failed"; exit 1 }
    $commitHash = git rev-parse --short HEAD
    Write-OK "Committed: $commitHash - $Message"
} else {
    Write-Info "Nothing to commit, skipping..."
}

# ============================================================
# STEP 3: Pre-push Safety Check
# ============================================================
Write-Step "STEP 3/5: Pre-Push Safety Check"

# Check for sensitive files that might have been accidentally staged
$sensitivePatterns = @(
    '\.env$',
    '\.jks$',
    'credentials',
    'secrets',
    '_private',
    '\.pem$',
    '\.key$'
)

$stagedFiles = git diff --cached --name-only 2>$null
$riskFound = $false
foreach ($pattern in $sensitivePatterns) {
    foreach ($file in $stagedFiles) {
        if ($file -match $pattern) {
            Write-Warn "Potential sensitive file detected: $file"
            $riskFound = $true
        }
    }
}

if ($riskFound -and -not $Force) {
    Write-Fail "Sensitive files detected! Review or use -Force to override."
    Pop-Location
    exit 1
}

# Check we're not about to force-push over main
$aheadCount = git rev-list --count HEAD..origin/$currentBranch 2>$null
$behindCount = git rev-list --count origin/$currentBranch..HEAD 2>$null
Write-Info "Ahead of origin: $behindCount commits | Behind: $aheadCount commits"

if ([int]$aheadCount -gt 0 -and -not $Force) {
    Write-Warn "Remote has new commits not in local. Consider pulling first."
}

# ============================================================
# STEP 4: Push to GitHub
# ============================================================
Write-Step "STEP 4/5: Push to GitHub"

if ($DryRun) {
    Write-Info "[DRY RUN] Would execute: git push origin $currentBranch"
    Write-Info "[DRY RUN] Skipping actual push."
} else {
    Write-Info "Pushing to origin/$currentBranch ..."
    Write-Info ""

    $pushOutput = git push origin $currentBranch 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-OK "Push successful!"
    } else {
        # Parse common errors
        $outputText = $pushOutPut -join "`n"
        if ($outputText -match 'rejected.*non-fast-forward') {
            Write-Fail "Push rejected: Remote has conflicting commits."
            Write-Info "Try: git pull --rebase, then run this script again."
        } elseif ($outputText -match 'Authentication') {
            Write-Fail "Push failed: Authentication error."
            Write-Info "Check your Git credentials / token."
        } elseif ($outputText -match 'could not resolve|network') {
            Write-Fail "Push failed: Network error."
        } else {
            Write-Fail "Push failed."
            $pushOutput | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray }
        }
        Pop-Location
        exit 1
    }
}

# ============================================================
# STEP 5: Summary
# ============================================================
Write-Step "STEP 5/5: Done!"

$latestHash = git log --oneline -1
$latestDate = git log -1 --format=%ai
Write-Info "Latest commit : $latestHash"
Write-Info "Committed at   : $latestDate"
Write-Info "Remote         : $displayUrl"
Write-Info "Branch         : $currentBranch"
Write-Info "Directory      : $RepoRoot"

Pop-Location

Write-Host ""
Write-Host "  All done!" -ForegroundColor Green
exit 0
