import type { Metadata } from "next";
import { CpuVisualizer } from "./CpuVisualizer";
import "./visualizer.css";

export const metadata: Metadata = {
  title: "交互式 CPU 原理图与 RTL Trace",
  description: "缩放、搜索并逐拍回放由当前 RISC-V CPU RTL 仿真生成的执行记录。",
};

export default function SimulatorPage() {
  return <CpuVisualizer />;
}
