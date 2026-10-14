[CmdletBinding()]
param(
    [ValidateSet('all', 'common', 'adc', 'demod', 'sync', 'protocol', 'spi', 'integration', 'misc')]
    [string]$Group = 'all',
    [switch]$SkipVectorGeneration,
    [switch]$ListOnly
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$tbRoot = Join-Path $projectRoot 'tb'
$rtlRoot = Join-Path $projectRoot 'rtl'
$generatedRoot = Join-Path $PSScriptRoot 'generated'
$runRoot = Join-Path $PSScriptRoot '.regression'
$logRoot = Join-Path $runRoot 'logs'

function Get-TestGroup([string]$name) {
    if ($name -like 'common_*') { return 'common' }
    if ($name -like 'adc_*' -or $name -like 'i2s_*') { return 'adc' }
    if ($name -match 'symbol_sync|^sync_') { return 'sync' }
    if ($name -like 'protocol_*') { return 'protocol' }
    if ($name -like 'spi_*') { return 'spi' }
    if ($name -like 'integration_*') { return 'integration' }
    if ($name -like 'fsk_*') { return 'demod' }
    return 'misc'
}

# These benches require manifest-driven arguments; run them with run_ook_vectors.py.
$manifestDrivenTests = @('ook_validation_vectors_tb', 'ook_tx_fixture_chain_tb')
$tests = @(Get-ChildItem -LiteralPath $tbRoot -File -Filter '*.sv' | Where-Object { $_.BaseName -notin $manifestDrivenTests } | Sort-Object Name | ForEach-Object {
    [pscustomobject]@{
        File = $_.FullName
        Module = $_.BaseName
        Group = Get-TestGroup $_.BaseName
    }
})
if ($Group -ne 'all') {
    $tests = @($tests | Where-Object Group -eq $Group)
}

if ($ListOnly) {
    $tests | Format-Table Group, Module, File -AutoSize
    exit 0
}
if ($tests.Count -eq 0) {
    Write-Error "No testbenches found for group '$Group'."
    exit 4
}

$requiredCommands = @('vlib', 'vlog', 'vsim', 'python')
foreach ($commandName in $requiredCommands) {
    if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        Write-Error "Required command '$commandName' is not available on PATH."
        exit 3
    }
}

if (-not $SkipVectorGeneration) {
    & python (Join-Path $projectRoot 'tools\gen_fsk_vectors.py') --output $generatedRoot
    if ($LASTEXITCODE -ne 0) {
        Write-Error "FSK vector generation failed with exit code $LASTEXITCODE."
        exit 3
    }
}

$resolvedProject = [IO.Path]::GetFullPath($projectRoot).TrimEnd('\') + '\'
$resolvedRun = [IO.Path]::GetFullPath($runRoot)
if (-not $resolvedRun.StartsWith($resolvedProject, [StringComparison]::OrdinalIgnoreCase)) {
    Write-Error "Refusing to prepare regression directory outside the FPGA project: $resolvedRun"
    exit 3
}
if (Test-Path -LiteralPath $runRoot) {
    Remove-Item -LiteralPath $runRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
$stagedTbRoot = Join-Path $runRoot 'tb'
New-Item -ItemType Directory -Path $stagedTbRoot -Force | Out-Null
Get-ChildItem -LiteralPath $tbRoot -File | Where-Object Extension -ne '.sv' | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $stagedTbRoot $_.Name)
}

$rtlSources = @(Get-ChildItem -LiteralPath $rtlRoot -Recurse -File -Filter '*.v' | Sort-Object FullName | Select-Object -ExpandProperty FullName)
$includeDirs = @(Get-ChildItem -LiteralPath $rtlRoot -Recurse -Directory | Sort-Object FullName | Select-Object -ExpandProperty FullName)

