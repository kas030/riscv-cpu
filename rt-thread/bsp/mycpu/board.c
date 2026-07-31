/*
 * board.c —— RT-Thread Nano 3.1.5 mycpu 平台板级支持
 *
 * 平台事实（以 rtl/bus/perip_bridge.sv 与 docs/cpu_capability_boundaries.md 为准）：
 *   - CPU 无中断通路，tick 只能由软件产生：idle hook 轮询 COUNTER（0x80200050，
 *     50 MHz 下按毫秒递增，写 0x80000000 启动）驱动 rt_tick_increase。
 *   - CPU 无 UART 访问通路，控制台输出走 SEG（0x80200020）：以 8 位环形缓冲
 *     保留最近输出字符，把最后 4 个字符以 8 位十六进制写入 SEG，板上数码管与
 *     仿真日志均可观测。
 */

#include <rthw.h>
#include <rtthread.h>

#include "board.h"

#define CNT_ADDR        0x80200050ul   /* COUNTER：毫秒计数 */
#define CNT_START_CMD   0x80000000ul
#define SEG_ADDR        0x80200020ul   /* 数码管写数据回读 */

/* 最近 8 个控制台字符的环形缓冲 */
static rt_uint8_t  console_ring[8];
static rt_uint8_t  console_ring_idx;

/* 最近一次读到的毫秒计数，用于 tick 追赶 */
static volatile rt_uint32_t last_ms = 0;

void rt_hw_console_output(const char *str)
{
    while (*str)
    {
        console_ring[console_ring_idx & 7] = (rt_uint8_t)*str;
        console_ring_idx++;
        str++;
    }

    /* 把最后 4 个字符拼成 8 位十六进制显示（最早的在最高字节） */
    rt_uint32_t v = 0;
    for (int i = 0; i < 4; i++)
        v = (v << 8) | console_ring[(console_ring_idx - 4 + i) & 7];
    *(volatile rt_uint32_t *)SEG_ADDR = v;
}

static void tick_hook(void)
{
    rt_uint32_t now = *(volatile rt_uint32_t *)CNT_ADDR;
    rt_uint32_t delta = now - last_ms;   /* 无符号回绕安全 */

    if (delta)
    {
        if (delta > 64)
            delta = 64;                  /* 限制长停滞后的追赶次数 */
        last_ms = now;
        while (delta--)
            rt_tick_increase();
    }
}

void rt_hw_board_init(void)
{
    /* 启动毫秒计数器 */
    *(volatile rt_uint32_t *)CNT_ADDR = CNT_START_CMD;

    /* 注册 tick 提供者：idle 循环中轮询 COUNTER */
    rt_thread_idle_sethook(tick_hook);

    /* 堆覆盖 bss 之后到 BRAM 顶的全部空间，线程栈由 rt_thread_create 从堆分配 */
    extern char __bss_end[];
    extern char __stack_top[];
    rt_system_heap_init(__bss_end, __stack_top);
}
