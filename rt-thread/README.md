# RT-Thread Nano 3.1.5 for mycpu（RV32IM）

RT-Thread Nano 3.1.5 在自研 32 位 RISC-V CPU（RV32I + RV32M + Zicsr 陷阱）上的移植，
含完整内核源码（vendor）、`bsp/mycpu` 板级移植与演示应用。演示程序在 Verilator
CPU-only 仿真中通过 LED 写入 `0xC0DEC0DE` 判定完成。

## 目录结构

- `kernel/`：RT-Thread Nano v3.1.5 内核源码（`src/`、`include/`、`libcpu/risc-v/common/`），
  来自 `RT-Thread/rtthread-nano` tag `v3.1.5`，未做修改；许可见 `kernel/LICENSE`（Apache-2.0）。
- `bsp/mycpu/`：板级移植（`rtconfig.h`、`board.c/h`、`main.c`、`entry_gcc.S`、`linker.ld`、`Makefile`）。

## 平台约束与移植要点

CPU 能力边界（详见 `docs/cpu_capability_boundaries.md` 与 `AGENTS.md`）：

- 取指仅走 IROM `0x80000000`–`0x80003FFF`（16 KiB），代码必须装入此范围。
- BRAM `0x80100000`–`0x8013FFFF`（256 KiB），`.coe` 预装载且可读写，
  `.rodata/.data/.bss` 直接放 BRAM，启动无需搬运。
- 仅 5 个 CSR、无中断通路；`libcpu/risc-v/common` 的上下文切换使用
  `csrw mepc` + `mret` 直接切换，不依赖 ecall/trap，与 CSR 实现完全兼容。
- CPU 无 UART 通路；控制台经 SEG（`0x80200020`）输出：8 字节环形缓冲保留最近
  字符，最后 4 个字符以 8 位十六进制写入 SEG，仿真日志可见。

对应移植决策：

- **tick 由软件产生**：无中断，`rt_thread_idle_sethook` 钩子在 idle 循环中轮询
  COUNTER（`0x80200050`，50 MHz 毫秒计数），每毫秒调用一次 `rt_tick_increase`
  （追赶上限 64 ms，防止长时间停滞后的连锁补偿）。
- **控制台**：`rt_hw_console_output` 按上述 SEG 方案实现。
- **启动序列**（`main.c`）：`_start -> main -> rtthread_startup`：
  `rt_hw_board_init`（启动 COUNTER、注册 tick 钩子、`rt_system_heap_init`）
  → `rt_show_version` → timer/scheduler init → `rt_application_init`（创建并
  `rt_thread_startup` 三个演示线程）→ `rt_thread_idle_init` → `rt_system_scheduler_start`。
  注意：Nano 3.1.5 的 idle 线程由 BSP 显式初始化，漏调 `rt_thread_idle_init`
  会导致就绪表为空、调度器取到垃圾指针。
- **链接布局**（`linker.ld`）：`.text` → IROM；`.rodata/.data/.bss` → BRAM；
  `__stack_top` = BRAM 顶；堆覆盖 `[__bss_end, __stack_top)`。脚本内 ASSERT
  IROM 使用量 ≤ 16 KiB。

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
`EXPECTED_LED=C0DEC0DE`；仿真时间默认 4 s（约 8 分钟墙钟）。

## 演示程序

三个线程 + 一个信号量：

- `t1`（优先级 10）：每 500 ms 打印 tick 并释放信号量；
- `t2`（优先级 11）：每 1000 ms 打印 tick 并获取信号量（计数 +1）；
- `fin`（优先级 12）：延时 `DEMO_RUN_MS`（默认 3000）ms 后打印汇总并写
  LED `0xC0DEC0DE`。

验收记录（Verilator，`DEMO_RUN_MS=500`，STOP_NS=5.5e8）：

```
>>> [PASS] final state matches enabled checks
stop_reason : led
virtual_led : 0xc0dec0de
cnt_ms      : 500
```

## 配置

`rtconfig.h`：`RT_THREAD_PRIORITY_MAX` 32、`RT_TICK_PER_SECOND` 1000、
`RT_USING_IDLE_HOOK`/`RT_USING_SEMAPHORE`/`RT_USING_MUTEX`/`RT_USING_HEAP`/
`RT_USING_SMALL_MEM`/`RT_USING_CONSOLE`；未启用 finsh、设备框架、
mailbox/message queue 等。内核仅编译 11 个核心源文件（clock/cpu/idle/ipc/
irq/kservice/mem/object/scheduler/thread/timer）。
