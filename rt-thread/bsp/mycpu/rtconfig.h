/* RT-Thread config file —— mycpu (RV32IM + Zicsr, 无中断) */

#ifndef __RTTHREAD_CFG_H__
#define __RTTHREAD_CFG_H__

// <h>Basic Configuration
#define RT_THREAD_PRIORITY_MAX  32
/* COUNTER 外设按毫秒递增，1 tick = 1 ms */
#define RT_TICK_PER_SECOND      1000
#define RT_ALIGN_SIZE           4
#define RT_NAME_MAX             8
// </h>

// <h>Hook Configuration
/* idle.c 的 rt_thread_idle_sethook 由此宏使能；tick 由 idle hook 轮询产生 */
#define RT_USING_IDLE_HOOK
/* 覆盖 idle.c 默认 256，容纳 tick hook 调用链 */
#define IDLE_THREAD_STACK_SIZE  512
// </h>

// <h>IPC Configuration
#define RT_USING_SEMAPHORE      /* mem.c 的 heap_sem 依赖 */
#define RT_USING_MUTEX
// </h>

// <h>Memory Management Configuration
#define RT_USING_HEAP
#define RT_USING_SMALL_MEM
// </h>

// <h>Console Configuration
#define RT_USING_CONSOLE
#define RT_CONSOLEBUF_SIZE      256
// </h>

#endif
