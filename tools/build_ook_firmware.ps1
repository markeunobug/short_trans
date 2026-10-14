param(
    [ValidateSet('tx_stm32','rx_stm32')][string]$Target,
    [string]$Compiler = 'C:\software\STM32CubeIDE_1.13.1\STM32CubeIDE\plugins\com.st.stm32cube.ide.mcu.externaltools.gnu-tools-for-stm32.11.3.rel1.win32_1.1.0.202305231506\tools\bin\arm-none-eabi-gcc.exe'
)
$ErrorActionPreference = 'Stop'
if (-not $Target) { throw 'Specify -Target tx_stm32 or rx_stm32' }
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "../code/stm32/$Target")).Path
$compilerPath = (Get-Command $Compiler -ErrorAction Stop).Source
$binPath = Split-Path -Parent $compilerPath
$buildRoot = Join-Path $projectRoot ('Tests/build_ook_hardfloat_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $buildRoot | Out-Null
$common = @('-mcpu=cortex-m4','-mthumb','-mfpu=fpv4-sp-d16','-mfloat-abi=hard','-Os','-ffunction-sections','-fdata-sections')
$defines = @('-DUSE_HAL_DRIVER','-DSTM32G431xx')
$includes = @('-ICore/Inc','-IDrivers/STM32G4xx_HAL_Driver/Inc','-IDrivers/STM32G4xx_HAL_Driver/Inc/Legacy','-IDrivers/CMSIS/Device/ST/STM32G4xx/Include','-IDrivers/CMSIS/Include')
$objects = @()
Push-Location $projectRoot
try {
    $sources = @(Get-ChildItem -File Core/Src/*.c) + @(Get-ChildItem -File Drivers/STM32G4xx_HAL_Driver/Src/*.c)
    foreach ($source in $sources) {
        $obj = Join-Path $buildRoot ($source.BaseName + '.o')
        & $compilerPath @common @defines @includes '-std=gnu11' '-Wall' '-Wextra' '-Werror' '-c' $source.FullName '-o' $obj
        if ($LASTEXITCODE -ne 0) { throw "Compile failed: $($source.FullName)" }
        $objects += $obj
    }
    $startup = Join-Path $buildRoot 'startup.o'
    & $compilerPath @common @defines @includes '-x' 'assembler-with-cpp' '-c' 'Core/Startup/startup_stm32g431rbtx.s' '-o' $startup
    if ($LASTEXITCODE -ne 0) { throw 'Startup failed' }
    $objects += $startup
    $elf = Join-Path $buildRoot ($Target + '_ook.elf')
    & $compilerPath @common @objects '-TSTM32G431RBTX_FLASH.ld' '-Wl,--gc-sections' "-Wl,-Map=$buildRoot/$Target.map" '--specs=nano.specs' '--specs=nosys.specs' '-Wl,--start-group' '-lc' '-lm' '-lgcc' '-Wl,--end-group' '-o' $elf
    if ($LASTEXITCODE -ne 0) { throw 'Hard-float link failed' }
    & (Join-Path $binPath arm-none-eabi-size.exe) $elf
    if ($LASTEXITCODE -ne 0) { throw 'Size failed' }
    foreach ($format in @(@('ihex','hex'),@('binary','bin'))) {
        & (Join-Path $binPath arm-none-eabi-objcopy.exe) '-O' $format[0] $elf (Join-Path $buildRoot ($Target + '_ook.' + $format[1]))
        if ($LASTEXITCODE -ne 0) { throw 'Object conversion failed' }
    }
    $sources | ForEach-Object { Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256 } | Select-Object Path,Hash | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $buildRoot 'source_hashes.json') -Encoding utf8
    Get-FileHash -LiteralPath $elf -Algorithm SHA256
    Write-Output "PASS hard-float compile and link: $elf"
}
finally { Pop-Location }
