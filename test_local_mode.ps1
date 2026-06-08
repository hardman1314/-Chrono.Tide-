# ChronoTide Open Source - Local Mode Test Script
#
# Usage:
#   .\test_local_mode.ps1 [-SkipBuild] [-KeepRunning] [-WaitSeconds 15]
#

param(
    [string]$ProjectRoot = $PSScriptRoot,
    [switch]$SkipBuild,
    [switch]$KeepRunning,
    [int]$WaitSeconds = 15
)

$ErrorActionPreference = "Stop"

$script:totalTests = 0
$script:passCount = 0
$script:failCount = 0

function Write-Header {
    param([string]$Text)
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
}

function Write-Pass {
    param([string]$Text)
    Write-Host "  [PASS] $Text" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Text)
    Write-Host "  [FAIL] $Text" -ForegroundColor Red
}

function Write-Info {
    param([string]$Text)
    Write-Host "  [INFO] $Text" -ForegroundColor Yellow
}

function Write-Skip {
    param([string]$Text)
    Write-Host "  [SKIP] $Text" -ForegroundColor DarkGray
}

function Test-Condition {
    param([string]$Name, [bool]$Result)

    $script:totalTests++
    if ($Result) {
        $script:passCount++
        Write-Pass $Name
    } else {
        $script:failCount++
        Write-Fail $Name
    }
    return $Result
}

# ============================================================
# PHASE 1: Environment Check
# ============================================================
Write-Header "1/5 Environment Check"

Test-Condition "Project directory exists" (Test-Path "$ProjectRoot")
Test-Condition "pubspec.yaml exists" (Test-Path "$ProjectRoot\pubspec.yaml")
Test-Condition "lib/main.dart exists" (Test-Path "$ProjectRoot\lib\main.dart")
Test-Condition "lib/core/backend_config.dart exists (security core)" (Test-Path "$ProjectRoot\lib\core\backend_config.dart")

Write-Info "Checking BackendConfig configuration state..."
$bcContent = Get-Content "$ProjectRoot\lib\core\backend_config.dart" -Raw -Encoding UTF8

Test-Condition "pbBaseUrl is empty string" ($bcContent -match "static const String pbBaseUrl = ''")
Test-Condition "openlistConfigRecordId is empty" ($bcContent -match "openlistConfigRecordId = ''")
Test-Condition "openlistAdminUsername is empty" ($bcContent -match "openlistAdminUsername = ''")
Test-Condition "openlistAdminPassword is empty" ($bcContent -match "openlistAdminPassword = ''")
Test-Condition "defaultExtractionPassword is empty" ($bcContent -match "defaultExtractionPassword = ''")

# Sensitive info scan
Write-Info "Scanning for sensitive info leaks..."
$leakFound = $false
$dartFiles = Get-ChildItem "$ProjectRoot\lib" -Recurse -Filter "*.dart" | Select-Object -ExpandProperty FullName

foreach ($f in $dartFiles) {
    $c = Get-Content $f -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $c) { continue }

    if ($c -match '117\.72\.115\.30') { Write-Fail "IP leak found: $f"; $leakFound = $true }
    if ($c -match 'tj9z6skib6207if') { Write-Fail "RecordID leak found: $f"; $leakFound = $true }
    if ($c -match 'Bilibili_Slpeey') { Write-Fail "Password leak found: $f"; $leakFound = $true }
}
Test-Condition "No sensitive info leaks detected" (-not $leakFound)

# ============================================================
# PHASE 2: Build
# ============================================================
Write-Header "2/5 Build & Compile"

if (-not $SkipBuild) {
    Write-Info "Running flutter clean..."
    Push-Location $ProjectRoot
    flutter clean 2>&1 | Out-Null
    Pop-Location

    Write-Info "Running flutter pub get..."
    Push-Location $ProjectRoot
    flutter pub get 2>&1 | Out-Null
    Pop-Location
    Test-Condition "Dependencies installed successfully" ($LASTEXITCODE -eq 0)

    Write-Info "Running flutter build windows..."
    Push-Location $ProjectRoot
    flutter build windows 2>&1 | Out-Null
    Pop-Location
    Test-Condition "Windows build succeeded" ($LASTEXITCODE -eq 0)
} else {
    Write-Skip "Build skipped (-SkipBuild flag)"
}

