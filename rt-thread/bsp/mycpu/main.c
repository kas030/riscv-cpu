/*
 * main.c —— RT-Thread Nano 3.1.5 mycpu 平台启动序列与演示程序
 *
 * 启动序列：_start -> main -> rtthread_startup。调度器启动后 boot 上下文不再
 * 返回，因此演示线程必须在 rt_system_scheduler_start() 之前创建。
 *
 * 完成判据：fin 线程延时 DEMO_RUN_MS（默认 3000）毫秒后向 LED（0x80200040）
 * 写入 0xC0DEC0DE，sim_cpu_only 的 testbench 据此判定 PASS。
 */

#include <rthw.h>
#include <rtthread.h>

#include "board.h"
#include "bme280.h"

#ifdef RT_USING_FINSH
#include <shell.h>
#endif

#define LED_ADDR 0x80200040ul

#define BME280_SAMPLE_TICKS (2 * RT_TICK_PER_SECOND)
#define BME280_RETRY_TICKS  (2 * RT_TICK_PER_SECOND)

#define SEG_DP      0x80u
#define SEG_BLANK   0x00u
#define SEG_MINUS   0x40u
#define SEG_B       0x7cu
#define SEG_C       0x39u
#define SEG_E       0x79u
#define SEG_H       0x76u
#define SEG_N       0x54u
#define SEG_P       0x73u
#define SEG_R       0x50u
#define SEG_T       0x78u
#define SEG_U       0x3eu

#ifndef DEMO_RUN_MS
#define DEMO_RUN_MS 3000
#endif

static struct rt_semaphore bme_control_sem;
static volatile rt_uint8_t bme_periodic_enabled = 1;
static volatile rt_uint8_t bme_initialized;
static volatile rt_uint8_t bme_display_page;
static volatile int bme_last_error;

static rt_uint8_t seg_digit(rt_uint32_t digit)
{
    static const rt_uint8_t patterns[10] = {
        0x3fu, 0x06u, 0x5bu, 0x4fu, 0x66u,
        0x6du, 0x7du, 0x07u, 0x7fu, 0x6fu
    };

    return patterns[digit < 10 ? digit : 0];
}

static void bme280_show_error(void)
{
    const rt_uint8_t glyphs[8] = {
        SEG_B, SEG_N, SEG_E, SEG_BLANK, SEG_E, SEG_R, SEG_R, SEG_BLANK
    };

    rt_hw_seg_show_raw(glyphs);
}

static void bme280_show_temperature(const struct bme280_sample *sample)
{
    rt_uint8_t glyphs[8] = {
        SEG_T, SEG_E, SEG_N, SEG_BLANK,
        SEG_BLANK, SEG_BLANK, SEG_BLANK, SEG_C
    };
    rt_int32_t temperature_abs = sample->temperature_centi_c;
    rt_uint32_t temperature_deci;
    rt_uint32_t whole;

    if (temperature_abs < 0)
    {
        glyphs[3] = SEG_MINUS;
        temperature_abs = -temperature_abs;
    }

    temperature_deci = ((rt_uint32_t)temperature_abs + 5u) / 10u;
    if (temperature_deci > 999u)
        temperature_deci = 999u;
    whole = temperature_deci / 10u;
    if (whole >= 10u)
        glyphs[4] = seg_digit(whole / 10u);
    glyphs[5] = seg_digit(whole % 10u) | SEG_DP;
    glyphs[6] = seg_digit(temperature_deci % 10u);
    rt_hw_seg_show_raw(glyphs);
}

static void bme280_show_humidity(const struct bme280_sample *sample)
{
    rt_uint8_t glyphs[8] = {
        SEG_H, SEG_U, SEG_N, SEG_BLANK,
        SEG_BLANK, SEG_BLANK, SEG_BLANK, SEG_H
    };
    rt_uint32_t humidity_deci = (sample->humidity_centi_pct + 5u) / 10u;
    rt_uint32_t whole;

    if (humidity_deci > 1000u)
        humidity_deci = 1000u;
    whole = humidity_deci / 10u;
    if (whole >= 100u)
    {
        glyphs[3] = seg_digit(whole / 100u);
        glyphs[4] = seg_digit((whole / 10u) % 10u);
    }
    else if (whole >= 10u)
    {
        glyphs[4] = seg_digit(whole / 10u);
    }
    glyphs[5] = seg_digit(whole % 10u) | SEG_DP;
    glyphs[6] = seg_digit(humidity_deci % 10u);
    rt_hw_seg_show_raw(glyphs);
}

