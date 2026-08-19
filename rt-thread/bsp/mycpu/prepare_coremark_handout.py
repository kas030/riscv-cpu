#!/usr/bin/env python3
"""Validate and prepare the supplied CoreMark archive for the mycpu BSP."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import tempfile
import zipfile


ARCHIVE_SHA256 = "374136da9368d508acd999712e21e1a0f6c799da8571a33d48f1a26a2610ce05"
SOURCE_SHA256 = {
    "core_list_join.c": "ca00e4e010ece47d7f040cb92aa50a95345a00d3171b59d088f6b243be06ce7b",
    "core_main.c": "17884c93c5b94378eb0ff02b4df3725756cf2addb9b8cbcaa6200a4649ff5ca7",
    "core_matrix.c": "ecdff717b5a5c4907d221a606760e25499899cbf617582c05d40db71c91351e4",
    "core_portme.c": "f5502e1ae2dc66bba1e1fe887105d497cd854b6be7410713b4231ee5f3daf502",
    "core_portme.h": "af54e7ceed05ab1cf44c34dee9cf27f835c47b38dd3dcc2994aa4c2f687ab28d",
    "core_portme.mak": "565beed1a5f65a701deacd2a7bc6260240f031a4fa28bd364cc62619656ad3cd",
    "core_state.c": "f4b84bb0a3452c45a4daa664ab502bfdccbd31cb57d93e9ac490c60937717a4e",
    "core_util.c": "a3fbfcb9bb943b638624b8ece01c5836dd56a96d7bcde2697b248d077447327f",
    "coremark.h": "42642b9a06c7ed2b3bd9eda971b7c3868c4f5d27bf7ef6c4bba11291a0c2598a",
    "cvt.c": "7c57eaa23c780cd707db2304365d1ded372fd73dd107f16bdd091d9dd16fd742",
    "ee_printf.c": "535ba1feaa731d69e6f45117b9a79ef58291619248505c67aec916571612abdc",
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def replace_once(text: str, old: str, new: str, filename: str) -> str:
    count = text.count(old)
    if count != 1:
        raise ValueError(f"{filename}: expected one adaptation marker, found {count}")
    return text.replace(old, new, 1)


def adapt_sources(raw: dict[str, bytes]) -> tuple[dict[str, bytes], list[str]]:
    adapted = dict(raw)
    adaptations: list[str] = []

    header = raw["core_portme.h"].decode("utf-8")
    header = replace_once(
        header,
        "#include <rtthread.h>   /* RT-Thread 标准头文件 */",
        "#include <stddef.h>\n#include <rtthread.h>   /* RT-Thread 标准头文件 */",
        "core_portme.h",
    )
    header = replace_once(
        header,
        "#define ee_printf rt_kprintf",
        "int ee_printf(const char *fmt, ...);",
        "core_portme.h",
    )
    adapted["core_portme.h"] = header.encode("utf-8")
    adaptations.append("core_portme.h: include the standard definition of size_t")
    adaptations.append("core_portme.h: use the supplied ee_printf implementation")

    port = raw["core_portme.c"].decode("utf-8")
    port = replace_once(
        port,
        "CORETIMETYPE barebones_clock()\n"
        "{\n"
        " // 读取 mcycle 或 mtime CSR\n"
        "    return (CORETIMETYPE)read_csr(mcycle);  \n"
        "}",
        "CORETIMETYPE barebones_clock()\n"
        "{\n"
        "    /* mycpu 尚未实现 mcycle；板级 COUNTER_US 提供 1 us 单调计时。 */\n"
        "    return (CORETIMETYPE)(*(volatile rt_uint32_t *)0x80200054ul);\n"
        "}",
        "core_portme.c",
    )
    port = replace_once(
        port,
        "#define EE_TICKS_PER_SEC  80000000  // 你的 CPU 频率",
        "#define EE_TICKS_PER_SEC  1000000  // mycpu COUNTER_US ticks per second",
        "core_portme.c",
    )
    port = replace_once(
        port,
        "#include <finsh.h>\nMSH_CMD_EXPORT(coremark, run EEMBC CoreMark);",
        "#include <finsh_config.h>\n"
        "#include \"finsh_api.h\"\n"
        "MSH_CMD_EXPORT(coremark, run EEMBC CoreMark);",
        "core_portme.c",
    )
    adapted["core_portme.c"] = port.encode("utf-8")
    adaptations.append("core_portme.c: bind barebones_clock to the 1 us board COUNTER_US")
    adaptations.append("core_portme.c: use the freestanding FinSH export headers")

    printf_source = raw["ee_printf.c"].decode("utf-8")
    start = printf_source.index("void\nuart_send_char(char c)\n{")
    end_marker = "\n}\n\nint\nee_printf(const char *fmt, ...)"
    end = printf_source.index(end_marker, start) + len("\n}")
    printf_source = (
        printf_source[:start]
        + "void\n"
        + "uart_send_char(char c)\n"
        + "{\n"
        + "    char text[2];\n"
        + "    extern void rt_hw_console_output(const char *str);\n"
        + "\n"
        + "    text[0] = c;\n"
        + "    text[1] = '\\0';\n"
        + "    rt_hw_console_output(text);\n"
        + "}"
        + printf_source[end:]
    )
    adapted["ee_printf.c"] = printf_source.encode("utf-8")
    adaptations.append("ee_printf.c: send characters through the RT-Thread console")

    cvt = raw["cvt.c"].decode("utf-8")
    cvt = replace_once(
        cvt,
        "#include <math.h>",
        "static double coremark_modf(double value, double *integral)\n"
        "{\n"
        "    union { double value; unsigned long long bits; } raw, whole, zero;\n"
        "    unsigned int exponent;\n"
        "    unsigned int fraction_bits;\n"
        "    unsigned long long fraction_mask;\n"
        "\n"
        "    raw.value = value;\n"
        "    exponent = (unsigned int)((raw.bits >> 52) & 0x7ffu);\n"
        "    zero.bits = raw.bits & (1ull << 63);\n"
        "    if (exponent < 1023u)\n"
        "    {\n"
        "        *integral = zero.value;\n"
        "        return value;\n"
        "    }\n"
        "    if (exponent >= 1075u)\n"
        "    {\n"
        "        *integral = value;\n"
        "        return exponent == 0x7ffu && (raw.bits & ((1ull << 52) - 1ull))\n"
        "                   ? value : zero.value;\n"
        "    }\n"
        "    fraction_bits = 1075u - exponent;\n"
        "    fraction_mask = (1ull << fraction_bits) - 1ull;\n"
        "    if ((raw.bits & fraction_mask) == 0ull)\n"
        "    {\n"
        "        *integral = value;\n"
        "        return zero.value;\n"
        "    }\n"
        "    whole.bits = raw.bits & ~fraction_mask;\n"
        "    *integral = whole.value;\n"
        "    return value - whole.value;\n"
        "}\n"
        "#define modf coremark_modf",
        "cvt.c",
    )
    adapted["cvt.c"] = cvt.encode("utf-8")
    adaptations.append("cvt.c: provide the freestanding modf helper used by supplied float formatting")

    return adapted, adaptations


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    archive_input = args.archive.as_posix()
    archive = args.archive.resolve()
    output = args.output.resolve()
    if output.name != "coremark-handout":
        raise ValueError(f"refusing unexpected output directory: {output}")

    archive_data = archive.read_bytes()
    actual_archive_sha = sha256(archive_data)
    if actual_archive_sha != ARCHIVE_SHA256:
        raise ValueError(
            f"archive SHA-256 mismatch: {actual_archive_sha}, expected {ARCHIVE_SHA256}"
        )

    raw: dict[str, bytes] = {}
    with zipfile.ZipFile(archive) as package:
        for info in package.infolist():
            if info.is_dir():
                continue
            name = PurePosixPath(info.filename).name
            if name in raw:
                raise ValueError(f"duplicate archive member basename: {name}")
            raw[name] = package.read(info)

    if set(raw) != set(SOURCE_SHA256):
        missing = sorted(set(SOURCE_SHA256) - set(raw))
        extra = sorted(set(raw) - set(SOURCE_SHA256))
        raise ValueError(f"archive member mismatch: missing={missing}, extra={extra}")
    for name, expected in SOURCE_SHA256.items():
        actual = sha256(raw[name])
        if actual != expected:
            raise ValueError(f"{name}: SHA-256 {actual}, expected {expected}")

    adapted, adaptations = adapt_sources(raw)
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix="coremark-handout.", dir=output.parent))
    try:
        upstream_dir = staging / "upstream"
        source_dir = staging / "src"
        upstream_dir.mkdir()
        source_dir.mkdir()
        for name in sorted(raw):
            (upstream_dir / name).write_bytes(raw[name])
            (source_dir / name).write_bytes(adapted[name])

        provenance = {
            "archive": archive_input,
            "archive_sha256": actual_archive_sha,
            "upstream_sha256": {name: sha256(raw[name]) for name in sorted(raw)},
            "compiled_source_sha256": {
                name: sha256(adapted[name]) for name in sorted(adapted)
            },
            "adaptations": adaptations,
        }
        (staging / "provenance.json").write_text(
            json.dumps(provenance, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        (staging / ".prepared").write_text(actual_archive_sha + "\n", encoding="ascii")

        if output.exists():
            shutil.rmtree(output)
        staging.rename(output)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise

    print(f"prepared CoreMark handout {actual_archive_sha} -> {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
