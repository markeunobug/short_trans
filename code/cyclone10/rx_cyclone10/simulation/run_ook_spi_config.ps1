param()

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runRoot = Join-Path $projectRoot (Join-Path '_codex\ook_spi' ([guid]::NewGuid().ToString('N')))
$logPath = Join-Path $runRoot 'ook_spi_config.log'
$rtl = @(
    'rtl/common/reset_sync.v',
    'rtl/spi/rx_frame_fifo.v',
    'rtl/spi/spi_register_bank.v',
    'rtl/spi/spi1_slave.v',
    'tb/ook_spi_config_tb.sv'
) | ForEach-Object { Join-Path $projectRoot $_ }

New-Item -ItemType Directory -Path $runRoot | Out-Null
Push-Location $runRoot
try {
    & vlib work 2>&1 | Tee-Object -FilePath $logPath
    if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
    & vlog -sv -work work @rtl 2>&1 | Tee-Object -FilePath $logPath -Append
    if ($LASTEXITCODE -ne 0) { throw 'vlog failed' }
    & vsim -c -lib work ook_spi_config_tb -do 'onerror {quit -code 1}; run -all; quit -code 0' 2>&1 |
        Tee-Object -FilePath $logPath -Append
    if ($LASTEXITCODE -ne 0) { throw 'vsim failed' }
    $log = Get-Content -Raw -LiteralPath $logPath
    if (($log -notmatch '(?m)^#\s+ook_spi_config_tb: PASS\s*$') -or
        ($log -match '(?im)\bFAIL\b|\bFatal:|\*\*\s+Error:')) {
        throw "OOK SPI configuration test did not pass; see $logPath"
    }
    Write-Output "PASS: OOK SPI configuration test log: $logPath"
}
finally {
    Pop-Location
}