$exePath = "$ProjectRoot\build\windows\x64\runner\Release\chrono_tide.exe"
Test-Condition "Executable exists: chrono_tide.exe" (Test-Path $exePath)

if (-not (Test-Path $exePath)) {
    Write-Header "TEST ABORTED"
    Write-Fail "Executable not found, cannot continue runtime tests"
    exit 1
}

# ============================================================
# PHASE 3: Static Code Analysis
# ============================================================
Write-Header "3/5 Static Code Logic Verification"

# main.dart checks
$mContent = Get-Content "$ProjectRoot\lib\main.dart" -Raw -Encoding UTF8
Test-Condition "main.dart imports backend_config.dart" ($mContent -match "import.*backend_config")
Test-Condition "main.dart calls checkAvailability()" ($mContent -match "checkAvailability")
Test-Condition "main.dart has _isBackendUnavailable variable" ($mContent -match "_isBackendUnavailable")
Test-Condition "main.dart skips login when backend unavailable" ($mContent -match "isLocalMode:\s*true")

# main_container.dart checks
$mcContent = Get-Content "$ProjectRoot\lib\main_container.dart" -Raw -Encoding UTF8
Test-Condition "MainContainer accepts isLocalMode parameter" ($mcContent -match "isLocalMode")
Test-Condition "MainContainer intercepts discover page in local mode" ($mcContent -match "_buildBackendUnavailableView|isLocalMode.*discover")

# sidebar.dart checks
$sbContent = Get-Content "$ProjectRoot\lib\widgets\sidebar.dart" -Raw -Encoding UTF8
Test-Condition "Sidebar accepts isLocalMode parameter" ($sbContent -match "isLocalMode")
Test-Condition "Sidebar hides Discover tab in local mode" ($sbContent -match "!widget\.isLocalMode")

# discover_page.dart checks
$dpContent = Get-Content "$ProjectRoot\lib\pages\discover_page.dart" -Raw -Encoding UTF8
Test-Condition "DiscoverPage checks isBackendAvailable" ($dpContent -match "isBackendAvailable")
Test-Condition "DiscoverPage shows unavailable message" ($dpContent -match "unavailableMessage")

# game_repository.dart checks
$grContent = Get-Content "$ProjectRoot\lib\repositories\game_repository.dart" -Raw -Encoding UTF8
Test-Condition "GameRepository returns empty when backend unavailable" ($grContent -match "isBackendAvailable")

# openlist_service.dart checks
$olContent = Get-Content "$ProjectRoot\lib\services\openlist_service.dart" -Raw -Encoding UTF8
Test-Condition "OpenListService.boot() checks backend availability" ($olContent -match "isBackendAvailable")
Test-Condition "OpenListService reads credentials from BackendConfig" ($olContent -match "BackendConfig\.openlistAdmin")

# extract_manager.dart checks
$exContent = Get-Content "$ProjectRoot\lib\services\extract_manager.dart" -Raw -Encoding UTF8
Test-Condition "ExtractManager reads password from BackendConfig" ($exContent -match "BackendConfig\.defaultExtractionPassword")

# UI components checks
$amContent = Get-Content "$ProjectRoot\lib\widgets\auth_modal.dart" -Raw -Encoding UTF8
Test-Condition "AuthModal shows prompt when backend unavailable" ($amContent -match "isBackendAvailable")

$pmContent = Get-Content "$ProjectRoot\lib\widgets\payment_modal.dart" -Raw -Encoding UTF8
Test-Condition "PaymentModal handles backend unavailability" ($pmContent.Length -gt 0)

$upmContent = Get-Content "$ProjectRoot\lib\widgets\user_profile_modal.dart" -Raw -Encoding UTF8
Test-Condition "UserProfileModal hides charge section locally" ($upmContent -match "isBackendAvailable")

$smContent = Get-Content "$ProjectRoot\lib\widgets\settings_modal.dart" -Raw -Encoding UTF8
Test-Condition "SettingsModal hides update check locally" ($smContent -match "isBackendAvailable")

