"""Build TX diagnostic images in unique directories, never flash or clean.

Builds Debug -O0 (to reproduce the user's CubeIDE Debug behavior) and -Os as
separate alternatives. Compare raw UART DIAG timings before changing priorities.
"""
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import subprocess
import uuid

PROJECT = Path(__file__).resolve().parents[1]
ROOT = PROJECT.parents[2]
DEFAULT_COMPILER = Path("C:/software/STM32CubeIDE_1.13.1/STM32CubeIDE/plugins/"
    "com.st.stm32cube.ide.mcu.externaltools.gnu-tools-for-stm32.11.3.rel1.win32_1.1.0.202305231506/"
    "tools/bin/arm-none-eabi-gcc.exe")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gcc", type=Path, default=DEFAULT_COMPILER)
    parser.add_argument("--output", type=Path, default=ROOT / "_codex/ber_20261102/tx_uart_diag_20261105")
    parser.add_argument("--optimization", choices=("both", "O0", "Os"), default="both")
    args = parser.parse_args()
    # Compiler runs from PROJECT; preserve the caller-relative output directory.
    args.output = args.output.resolve()
    build = args.output / ("target_" + dt.datetime.now().strftime("%Y%m%d_%H%M%S_") + uuid.uuid4().hex[:6])
    build.mkdir(parents=True)
    sources = sorted((PROJECT / "Core/Src").glob("*.c")) + sorted((PROJECT / "Drivers/STM32G4xx_HAL_Driver/Src").glob("*.c"))
    inputs = list((PROJECT / "Core").rglob("*")) + list((PROJECT / "Drivers").rglob("*")) + [PROJECT / "STM32G431RBTX_FLASH.ld"]
    hashes = {str(p.relative_to(PROJECT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs if p.is_file()}
    (build / "source_hashes.json").write_text(json.dumps(hashes, indent=2))
    includes = ["-ICore/Inc", "-IDrivers/STM32G4xx_HAL_Driver/Inc", "-IDrivers/STM32G4xx_HAL_Driver/Inc/Legacy",
                "-IDrivers/CMSIS/Device/ST/STM32G4xx/Include", "-IDrivers/CMSIS/Include"]
    cpu = ["-mcpu=cortex-m4", "-mthumb", "-mfpu=fpv4-sp-d16", "-mfloat-abi=hard"]
    log = (build / "build.log").open("w", encoding="utf-8")

    def run(command):
        log.write(json.dumps([str(x) for x in command]) + "\n"); log.flush()
        subprocess.run([str(x) for x in command], cwd=PROJECT, stdout=log, stderr=subprocess.STDOUT, check=True)

    results = []
    try:
        for opt in (("O0", "Os") if args.optimization == "both" else (args.optimization,)):
            out = build / opt; out.mkdir()
            print("BUILD", opt, out, flush=True)
            flags = [*cpu, "-" + opt, "-g3", "-ffunction-sections", "-fdata-sections", "-fstack-usage"]
            objects = []
            for source in sources:
                obj = out / (source.stem + ".o")
                warnings = ["-Wall", "-Wextra"] + (["-Werror"] if "Core" in source.parts else [])
                run([args.gcc, *flags, *includes, "-DUSE_HAL_DRIVER", "-DSTM32G431xx", "-std=gnu11", *warnings,
                     "-c", source, "-o", obj])
                objects.append(obj)
            startup = out / "startup.o"
            run([args.gcc, *flags, "-x", "assembler-with-cpp", "-c", PROJECT / "Core/Startup/startup_stm32g431rbtx.s", "-o", startup])
            elf = out / "tx_uart_diag.elf"
            run([args.gcc, *flags, *objects, startup, "-TSTM32G431RBTX_FLASH.ld", "--specs=nano.specs", "--specs=nosys.specs",
                 "-Wl,--gc-sections", "-Wl,-Map=" + str(out / "tx_uart_diag.map"), "-Wl,--start-group", "-lc", "-lm", "-lgcc", "-Wl,--end-group", "-o", elf])
            for fmt, ext in (("ihex", "hex"), ("binary", "bin")):
                run([args.gcc.with_name("arm-none-eabi-objcopy.exe"), "-O", fmt, elf, out / ("tx_uart_diag." + ext)])
            size = subprocess.run([str(args.gcc.with_name("arm-none-eabi-size.exe")), str(elf)], capture_output=True, text=True, check=True)
            (out / "size.log").write_text(size.stdout)
            print(size.stdout, end="", flush=True)
            # Keep compiler output for static review; not a hardware-cycle measurement.
            with (out / "fsk_tx_disassembly.txt").open("w") as asm:
                subprocess.run([str(args.gcc.with_name("arm-none-eabi-objdump.exe")), "-dr", str(out / "fsk_tx.o")], stdout=asm, check=True)
            results.append({"optimization": opt, "elf": str(elf), "elf_sha256": hashlib.sha256(elf.read_bytes()).hexdigest(), "flash_performed": False})
        drift = [name for name, before in hashes.items() if hashlib.sha256((PROJECT / name).read_bytes()).hexdigest() != before]
        if drift:
            raise RuntimeError(f"Build input changed: {drift}")
        (build / "results.json").write_text(json.dumps(results, indent=2))
        print("PASS TX diagnostic build, source stable, no flash:", build, flush=True)
    finally:
        log.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
