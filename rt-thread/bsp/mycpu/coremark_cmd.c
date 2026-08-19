/*
 * coremark_cmd.c —— 材料版 CoreMark 的 CPU-only 性能自动运行包装
 *
 * 正式板卡命令和 Team ID 交互由 handouts 中的 core_portme.c 提供。
 * 本文件只在 COREMARK_PERF_AUTORUN 构建中绕过串口输入，直接调用同一份
 * 材料版 coremark_main；迭代次数仍由 ITERATIONS 编译参数唯一确定。
 */
#ifdef COREMARK_PERF_AUTORUN

#include <rtthread.h>

int coremark_main(void);

/* Soft-float varargs follow the RV32 psABI stack alignment requirement.  Keep
 * the performance-only stack explicitly aligned even if allocator settings
 * change independently from this wrapper. */
static struct rt_thread coremark_perf_thread;
static rt_uint8_t coremark_perf_stack[8192] __attribute__((aligned(16)));

static void coremark_perf_entry(void *parameter)
{
    (void)parameter;
    (void)coremark_main();
}

void coremark_perf_autorun_init(void)
{
    if (rt_thread_init(&coremark_perf_thread, "cmperf", coremark_perf_entry,
                       RT_NULL, coremark_perf_stack,
                       sizeof(coremark_perf_stack), 11, 20) == RT_EOK)
        rt_thread_startup(&coremark_perf_thread);
}

#endif
