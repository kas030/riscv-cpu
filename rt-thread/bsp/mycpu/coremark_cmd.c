/*
 * coremark_cmd.c —— 官方 EEMBC CoreMark 1.0 的 msh 命令导出
 *
 * 编译参数 -Dmain=coremark 把 coremark/core_main.c 的 main() 重命名为本命令
 * 入口，函数签名保持官方 CLI 语义：
 *     coremark [seed1] [seed2] [seed3] [iterations]
 * 缺省（裸 coremark）：种子 0,0,0x66，迭代 5000（约 11--12 s @200 MHz）。
 */
#include <rtthread.h>
#include <finsh_config.h>
#include "finsh.h"

int coremark(int argc, char **argv);

MSH_CMD_EXPORT(coremark, run official CoreMark 1.0 benchmark);

#ifdef COREMARK_PERF_AUTORUN
#define CM_PERF_STRINGIFY_INNER(value) #value
#define CM_PERF_STRINGIFY(value) CM_PERF_STRINGIFY_INNER(value)

static void coremark_perf_entry(void *parameter)
{
    char *argv[] = {
        "coremark", "0", "0", "0x66", CM_PERF_STRINGIFY(COREMARK_RUN_ITERATIONS)
    };

    (void)parameter;
    (void)coremark(5, argv);
}

void coremark_perf_autorun_init(void)
{
    rt_thread_t thread;

    thread = rt_thread_create("cmperf", coremark_perf_entry, RT_NULL,
                              8192, 11, 20);
    if (thread != RT_NULL)
        rt_thread_startup(thread);
}
#endif
