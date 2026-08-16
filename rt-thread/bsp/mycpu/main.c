/*
 * main.c —— RT-Thread Nano 3.1.5 mycpu 平台启动序列与演示程序
 *
 * 启动序列：_start -> main -> rtthread_startup。调度器启动后 boot 上下文不再
 * 返回，因此演示线程必须在 rt_system_scheduler_start() 之前创建。
 *
 * 正常板卡镜像禁用 3 秒后写 LED 0xC0DEC0DE 的仿真完成线程，
 * 避免覆盖 CoreMark 的 LED 开始/结束标记。
 */

#include <rthw.h>
#include <rtthread.h>

#include "board.h"
#include "bme280.h"

#ifdef RT_USING_FINSH
int finsh_system_init(void);
#endif

#define LED_ADDR 0x80200040ul

#define BME280_SAMPLE_TICKS (RT_TICK_PER_SECOND)
#define BME280_RETRY_TICKS  (2 * RT_TICK_PER_SECOND)

#ifndef DEMO_RUN_MS
#define DEMO_RUN_MS 3000
#endif

#ifndef DEMO_FINISH_THREAD
#define DEMO_FINISH_THREAD 0
#endif

static struct rt_semaphore bme_control_sem;
static volatile rt_uint8_t bme_periodic_enabled;
static volatile rt_uint8_t bme_initialized;
static volatile int bme_last_error;

#ifdef COREMARK_PERF_AUTORUN
void coremark_perf_autorun_init(void);
#endif

#if DEMO_FINISH_THREAD
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
#endif

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
        return result;
    }

    bme_initialized = 1;
    rt_kprintf("bme280: detected at 0x%x\n", bme280_get_address());
    return 0;
}

static int bme280_print_sample(void)
{
    struct bme280_sample sample;
    rt_int32_t temperature_abs;
    int result;

    result = bme280_read(&sample);
    bme_last_error = result;
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
        return 0;
    }

    /* 测量超时或复位后的无效占位值属于可恢复错误，保留初始化状态，
     * 下一周期直接重新触发 forced mode；I2C 事务错误才重新初始化。 */
    if (result == -2 || result == -3 || result == -4)
        bme_initialized = 0;
    rt_kprintf("bme280: read failed (err=%d)\n", result);
    return result;
}

static void bme280_entry(void *param)
{
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

            bme280_print_sample();
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
            rt_kprintf("bme280: periodic output is already running\n");
            return 0;
        }

        bme_periodic_enabled = 1;
        rt_kprintf("bme280: periodic output started\n");
        rt_sem_release(&bme_control_sem);
        return 0;
    }

    if (rt_strcmp(argv[1], "stop") == 0)
    {
        if (!bme_periodic_enabled)
        {
            rt_kprintf("bme280: periodic output is already stopped\n");
            return 0;
        }

        bme_periodic_enabled = 0;
        rt_sem_release(&bme_control_sem);
        rt_kprintf("bme280: periodic output stopped\n");
        return 0;
    }

    if (rt_strcmp(argv[1], "once") == 0)
    {
        if (bme_periodic_enabled)
        {
            rt_kprintf("bme280: periodic output is running; use 'bme stop' first\n");
            return -1;
        }

        if (bme280_ensure_initialized() != 0)
            return -1;
        return bme280_print_sample();
    }

    if (rt_strcmp(argv[1], "status") == 0)
    {
        rt_kprintf("bme280: periodic=%s initialized=%s last_error=%d",
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

MSH_CMD_EXPORT_ALIAS(bme_command, bme, control BME280 periodic output);
#endif

void rt_application_init(void)
{
#if DEMO_FINISH_THREAD
    rt_thread_t fin;
#endif
    rt_thread_t bme;

#ifdef COREMARK_PERF_AUTORUN
    coremark_perf_autorun_init();
#endif

#if DEMO_FINISH_THREAD
    fin = rt_thread_create("fin", finish_entry, RT_NULL, 1024, 12, 20);
    if (fin != RT_NULL)
        rt_thread_startup(fin);
#endif

    if (rt_sem_init(&bme_control_sem, "bmectl", 0, RT_IPC_FLAG_FIFO) == RT_EOK)
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
