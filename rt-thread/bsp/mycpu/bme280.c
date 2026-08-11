/* BME280 轮询驱动：CPU MMIO -> FPGA I2C 主机 -> J7 -> BME280。 */

#include <rtthread.h>

#include "bme280.h"

#define I2C_DEV_ADDR_REG  (*(volatile rt_uint32_t *)0x80200068ul)
#define I2C_REG_ADDR_REG  (*(volatile rt_uint32_t *)0x8020006cul)
#define I2C_DATA_REG      (*(volatile rt_uint32_t *)0x80200070ul)
#define I2C_CTRL_REG      (*(volatile rt_uint32_t *)0x80200074ul)

#define I2C_CTRL_START     (1u << 0)
#define I2C_CTRL_READ      (1u << 1)
#define I2C_STATUS_BUSY    (1u << 0)
#define I2C_STATUS_DONE    (1u << 1)
#define I2C_STATUS_NACK    (1u << 2)

#define BME280_REG_CALIB00    0x88u
#define BME280_REG_ID         0xd0u
#define BME280_REG_RESET      0xe0u
#define BME280_REG_CALIB26    0xe1u
#define BME280_REG_CTRL_HUM   0xf2u
#define BME280_REG_STATUS     0xf3u
#define BME280_REG_CTRL_MEAS  0xf4u
#define BME280_REG_CONFIG     0xf5u
#define BME280_REG_PRESS_MSB  0xf7u

#define BME280_CHIP_ID        0x60u
#define BME280_SOFT_RESET     0xb6u
#define BME280_TIMEOUT_LOOPS  2000000u

struct bme280_calibration
{
    rt_uint16_t dig_t1;
    rt_int16_t  dig_t2;
    rt_int16_t  dig_t3;
    rt_uint16_t dig_p1;
    rt_int16_t  dig_p2;
    rt_int16_t  dig_p3;
    rt_int16_t  dig_p4;
    rt_int16_t  dig_p5;
    rt_int16_t  dig_p6;
    rt_int16_t  dig_p7;
    rt_int16_t  dig_p8;
    rt_int16_t  dig_p9;
    rt_uint8_t  dig_h1;
    rt_int16_t  dig_h2;
    rt_uint8_t  dig_h3;
    rt_int16_t  dig_h4;
    rt_int16_t  dig_h5;
    rt_int8_t   dig_h6;
};

static struct bme280_calibration calibration;
static rt_uint8_t bme280_address = 0x76u;
static rt_int32_t t_fine;
static rt_uint8_t initialized;

static int i2c_wait_done(rt_uint8_t *read_data)
{
    rt_uint32_t timeout;

    for (timeout = 0; timeout < BME280_TIMEOUT_LOOPS; timeout++)
    {
        rt_uint32_t status = I2C_CTRL_REG;

        if (status & I2C_STATUS_DONE)
        {
            if ((status & I2C_STATUS_BUSY) || (status & I2C_STATUS_NACK))
                return -1;
            if (read_data != RT_NULL)
                *read_data = (rt_uint8_t)I2C_DATA_REG;
            return 0;
        }
    }

    return -2;
}

static int bme280_write_reg(rt_uint8_t reg, rt_uint8_t value)
{
    I2C_DEV_ADDR_REG = bme280_address;
    I2C_REG_ADDR_REG = reg;
    I2C_DATA_REG = value;
    I2C_CTRL_REG = I2C_CTRL_START;
    return i2c_wait_done(RT_NULL);
}

static int bme280_read_reg(rt_uint8_t reg, rt_uint8_t *value)
{
    I2C_DEV_ADDR_REG = bme280_address;
    I2C_REG_ADDR_REG = reg;
    I2C_CTRL_REG = I2C_CTRL_START | I2C_CTRL_READ;
    return i2c_wait_done(value);
}

static int read_u16_le(rt_uint8_t reg, rt_uint16_t *value)
{
    rt_uint8_t low;
    rt_uint8_t high;

    if (bme280_read_reg(reg, &low) != 0 ||
        bme280_read_reg((rt_uint8_t)(reg + 1u), &high) != 0)
        return -1;

    *value = (rt_uint16_t)(((rt_uint16_t)high << 8) | low);
    return 0;
}

static rt_int16_t sign_extend_12(rt_uint16_t value)
{
    if (value & 0x0800u)
        value |= 0xf000u;
    return (rt_int16_t)value;
}

