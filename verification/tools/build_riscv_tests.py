#!/usr/bin/env python3
import argparse
import json
import subprocess
from pathlib import Path


def run(command: list[str]) -> None:
    subprocess.run(command, check=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--sources", type=Path, required=True)
    parser.add_argument("--lock", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cross", default="riscv64-unknown-elf-")
    args = parser.parse_args()

    verification = Path(__file__).resolve().parents[1]
    source_root = (verification / args.sources / "riscv-tests").resolve()
    if not source_root.is_dir():
        raise SystemExit("missing pinned riscv-tests checkout; run 'make fetch-open-source' first")
    lock = json.loads((verification / args.lock).read_text(encoding="utf-8"))
    entry = next(item for item in lock["sources"] if item["name"] == "riscv-tests")
    actual = subprocess.check_output(["git", "-C", str(source_root), "rev-parse", "HEAD"], text=True).strip()
    if actual != entry["commit"]:
        raise SystemExit(f"riscv-tests checkout mismatch: expected {entry['commit']}, got {actual}")

    output = (verification / args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    env_dir = verification / "open_source" / "riscv-tests-env"
    macro_dir = source_root / "isa" / "macros" / "scalar"
    cc = args.cross + "gcc"
    objcopy = args.cross + "objcopy"
    objdump = args.cross + "objdump"
    manifest = []
    for group, tests in entry["allowlist"].items():
        family = group.split("-")[0]
        for name in tests:
            test_id = f"{group}-{name}"
            source = source_root / "isa" / family / f"{name}.S"
            if not source.is_file():
                raise SystemExit(f"allowlisted source missing: {source}")
            elf = output / f"{test_id}.elf"
            run([
                cc, "-march=rv32im", "-mabi=ilp32", "-mno-relax", "-nostdlib",
                "-nostartfiles", "-static", "-Wl,--no-relax", "-Wl,--build-id=none",
                "-T", str(verification / "linker.ld"), "-I", str(env_dir), "-I", str(macro_dir),
                "-o", str(elf), str(source),
            ])
            run(["python3", str(verification / "tools" / "validate_elf.py"), "--objdump", objdump, str(elf)])
            dump = subprocess.check_output([objdump, "-d", "-M", "no-aliases,numeric", str(elf)], text=True)
            (output / f"{test_id}.dump").write_text(dump, encoding="utf-8")
            irom_bin = output / f"{test_id}.irom.bin"
            bram_bin = output / f"{test_id}.bram.bin"
            run([objcopy, "-O", "binary", "--only-section=.text", str(elf), str(irom_bin)])
            run([objcopy, "-O", "binary", "--only-section=.data", str(elf), str(bram_bin)])
            run(["python3", str(verification / "tools" / "bin_to_coe.py"), "--max-words", "4096",
                 str(irom_bin), str(output / f"{test_id}.irom.coe")])
            run(["python3", str(verification / "tools" / "bin_to_coe.py"), "--max-words", "65536",
                 str(bram_bin), str(output / f"{test_id}.bram.coe")])
            manifest.append({"id": test_id, "source": str(source.relative_to(source_root)), "commit": actual})
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"built {len(manifest)} pinned riscv-tests cases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