Push-Location $runRoot
try {
    & vlib work 2>&1 | Tee-Object -FilePath (Join-Path $logRoot 'vlib.log')
    if ($LASTEXITCODE -ne 0) { exit 2 }

    $vlogArgs = @('-sv', '-work', 'work')
    foreach ($includeDir in $includeDirs) {
        $vlogArgs += "+incdir+$includeDir"
    }
    $vlogArgs += $rtlSources
    $vlogArgs += @($tests.File)
    & vlog @vlogArgs 2>&1 | Tee-Object -FilePath (Join-Path $logRoot 'vlog.log')
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'RTL/testbench compilation: FAIL'
        exit 2
    }

    $manifest = $null
    $vectorScenario = $null
    $manifestPath = Join-Path $generatedRoot 'manifest.json'
    if (Test-Path -LiteralPath $manifestPath) {
        $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
        $vectorScenario = $manifest.scenarios | Where-Object name -eq 'complete_frame_nominal' | Select-Object -First 1
    }

    $passed = 0
    $failed = 0
    $skipped = 0
    foreach ($test in $tests) {
        $logPath = Join-Path $logRoot ($test.Module + '.log')
        $vsimArgs = @('-c', '-lib', 'work', $test.Module, '-l', $logPath)
        if ($test.Module -in @('integration_vector_contract_tb', 'integration_rx_chain_tb')) {
            if (-not $vectorScenario) {
                Write-Host "[$($test.Group)] $($test.Module): FAIL (generated manifest missing)"
                $failed++
                continue
            }
            $sampleFile = (Join-Path $generatedRoot $vectorScenario.files.samples_i20_mem).Replace('\', '/')
            $frameFile = (Join-Path $generatedRoot $vectorScenario.files.frame_hex).Replace('\', '/')
            $vsimArgs += "+SAMPLE_FILE=$sampleFile"
            $vsimArgs += "+FRAME_FILE=$frameFile"
            $vsimArgs += "+SAMPLE_COUNT=$($vectorScenario.sample_count)"
            $vsimArgs += "+FRAME_BYTE_COUNT=$($vectorScenario.frame_byte_count)"
            $vsimArgs += "+SYNC_WORD=$($manifest.parameters.sync_word_hex)"
            if ($test.Module -eq 'integration_vector_contract_tb') {
                $bitFile = (Join-Path $generatedRoot $vectorScenario.files.bits_mem).Replace('\', '/')
                $vsimArgs += "+BIT_FILE=$bitFile"
                $vsimArgs += "+BIT_COUNT=$($vectorScenario.bit_count)"
            }
        }
        $vsimArgs += @('-do', 'onerror {quit -code 1}; run -all; quit -code 0')

        $console = (& vsim @vsimArgs 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
        $text = if (Test-Path -LiteralPath $logPath) { Get-Content -Raw -LiteralPath $logPath } else { $console }

        if ($text -match 'SKIP:\s*END_TO_END_RTL_NOT_READY') {
            Write-Host "[$($test.Group)] $($test.Module): SKIP (end-to-end RTL not integrated)"
            $skipped++
        } elseif ($exitCode -ne 0 -or $text -match '(?im)^\s*(\*\*\s+)?(Error|Fatal):' -or $text -match '(?im)\bFAIL(?:\s|:|\()') {
            Write-Host "[$($test.Group)] $($test.Module): FAIL (see $logPath)"
            $failed++
        } elseif ($text -match '(?im)\bPASS(?:\s|:|\))') {
            Write-Host "[$($test.Group)] $($test.Module): PASS"
            $passed++
        } else {
            Write-Host "[$($test.Group)] $($test.Module): FAIL (no explicit PASS marker)"
            $failed++
        }
    }

    Write-Host "Summary: PASS=$passed FAIL=$failed SKIP=$skipped"
    $hasE2eBench = @($tests | Where-Object Module -eq 'integration_rx_chain_tb').Count -gt 0
    if (-not $hasE2eBench) {
        Write-Host 'End-to-end RTL status: NOT READY (integration_rx_chain_tb is absent)'
    } elseif ($failed -eq 0) {
        Write-Host 'End-to-end RTL status: PASS (20-bit samples through frame payload output)'
    }
    if ($failed -gt 0) { exit 1 }
    exit 0
}
finally {
    Pop-Location
}
