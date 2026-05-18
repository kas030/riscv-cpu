import os
import glob
import argparse

script_dir = os.path.dirname(os.path.abspath(__file__))

parser = argparse.ArgumentParser(description="Export CPU core source files to a single Markdown file.")
parser.add_argument(
    "--include-new",
    action="store_true",
    help="Also export files from digital_twin.srcs/sources_1/new",
)
args = parser.parse_args()

cpu_dir = os.path.join(
    script_dir,
    "digital_twin.srcs", "sources_1", "imports", "new"
)

new_dir = os.path.join(
    script_dir,
    "digital_twin.srcs", "sources_1", "new"
)

def collect_files(directory):
    return sorted(
        glob.glob(os.path.join(directory, "*.sv")) +
        glob.glob(os.path.join(directory, "*.v"))
    )

def append_files(lines, files, section_title=None):
    if section_title:
        lines.append(section_title)
    for fpath in files:
        fname = os.path.basename(fpath)
        ext = os.path.splitext(fname)[1].lower()
        lang = "systemverilog" if ext == ".sv" else "verilog"
        with open(fpath, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
        lines.append(f"## {fname}\n")
        lines.append(f"```{lang}")
        lines.append(content.rstrip())
        lines.append("```\n")
    return lines

cpu_files = collect_files(cpu_dir)
lines = ["# RV32I CPU Core 源文件\n"]
lines = append_files(lines, cpu_files)

total_files = len(cpu_files)

if args.include_new:
    new_files = collect_files(new_dir)
    if new_files:
        lines.append("# Additional Source Files (sources_1/new)\n")
        lines = append_files(lines, new_files)
        total_files += len(new_files)

out_path = os.path.join(script_dir, "cpu_core_files.md")
with open(out_path, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")

print(f"Done: {total_files} files exported to {out_path}")