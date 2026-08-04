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
#include <stddef.h>

#include "board.h"

#define CNT_ADDR        0x80200050ul   /* COUNTER：毫秒计数 */
#define CNT_START_CMD   0x80000000ul
#define SEG_ADDR        0x80200020ul   /* 数码管写数据回读 */
#define UART_DATA_ADDR  0x80200060ul   /* UART 数据：写=发送，读=接收并清 valid */
#define UART_STATUS_ADDR 0x80200064ul  /* UART 状态：bit0=TX_BUSY，bit1=RX_VALID */

/* 最近 8 个控制台字符的环形缓冲 */
static rt_uint8_t  console_ring[8];
static rt_uint8_t  console_ring_idx;

/* 最近一次读到的毫秒计数，用于 tick 追赶 */
static volatile rt_uint32_t last_ms = 0;

void rt_hw_console_output(const char *str)
{
    while (*str)
    {
        /* 终端需要 CRLF：仅发 '\n' 只换行不回行首，输出会阶梯状错位 */
        if (*str == '\n')
        {
            while (*(volatile rt_uint32_t *)UART_STATUS_ADDR & 1u)
                ;
            *(volatile rt_uint32_t *)UART_DATA_ADDR = '\r';
            console_ring[console_ring_idx & 7] = '\r';
            console_ring_idx++;
        }
        /* 串口发送为主：轮询 TX_BUSY 后写数据寄存器 */
        while (*(volatile rt_uint32_t *)UART_STATUS_ADDR & 1u)
            ;
        *(volatile rt_uint32_t *)UART_DATA_ADDR = (rt_uint32_t)*str;

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

/* finsh 输入（shell.c 无 RT_USING_DEVICE 时调用本函数）
 * 注意：本工具链默认 -funsigned-char，无输入时返回 0xFF（-1 的字节值），
 * shell.c 以 ch == 0xFF 识别空输入并让出 CPU（见 shell.c 注释） */
char rt_hw_console_getchar(void)
{
    if (*(volatile rt_uint32_t *)UART_STATUS_ADDR & 2u)
        return (char)(*(volatile rt_uint32_t *)UART_DATA_ADDR & 0xFFu);
    return (char)-1;
}

/* 无 libc：finsh 用到的标准库函数以 rt_* 等价实现（freestanding 编译） */
size_t strlen(const char *s) { return rt_strlen(s); }
int strncmp(const char *a, const char *b, size_t n) { return rt_strncmp(a, b, n); }
char *strcpy(char *d, const char *s) { char *r = d; while ((*d++ = *s++)) ; return r; }
char *strcat(char *d, const char *s) { char *r = d; while (*d) d++; while ((*d++ = *s++)) ; return r; }
char *strncpy(char *d, const char *s, size_t n) { char *r = d; while (n-- && (*d++ = *s)) s++; while (n-- > 0) *d++ = 0; return r; }
void *memset(void *p, int c, size_t n) { unsigned char *q = p; while (n--) *q++ = (unsigned char)c; return p; }
void *memcpy(void *d, const void *s, size_t n) { unsigned char *q = d; const unsigned char *p = s; while (n--) *q++ = *p++; return d; }

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

    /* 请求进入串口透传：写 UART_STATUS 触发（bridge 置透传请求脉冲），
     * 轮询 bit2（透传已建立，twin 进入 PASSTHROUGH）确认。此后全部控制台
     * 输出直接走 UART，串口终端（9600 8N1）连接即可操作 msh，无需发送
     * 0xC9。竞赛裸机镜像不写本寄存器，twin 保持 IDLE，上位机协议零影响。 */
    *(volatile rt_uint32_t *)UART_STATUS_ADDR = 1;
    while (!(*(volatile rt_uint32_t *)UART_STATUS_ADDR & 4u))
        ;
}



