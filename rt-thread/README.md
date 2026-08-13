# RT-Thread Nano 3.1.5 for mycpu（RV32IM）

RT-Thread Nano 3.1.5 在自研 32 位 RISC-V CPU（RV32I + RV32M + Zicsr 陷阱）上的移植，
含完整内核源码（vendor）、`bsp/mycpu` 板级移植与演示应用。演示程序在 Verilator
CPU-only 仿真中通过 LED 写入 `0xC0DEC0DE` 判定完成。

## 目录结构

- `kernel/`：RT-Thread Nano v3.1.5 内核源码（`src/`、`include/`、`libcpu/risc-v/common/`），
  来自 `RT-Thread/rtthread-nano` tag `v3.1.5`，未做修改；许可见 `kernel/LICENSE`（Apache-2.0）。
- `bsp/mycpu/`：板级移植（`rtconfig.h`、`board.c/h`、`bme280.c/h`、`main.c`、`entry_gcc.S`、`linker.ld`、`Makefile`）。
- `components/finsh/`：finsh/msh 组件（`shell.c`、`cmd.c`、`msh.c`、`finsh_config.h`）。
  仅 `shell.c` 有一处针对无设备框架的修改：空输入（0xFF）分支让出 CPU
  （`rt_thread_mdelay(1)`），其余与上游一致。

## 平台约束与移植要点

CPU 能力边界（详见 `docs/cpu_capability_boundaries.md` 与 `AGENTS.md`）：

- 取指仅走 IROM `0x80000000`–`0x8000FFFF`（64 KiB），代码必须装入此范围。
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
- **BME280**：`bme` 线程默认阻塞，不访问 I²C。输入 `bme start` 后通过 FPGA
  内的 100 kHz I²C 主机探测 `0x76/0x77`，读取校准参数，并每秒以 forced mode
  测量一次温度、气压和湿度。补偿后的定点结果直接打印到 UART，不使用浮点格式化。
- **启动序列**（`main.c`）：`_start -> main -> rtthread_startup`：
  `rt_hw_board_init`（启动 COUNTER、注册 tick 钩子、`rt_system_heap_init`）
  → `rt_show_version` → timer/scheduler init → `rt_application_init`（创建并
  `rt_thread_startup` 三个演示线程）→ `rt_thread_idle_init` → `rt_system_scheduler_start`。
  注意：Nano 3.1.5 的 idle 线程由 BSP 显式初始化，漏调 `rt_thread_idle_init`
  会导致就绪表为空、调度器取到垃圾指针。
- **链接布局**（`linker.ld`）：`.text` → IROM；`.rodata/.data/.bss` → BRAM；
  `__stack_top` = BRAM 顶；堆覆盖 `[__bss_end, __stack_top)`。脚本内 ASSERT
  IROM 使用量 ≤ 64 KiB。

## BME280 接线与输出

请断电接线：

| BME280 | FPGA 板 | 说明 |
| --- | --- | --- |
| VCC | J7 pin 20 | `+3.3V` |
| GND | J7 pin 19 | GND；J7 pin 11–19 任取一个也可以 |
| SCL | J7 pin 1 | Debug_1，FPGA `G17` |
| SDA | J7 pin 2 | Debug_2，FPGA `G18` |
| CSB | `+3.3V` | I²C 模式必须为高；可与 VCC 短接，或接 J8/J9/J10 pin 20 |
| SDO | GND 或 `+3.3V` | GND=`0x76`，3.3V=`0x77`；驱动会自动探测两者，不能悬空 |

SCL/SDA 必须上拉到 3.3V；当前模块已有 10 kΩ 上拉，不需要再并接。串口终端配置
为 9600、8 数据位、无校验、1 停止位。传感器周期输出默认关闭，命令规则为：

```text
msh >bme status    # 查看运行状态、初始化状态和最近一次错误码
msh >bme start     # 开始采样，此后每秒输出一次
msh >bme stop      # 停止采样；等待中的线程会立即被唤醒
msh >bme once      # 周期输出停止时，只读取并显示一次
```

识别成功后可看到类似输出：

```text
bme280: detected at 0x76
bme280: T=24.31 C, P=100812 Pa, H=45.67 %
```

