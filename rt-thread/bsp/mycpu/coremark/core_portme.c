/*
Copyright 2018 Embedded Microprocessor Benchmark Consortium (EEMBC)

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

Original Author: Shay Gal-on
*/
/* 平台适配（mycpu：RV32IM + Zicsr，无中断，RT-Thread Nano）
   - 计时：硬件 COUNTER（0x80200050）毫秒计数（board.c 已在 rt_hw_board_init
     启动；不用 rt_tick_get——无中断平台 tick 由 idle 钩子轮询推进，忙跑时冻结）
   - 输出：ee_printf 经 rt_vsnprintf 直接转发到平台控制台（UART/SEG）
   - 种子/迭代数：SEED_ARG 模式，来自 msh 命令行（get_seed_args）
   - 数据：MEM_STATIC，core_main.c 内置 static_memblk，无需 portable_malloc
*/
#include <stdarg.h>
#include "coremark.h"
#include "core_portme.h"
#include <rtthread.h>
#include <rthw.h>

#define CM_CNT_ADDR 0x80200050ul   /* COUNTER：毫秒计数 */

CORETIMETYPE
barebones_clock(void)
{
    return *(volatile rt_uint32_t *)CM_CNT_ADDR;
}

#define CLOCKS_PER_SEC 1000
/* Define : TIMER_RES_DIVIDER
        Divider to trade off timer resolution and total time that can be
   measured. Use lower values to increase resolution.
        */
#define GETMYTIME(_t)              (*_t = barebones_clock())
#define MYTIMEDIFF(fin, ini)       ((fin) - (ini))
#define TIMER_RES_DIVIDER          1
#define SAMPLE_TIME_IMPLEMENTATION 1

/** Define target specific global time variables. */
static CORETIMETYPE start_time_val, stop_time_val;

/* Function : start_time
        Called right before starting the timed portion of the benchmark.
*/
void
start_time(void)
{
    GETMYTIME(&start_time_val);
}
/* Function : stop_time
        Called right after ending the timed portion of the benchmark.
*/
void
stop_time(void)
{
    GETMYTIME(&stop_time_val);
}
/* Function : get_time
        Return an abstract "ticks" number that signifies time on the system.
        Ticks are milliseconds (COUNTER resolution 1 ms).
*/
CORE_TICKS
get_time(void)
{
    CORE_TICKS elapsed
        = (CORE_TICKS)(MYTIMEDIFF(stop_time_val, start_time_val));
    return elapsed;
}
/* Function : time_in_secs
        Convert the value returned by get_time to seconds.
        Integer division (secs_ret 为 u32，HAS_FLOAT=0)。
*/
secs_ret
time_in_secs(CORE_TICKS ticks)
{
    secs_ret retval = ((secs_ret)ticks) / (secs_ret)EE_TICKS_PER_SEC;
    return retval;
}

ee_u32 default_num_contexts = 1;

/* 注意：SEED_ARG 模式下 get_seed_args/parseval 由官方 core_util.c 提供
 * （parseval 支持十进制、0x 十六进制与 K/M 后缀，迭代参数缺省返回 0，
 * core_main 会按官方语义自动确定迭代数以跑满约 10 s）。此处不再重复定义。 */

/* Function : portable_init
        Target specific initialization code. Test for some common mistakes.
*/
void
portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc; /* prevent unused warning */
    (void)argv; /* prevent unused warning */

    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *))
    {
        ee_printf(
            "ERROR! Please define ee_ptr_int to a type that holds a "
            "pointer!\n");
    }
    if (sizeof(ee_u32) != 4)
    {
        ee_printf("ERROR! Please define ee_u32 to a 32b unsigned type!\n");
    }
    p->portable_id = 1;
}
/* Function : portable_fini
        Target specific final code
*/
void
portable_fini(core_portable *p)
{
    p->portable_id = 0;
}
static void
cm_putc(char *buf, size_t *used, size_t cap, char c)
{
    if (*used + 1 < cap)
        buf[(*used)++] = c;
}

static void
cm_puts(char *buf, size_t *used, size_t cap, const char *s)
{
    if (s == RT_NULL)
        s = "(null)";
    while (*s != '\0')
        cm_putc(buf, used, cap, *s++);
}

static void
cm_putu(char *buf, size_t *used, size_t cap, ee_u32 value,
        unsigned base, int width, char pad)
{
    char digits[11];
    int count = 0;
    int i;
    static const char hex[] = "0123456789abcdef";

    do
    {
        digits[count++] = hex[value % base];
        value /= base;
    } while (value != 0);
    while (count < width)
        digits[count++] = pad;
    for (i = count - 1; i >= 0; --i)
        cm_putc(buf, used, cap, digits[i]);
}

/* CoreMark 在 HAS_FLOAT=0 下实际使用的格式子集；避免 RT-Thread
 * rt_vsnprintf 对长串的二次解析，且不依赖 libc。 */
int
ee_printf(const char *fmt, ...)
{
    char buf[256];
    va_list ap;
    size_t used = 0;

    va_start(ap, fmt);
    while (*fmt != '\0')
    {
        int width = 0;
        char pad = ' ';
        char qualifier = 0;
        char spec;

        if (*fmt != '%')
        {
            cm_putc(buf, &used, sizeof(buf), *fmt++);
            continue;
        }
        ++fmt;
        if (*fmt == '%')
        {
            cm_putc(buf, &used, sizeof(buf), *fmt++);
            continue;
        }
        if (*fmt == '0')
        {
            pad = '0';
            ++fmt;
        }
        while (*fmt >= '0' && *fmt <= '9')
            width = width * 10 + (*fmt++ - '0');
        if (*fmt == 'l')
            qualifier = *fmt++;
        spec = *fmt++;

        switch (spec)
        {
        case 'd':
        {
            int value = va_arg(ap, int);
            ee_u32 magnitude;
            if (value < 0)
            {
                cm_putc(buf, &used, sizeof(buf), '-');
                magnitude = (ee_u32)(0u - (ee_u32)value);
            }
            else
                magnitude = (ee_u32)value;
            cm_putu(buf, &used, sizeof(buf), magnitude, 10, width, pad);
            break;
        }
        case 'u':
        case 'x':
        {
            ee_u32 value;
            if (qualifier == 'l')
                value = (ee_u32)va_arg(ap, unsigned long);
            else
                value = (ee_u32)va_arg(ap, unsigned int);
            cm_putu(buf, &used, sizeof(buf), value,
                    spec == 'x' ? 16u : 10u, width, pad);
            break;
        }
        case 's':
            cm_puts(buf, &used, sizeof(buf), va_arg(ap, char *));
            break;
        case 'c':
            cm_putc(buf, &used, sizeof(buf), (char)va_arg(ap, int));
            break;
        default:
            cm_putc(buf, &used, sizeof(buf), '%');
            cm_putc(buf, &used, sizeof(buf), spec);
            break;
        }
    }
    va_end(ap);
    buf[used] = '\0';
    rt_hw_console_output(buf);
    return (int)used;
}