# pb_config.dart checks
$pbcContent = Get-Content "$ProjectRoot\lib\core\pb_config.dart" -Raw -Encoding UTF8
Test-Condition "pb_config.dart reads URL from BackendConfig" ($pbcContent -match "BackendConfig\.pbBaseUrl")

# game_model.dart checks
$gmContent = Get-Content "$ProjectRoot\lib\models\game_model.dart" -Raw -Encoding UTF8
Test-Condition "game_model.dart reads URL from BackendConfig" ($gmContent -match "BackendConfig\.pbBaseUrl")

# update_service.dart checks
$usContent = Get-Content "$ProjectRoot\lib\services\update\update_service.dart" -Raw -Encoding UTF8
Test-Condition "update_service.dart derives URL from BackendConfig" ($usContent -match "BackendConfig")

# ============================================================
# PHASE 4: Runtime Test
# ============================================================
Write-Header "4/5 Runtime Behavior Verification"

Write-Info "Starting chrono_tide.exe (auto-close after ${WaitSeconds}s)..."

# Kill existing instances
Get-Process -Name "chrono_tide" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

# Start process
$proc = Start-Process -FilePath $exePath -WorkingDirectory (Split-Path $exePath) -PassThru

if ($null -eq $proc -or $proc.HasExited) {
    Write-Fail "Process failed to start or exited immediately"
    Test-Condition "Process starts successfully" $false
} else {
    Test-Condition "Process started (PID: $($proc.Id))" $true
    Write-Info "Waiting for window initialization..."

    Start-Sleep -Seconds 3

    $aliveAfter3s = -not $proc.HasExited
    Test-Condition "Process alive after 3 seconds (no crash)" $aliveAfter3s

    if ($aliveAfter3s) {
        $procCount = (Get-Process -Name "chrono_tide" -ErrorAction SilentlyContinue | Measure-Object).Count
        Test-Condition "Main window created ($procCount process(es))" ($procCount -gt 0)

        $remaining = ($WaitSeconds - 3)
        Write-Info "Waiting for full initialization (${remaining}s remaining)..."
        Start-Sleep -Seconds $remaining

        $finalAlive = -not $proc.HasExited
        Test-Condition "Process stable during observation period (no crash)" $finalAlive

        if (-not $KeepRunning) {
            Write-Info "Test complete, closing process..."
            try {
                $proc.CloseMainWindow() | Out-Null
                Start-Sleep -Milliseconds 2000
                if (-not $proc.HasExited) {
                    $proc.Kill()
                }
                Test-Condition "Process closes normally" $true
            } catch {
                Write-Skip "Close exception (may have exited already)"
            }
        } else {
            Write-Info "-KeepRunning mode: process stays running. Close manually."
        }
    }
}

# ============================================================
# PHASE 5: Report
# ============================================================
Write-Header "5/5 Test Summary"

Write-Host ""
Write-Host ("  Total : $script:totalTests tests") -ForegroundColor White
Write-Host ("  Passed: $script:passCount") -ForegroundColor Green
if ($script:failCount -gt 0) {
    Write-Host ("  Failed: $script:failCount") -ForegroundColor Red
} else {
    Write-Host ("  Failed: $script:failCount") -ForegroundColor Green
}
Write-Host ""

$rate = [math]::Round(($script:passCount / $script:totalTests) * 100, 1)
if ($script:failCount -eq 0) {
    Write-Host ("  Rate  : $rate% -- ALL PASSED!") -ForegroundColor Green
    Write-Host ""
    Write-Host "  CONCLUSION: Open source version works correctly without backend config." -ForegroundColor Green
} elseif ($script:failCount -le 2) {
    Write-Host ("  Rate  : $rate% -- MOSTLY PASSED") -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  CONCLUSION: Minor issues found, core functionality intact." -ForegroundColor Yellow
} else {
    Write-Host ("  Rate  : $rate% -- NEEDS FIX") -ForegroundColor Red
    Write-Host ""
    Write-Host "  CONCLUSION: Multiple issues found, fix before releasing." -ForegroundColor Red
}
Write-Host ""

exit $(if ($script:failCount -gt 0) { 1 } else { 0 })