FPU 继续使用 `0x80200070`--`0x80200080`；为避免地址冲突，BME280 I²C
寄存器安排在 `0x80200084`--`0x80200090`。运行 CoreMark 前执行 `bme stop`；
停止状态下 BME280 线程不访问 I²C，也不会周期唤醒或打印，因此不会干扰 benchmark。
若持续显示 `not found`，依次检查供电、共地、SCL/SDA 是否接反、CSB 是否为高、
SDO 是否固定到 GND/3.3V，并确认已重新生成固件 COE 和 FPGA bitstream。

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
- **丢字节防护**（`uart_bridge.sv`）：200 MHz 域 `bit0 = tx_busy_sync | tx_pend`，
  50 MHz 域按 UART 实际锁存（busy 上升沿）确认，透传期字节挂起等待、不丢弃；
  非透传期丢弃并立即确认，避免 CPU 轮询挂死。
- **shell 空输入必须让出 CPU**：无设备框架时 `finsh_getchar` 不阻塞，空输入
  返回 0xFF；`shell.c` 的 `ch == 0xFF` 分支改为 `rt_thread_mdelay(1)`。
  若此处忙等，会饿死 idle 线程——mycpu 的 tick 由 idle hook 轮询 COUNTER
  产生，系统时间将停止，演示线程永不醒来。

## 官方 CoreMark 1.0

`bsp/mycpu/coremark/` 中的五个核心算法源文件和 MD5 清单来自 EEMBC
官方 CoreMark 仓库，基准算法保持原样。本平台的计时直接读取 COUNTER
毫秒计数，避免 CoreMark 忙跑期间 idle hook 不执行而导致 RT-Thread tick
停止。停止计时后，`0x80200070`--`0x80200080` 的最小化 MMIO 单精度 FPU
仅负责 `ticks / 1000` 和 `iterations / seconds` 换算；不向 CoreMark 主循环
加入浮点指令，也不要求 CPU 实现 RV32F 指令集。

CoreMark 通过 finsh 命令运行：

```text
msh >coremark
```

裸命令使用标准性能种子 `0,0,0x66`、总数据量 2000 字节和 5000 次迭代；
200 MHz 配置下预计约 11--12 秒，满足官方结果至少运行 10 秒的规则。输出应包含
`Correct operation validated`、三项 CRC `e714 / 1fd7 / 8e3a` 和 CoreMark 分数。
官方验证种子可另行运行：

```text
msh >coremark 0x3415 0x3415 0x66 5000
```

此时三项 CRC 应为 `e3c1 / 0747 / 8d84`。命令行第 4 个参数可覆盖迭代数，
但少于 10 秒的结果只适合调试，不能作为正式成绩。

## 构建与运行

Makefile 默认使用 `riscv32-unknown-elf-` 前缀，也可通过 `CROSS` 或
`CC`/`OBJCOPY`/`SIZE` 覆盖为其他支持 RV32IM+Zicsr 的 GCC 工具链。本仓库当前
跟踪的固件 COE 使用 Vivado 2025.2.1 自带 GCC 13.4.0 生成。

```sh
cd bsp/mycpu
make              # 编译内核与 BSP，生成 irom/bram 的 .coe
make run          # 全量仿真：3 秒演示，LED 写 0xC0DEC0DE 判定 PASS
make run DEMO_RUN_MS=500 STOP_NS=900000000   # 缩短演示与仿真时间
make coremark-smoke # 24 次短测，检查官方性能种子 CRC 与返回 msh
```

`coremark-smoke` 故意小于 10 秒，因此会检查官方的最短时间警告；它只证明 RTL
执行、CRC 和 shell 返回路径正确，不是可上报的 CoreMark 成绩。

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

完成线程 `fin`（优先级 12）：延时 `DEMO_RUN_MS`（默认 3000）ms 后打印
`demo done` 并写 LED `0xC0DEC0DE`，随后永久让出 CPU（`rt_thread_mdelay`
`RT_WAITING_FOREVER`）——本平台无中断、tick 由 idle 钩子轮询产生，空转
会饿死 idle 导致系统冻结，必须让出。控制台保持安静，msh 终端可用。

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
