<#
.SYNOPSIS
  Stage the Idemia HSM Simulator (SPHERE, SoftHSM2 backend) on Windows and
  initialise a token for the KMS tests.

.DESCRIPTION
  The Idemia HSM Simulator is a Windows-only PKCS#11 DLL (librooky-simulator.dll).
  In NON_FIPS mode it forwards every call to SoftHSM2 (C:\SoftHSMv2), in FIPS
  mode C_WrapKey / C_UnwrapKey / C_DeriveKey return CKR_FUNCTION_NOT_SUPPORTED.

  The script:
    1. gets the package (local -PackageDir, else downloaded from -PackageUrl),
    2. installs SoftHSM2 in C:\SoftHSMv2 and writes its softhsm2.conf,
    3. installs the simulator in C:\Idemia_HSM_Simulator and forces SECURITY_LEVEL,
    4. initialises a fresh token (label idemia_sim),
    5. writes a dotenv file (-EnvFile) and, in GitHub Actions, GITHUB_ENV / GITHUB_PATH.

  Runs unchanged under Windows PowerShell 5.1 and PowerShell 7.

.EXAMPLE
  .\.github\reusable_scripts\prepare_idemia_hsm.ps1 -PackageDir 'C:\Users\me\Downloads\HSM Simulator V0.0.0.1'
#>
param(
    [string]$PackageDir = $env:IDEMIA_SIM_PACKAGE_DIR,
    [string]$PackageUrl = $(if ($env:IDEMIA_SIM_PACKAGE_URL) { $env:IDEMIA_SIM_PACKAGE_URL } else { "https://package.cosmian.com/ci/hsm-idemia-simulator.zip" }),
    [string]$SimRoot = "C:\Idemia_HSM_Simulator",
    [string]$SoftHsmRoot = "C:\SoftHSMv2",
    [ValidateSet("NON_FIPS", "FIPS")]
    [string]$SecurityLevel = "NON_FIPS",
    [string]$Pin = "12345678",
    # INFO logs one line per PKCS#11 call; DEBUG logs every frame (hundreds of MB over a full test run).
    [ValidateSet("INFO", "DEBUG")]
    [string]$LogLevel = "INFO",
    [string]$EnvFile = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# -- 1. Guard -----------------------------------------------------------------
if ($env:OS -ne "Windows_NT") { throw "prepare_idemia_hsm.ps1 runs on Windows only" }

# Repo root: the script lives in the .github\reusable_scripts submodule.
$scriptDir = (Resolve-Path -LiteralPath $PSScriptRoot).Path
if ($scriptDir -match '[\\/]\.github[\\/]reusable_scripts$') {
    $repoRoot = (Resolve-Path -LiteralPath (Join-Path $scriptDir "..\..")).Path
} else {
    $repoRoot = (Get-Location).Path
}
if (-not $EnvFile) { $EnvFile = Join-Path $repoRoot ".idemia-sim\env" }

$simDllName = "librooky-simulator.dll"
$simCfgName = "rooky-simulator.cfg"
$softHsmZipName = "SoftHSM V2.7.0.zip"

# Run a native program through cmd /c so that stderr never reaches PowerShell
# (5.1 raises NativeCommandError on any stderr output under $ErrorActionPreference=Stop).
function Invoke-Native {
    param([string]$Exe, [string]$Arguments)
    $out = cmd /c "`"$Exe`" $Arguments 2>&1"
    $code = $LASTEXITCODE
    $text = ($out | ForEach-Object { "$_" }) -join "`n"
    if ($code -ne 0) { throw "$Exe failed with exit code ${code}:`n$text" }
    return $text
}

# -- 2. Package ---------------------------------------------------------------
if (-not $PackageDir) {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "idemia-pkg"
    if (Test-Path -LiteralPath $tmp) { Remove-Item -Recurse -Force -LiteralPath $tmp }
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $zip = Join-Path ([System.IO.Path]::GetTempPath()) "idemia-pkg.zip"
    Write-Host "Downloading $PackageUrl"
    Invoke-WebRequest -UseBasicParsing -Uri $PackageUrl -OutFile $zip
    Expand-Archive -Force -LiteralPath $zip -DestinationPath $tmp
    $PackageDir = $tmp
}
foreach ($f in @($simDllName, $simCfgName, $softHsmZipName)) {
    if (-not (Test-Path -LiteralPath (Join-Path $PackageDir $f))) { throw "missing $f in $PackageDir" }
}

# -- 3. SoftHSM2 --------------------------------------------------------------
if ((Split-Path $SoftHsmRoot -Leaf) -ne "SoftHSMv2") {
    throw "-SoftHsmRoot must end in 'SoftHSMv2': the simulator cfg hard-codes C:\SoftHSMv2 and the zip top folder is SoftHSMv2"
}
if (Test-Path -LiteralPath $SoftHsmRoot) { Remove-Item -Recurse -Force -LiteralPath $SoftHsmRoot }
Expand-Archive -Force -LiteralPath (Join-Path $PackageDir $softHsmZipName) -DestinationPath (Split-Path $SoftHsmRoot)
$tokenDir = Join-Path $SoftHsmRoot "var\softhsm2\tokens"
New-Item -ItemType Directory -Force -Path $tokenDir | Out-Null

$softHsmConf = Join-Path $SoftHsmRoot "etc\softhsm2.conf"
New-Item -ItemType Directory -Force -Path (Split-Path $softHsmConf) | Out-Null
Set-Content -Encoding ASCII -LiteralPath $softHsmConf -Value @(
    "directories.tokendir = $tokenDir",
    "objectstore.backend = file",
    "objectstore.umask = 0077",
    "log.level = INFO",
    "slots.removable = false",
    "slots.mechanisms = ALL",
    "library.reset_on_fork = false"
)

# The SoftHSM2 zip does not ship its OpenSSL runtime (libcrypto-3-x64.dll, MSYS2/mingw build).
# Take it from the package dir if present, else from Git for Windows (mingw64\bin: same build,
# present on the GitHub windows runners).
$libcrypto = "libcrypto-3-x64.dll"
$softHsmBinDir = Join-Path $SoftHsmRoot "bin"
if (-not (Test-Path -LiteralPath (Join-Path $softHsmBinDir $libcrypto))) {
    $candidates = @((Join-Path $PackageDir $libcrypto))
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCmd) { $candidates += (Join-Path (Split-Path (Split-Path $gitCmd.Source)) "mingw64\bin\$libcrypto") }
    $candidates += (Join-Path $env:ProgramFiles "Git\mingw64\bin\$libcrypto")
    $found = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $found) { throw "$libcrypto not found (needed by SoftHSM2); looked in: $($candidates -join ', ')" }
    Copy-Item -Force -LiteralPath $found -Destination $softHsmBinDir
    Write-Host "Using $libcrypto from $found"
}
foreach ($rel in @(
        "lib\softhsm\libsofthsm2.dll",
        "bin\libgcc_s_seh-1.dll",
        "bin\libstdc++-6.dll",
        "bin\libwinpthread-1.dll",
        "bin\softhsm2-util.exe")) {
    if (-not (Test-Path -LiteralPath (Join-Path $SoftHsmRoot $rel))) { throw "missing $rel in $SoftHsmRoot" }
}