static void bme280_show_pressure(const struct bme280_sample *sample)
{
    rt_uint8_t glyphs[8] = {
        SEG_P, SEG_R, SEG_E, SEG_BLANK,
        SEG_BLANK, SEG_BLANK, SEG_BLANK, SEG_BLANK
    };
    rt_uint32_t pressure_hpa = (sample->pressure_pa + 50u) / 100u;

    if (pressure_hpa > 9999u)
        pressure_hpa = 9999u;
    if (pressure_hpa >= 1000u)
        glyphs[4] = seg_digit(pressure_hpa / 1000u);
    if (pressure_hpa >= 100u)
        glyphs[5] = seg_digit((pressure_hpa / 100u) % 10u);
    if (pressure_hpa >= 10u)
        glyphs[6] = seg_digit((pressure_hpa / 10u) % 10u);
    glyphs[7] = seg_digit(pressure_hpa % 10u);
    rt_hw_seg_show_raw(glyphs);
}

static void bme280_show_page(const struct bme280_sample *sample, rt_uint8_t page)
{
    if (page == 0u)
        bme280_show_temperature(sample);
    else if (page == 1u)
        bme280_show_humidity(sample);
    else
        bme280_show_pressure(sample);
}

static void finish_entry(void *param)
{
    (void)param;
    rt_thread_mdelay(DEMO_RUN_MS);
    rt_kprintf("demo done tick=%d\n", rt_tick_get());
    *(volatile rt_uint32_t *)LED_ADDR = 0xC0DEC0DEul;
    /* 必须让出 CPU：本平台无中断，tick 由 idle 钩子轮询 COUNTER 产生；
     * 若空转（while(1);）会饿死 idle，tick 停止，所有 mdelay 线程永久
     * 睡眠，系统冻结（demo 完成后串口不再有任何输出） */
    rt_thread_mdelay(RT_WAITING_FOREVER);
}

static int bme280_ensure_initialized(void)
{
    int result;

    if (bme_initialized)
        return 0;

    result = bme280_init();
    bme_last_error = result;
    if (result != 0)
    {
        rt_kprintf("bme280: not found (err=%d), check 3V3/GND/SCL/SDA/CSB/SDO\n",
                   result);
        bme280_show_error();
        return result;
    }

    bme_initialized = 1;
    rt_kprintf("bme280: detected at 0x%x\n", bme280_get_address());
    return 0;
}

static int bme280_read_sample(struct bme280_sample *sample)
{
    rt_int32_t temperature_abs;
    int result;

    result = bme280_read(sample);
    bme_last_error = result;
    if (result == 0)
    {
        temperature_abs = sample->temperature_centi_c;
        if (temperature_abs < 0)
            temperature_abs = -temperature_abs;
        rt_kprintf("bme280: T=%s%d.%02d C, P=%u Pa, H=%u.%02u %%\n",
                   sample->temperature_centi_c < 0 ? "-" : "",
                   temperature_abs / 100,
                   temperature_abs % 100,
                   sample->pressure_pa,
                   sample->humidity_centi_pct / 100,
                   sample->humidity_centi_pct % 100);
        return 0;
    }

    bme_initialized = 0;
    rt_kprintf("bme280: read failed (err=%d)\n", result);
    bme280_show_error();
    return result;
}

