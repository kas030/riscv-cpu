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
/* Topic : Description
        This file contains configuration constants required to execute on
   different platforms
   平台适配（mycpu：RV32IM + Zicsr，无中断，RT-Thread Nano）：
        HAS_FLOAT=1：计时换算由最小化 MMIO 单精度硬件 FPU 完成
        SEED_METHOD=SEED_ARG：种子/迭代数走 msh 命令行（官方 CLI 语义）
        MEM_METHOD=MEM_STATIC：core_main.c 内置静态缓冲，无需 malloc
        计时取 COUNTER（0x80200050）毫秒计数，EE_TICKS_PER_SEC=1000
        TOTAL_DATA_SIZE=2000 为官方标准性能跑分缓冲（CoreMark Size 666/算法）
*/
#ifndef CORE_PORTME_H
#define CORE_PORTME_H
/************************/
/* Data types and settings */
/************************/
/* Configuration : HAS_FLOAT
        Define to 1 if the platform supports floating point.
*/
#define HAS_FLOAT 1
/* Configuration : HAS_TIME_H
        Define to 1 if platform has the time.h header file,
        and implementation of functions thereof.
*/
#define HAS_TIME_H 0
/* Configuration : USE_CLOCK
        Define to 1 if platform has the time.h header file,
        and implementation of functions thereof.
*/
#define USE_CLOCK 0
/* Configuration : HAS_STDIO
        Define to 1 if the platform has stdio.h.
*/
#define HAS_STDIO 0
/* Configuration : HAS_PRINTF
        Define to 1 if the platform has stdio.h and implements the printf
   function.
*/
#define HAS_PRINTF 0

#include <stdint.h>
#include <stddef.h>

/* Definitions : COMPILER_VERSION, COMPILER_FLAGS, MEM_LOCATION
        Initialize these strings per platform
*/
#define COMPILER_VERSION "GCC"__VERSION__
#define CM_STRINGIFY_INNER(value) #value
#define CM_STRINGIFY(value)       CM_STRINGIFY_INNER(value)
#define COMPILER_FLAGS \
    "-O3 -fsched-pressure -ftracer -mbranch-cost=1 " \
    "-funroll-all-loops[list,matrix,util] -funroll-loops[main,state,port] " \
    "-march=rv32im_zicsr -Dmain=coremark_main -DPERFORMANCE_RUN=1 " \
    "-DTOTAL_DATA_SIZE=2000 -DITERATIONS=" CM_STRINGIFY(ITERATIONS) \
    " -DHAS_FLOAT=1 -DHARDWARE_FPU_SINGLE=1"
#define MEM_LOCATION "Static"

/* Data Types :
        ee_ptr_int needs to be the data type used to hold pointers, otherwise
   coremark may fail!!!
*/
typedef uint8_t  ee_u8;
typedef int16_t  ee_s16;
typedef uint16_t ee_u16;
typedef int32_t  ee_s32;
typedef uint32_t ee_u32;
typedef ee_u32   ee_ptr_int;   /* 32 位平台，指针与 u32 同宽 */
typedef size_t   ee_size_t;
#define NULL ((void *)0)
/* align_mem :
        This macro is used to align an offset to point to a 32b value. It is
   used in the Matrix algorithm to initialize the input memory blocks.
*/
#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x)-1) & ~3))

/* Configuration : CORE_TICKS
        Define type of return from the timing functions.
 */
#define CORETIMETYPE ee_u32
typedef ee_u32 CORE_TICKS;
#define EE_TICKS_PER_SEC 1000   /* COUNTER 毫秒计数：1 tick = 1 ms */

/* Configuration : SEED_METHOD
        SEED_ARG - from command line.
*/
#define SEED_METHOD SEED_ARG

/* Configuration : MEM_METHOD
        MEM_STATIC - to use a static memory array.
*/
#define MEM_METHOD MEM_STATIC

/* Configuration : MULTITHREAD
        Define for parallel execution. 1 - only one context (default).
*/
#define MULTITHREAD 1
#define USE_PTHREAD 0
#define USE_FORK    0
#define USE_SOCKET  0

/* Configuration : MAIN_HAS_NOARGC
        0 - argc/argv to main is supported
*/
#define MAIN_HAS_NOARGC 0

/* Configuration : MAIN_HAS_NORETURN
        0 - main returns an int, and return value will be 0.
*/
#define MAIN_HAS_NORETURN 0

/* 交互命令默认运行 18000 次；调用者仍可用第 4 个参数覆盖。 */
#ifndef ITERATIONS
#define ITERATIONS 18000
#endif
#ifndef TOTAL_DATA_SIZE
#define TOTAL_DATA_SIZE 2000
#endif

/* Variable : default_num_contexts
        Not used for this simple port, must contain the value 1.
*/
extern ee_u32 default_num_contexts;

typedef struct CORE_PORTABLE_S
{
    ee_u8 portable_id;
} core_portable;

/* target specific init/fini */
void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);

#if !defined(PROFILE_RUN) && !defined(PERFORMANCE_RUN) \
    && !defined(VALIDATION_RUN)
#if (TOTAL_DATA_SIZE == 1200)
#define PROFILE_RUN 1
#elif (TOTAL_DATA_SIZE == 2000)
#define PERFORMANCE_RUN 1
#else
#define VALIDATION_RUN 1
#endif
#endif

int   ee_printf(const char *fmt, ...);
int   ee_print_float(float value);
float coremark_iterations_per_sec(ee_u32 iterations, CORE_TICKS ticks);

#endif /* CORE_PORTME_H */
