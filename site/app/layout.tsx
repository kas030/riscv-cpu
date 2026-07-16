import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: {
    default: "从一条指令到双槽流水线｜RISC-V CPU 教学站",
    template: "%s｜RISC-V CPU 教学站",
  },
  description:
    "从当前 SystemVerilog RTL 出发，逐拍理解双槽顺序发射 RISC-V CPU 的取指、执行、访存、冒险与提交。",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="zh-CN">
      <body>{children}</body>
    </html>
  );
}
