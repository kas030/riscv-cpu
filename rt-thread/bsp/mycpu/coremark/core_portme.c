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
/* 平台适配（mycpu：RV32IM + Zicsr + MMIO 单精度 FPU，无中断，RT-Thread Nano）
   - 计时：硬件 COUNTER（0x80200050）毫秒计数（board.c 已在 rt_hw_board_init
     启动；不用 rt_tick_get——无中断平台 tick 由 idle 钩子轮询推进，忙跑时冻结）
   - 标记：正式计时前点亮物理 LED1，计时结束后熄灭
   - 浮点：硬件 FPU 完成 u32->binary32 与 binary32 除法，整数代码负责格式化
   - 输出：ee_printf/ee_print_float 直接转发到平台控制台（UART/SEG）
   - 种子/迭代数：SEED_ARG 模式，来自 msh 命令行（get_seed_args）
   - 数据：MEM_STATIC，core_main.c 内置 static_memblk，无需 portable_malloc
*/
#include <stdarg.h>
#include "coremark.h"
#include "core_portme.h"
#include <rtthread.h>
#include <rthw.h>

#define CM_LED_ADDR 0x80200040ul   /* 4x8 LED 阵列 */
#define CM_CNT_ADDR 0x80200050ul   /* COUNTER：毫秒计数 */
#define CM_FPU_A_ADDR      0x80200070ul
#define CM_FPU_B_ADDR      0x80200074ul
#define CM_FPU_CMD_ADDR    0x80200078ul
#define CM_FPU_STATUS_ADDR 0x8020007cul
#define CM_FPU_RESULT_ADDR 0x80200080ul

#define CM_FPU_CMD_U32_TO_F32 1u
#define CM_FPU_CMD_DIV_F32    2u

/* 原理图中物理 LED1 连接 FPGA F12，对应 virtual_led[16]。 */
#define CM_LED_RUNNING 0x00010000u
#define CM_LED_OFF     0x00000000u

typedef union
{
    float  value;
    ee_u32 word;
} cm_f32;

static volatile ee_u32 *
cm_mmio(ee_u32 addr)
{
    return (volatile ee_u32 *)(ee_ptr_int)addr;
}

static cm_f32
cm_fpu_read_result(void)
{
    cm_f32 result;
    while ((*cm_mmio(CM_FPU_STATUS_ADDR) & 1u) != 0)
    {
    }
    result.word = *cm_mmio(CM_FPU_RESULT_ADDR);
    return result;
}

static cm_f32
cm_fpu_u32_to_f32(ee_u32 value)
{
    *cm_mmio(CM_FPU_A_ADDR) = value;
    *cm_mmio(CM_FPU_CMD_ADDR) = CM_FPU_CMD_U32_TO_F32;
    return cm_fpu_read_result();
}

static cm_f32
cm_fpu_div_f32(cm_f32 numerator, cm_f32 denominator)
{
    *cm_mmio(CM_FPU_A_ADDR) = numerator.word;
    *cm_mmio(CM_FPU_B_ADDR) = denominator.word;
    *cm_mmio(CM_FPU_CMD_ADDR) = CM_FPU_CMD_DIV_F32;
    return cm_fpu_read_result();
}

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
    /* 先显示开始标记再取时间，LED 写入开销不计入 CoreMark 成绩。 */
    *cm_mmio(CM_LED_ADDR) = CM_LED_RUNNING;
    GETMYTIME(&start_time_val);
}
/* Function : stop_time
        Called right after ending the timed portion of the benchmark.
*/
void
stop_time(void)
{
    GETMYTIME(&stop_time_val);
    /* 先停止内部计时再熄灭，便于评委用 LED 边沿复核时间。 */
    *cm_mmio(CM_LED_ADDR) = CM_LED_OFF;
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
        Convert the value returned by get_time to seconds using the MMIO FPU.
*/
secs_ret
time_in_secs(CORE_TICKS ticks)
{
    cm_f32 numerator = cm_fpu_u32_to_f32(ticks);
    cm_f32 denominator = cm_fpu_u32_to_f32(EE_TICKS_PER_SEC);
    return cm_fpu_div_f32(numerator, denominator).value;
}

float
coremark_iterations_per_sec(ee_u32 iterations, CORE_TICKS ticks)
{
    cm_f32 numerator = cm_fpu_u32_to_f32(iterations);
    cm_f32 denominator;
    denominator.value = time_in_secs(ticks);
    return cm_fpu_div_f32(numerator, denominator).value;
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

/* FPU 已给出 binary32 结果；这里仅解析 IEEE-754 位模式并用整数生成
 * CoreMark 默认的六位小数，不执行任何软件浮点运算。 */
static void
cm_putf(char *buf, size_t *used, size_t cap, float value)
{
    cm_f32 raw;
    const ee_u32 scale = 1000000u;
    ee_u32 exponent_bits;
    ee_u32 whole = 0;
    ee_u32 fraction = 0;
    ee_u32 mantissa;
    ee_u32 remainder = 0;
    ee_u32 denominator = 1;
    int exponent;
    int shift;
    int i;

    raw.value = value;
    exponent_bits = (raw.word >> 23) & 0xffu;

    if ((raw.word & 0x80000000u) != 0)
        cm_putc(buf, used, cap, '-');

    if (exponent_bits == 0xffu)
    {
        if ((raw.word & 0x7fffffu) != 0)
            cm_puts(buf, used, cap, "nan");
        else
            cm_puts(buf, used, cap, "inf");
        return;
    }

    if (exponent_bits != 0)
    {
        exponent = (int)exponent_bits - 127;
        mantissa = (raw.word & 0x7fffffu) | 0x800000u;

        if (exponent >= 31)
        {
            cm_puts(buf, used, cap, "overflow");
            return;
        }

        if (exponent >= 23)
        {
            whole = mantissa << (exponent - 23);
        }
        else if (exponent >= 0)
        {
            shift = 23 - exponent;
            whole = (ee_u32)(mantissa >> shift);
            denominator = 1u << shift;
            remainder = mantissa & (denominator - 1u);
        }
        else
        {
            shift = 23 - exponent;
            remainder = mantissa;
            if (shift > 28)
            {
                int drop = shift - 28;
                remainder = drop >= 24 ? 0 : remainder >> drop;
                shift = 28;
            }
            denominator = 1u << shift;
        }

        if (remainder != 0)
        {
            for (i = 0; i < 6; ++i)
            {
                ee_u32 scaled = remainder * 10u;
                ee_u32 digit = scaled >> shift;
                remainder = scaled & (denominator - 1u);
                fraction = fraction * 10u + digit;
            }
            if (remainder >= ((denominator + 1u) >> 1))
                ++fraction;
        }
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

int
ee_print_float(float value)
{
    char buf[32];
    size_t used = 0;

    cm_putf(buf, &used, sizeof(buf), value);
    buf[used] = '\0';
    rt_hw_console_output(buf);
    return (int)used;
}

/* CoreMark 的非浮点格式子集；浮点值走 ee_print_float 的非可变参数接口。 */
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