static void bme280_entry(void *param)
{
    struct bme280_sample sample;

    (void)param;
    while (1)
    {
        rt_sem_take(&bme_control_sem, RT_WAITING_FOREVER);
        while (bme_periodic_enabled)
        {
            if (bme280_ensure_initialized() != 0)
            {
                if (bme_periodic_enabled)
                    rt_sem_take(&bme_control_sem, BME280_RETRY_TICKS);
                continue;
            }

            if (!bme_periodic_enabled)
                break;

            if (bme280_read_sample(&sample) == 0)
            {
                bme280_show_page(&sample, bme_display_page);
                bme_display_page = (bme_display_page + 1u) % 3u;
            }
            if (bme_periodic_enabled)
                rt_sem_take(&bme_control_sem, BME280_SAMPLE_TICKS);
        }
    }
}

#ifdef RT_USING_FINSH
static int bme_command(int argc, char **argv)
{
    if (argc != 2)
    {
        rt_kprintf("usage: bme start|stop|once|status\n");
        return -1;
    }

    if (rt_strcmp(argv[1], "start") == 0)
    {
        if (bme_periodic_enabled)
        {
            rt_kprintf("bme280: display rotation is already running\n");
            return 0;
        }

        bme_periodic_enabled = 1;
        bme_display_page = 0;
        rt_kprintf("bme280: display rotation started\n");
        rt_sem_release(&bme_control_sem);
        return 0;
    }

    if (rt_strcmp(argv[1], "stop") == 0)
    {
        if (!bme_periodic_enabled)
        {
            rt_hw_seg_release();
            rt_kprintf("bme280: display rotation is already stopped\n");
            return 0;
        }

        bme_periodic_enabled = 0;
        rt_sem_release(&bme_control_sem);
        rt_hw_seg_release();
        rt_kprintf("bme280: display rotation stopped\n");
        return 0;
    }

    if (rt_strcmp(argv[1], "once") == 0)
    {
        struct bme280_sample sample;

        if (bme_periodic_enabled)
        {
            rt_kprintf("bme280: display rotation is running; use 'bme stop' first\n");
            return -1;
        }

        if (bme280_ensure_initialized() != 0)
            return -1;
        if (bme280_read_sample(&sample) != 0)
            return -1;
        bme280_show_temperature(&sample);
        return 0;
    }

    if (rt_strcmp(argv[1], "status") == 0)
    {
        rt_kprintf("bme280: display=%s initialized=%s last_error=%d",
                   bme_periodic_enabled ? "running" : "stopped",
                   bme_initialized ? "yes" : "no",
                   bme_last_error);
        if (bme_initialized)
            rt_kprintf(" address=0x%x", bme280_get_address());
        rt_kprintf("\n");
        return 0;
    }

    rt_kprintf("usage: bme start|stop|once|status\n");
    return -1;
}

MSH_CMD_EXPORT_ALIAS(bme_command, bme, control BME280 display rotation);
#endif

void rt_application_init(void)
{
    rt_thread_t fin;
    rt_thread_t bme;

    fin = rt_thread_create("fin", finish_entry, RT_NULL, 1024, 12, 20);
    if (fin != RT_NULL)
        rt_thread_startup(fin);

    if (rt_sem_init(&bme_control_sem, "bmectl", 1, RT_IPC_FLAG_FIFO) == RT_EOK)
    {
        bme = rt_thread_create("bme", bme280_entry, RT_NULL, 2048, 15, 20);
        if (bme != RT_NULL)
            rt_thread_startup(bme);
    }

#ifdef RT_USING_FINSH
    /* 串口命令行：finsh 线程（优先级 21）
     * 注意：本函数在 rt_system_scheduler_start() 之前调用，finsh_system_init
     * 内部用 rt_thread_init 创建线程，不依赖调度器已启动 */
    finsh_system_init();
#endif
}

void rtthread_startup(void);

void main(void)
{
    rtthread_startup();
    while (1)
    {
    }
}

void rtthread_startup(void)
{
    rt_hw_interrupt_disable();
    rt_hw_board_init();
    rt_show_version();
    rt_system_timer_init();
    rt_system_scheduler_init();
    rt_application_init();
    rt_thread_idle_init();
    rt_system_scheduler_start();
    while (1)
    {
    }
}
