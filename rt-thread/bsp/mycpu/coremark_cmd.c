/*
 * coremark_cmd.c —— 官方 EEMBC CoreMark 1.0 的 msh 命令导出
 *
 * 编译参数 -Dmain=coremark_main 把官方 main() 重命名为内部入口；
 * 本文件导出 msh 命令并补齐缺省参数，CLI 语义为：
 *     coremark [seed1] [seed2] [seed3] [iterations]
 * 缺省（裸 coremark）：种子 0,0,0x66，迭代 10000（短测外推约 13.98 s @200 MHz）。
 * 只有显式传入 iterations=0 时才进入官方自动校准。
 */
#include <rtthread.h>
#include <finsh_config.h>
#include "finsh_api.h"
#include "core_portme.h"

int coremark_main(int argc, char **argv);

int coremark(int argc, char **argv)
{
    char *run_argv[5];

    if (argc >= 5)
        return coremark_main(argc, argv);

    run_argv[0] = argv[0];
    run_argv[1] = argc > 1 ? argv[1] : "0";
    run_argv[2] = argc > 2 ? argv[2] : "0";
    run_argv[3] = argc > 3 ? argv[3] : "0x66";
    run_argv[4] = CM_STRINGIFY(ITERATIONS);
    return coremark_main(5, run_argv);
}

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
