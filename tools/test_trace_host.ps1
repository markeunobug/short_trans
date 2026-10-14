$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot/..").Path
$project = Join-Path $root 'code/stm32/rx_stm32'
$run = Join-Path $root '_codex/trace'
New-Item -ItemType Directory -Force -Path $run | Out-Null
& gcc -std=c11 -Wall -Wextra -Werror -pedantic "-I$project/Core/Inc" "$project/Core/Src/fpga_rx_spi.c" "$project/Core/Src/rx_command_text.c" "$project/Core/Src/rx_trace.c" "$project/Tests/rx_trace_test.c" -o "$run/rx_trace_test.exe"
if ($LASTEXITCODE) { throw 'trace native compile failed' }
& "$run/rx_trace_test.exe" "$run/rtl/rtl_capture.bin" "$run/uart_capture.bin"
if ($LASTEXITCODE) { throw 'trace native test failed' }
