param(
    [string]$Compiler = "gcc"
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$compilerPath = (Get-Command $Compiler -ErrorAction Stop).Source
$output = Join-Path $env:TEMP ("fpga_rx_spi_test_" + [guid]::NewGuid().ToString("N") + ".exe")

Push-Location $projectRoot
try {
    & $compilerPath `
        "-std=c11" `
        "-Wall" `
        "-Wextra" `
        "-Werror" `
        "-pedantic" `
        "-ICore/Inc" `
        "Core/Src/fpga_rx_spi.c" `
        "Tests/fpga_rx_spi_test.c" `
        "-o" $output
    if ($LASTEXITCODE -ne 0) {
        throw "Host test compilation failed"
    }

    & $output
    if ($LASTEXITCODE -ne 0) {
        throw "Host test failed"
    }

    & $compilerPath `
        "-std=c11" `
        "-Wall" `
        "-Wextra" `
        "-Werror" `
        "-pedantic" `
        "-DFPGA_RX_SPI_ENABLE_STM32_HAL" `
        "-ITests/fpga_rx_spi_hal_mock" `
        "-ICore/Inc" `
        "-fsyntax-only" `
        "Core/Src/fpga_rx_spi.c"
    if ($LASTEXITCODE -ne 0) {
        throw "HAL adapter syntax check failed"
    }

    Write-Output "PASS: optional STM32 HAL adapter compiled against the mock HAL"
}
finally {
    Pop-Location
    if (Test-Path -LiteralPath $output) {
        Remove-Item -LiteralPath $output -Force
    }
}
