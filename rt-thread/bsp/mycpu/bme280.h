#ifndef __BME280_H__
#define __BME280_H__

#include <rtthread.h>

struct bme280_sample
{
    rt_int32_t  temperature_centi_c;
    rt_uint32_t pressure_pa;
    rt_uint32_t humidity_centi_pct;
};

int bme280_init(void);
int bme280_read(struct bme280_sample *sample);
rt_uint8_t bme280_get_address(void);

#endif
