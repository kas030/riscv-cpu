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
        secs_ret 为 double；RV32IM 无 FPU，运算由 GCC/libgcc 软件实现。
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

/* CoreMark 的 %f 均使用默认精度。计时与得分仍由 libgcc 软浮点计算，
 * 这里只直接解析 IEEE-754 double 位模式并用整数生成 6 位小数。
 * 这样不依赖 libc printf，也避开目标 CPU 上不可靠的 double 到 u32 转换。 */
static void
cm_putf(char *buf, size_t *used, size_t cap, double value)
{
    union
    {
        double value;
        struct
        {
            ee_u32 low;
            ee_u32 high;
        } word;
    } raw;
    const ee_u32 scale = 1000000u;
    ee_u32 exponent_bits;
    ee_u32 whole = 0;
    ee_u32 fraction = 0;
    uint64_t mantissa;
    uint64_t remainder;
    uint64_t denominator;
    int exponent;
    int shift;
    int i;

    raw.value = value;
    exponent_bits = (raw.word.high >> 20) & 0x7ffu;

    if ((raw.word.high & 0x80000000u) != 0)
        cm_putc(buf, used, cap, '-');

    if (exponent_bits == 0x7ffu)
    {
        if (((raw.word.high & 0xfffffu) | raw.word.low) != 0)
            cm_puts(buf, used, cap, "nan");
        else
            cm_puts(buf, used, cap, "inf");
        return;
    }

    if (exponent_bits != 0)
    {
        exponent = (int)exponent_bits - 1023;
        mantissa = ((uint64_t)(raw.word.high & 0xfffffu) << 32)
                   | (uint64_t)raw.word.low | (UINT64_C(1) << 52);

        if (exponent >= 32)
        {
            cm_puts(buf, used, cap, "overflow");
            return;
        }

        shift = 52 - exponent;
        if (exponent >= 0)
        {
            whole = (ee_u32)(mantissa >> shift);
            remainder = mantissa & ((UINT64_C(1) << shift) - 1u);
        }
        else
        {
            remainder = mantissa;
            /* 将很大的二进制分母等比例缩到 2^60；保留的精度远高于
             * 最终 6 位十进制小数所需精度。 */
            if (shift > 60)
            {
                int drop = shift - 60;
                remainder = drop >= 64 ? 0 : remainder >> drop;
                shift = 60;
            }
        }

        denominator = UINT64_C(1) << shift;
        for (i = 0; i < 6; ++i)
        {
            uint64_t scaled = remainder * 10u;
            ee_u32 digit = (ee_u32)(scaled >> shift);
            remainder = scaled & (denominator - 1u);
            fraction = fraction * 10u + digit;
        }
        if (remainder >= (denominator >> 1))
            ++fraction;
    }

    if (fraction >= scale)
    {
        ++whole;
        fraction -= scale;
    }

    cm_putu(buf, used, cap, whole, 10u, 0, ' ');
    cm_putc(buf, used, cap, '.');
    cm_putu(buf, used, cap, fraction, 10u, 6, '0');
}

/* double 单独按非可变参数传递，避免 RV32 可变参数寄存器对齐路径把两个
 * 32 位字错误解释。调用者负责输出前后缀，便于保持官方结果行的格式。 */
int
ee_print_float(double value)
{
    char buf[32];
    size_t used = 0;

    cm_putf(buf, &used, sizeof(buf), value);
    buf[used] = '\0';
    rt_hw_console_output(buf);
    return (int)used;
}

/* CoreMark 实际使用的非浮点格式子集；浮点值由 ee_print_float 通过
 * 非可变参数接口输出，避免 RV32 varargs 对 double 的字序解释问题。 */
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