static int read_calibration(void)
{
    rt_uint16_t value;
    rt_uint8_t e4;
    rt_uint8_t e5;
    rt_uint8_t e6;
    rt_uint8_t h6;

    if (read_u16_le(BME280_REG_CALIB00 + 0u, &calibration.dig_t1) != 0)
        return -1;
    if (read_u16_le(BME280_REG_CALIB00 + 2u, &value) != 0)
        return -1;
    calibration.dig_t2 = (rt_int16_t)value;
    if (read_u16_le(BME280_REG_CALIB00 + 4u, &value) != 0)
        return -1;
    calibration.dig_t3 = (rt_int16_t)value;

    if (read_u16_le(BME280_REG_CALIB00 + 6u, &calibration.dig_p1) != 0)
        return -1;
    if (read_u16_le(BME280_REG_CALIB00 + 8u, &value) != 0)
        return -1;
    calibration.dig_p2 = (rt_int16_t)value;
    if (read_u16_le(BME280_REG_CALIB00 + 10u, &value) != 0)
        return -1;
    calibration.dig_p3 = (rt_int16_t)value;
    if (read_u16_le(BME280_REG_CALIB00 + 12u, &value) != 0)
        return -1;
    calibration.dig_p4 = (rt_int16_t)value;
    if (read_u16_le(BME280_REG_CALIB00 + 14u, &value) != 0)
        return -1;
    calibration.dig_p5 = (rt_int16_t)value;
    if (read_u16_le(BME280_REG_CALIB00 + 16u, &value) != 0)
        return -1;
    calibration.dig_p6 = (rt_int16_t)value;
    if (read_u16_le(BME280_REG_CALIB00 + 18u, &value) != 0)
        return -1;
    calibration.dig_p7 = (rt_int16_t)value;
    if (read_u16_le(BME280_REG_CALIB00 + 20u, &value) != 0)
        return -1;
    calibration.dig_p8 = (rt_int16_t)value;
    if (read_u16_le(BME280_REG_CALIB00 + 22u, &value) != 0)
        return -1;
    calibration.dig_p9 = (rt_int16_t)value;

    if (bme280_read_reg(0xa1u, &calibration.dig_h1) != 0)
        return -1;
    if (read_u16_le(BME280_REG_CALIB26, &value) != 0)
        return -1;
    calibration.dig_h2 = (rt_int16_t)value;
    if (bme280_read_reg(0xe3u, &calibration.dig_h3) != 0 ||
        bme280_read_reg(0xe4u, &e4) != 0 ||
        bme280_read_reg(0xe5u, &e5) != 0 ||
        bme280_read_reg(0xe6u, &e6) != 0 ||
        bme280_read_reg(0xe7u, &h6) != 0)
        return -1;

    calibration.dig_h4 = sign_extend_12((rt_uint16_t)(((rt_uint16_t)e4 << 4) |
                                                       (e5 & 0x0fu)));
    calibration.dig_h5 = sign_extend_12((rt_uint16_t)(((rt_uint16_t)e6 << 4) |
                                                       (e5 >> 4)));
    calibration.dig_h6 = (rt_int8_t)h6;
    return 0;
}

static rt_int32_t compensate_temperature(rt_int32_t adc_t)
{
    rt_int32_t var1;
    rt_int32_t var2;

    var1 = ((((adc_t >> 3) - ((rt_int32_t)calibration.dig_t1 << 1))) *
            (rt_int32_t)calibration.dig_t2) >> 11;
    var2 = (((((adc_t >> 4) - (rt_int32_t)calibration.dig_t1) *
              ((adc_t >> 4) - (rt_int32_t)calibration.dig_t1)) >> 12) *
            (rt_int32_t)calibration.dig_t3) >> 14;
    t_fine = var1 + var2;
    return (t_fine * 5 + 128) >> 8;
}

static rt_uint32_t compensate_pressure(rt_int32_t adc_p)
{
    rt_int64_t var1;
    rt_int64_t var2;
    rt_int64_t pressure;

    var1 = (rt_int64_t)t_fine - 128000;
    var2 = var1 * var1 * (rt_int64_t)calibration.dig_p6;
    var2 += (var1 * (rt_int64_t)calibration.dig_p5) * 131072;
    var2 += (rt_int64_t)calibration.dig_p4 * ((rt_int64_t)1 << 35);
    var1 = ((var1 * var1 * (rt_int64_t)calibration.dig_p3) >> 8) +
           ((var1 * (rt_int64_t)calibration.dig_p2) * 4096);
    var1 = (((((rt_int64_t)1 << 47) + var1) *
             (rt_int64_t)calibration.dig_p1) >> 33);
    if (var1 == 0)
        return 0;

    pressure = 1048576 - adc_p;
    pressure = (((pressure << 31) - var2) * 3125) / var1;
    var1 = ((rt_int64_t)calibration.dig_p9 * (pressure >> 13) *
            (pressure >> 13)) >> 25;
    var2 = ((rt_int64_t)calibration.dig_p8 * pressure) >> 19;
    pressure = ((pressure + var1 + var2) >> 8) +
               ((rt_int64_t)calibration.dig_p7 * 16);
    return (rt_uint32_t)(pressure >> 8);
}

