import type { SignalManifest } from "./types";
import { disassemble } from "./disassemble";

export function hasUnknown(value: string) {
  return /[xz]/i.test(value);
}

export function formatSignalValue(value: string | undefined, signal?: SignalManifest, mode?: "hex" | "unsigned" | "signed") {
  if (value === undefined) return "—";
  if (hasUnknown(value)) return value.toUpperCase();
  const semanticFormat = signal?.format;
  const selected = mode ?? semanticFormat ?? "hex";
  if (semanticFormat === "enum" && signal?.enum?.[String(Number.parseInt(value, 2))]) return `${value} · ${signal.enum[String(Number.parseInt(value, 2))]}`;
  const radix = /^[01]+$/.test(value) && (signal?.width ?? 0) < 8 ? 2 : 16;
  const number = BigInt(radix === 2 ? `0b${value}` : `0x${value}`);
  const hexadecimal = `0x${value.padStart(Math.ceil((signal?.width ?? value.length * 4) / 4), "0").toUpperCase()}`;
  if (semanticFormat === "instruction") return `${hexadecimal} · ${disassemble(value)}`;
  if (selected === "unsigned") return number.toString(10);
  if (selected === "signed") {
    const width = BigInt(signal?.width ?? Math.max(1, value.length * 4));
    const sign = 1n << (width - 1n);
    return (number & sign ? number - (1n << width) : number).toString(10);
  }
  if (selected === "binary") return value;
  return hexadecimal;
}
