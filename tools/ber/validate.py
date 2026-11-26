#!/usr/bin/env python3
"""Non-destructive BER validation. Every run gets a new _codex directory.

Does not run the legacy regression scripts, delete any directory, or program
hardware. Target builds use CubeIDE hard-float GCC and original linker scripts.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]
FPGA = ROOT / "code/cyclone10/rx_cyclone10"
RX = ROOT / "code/stm32/rx_stm32"
TX = ROOT / "code/stm32/tx_stm32"
ARTIFACTS = ROOT / "_codex/ber_20261102"


class Validation:
    def __init__(self, output):
        self.output = output
        output.mkdir(parents=True, exist_ok=False)
        self.results = []
        self.env = dict(os.environ, PYTHONPYCACHEPREFIX=str(ARTIFACTS / "pycache"))
        self.input_hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                             for folder in (FPGA / "rtl", RX / "Core", TX / "Core", ROOT / "tools/ber")
                             for p in folder.rglob("*") if p.is_file() and p.suffix in (".c", ".h", ".v", ".vh", ".py", ".s")}
        for p in (FPGA / "tb").glob("*.sv"):
            self.input_hashes[str(p.relative_to(ROOT))] = hashlib.sha256(p.read_bytes()).hexdigest()
        for p in (FPGA / "rx_cyclone10.v", FPGA / "rx_cyclone10.qsf", FPGA / "rx_cyclone10.sdc"):
            self.input_hashes[str(p.relative_to(ROOT))] = hashlib.sha256(p.read_bytes()).hexdigest()

    def command(self, name, args, cwd=None, timeout=180, marker=None):
        log = self.output / (name + ".log")
        print("RUN", name, flush=True)
        with log.open("w", encoding="utf-8") as handle:
            handle.write(json.dumps({"argv": [str(x) for x in args], "cwd": str(cwd or ROOT)}) + "\n")
            handle.flush()
            try:
                result = subprocess.run([str(x) for x in args], cwd=cwd or ROOT,
                                        stdout=handle, stderr=subprocess.STDOUT,
                                        env=self.env, timeout=timeout)
                code = result.returncode
            except (OSError, subprocess.TimeoutExpired) as exc:
                handle.write(str(exc)); code = -1
        text = log.read_text(encoding="utf-8", errors="replace")
        passed = code == 0 and not re.search(r"(?im)(?:^#\s*)?\*\*\s*(?:Error|Fatal):|\bFAIL(?:\s|:|\()", text)
        if marker:
            passed &= marker in text
        self.results.append({"test": name, "passed": bool(passed), "exit_code": code, "log": str(log)})
        print("PASS" if passed else "FAIL", name, flush=True)
        self.save()
        return bool(passed)

    def save(self):
        (self.output / "results.json").write_text(json.dumps(self.results, indent=2), encoding="utf-8")
        (self.output / "source_hashes.json").write_text(json.dumps(self.input_hashes, indent=2), encoding="utf-8")

    def host(self):
        self.command("python_ber", [sys.executable, "-m", "unittest", "discover", "-s", ROOT / "tools/ber", "-p", "test_*.py", "-v"], marker="OK")
        for name, script in (("rx_integration", RX / "Tests/test_stm32_integration.py"),
                             ("tx_model", TX / "Tests/test_fsk_tx_model.py"),
                             ("sweep_model", ROOT / "tools/test_sweep_iq_model.py")):
            self.command(name, [sys.executable, script], marker="PASS")
        jobs = [
            ("rx_spi", RX, ["Core/Src/fpga_rx_spi.c", "Tests/fpga_rx_spi_test.c"], []),
            ("rx_text", RX, ["Core/Src/rx_command_text.c", "Tests/rx_command_text_test.c"], []),
            ("rx_trace", RX, ["Core/Src/fpga_rx_spi.c", "Core/Src/rx_command_text.c", "Core/Src/rx_trace.c", "Tests/rx_trace_test.c"], []),
            ("rx_ber", RX, ["Core/Src/fpga_rx_spi.c", "Core/Src/rx_command_text.c", "Core/Src/rx_ber.c", "Tests/rx_ber_test.c"], []),
            ("tx_hal", TX, ["Core/Src/fsk_tx.c", "Tests/hal_mock/hal_mock.c", "Tests/test_fsk_tx_hal_mock.c"], ["-ITests/hal_mock"]),
        ]
        for name, project, sources, extra in jobs:
            exe = self.output / (name + ".exe")
            if self.command(name + "_compile", ["gcc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-ICore/Inc", *extra, *sources, "-o", exe], project):
                self.command(name, [exe], self.output, marker="PASS")
        self.command("rx_optional_hal", ["gcc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic", "-DFPGA_RX_SPI_ENABLE_STM32_HAL", "-ITests/fpga_rx_spi_hal_mock", "-ICore/Inc", "-fsyntax-only", "Core/Src/fpga_rx_spi.c"], RX)
        self.command("tx_uart_diagnostics", [sys.executable, TX / "Tests/test_uart_diagnostics.py", "--output", self.output], marker="PASS")
        self.command("tx_uart_vendor_rearm", [sys.executable, TX / "Tests/test_uart_vendor_rearm.py", "--output", self.output], marker="PASS")
        self.command("tx_uart_status_compare", [sys.executable, TX / "Tests/compare_uart_status.py", "--output", self.output], marker="PASS")

    def rtl(self):
        work = self.output / "rtl"
        work.mkdir()
        for p in (FPGA / "tb").iterdir():
            if p.is_file() and p.suffix != ".sv":
                shutil.copy2(p, work / p.name)
        # Benches expecting tb/... fixture paths run from this private staging.
        shutil.copytree(FPGA / "tb", work / "tb")
        excluded = {"ook_validation_vectors_tb", "ook_tx_fixture_chain_tb"}
        tests = sorted(p.stem for p in (FPGA / "tb").glob("*.sv") if p.stem not in excluded)
        includes = ["+incdir+" + str(p).replace("\\", "/") for p in (FPGA / "rtl").rglob("*") if p.is_dir()]
        sources = sorted((FPGA / "rtl").rglob("*.v"))
        self.command("vlib", ["vlib", "work"], work)
        if self.command("vlog", ["vlog", "-sv", *includes, *sources, *(FPGA / "tb" / (n + ".sv") for n in tests)], work):
            generated = work / "generated"
            if not self.command("fsk_vectors", [sys.executable, FPGA / "tools/gen_fsk_vectors.py", "--output", generated], work):
                return
            manifest = json.loads((generated / "manifest.json").read_text())
            scenario = next(s for s in manifest["scenarios"] if s["name"] == "complete_frame_nominal")
            for name in tests:
                extra = []
                if name in ("integration_vector_contract_tb", "integration_rx_chain_tb"):
                    extra = ["+SAMPLE_FILE=" + str(generated / scenario["files"]["samples_i20_mem"]).replace("\\", "/"),
                             "+FRAME_FILE=" + str(generated / scenario["files"]["frame_hex"]).replace("\\", "/"),
                             "+SAMPLE_COUNT=" + str(scenario["sample_count"]),
                             "+FRAME_BYTE_COUNT=" + str(scenario["frame_byte_count"]),
                             "+SYNC_WORD=" + str(manifest["parameters"]["sync_word_hex"])]
                    if name == "integration_vector_contract_tb":
                        extra += ["+BIT_FILE=" + str(generated / scenario["files"]["bits_mem"]).replace("\\", "/"),
                                  "+BIT_COUNT=" + str(scenario["bit_count"])]
                self.command(name, ["vsim", "-c", "-novopt", "-lib", "work", name,
                                   *extra, "-l", work / (name + ".log"), "-do", "run -all; quit -code 0"], work, 300, "PASS")

    def target(self, compiler):
        for name, project in (("rx_target", RX), ("tx_target", TX)):
            build = self.output / name
            build.mkdir()
            common = ["-mcpu=cortex-m4", "-mthumb", "-mfpu=fpv4-sp-d16", "-mfloat-abi=hard", "-Os", "-ffunction-sections", "-fdata-sections", "-fstack-usage"]
            inc = ["-ICore/Inc", "-IDrivers/STM32G4xx_HAL_Driver/Inc", "-IDrivers/STM32G4xx_HAL_Driver/Inc/Legacy", "-IDrivers/CMSIS/Device/ST/STM32G4xx/Include", "-IDrivers/CMSIS/Include"]
            defines = ["-DUSE_HAL_DRIVER", "-DSTM32G431xx"]
            objects = []
            sources = sorted((project / "Core/Src").glob("*.c")) + sorted((project / "Drivers/STM32G4xx_HAL_Driver/Src").glob("*.c"))
            good = True
            for source in sources:
                obj = build / (source.stem + ".o")
                args = [compiler, *common, *inc, *defines, "-std=gnu11", "-Wall", "-Wextra"]
                if "Core" in source.parts:
                    args += ["-Werror"]
                if not self.command(name + "_" + source.stem, [*args, "-c", source, "-o", obj], project):
                    good = False; break
                objects.append(obj)
            if not good:
                continue
            obj = build / "startup.o"
            if not self.command(name + "_startup", [compiler, *common, "-x", "assembler-with-cpp", "-c", project / "Core/Startup/startup_stm32g431rbtx.s", "-o", obj], project):
                continue
            objects.append(obj)
            elf = build / (name + ".elf")
            if self.command(name + "_link", [compiler, *common, *objects, "-TSTM32G431RBTX_FLASH.ld", "--specs=nano.specs", "--specs=nosys.specs", "-Wl,--gc-sections", "-Wl,-Map=" + str(build / (name + ".map")), "-Wl,--start-group", "-lc", "-lm", "-lgcc", "-Wl,--end-group", "-o", elf], project):
                self.command(name + "_size", [str(compiler).replace("gcc.exe", "size.exe"), elf])

    def quartus(self, executable):
        build = self.output / "quartus"
        build.mkdir()
        for filename in ("rx_cyclone10.v", "rx_cyclone10.qsf", "rx_cyclone10.qpf", "rx_cyclone10.sdc", "rx_cyclone10_assignment_defaults.qdf"):
            if (FPGA / filename).exists():
                shutil.copy2(FPGA / filename, build / filename)
        for folder in ("rtl", "SignalTap"):
            shutil.copytree(FPGA / folder, build / folder)
        sld = FPGA / "db/FSK_3_SYMBOLS_auto_stripped.stp"
        if sld.exists():
            (build / "db").mkdir()
            shutil.copy2(sld, build / "db" / sld.name)
        self.command("quartus_full", [executable, "--flow", "compile", "rx_cyclone10"], build, 1800)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", action="store_true")
    parser.add_argument("--rtl", action="store_true")
    parser.add_argument("--target", action="store_true")
    parser.add_argument("--quartus", action="store_true")
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--arm-gcc", type=Path, default=Path("C:/software/STM32CubeIDE_1.13.1/STM32CubeIDE/plugins/com.st.stm32cube.ide.mcu.externaltools.gnu-tools-for-stm32.11.3.rel1.win32_1.1.0.202305231506/tools/bin/arm-none-eabi-gcc.exe"))
    parser.add_argument("--quartus-sh", type=Path, default=Path("C:/software/quartus22_1/quartus/bin64/quartus_sh.exe"))
    args = parser.parse_args()
    out = ARTIFACTS / ("validation_" + dt.datetime.now().strftime("%Y%m%d_%H%M%S_") + uuid.uuid4().hex[:6])
    validation = Validation(out)
    print("OUTPUT", out, flush=True)
    try:
        if args.host or args.all:
            validation.host()
        if args.rtl or args.all:
            validation.rtl()
        if args.target or args.all:
            validation.target(args.arm_gcc)
        if args.quartus or args.all:
            validation.quartus(args.quartus_sh)
    finally:
        validation.save()
    failed = [r["test"] for r in validation.results if not r["passed"]]
    print(json.dumps({"checks": len(validation.results), "failed": failed, "output": str(out)}), flush=True)
    return int(bool(failed))


if __name__ == "__main__":
    raise SystemExit(main())
