#!/usr/bin/env python3
"""Mirror raw simulator output to the terminal and save its final rendered text."""

from __future__ import annotations

import argparse
import codecs
import re
import sys
from pathlib import Path


CSI_RE = re.compile(r"\x1b\[([0-9;?]*)([ -/]*)([@-~])")


class TerminalScreen:
    def __init__(self) -> None:
        self.lines: list[list[str]] = [[]]
        self.row = 0
        self.col = 0
        self.pending = ""

    def _ensure_row(self) -> None:
        while len(self.lines) <= self.row:
            self.lines.append([])

    def _write_char(self, char: str) -> None:
        self._ensure_row()
        line = self.lines[self.row]
        if self.col > len(line):
            line.extend(" " for _ in range(self.col - len(line)))
        if self.col == len(line):
            line.append(char)
        else:
            line[self.col] = char
        self.col += 1

    def _handle_csi(self, params: str, command: str) -> None:
        values = [int(value) if value else 0 for value in params.lstrip("?").split(";")]
        amount = values[0] if values and values[0] else 1
        if command == "A":
            self.row = max(0, self.row - amount)
        elif command == "B":
            self.row += amount
            self._ensure_row()
        elif command == "C":
            self.col += amount
        elif command == "D":
            self.col = max(0, self.col - amount)
        elif command == "G":
            self.col = max(0, amount - 1)
        elif command == "K":
            self._ensure_row()
            mode = values[0] if values else 0
            if mode == 2:
                self.lines[self.row] = []
            elif mode == 0:
                del self.lines[self.row][self.col :]
            elif mode == 1:
                end = min(self.col + 1, len(self.lines[self.row]))
                self.lines[self.row][:end] = [" "] * end
        # Color/style and cursor visibility commands do not affect saved text.

    def feed(self, text: str, final: bool = False) -> None:
        data = self.pending + text
        self.pending = ""
        index = 0
        while index < len(data):
            char = data[index]
            if char == "\x1b":
                match = CSI_RE.match(data, index)
                if match:
                    self._handle_csi(match.group(1), match.group(3))
                    index = match.end()
                    continue
                if not final:
                    self.pending = data[index:]
                    return
                index += 1
                continue
            if char == "\n":
                self.row += 1
                self.col = 0
                self._ensure_row()
            elif char == "\r":
                self.col = 0
            elif char == "\b":
                self.col = max(0, self.col - 1)
            elif char == "\t":
                next_tab = ((self.col // 8) + 1) * 8
                while self.col < next_tab:
                    self._write_char(" ")
            elif char >= " " and char != "\x7f":
                self._write_char(char)
            index += 1

    def text(self) -> str:
        rendered = ["".join(line).rstrip() for line in self.lines]
        while rendered and not rendered[-1]:
            rendered.pop()
        return clean_dynamic_status(rendered)


def clean_dynamic_status(lines: list[str]) -> str:
    """Remove a progress panel if an interrupted refresh left it on screen."""
    cleaned: list[str] = []
    for line in lines:
        if "[progress]" not in line:
            cleaned.append(line)
            continue

        # A six-line panel consists of four LED rows, one SEG row and progress.
        if len(cleaned) >= 5 and cleaned[-5].startswith(" led_graphic"):
            del cleaned[-5:]
        marker = line.find(">>> ")
        if marker >= 0:
            cleaned.append(line[marker:])

    while cleaned and not cleaned[-1]:
        cleaned.pop()
    return "\n".join(cleaned) + ("\n" if cleaned else "")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    decoder = codecs.getincrementaldecoder("utf-8")("replace")
    screen = TerminalScreen()
    while True:
        chunk = sys.stdin.buffer.read1(65536)
        if not chunk:
            break
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()
        decoded = decoder.decode(chunk)
        screen.feed(decoded)
    decoded = decoder.decode(b"", final=True)
    screen.feed(decoded, final=True)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(screen.text(), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
