# RT-Thread Nano 3.1.5 for mycpu（RV32IM）

RT-Thread Nano 3.1.5 在自研 32 位 RISC-V CPU（RV32I + RV32M + Zicsr 陷阱）上的移植，
含完整内核源码（vendor）、`bsp/mycpu` 板级移植与演示应用。演示程序在 Verilator
CPU-only 仿真中通过 LED 写入 `0xC0DEC0DE` 判定完成。

## 目录结构

- `kernel/`：RT-Thread Nano v3.1.5 内核源码（`src/`、`include/`、`libcpu/risc-v/common/`），
  来自 `RT-Thread/rtthread-nano` tag `v3.1.5`，未做修改；许可见 `kernel/LICENSE`（Apache-2.0）。
- `bsp/mycpu/`：板级移植（`rtconfig.h`、`board.c/h`、`main.c`、`entry_gcc.S`、`linker.ld`、`Makefile`）。
- `components/finsh/`：finsh/msh 组件（`shell.c`、`cmd.c`、`msh.c`、`finsh_config.h`）。
  仅 `shell.c` 有一处针对无设备框架的修改：空输入（0xFF）分支让出 CPU
  （`rt_thread_mdelay(1)`），其余与上游一致。

## 平台约束与移植要点

CPU 能力边界（详见 `docs/cpu_capability_boundaries.md` 与 `AGENTS.md`）：

- 取指仅走 IROM `0x80000000`–`0x80003FFF`（16 KiB），代码必须装入此范围。
- BRAM `0x80100000`–`0x8013FFFF`（256 KiB），`.coe` 预装载且可读写，
  `.rodata/.data/.bss` 直接放 BRAM，启动无需搬运。
- CPU 无中断通路；`libcpu/risc-v/common` 的上下文切换使用
  `csrw mepc` + `mret` 直接切换，不依赖 ecall/trap，与 CSR 实现完全兼容。
- CPU 串口经 `twin_controller` 透传协议接入板级 UART（9600 8N1）：
  发送 0xC9 进入透传后 CPU 独占串口，0xCA 退出；控制台同时保留
  SEG（`0x80200020`）输出：8 字节环形缓冲保留最近字符，最后 4 个
  字符以 8 位十六进制写入 SEG，仿真日志可见。

对应移植决策：

- **tick 由软件产生**：无中断，`rt_thread_idle_sethook` 钩子在 idle 循环中轮询
  COUNTER（`0x80200050`，50 MHz 毫秒计数），每毫秒调用一次 `rt_tick_increase`
  （追赶上限 64 ms，防止长时间停滞后的连锁补偿）。
- **控制台**：`rt_hw_console_output` 先按 UART 发送（轮询
  `0x80200064` bit0 TX_BUSY 后写 `0x80200060`），再按上述 SEG 方案输出。
  非透传期 bridge 丢弃 CPU 字节（不挂死），进入透传后逐字节发送。
- **串口输入**：`rt_hw_console_getchar` 轮询 `0x80200064` bit1 RX_VALID，
  读 `0x80200060` 取字节并清除 valid。本工具链默认 `-funsigned-char`，
  无输入返回 0xFF（-1 的字节值）。
- **启动序列**（`main.c`）：`_start -> main -> rtthread_startup`：
  `rt_hw_board_init`（启动 COUNTER、注册 tick 钩子、`rt_system_heap_init`）
  → `rt_show_version` → timer/scheduler init → `rt_application_init`（创建并
  `rt_thread_startup` 三个演示线程）→ `rt_thread_idle_init` → `rt_system_scheduler_start`。
  注意：Nano 3.1.5 的 idle 线程由 BSP 显式初始化，漏调 `rt_thread_idle_init`
  会导致就绪表为空、调度器取到垃圾指针。
- **链接布局**（`linker.ld`）：`.text` → IROM；`.rodata/.data/.bss` → BRAM；
  `__stack_top` = BRAM 顶；堆覆盖 `[__bss_end, __stack_top)`。脚本内 ASSERT
  IROM 使用量 ≤ 16 KiB。

## 串口命令行（finsh/msh）

启用 `RT_USING_FINSH` + `FINSH_USING_MSH_ONLY`，finsh 线程（优先级 21）
提供 msh 命令行。板级 UART 与 CPU 的透传由 `twin_controller` 管理：

- **即连即用**：RT-Thread 启动时（`rt_hw_board_init`）写 `0x80200064` 主动
  请求透传并轮询 bit2 确认，twin 自动进入透传。串口终端（9600 8N1）连接后
  直接看到完整启动 banner 与 `msh >` 提示符，无需任何握手字节。
