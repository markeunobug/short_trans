param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('samples', 'metrics', 'symbols', 'frames')]
    [string]$Preset,

    [switch]$Compile
)

$ErrorActionPreference = 'Stop'
$projectDir = Split-Path -Parent $PSScriptRoot
$quartusRoot = 'C:\software\quartus22_1\quartus'
$quartusStp = Join-Path $quartusRoot 'bin64\quartus_stp.exe'
$quartusSh = Join-Path $quartusRoot 'bin64\quartus_sh.exe'

$presetFiles = @{
    samples = 'SignalTap/FSK_1_SAMPLES_20BIT.stp'
    metrics = 'SignalTap/FSK_2_DEMOD_METRICS.stp'
    symbols = 'SignalTap/FSK_3_SYMBOLS.stp'
    frames  = 'SignalTap/FSK_4_FRAME_RESULT.stp'
}

if (-not (Test-Path -LiteralPath $quartusStp -PathType Leaf)) {
    throw "Quartus Prime 22.1 was not found at $quartusRoot"
}

$env:QUARTUS_ROOTDIR = $quartusRoot
$env:QSYS_ROOTDIR = Join-Path $quartusRoot 'sopc_builder\bin'
$env:SOPC_KIT_NIOS2 = 'C:\software\quartus22_1\nios2eds'
$env:PATH = (Join-Path $quartusRoot 'bin64') + ';' + $env:PATH

Push-Location -LiteralPath $projectDir
try {
    $presetFile = $presetFiles[$Preset]
    & $quartusStp rx_cyclone10 --signaltap --enable "--stp_file=$presetFile"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to activate SignalTap preset '$Preset'."
    }

    Write-Host "Active SignalTap preset: $Preset"
    Write-Host "File: $presetFile"

    if ($Compile) {
        & $quartusSh --clean rx_cyclone10
        if ($LASTEXITCODE -ne 0) {
            throw 'Quartus project clean failed.'
        }

        & $quartusSh --flow compile rx_cyclone10
        if ($LASTEXITCODE -ne 0) {
            throw 'Quartus full compilation failed.'
        }
    } else {
        Write-Host 'The preset change requires a full compilation before programming the FPGA.'
    }
} finally {
    Pop-Location
}
