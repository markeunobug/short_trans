param(
    [string]$Compiler = "arm-none-eabi-gcc",
    [switch]$KeepBuildDirectory
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$compilerCommand = Get-Command $Compiler -ErrorAction Stop
$gcc = $compilerCommand.Source
$size = Join-Path (Split-Path -Parent $gcc) "arm-none-eabi-size.exe"

if (-not (Test-Path -LiteralPath $size)) {
    throw "arm-none-eabi-size.exe was not found next to $gcc"
}

$includes = @(
    "-ICore/Inc",
    "-IDrivers/STM32G4xx_HAL_Driver/Inc",
    "-IDrivers/STM32G4xx_HAL_Driver/Inc/Legacy",
    "-IDrivers/CMSIS/Device/ST/STM32G4xx/Include",
    "-IDrivers/CMSIS/Include"
)
$defines = @("-DUSE_HAL_DRIVER", "-DSTM32G431xx")

Push-Location $projectRoot
try {
    Write-Output "[1/2] Hard-float strict syntax check"
    & $gcc "-mcpu=cortex-m4" "-mthumb" "-mfpu=fpv4-sp-d16" `
        "-mfloat-abi=hard" @defines @includes "-std=gnu11" "-Wall" `
        "-Wextra" "-Werror" "-fsyntax-only" "Core/Src/fpga_rx_spi.c" `
        "Core/Src/fpga_rx_spi_stm32.c" "Core/Src/rs485_half_duplex.c" `
        "Core/Src/main.c"
    if ($LASTEXITCODE -ne 0) {
        throw "Hard-float syntax check failed"
    }

    Write-Output "[2/2] Full firmware compile and link integration check"
    $buildDirectory = Join-Path $env:TEMP `
        ("short_trans_rx_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $buildDirectory | Out-Null

    $common = @(
        "-mcpu=cortex-m4",
        "-mthumb",
        "-mfloat-abi=soft",
        "-Os",
        "-ffunction-sections",
        "-fdata-sections"
    )
    $objects = @()
    $sources = @(Get-ChildItem -File "Core/Src/*.c") +
               @(Get-ChildItem -File "Drivers/STM32G4xx_HAL_Driver/Src/*.c")

    foreach ($source in $sources) {
        $object = Join-Path $buildDirectory ($source.BaseName + ".o")
        & $gcc @common @defines @includes "-std=gnu11" "-Wall" "-Wextra" `
            "-c" $source.FullName "-o" $object
        if ($LASTEXITCODE -ne 0) {
            throw "Compile failed: $($source.FullName)"
        }
        $objects += $object
    }

    $startupObject = Join-Path $buildDirectory "startup.o"
    & $gcc @common "-x" "assembler-with-cpp" "-c" `
        "Core/Startup/startup_stm32g431rbtx.s" "-o" $startupObject
    if ($LASTEXITCODE -ne 0) {
        throw "Startup compile failed"
    }
    $objects += $startupObject

    $elf = Join-Path $buildDirectory "rx_stm32.elf"
    $mapArgument = "-Wl,-Map=" + (Join-Path $buildDirectory "rx_stm32.map")
    & $gcc @common @objects "-TSTM32G431RBTX_FLASH.ld" "-Wl,--gc-sections" `
        $mapArgument "-Wl,--start-group" "-lc" "-lm" "-lgcc" `
        "-Wl,--end-group" "-o" $elf
    if ($LASTEXITCODE -ne 0) {
        throw "Firmware link failed"
    }

    & $size $elf
    if ($LASTEXITCODE -ne 0) {
        throw "Size reporting failed"
    }
    Write-Output ("PASS: compiled {0} C sources and linked the firmware" -f $sources.Count)
}
finally {
    Pop-Location
    if ((-not $KeepBuildDirectory) -and $buildDirectory -and
        (Test-Path -LiteralPath $buildDirectory)) {
        $resolvedBuild = (Resolve-Path -LiteralPath $buildDirectory).Path
        $resolvedTemp = (Resolve-Path -LiteralPath $env:TEMP).Path
        if ($resolvedBuild.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedBuild -Recurse -Force
        }
        else {
            throw "Refusing to remove build directory outside TEMP: $resolvedBuild"
        }
    }
}
