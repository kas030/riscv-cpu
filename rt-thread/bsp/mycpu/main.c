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

#ifndef DEMO_RUN_MS
#define DEMO_RUN_MS 3000
#endif

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

static void bme280_entry(void *param)
{
    struct bme280_sample sample;
    rt_int32_t temperature_abs;
    int result;

    (void)param;
    while ((result = bme280_init()) != 0)
    {
        rt_kprintf("bme280: not found (err=%d), check 3V3/GND/SCL/SDA/CSB/SDO\n",
                   result);
        rt_thread_mdelay(2000);
    }

    rt_kprintf("bme280: detected at 0x%x\n", bme280_get_address());
    while (1)
    {
        result = bme280_read(&sample);
        if (result == 0)
        {
            temperature_abs = sample.temperature_centi_c;
            if (temperature_abs < 0)
                temperature_abs = -temperature_abs;
            rt_kprintf("bme280: T=%s%d.%02d C, P=%u Pa, H=%u.%02u %%\n",
                       sample.temperature_centi_c < 0 ? "-" : "",
                       temperature_abs / 100,
                       temperature_abs % 100,
                       sample.pressure_pa,
                       sample.humidity_centi_pct / 100,
                       sample.humidity_centi_pct % 100);
        }
        else
        {
            rt_kprintf("bme280: read failed (err=%d)\n", result);
        }
        rt_thread_mdelay(1000);
    }
}

void rt_application_init(void)
{
    rt_thread_t fin;
    rt_thread_t bme;

    fin = rt_thread_create("fin", finish_entry, RT_NULL, 1024, 12, 20);
    if (fin != RT_NULL)
        rt_thread_startup(fin);

    bme = rt_thread_create("bme", bme280_entry, RT_NULL, 2048, 15, 20);
    if (bme != RT_NULL)
        rt_thread_startup(bme);

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
