/*
 * coremark_cmd.c —— 官方 EEMBC CoreMark 1.0 的 msh 命令导出
 *
 * 编译参数 -Dmain=coremark 把 coremark/core_main.c 的 main() 重命名为本命令
 * 入口，函数签名保持官方 CLI 语义：
 *     coremark [seed1] [seed2] [seed3] [iterations]
 * 缺省（裸 coremark）：种子 0,0,0x66，迭代 1000（约 10 s @50 MHz）。
 */
#include <rtthread.h>
#include <finsh_config.h>
#include "finsh.h"

int coremark(int argc, char **argv);

MSH_CMD_EXPORT(coremark, run official CoreMark 1.0 benchmark);