static rt_uint32_t compensate_humidity(rt_int32_t adc_h)
{
    rt_int32_t value;

    value = t_fine - 76800;
    value = (((((adc_h << 14) -
                ((rt_int32_t)calibration.dig_h4 * 1048576) -
                ((rt_int32_t)calibration.dig_h5 * value)) + 16384) >> 15) *
             (((((((value * (rt_int32_t)calibration.dig_h6) >> 10) *
                  (((value * (rt_int32_t)calibration.dig_h3) >> 11) + 32768)) >> 10) +
                2097152) * (rt_int32_t)calibration.dig_h2 + 8192) >> 14));
    value -= (((((value >> 15) * (value >> 15)) >> 7) *
               (rt_int32_t)calibration.dig_h1) >> 4);
    if (value < 0)
        value = 0;
    if (value > 419430400)
        value = 419430400;

    /* 数据手册结果单位为 1/1024 %RH，转换为 0.01 %RH。 */
    return (rt_uint32_t)(((rt_uint32_t)(value >> 12) * 100u) / 1024u);
}

int bme280_init(void)
{
    static const rt_uint8_t candidate_addresses[] = {0x76u, 0x77u};
    rt_uint8_t chip_id = 0;
    rt_uint8_t status = 0;
    rt_size_t i;

    initialized = 0;
    for (i = 0; i < sizeof(candidate_addresses); i++)
    {
        bme280_address = candidate_addresses[i];
        if (bme280_read_reg(BME280_REG_ID, &chip_id) == 0 &&
            chip_id == BME280_CHIP_ID)
            break;
    }
    if (i == sizeof(candidate_addresses))
        return -1;

    if (bme280_write_reg(BME280_REG_RESET, BME280_SOFT_RESET) != 0)
        return -2;
    rt_thread_mdelay(5);

    /* 等待 NVM 校准参数复制完成（status.im_update 清零）。 */
    for (i = 0; i < 20; i++)
    {
        if (bme280_read_reg(BME280_REG_STATUS, &status) != 0)
            return -3;
        if ((status & 0x01u) == 0)
            break;
        rt_thread_mdelay(1);
    }
    if (status & 0x01u)
        return -4;

    if (read_calibration() != 0)
        return -5;

    /* 湿度、温度、气压均 x1；保持 sleep，由每次读取触发 forced mode。 */
    if (bme280_write_reg(BME280_REG_CTRL_HUM, 0x01u) != 0 ||
        bme280_write_reg(BME280_REG_CONFIG, 0x00u) != 0 ||
        bme280_write_reg(BME280_REG_CTRL_MEAS, 0x24u) != 0)
        return -6;

    initialized = 1;
    return 0;
}

int bme280_read(struct bme280_sample *sample)
{
    rt_uint8_t raw[8];
    rt_uint8_t status;
    rt_int32_t adc_p;
    rt_int32_t adc_t;
    rt_int32_t adc_h;
    rt_size_t i;

    if (!initialized || sample == RT_NULL)
        return -1;

    /* forced mode：测量完成后芯片回到 sleep，逐字节读取期间数据保持不变。 */
    if (bme280_write_reg(BME280_REG_CTRL_MEAS, 0x25u) != 0)
        return -2;
    rt_thread_mdelay(10);

    if (bme280_read_reg(BME280_REG_STATUS, &status) != 0 ||
        (status & 0x08u))
        return -3;

    for (i = 0; i < sizeof(raw); i++)
    {
        if (bme280_read_reg((rt_uint8_t)(BME280_REG_PRESS_MSB + i), &raw[i]) != 0)
            return -4;
    }

    adc_p = ((rt_int32_t)raw[0] << 12) |
            ((rt_int32_t)raw[1] << 4) | (raw[2] >> 4);
    adc_t = ((rt_int32_t)raw[3] << 12) |
            ((rt_int32_t)raw[4] << 4) | (raw[5] >> 4);
    adc_h = ((rt_int32_t)raw[6] << 8) | raw[7];
    if (adc_p == 0x80000 || adc_t == 0x80000 || adc_h == 0x8000)
        return -5;

    sample->temperature_centi_c = compensate_temperature(adc_t);
    sample->pressure_pa = compensate_pressure(adc_p);
    sample->humidity_centi_pct = compensate_humidity(adc_h);
    return 0;
}

rt_uint8_t bme280_get_address(void)
{
    return bme280_address;
}
