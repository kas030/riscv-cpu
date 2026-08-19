/*
 * coremark_cmd.c —— 提供版本兼容的 CoreMark msh 命令导出
 *
 * 编译参数 -Dmain=coremark_main 把上游 main() 重命名为内部入口；
 * 本文件在运行前采集 Team ID，并保持既有 CLI：
 *     coremark [seed1] [seed2] [seed3] [iterations]
 * 缺省参数为 0,0,0x66,18000；显式传入 iterations=0 时才进入官方自动校准。
 * 性能 autorun 没有交互终端，因此跳过采集并使用固定标识。
 */
#include <rtthread.h>
#include <finsh_config.h>
#include "finsh_api.h"
#include "core_portme.h"

int coremark_main(int argc, char **argv);
extern char rt_hw_console_getchar(void);

static char coremark_team_id[32];

static void coremark_set_team_id(const char *team_id)
{
    rt_size_t index = 0;

    while (team_id[index] != '\0' && index < sizeof(coremark_team_id) - 1)
    {
        coremark_team_id[index] = team_id[index];
        ++index;
    }
    coremark_team_id[index] = '\0';
}

static void coremark_read_team_id(void)
{
    int character;
    rt_size_t index = 0;

    rt_kprintf("\r\n========================================\r\n");
    rt_kprintf("Please enter your Team ID and press Enter:\r\nteam id: ");
    while (index < sizeof(coremark_team_id) - 1)
    {
        character = (unsigned char)rt_hw_console_getchar();
        if (character == 0xff)
        {
            rt_thread_mdelay(1);
            continue;
        }
        if (character == '\r' || character == '\n')
            break;
        if ((character == '\b' || character == 127) && index != 0)
        {
            --index;
            rt_kprintf("\b \b");
            continue;
        }
        if (character >= 32 && character <= 126)
        {
            coremark_team_id[index++] = (char)character;
            rt_kprintf("%c", character);
        }
    }
    coremark_team_id[index] = '\0';
    if (index == 0)
        coremark_set_team_id("NO_ID");
    rt_kprintf("\r\nTeam ID locked: %s\r\n", coremark_team_id);
    rt_kprintf("Starting CoreMark, please wait...\r\n");
    rt_kprintf("========================================\r\n\r\n");
}

int coremark(int argc, char **argv)
{
    char *run_argv[5];

#ifdef COREMARK_PERF_AUTORUN
    coremark_set_team_id("PERF_AUTORUN");
#else
    coremark_read_team_id();
#endif

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
