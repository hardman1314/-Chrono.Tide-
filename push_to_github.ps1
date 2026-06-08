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

$ErrorActionPreference = "Continue"
$RepoRoot = $PSScriptRoot
if (-not $RepoRoot) { $RepoRoot = "." }

# Safe git command wrapper - captures output without throwing on stderr
function Invoke-Git {
    param([string]$Arguments)
    $result = @{ Output = ""; ExitCode = 0 }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "git"
        $psi.Arguments = $Arguments
        $psi.WorkingDirectory = $RepoRoot
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()

        $result.Output = $stdout
        $result.ExitCode = $proc.ExitCode
    } catch {
        $result.Output = ""
        $result.ExitCode = 1
    }
    return $result
}

# ─── Colors ───
function Write-Step($text)  { Write-Host ("`n" + "=" * 50) -ForegroundColor Cyan; Write-Host "  $text" -ForegroundColor Cyan; Write-Host ("=" * 50) -ForegroundColor Cyan }
function Write-OK($text)    { Write-Host "  [OK]    $text" -ForegroundColor Green }
function Write-Warn($text)  { Write-Host "  [WARN]  $text" -ForegroundColor Yellow }
function Write-Fail($text)  { Write-Host "  [FAIL]  $text" -ForegroundColor Red }
function Write-Info($text)  { Write-Host "  [INFO]  $text" -ForegroundColor White }

# ============================================================
# STEP 0: Pre-flight Checks
# ============================================================
Write-Step "STEP 0/5: Environment Check"

# Check git
$r = Invoke-Git "--version"
if ($r.ExitCode -ne 0) { Write-Fail "Git not found. Please install Git first."; exit 1 }
Write-OK "Git: $($r.Output.Trim())"

# Check we're inside a git repo
Push-Location $RepoRoot
$r = Invoke-Git "rev-parse --is-inside-work-tree"
if ($r.ExitCode -ne 0) { Pop-Location; Write-Fail "Not a git repository."; exit 1 }
Pop-Location
Write-OK "Git repository: $RepoRoot"

# Check remote
$r = Invoke-Git "config --get remote.origin.url"
if ($r.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($r.Output)) {
    Write-Fail "No remote 'origin' configured."; exit 1
}
$remoteUrl = $r.Output.Trim()
$displayUrl = $remoteUrl -replace '(https?://)[^@]+(@)', '$1***$2'
Write-OK "Remote origin: $displayUrl"

# Check network
try {
    $test = Test-NetConnection -ComputerName github.com -Port 443 -WarningAction SilentlyContinue -ErrorAction Stop
    if ($test.TcpTestSucceeded) { Write-OK "Network: GitHub reachable" }
    else { Write-Warn "Network: Cannot reach github.com" }
} catch {
    Write-Warn "Network check skipped"
}

# ============================================================
# STEP 1: Show Current Status
# ============================================================
Write-Step "STEP 1/5: Current Status"

Push-Location $RepoRoot

$r = Invoke-Git "branch --show-current"
$currentBranch = $r.Output.Trim()
Write-Info "Branch: $currentBranch"

$r = Invoke-Git "status --short"
$statusOutput = $r.Output.Trim()

if ([string]::IsNullOrWhiteSpace($statusOutput)) {
    Write-Warn "Working tree is clean - nothing to commit."
    Write-Info "Use -Force to skip commit and just push."
    Pop-Location
    exit 0
}

$lines = $statusOutput -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$fileCount = ($lines | Measure-Object).Count
Write-Info "Changed files: $fileCount"
Write-Info ""
foreach ($line in $lines) {
    $line = $line.Trim()
    if ($line.Length -lt 3) { continue }
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

# Show recent commits
Write-Info ""
Write-Info "Recent commits:"
$r = Invoke-Git "log --oneline -5"
($r.Output -split "`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { Write-Host "       $_" }

# ============================================================
# STEP 2: Stage & Commit
# ============================================================
Write-Step "STEP 2/5: Stage & Commit"

# Auto-generate commit message if not provided
if ([string]::IsNullOrWhiteSpace($Message)) {
    $now = Get-Date
    $dateStr = $now.ToString("yyyy-MM-dd HH:mm")
    $Message = "chore: sync opensource [$dateStr]"
}

Write-Info "Commit message: $Message"
Write-Info ""

# Stage all changes
$r = Invoke-Git "add -A"
if ($r.ExitCode -ne 0) { Pop-Location; Write-Fail "git add failed"; exit 1 }
Write-OK "All changes staged"

# Commit
$r = Invoke-Git "commit -m `"$Message`""
if ($r.ExitCode -ne 0) { Pop-Location; Write-Fail "git commit failed"; exit 1 }

$r = Invoke-Git "rev-parse --short HEAD"
$commitHash = $r.Output.Trim()
Write-OK "Committed: $commitHash - $Message"

# ============================================================
# STEP 3: Pre-push Safety Check
# ============================================================
Write-Step "STEP 3/5: Pre-Push Safety Check"

$sensitivePatterns = @('\.env$', '\.jks$', 'credentials', 'secrets', '_private', '\.pem$', '\.key$')

$r = Invoke-Git "diff --cached --name-only"
$stagedFiles = $r.Output -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$riskFound = $false
foreach ($pattern in $sensitivePatterns) {
    foreach ($file in $stagedFiles) {
        if ($file -match $pattern) {
            Write-Warn "Potential sensitive file: $file"
            $riskFound = $true
        }
    }
}

if ($riskFound -and -not $Force) {
    Write-Fail "Sensitive files detected! Use -Force to override."
    Pop-Location; exit 1
}

# Check ahead/behind
$r = Invoke-Git "rev-list --count HEAD..origin/$currentBranch"
$aheadCount = $r.Output.Trim()
$r = Invoke-Git "rev-list --count origin/$currentBranch..HEAD"
$behindCount = $r.Output.Trim()
Write-Info "Ahead of origin: $behindCount commits | Behind: $aheadCount commits"

# ============================================================
# STEP 4: Push to GitHub
# ============================================================
Write-Step "STEP 4/5: Push to GitHub"

if ($DryRun) {
    Write-Info "[DRY RUN] Would push to origin/$currentBranch"
} else {
    Write-Info "Pushing to origin/$currentBranch ..."
    Write-Info ""

    $r = Invoke-Git "push origin $currentBranch"
    if ($r.ExitCode -eq 0) {
        Write-OK "Push successful!"
    } else {
        $errText = $r.Output
        if ($errText -match 'rejected.*non-fast-forward') {
            Write-Fail "Push rejected: Remote has conflicting commits."
            Write-Info "Try: git pull --rebase, then run this script again."
        } elseif ($errText -match 'Authentication|403|denied') {
            Write-Fail "Push failed: Authentication error."
            Write-Info "Check your Git token / credentials."
        } elseif ($errText -match 'could not resolve|network') {
            Write-Fail "Push failed: Network error."
        } else {
            Write-Fail "Push failed (exit code: $($r.ExitCode))."
        }
        Pop-Location; exit 1
    }
}

# ============================================================
# STEP 5: Summary
# ============================================================
Write-Step "STEP 5/5: Done!"

$r = Invoke-Git "log --oneline -1"
Write-Info "Latest commit : $($r.Output.Trim())"
$r = Invoke-Git "log -1 --format=%ai"
Write-Info "Committed at   : $($r.Output.Trim())"
Write-Info "Remote         : $displayUrl"
Write-Info "Branch         : $currentBranch"
Write-Info "Directory      : $RepoRoot"

Pop-Location

Write-Host ""
Write-Host "  All done!" -ForegroundColor Green
exit 0