- **透传协议**（保留给上位机/调试）：发送 `0xC9` 进入透传，`0xCA` 退出；
  透传中 `0x80` 保留（twin 状态回读命令），其余字节原样转发给 CPU。
  竞赛裸机镜像不写请求寄存器，twin 复位后保持 IDLE，上位机注入协议零影响。
- **寄存器**（`perip_bridge` 地址译码）：
  - `0x80200060`：数据，写=发送，读=接收并清除 RX_VALID；
  - `0x80200064`：状态，bit0=TX_BUSY，bit1=RX_VALID，bit2=PASSTHROUGH
    （透传已建立）；写任意值=请求进入透传。
- **丢字节防护**（`uart_bridge.sv`）：240 MHz 域 `bit0 = tx_busy_sync | tx_pend`，
  50 MHz 域按 UART 实际锁存（busy 上升沿）确认，透传期字节挂起等待、不丢弃；
  非透传期丢弃并立即确认，避免 CPU 轮询挂死。
- **shell 空输入必须让出 CPU**：无设备框架时 `finsh_getchar` 不阻塞，空输入
  返回 0xFF；`shell.c` 的 `ch == 0xFF` 分支改为 `rt_thread_mdelay(1)`。
  若此处忙等，会饿死 idle 线程——mycpu 的 tick 由 idle hook 轮询 COUNTER
  产生，系统时间将停止，演示线程永不醒来。

## 构建与运行

工具链 `riscv32-unknown-elf-gcc`（GCC 16.1.0，带 newlib）位于
`$HOME/.local/riscv-tc/bin`，Makefile 自动前置该目录到 PATH。

```sh
cd bsp/mycpu
make              # 编译内核与 BSP，生成 irom/bram 的 .coe
make run          # 全量仿真：3 秒演示，LED 写 0xC0DEC0DE 判定 PASS
make run DEMO_RUN_MS=500 STOP_NS=900000000   # 缩短演示与仿真时间
```

`make run` 调用 `sim_cpu_only/run_verilator.sh`，传
`IROM_COE`/`BRAM_COE`/`PASS_LED=C0DEC0DE`/`FAIL_LED=DEADBEEF`/
`EXPECTED_LED=C0DEC0DE`；仿真时间默认 4 s。testbench 会自动执行串口
验收：约 200 ms 时注入 0xC9 进入透传并发送 `help\r`，检查输出含
`version`；随后注入 0xCA 退出并发送 0x80 回读，检查 twin 状态回读
（18 字节）完整。

板卡验证（Vivado `tb/tb_top.sv` 或真实板卡）同样使用 9600 8N1：
MobaXterm/SecureCRT 等终端直接连接即可——RT-Thread 启动时自动进入透传，
启动 banner 与 `msh >` 提示符直接可见，输入 `help` 查看命令列表。
竞赛模式上位机不受影响：它不写 `0x80200064`，twin 保持 IDLE。

## 演示程序

三个线程 + 一个信号量：

- `t1`（优先级 10）：每 500 ms 打印 tick 并释放信号量；
- `t2`（优先级 11）：每 1000 ms 打印 tick 并获取信号量（计数 +1）；
- `fin`（优先级 12）：延时 `DEMO_RUN_MS`（默认 3000）ms 后打印汇总并写
  LED `0xC0DEC0DE`。

验收记录（Verilator，`DEMO_RUN_MS=500`，STOP_NS=1.5e9，含串口自动验收）：

```
[UART-VERIFY] passthrough established by CPU (state=2)
[UART-VERIFY] shell verification passed (qlen=184)
[UART-VERIFY] readback verification passed (qlen=204)
>>> [PASS] final state matches enabled checks
stop_reason : led
virtual_led : 0xc0dec0de
cnt_ms      : 564
```

## 配置

`rtconfig.h`：`RT_THREAD_PRIORITY_MAX` 32、`RT_TICK_PER_SECOND` 1000、
`RT_USING_IDLE_HOOK`/`RT_USING_SEMAPHORE`/`RT_USING_MUTEX`/`RT_USING_HEAP`/
`RT_USING_SMALL_MEM`/`RT_USING_CONSOLE`/`RT_USING_FINSH`；finsh 使用
`FINSH_USING_MSH`/`FINSH_USING_MSH_ONLY`/`FINSH_USING_SYMTAB`，未启用
设备框架、mailbox/message queue 等。内核编译 11 个核心源文件
（clock/cpu/idle/ipc/irq/kservice/mem/object/scheduler/thread/timer），
finsh 编译 3 个源文件（shell/cmd/msh）。