# -- 4. Simulator -------------------------------------------------------------
New-Item -ItemType Directory -Force -Path (Join-Path $SimRoot "log") | Out-Null
Copy-Item -Force -LiteralPath (Join-Path $PackageDir $simDllName) -Destination $SimRoot
$cfg = Join-Path $SimRoot $simCfgName
Copy-Item -Force -LiteralPath (Join-Path $PackageDir $simCfgName) -Destination $cfg
(Get-Content -LiteralPath $cfg) `
    -replace '^\s*SECURITY_LEVEL\s*=.*$', "SECURITY_LEVEL = $SecurityLevel" `
    -replace '^\s*LOG_LEVEL\s*=.*$', "LOG_LEVEL = $LogLevel" |
    Set-Content -Encoding ASCII -LiteralPath $cfg
Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath (Join-Path $SimRoot "log\HSM_simulator.log")
foreach ($expected in @(
        "SECURITY_LEVEL = $SecurityLevel",
        "PKCS11_DLL_PATH = C:\SoftHSMv2\lib\softhsm\libsofthsm2.dll",
        "LOG_PATH = C:\Idemia_HSM_Simulator\log\HSM_simulator.log",
        "IS_HSM_IDEMIA_SPHERE = false")) {
    if (-not (Select-String -LiteralPath $cfg -SimpleMatch -Quiet -Pattern $expected)) {
        throw "$cfg does not contain '$expected'"
    }
}

# -- 5. Token -----------------------------------------------------------------
# Process-local only: the machine-wide SOFTHSM2_CONF is left untouched.
$env:SOFTHSM2_CONF = $softHsmConf
$softHsmBin = Join-Path $SoftHsmRoot "bin"
$env:PATH = "$softHsmBin;$env:PATH"
$initOut = Invoke-Native (Join-Path $softHsmBin "softhsm2-util.exe") "--init-token --free --label idemia_sim --so-pin $Pin --pin $Pin"
Write-Host $initOut
$m = [regex]::Match($initOut, 'reassigned to slot (\d+)')
if (-not $m.Success) { throw "could not find the slot id in softhsm2-util output" }
$slot = $m.Groups[1].Value

# -- 6. Output ----------------------------------------------------------------
$lines = @(
    "IDEMIA_SPHERE_PKCS11_LIB=$(Join-Path $SimRoot $simDllName)",
    "SOFTHSM2_CONF=$softHsmConf",
    "HSM_MODEL=idemia_sphere",
    "HSM_USER_PASSWORD=$Pin",
    "HSM_SLOT_ID=$slot"
)
New-Item -ItemType Directory -Force -Path (Split-Path $EnvFile) | Out-Null
Set-Content -Encoding ASCII -LiteralPath $EnvFile -Value ($lines + "IDEMIA_SOFTHSM_BIN=$softHsmBin")
if ($env:GITHUB_ENV) { Add-Content -Encoding utf8 -LiteralPath $env:GITHUB_ENV -Value $lines }
if ($env:GITHUB_PATH) { Add-Content -Encoding utf8 -LiteralPath $env:GITHUB_PATH -Value $softHsmBin }

Write-Host "Idemia simulator ready ($SecurityLevel): slot $slot, env file $EnvFile"
