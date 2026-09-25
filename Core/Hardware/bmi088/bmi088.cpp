#include "bmi088.hpp"
#include "bmi088_reg.h"

#include "gpio.h"
#include "cmsis_os2.h"
#include "FreeRTOS.h"
#include "MahonyAHRS.h"
#include <arm_math.h>

extern osSemaphoreId_t Bmi088GyroBufferSemHandle;
extern osSemaphoreId_t Bmi088AccBufferSemHandle;
extern osSemaphoreId_t Bmi088TempBufferSemHandle;

Bmi088::Bmi088(Bmi088CommunicationController_t communication_controller, Bmi088TemperatureCommunicationController_t temperature_communication_controller)
    : communication_controller(communication_controller), bmi088_temperature(temperature_communication_controller)
{
    this->acc_data = {0.0f, 0.0f, 0.0f};
    this->gyro_data = {0.0f, 0.0f, 0.0f};
    this->gyro_bias = {
        .gyroscope_roll = 0.00155281043f,
        .gyroscope_pitch = 0.00148057903f,
        .gyroscope_yaw = 0.00126652408f};
    this->sensor_time = 0.0f;
    this->quaternions[0] = 1.0f;
    this->quaternions[1] = 0.0f;
    this->quaternions[2] = 0.0f;
    this->quaternions[3] = 0.0f;
    this->euler_angles = {0.0f, 0.0f, 0.0f};
};

Bmi088::~Bmi088()
{
    ; // Destructor implementation (if needed)
}

Bmi088Status_t Bmi088::setup()
{
    uint8_t dummy = 0;
    Bmi088Status_t status = BMI088_ERROR_NONE;
    HAL_SPI_RegisterCallback(this->communication_controller.hspi, HAL_SPI_TX_RX_COMPLETE_CB_ID, this->SPI_TxRxCpltCallback);

    osDelay(100); // 等待 BMI088 上电稳定。

    // 加速度计软复位：清空加速度计寄存器并回到默认状态。
    this->_write_reg(BMI088_REG_ACC, ACC_SOFTRESET_ADDR, ACC_SOFTRESET_VAL);
    osDelay(50); // 等待加速度计复位完成。

    // 加速度计 dummy read：上电后首次 SPI 读用于切换/稳定 SPI 接口，读值不使用。
    this->_read_reg(BMI088_REG_ACC, ACC_CHIP_ID_ADDR, &dummy);
    osDelay(1);

    // 加速度计电源控制：打开加速度计数据通路。
    this->_write_reg(BMI088_REG_ACC, ACC_PWR_CTRL_ADDR, ACC_PWR_CTRL_ON);
    osDelay(50); // 等待加速度计电源域启动。

    // 加速度计电源模式：退出 suspend，进入 active 正常工作模式。
    this->_write_reg(BMI088_REG_ACC, ACC_PWR_CONF_ADDR, ACC_PWR_CONF_ACT);

    // 陀螺仪软复位：清空陀螺仪寄存器并回到默认状态。
    this->_write_reg(BMI088_REG_GYRO, GYRO_SOFTRESET_ADDR, GYRO_SOFTRESET_VAL);
    osDelay(50); // 等待陀螺仪复位完成。

    // 陀螺仪 dummy read：确认 SPI 访问链路已稳定，读值不使用。
    this->_read_reg(BMI088_REG_GYRO, GYRO_CHIP_ID_ADDR, &dummy);
    osDelay(1);

    // 陀螺仪低功耗模式：配置为 normal mode，允许陀螺仪正常采样。
    this->_write_reg(BMI088_REG_GYRO, GYRO_LPM1_ADDR, GYRO_LPM1_NOR);

    // 校验加速度计芯片 ID：期望 ACC_CHIP_ID_VAL。
    status = static_cast<Bmi088Status_t>(status | this->_acc_checkid());

    // 校验陀螺仪芯片 ID：期望 GYRO_CHIP_ID_VAL。
    status = static_cast<Bmi088Status_t>(status | this->_gyro_checkid());

    // // 加速度计自检：切换正/负自检激励并比较三轴响应。
    // status = (BMI088_Status_t)(status | bmi088_acc_selfcheck(bmi088_controller));

    // // 陀螺仪自检：触发 BIST 并检查 bist_rdy / bist_fail 标志。
    // status = (BMI088_Status_t)(status | bmi088_gyro_selfcheck(bmi088_controller));

    if (status != BMI088_ERROR_NONE)
    {
        return status;
    }

    // 加速度计量程：配置为 +-3g。
    this->_write_reg(BMI088_REG_ACC, ACC_RANGE_ADDR, ACC_RANGE_3G);

    // 加速度计输出配置：bit7 保留位写 1，bit[6:4] 正常带宽，bit[3:0] 800Hz 输出数据率。
    this->_write_reg(BMI088_REG_ACC, ACC_CONF_ADDR, (ACC_CONF_RESERVED << 7) | (ACC_CONF_BWP_NORM << 4) | ACC_CONF_ODR_800_Hz);

    // 加速度计 INT1 引脚配置：输出使能、推挽、高有效，用作数据就绪中断输出。
    this->_write_reg(BMI088_REG_ACC, INT1_IO_CTRL_ADDR, ACC_INT1_IO_DRDY_OUTPUT);

    // 加速度计中断映射：将加速度计 data ready 中断映射到 INT1。
    this->_write_reg(BMI088_REG_ACC, INT_MAP_DATA_ADDR, ACC_INT_MAP_DATA_DRDY_TO_INT1);

    // 陀螺仪量程：配置为 +-500 deg/s。
    this->_write_reg(BMI088_REG_GYRO, GYRO_RANGE_ADDR, GYRO_RANGE_1000_DEG_S);

    // 陀螺仪带宽/输出速率：1000Hz ODR，116Hz 带宽。
    this->_write_reg(BMI088_REG_GYRO, GYRO_BANDWIDTH_ADDR, GYRO_ODR_1000Hz_BANDWIDTH_116Hz);

    // 陀螺仪中断控制：使能 data ready 中断。
    this->_write_reg(BMI088_REG_GYRO, GYRO_INT_CTRL_ADDR, GYRO_INT_CTRL_DRDY_ENABLE);

    // 陀螺仪 INT3/INT4 电气配置：INT3 推挽、高有效。
    this->_write_reg(BMI088_REG_GYRO, GYRO_INT3_INT4_IO_CONF_ADDR, GYRO_INT3_IO_DRDY_OUTPUT);

    // 陀螺仪中断映射：将陀螺仪 data ready 中断映射到 INT3。
    this->_write_reg(BMI088_REG_GYRO, GYRO_INT3_INT4_IO_MAP_ADDR, GYRO_INT_MAP_DRDY_TO_INT3);

    this->bmi088_temperature.setup();

    return status;
}

void Bmi088::control()
{
    {
        // 解析陀螺仪数据
        // uint8_t range = GYRO_RANGE_1000_DEG_S;
        int16_t raw_roll;
        int16_t raw_pitch;
        int16_t raw_yaw;
        float unit = 32.768f;

        if (osSemaphoreAcquire(Bmi088GyroBufferSemHandle, 0) == osOK)
        {
            raw_roll = static_cast<int16_t>(static_cast<uint16_t>(this->gyro_rx_buffer[2]) << 8 | gyro_rx_buffer[1]);
            raw_pitch = static_cast<int16_t>(static_cast<uint16_t>(gyro_rx_buffer[4]) << 8 | gyro_rx_buffer[3]);
            raw_yaw = static_cast<int16_t>(static_cast<uint16_t>(gyro_rx_buffer[6]) << 8 | gyro_rx_buffer[5]);

            float rad_roll = raw_roll / unit * DEG2SEC;
            float rad_pitch = raw_pitch / unit * DEG2SEC;
            float rad_yaw = raw_yaw / unit * DEG2SEC;

            // 减去陀螺仪偏置
            this->gyro_data.gyroscope_roll = rad_roll - this->gyro_bias.gyroscope_roll;
            this->gyro_data.gyroscope_pitch = rad_pitch - this->gyro_bias.gyroscope_pitch;
            this->gyro_data.gyroscope_yaw = rad_yaw - this->gyro_bias.gyroscope_yaw;

            osSemaphoreRelease(Bmi088GyroBufferSemHandle);
        }
    }
    {
        // 解析加速度计数据
        int16_t raw_x;
        int16_t raw_y;
        int16_t raw_z;
        float unit = BMI088_ACCEL_3G_SEN;

        if (osSemaphoreAcquire(Bmi088AccBufferSemHandle, 0) == osOK)
        {
            raw_x = static_cast<int16_t>(static_cast<uint16_t>(acc_rx_buffer[3]) << 8 | acc_rx_buffer[2]);
            raw_y = static_cast<int16_t>(static_cast<uint16_t>(acc_rx_buffer[5]) << 8 | acc_rx_buffer[4]);
            raw_z = static_cast<int16_t>(static_cast<uint16_t>(acc_rx_buffer[7]) << 8 | acc_rx_buffer[6]);

            this->acc_data.acceleration_x = raw_x * unit;
            this->acc_data.acceleration_y = raw_y * unit;
            this->acc_data.acceleration_z = raw_z * unit;

            osSemaphoreRelease(Bmi088AccBufferSemHandle);
        }
    }
}

void Bmi088::temp_control()
{
    {
        if (osSemaphoreAcquire(Bmi088TempBufferSemHandle, 0) == osOK)
        {
            this->bmi088_temperature.control();
            osSemaphoreRelease(Bmi088TempBufferSemHandle);
        }
    }
    this->bmi088_temperature._pid_calculate();
    this->bmi088_temperature.callback();
}

void Bmi088::callback()
{
    MahonyAHRSupdate(this->quaternions, this->gyro_data.gyroscope_roll, this->gyro_data.gyroscope_pitch, this->gyro_data.gyroscope_yaw, this->acc_data.acceleration_x, this->acc_data.acceleration_y, this->acc_data.acceleration_z, 0.0f, 0.0f, 0.0f);

    this->euler_angles.yaw = atan2f(2.0f * (quaternions[0] * quaternions[3] + quaternions[1] * quaternions[2]), 2.0f * (quaternions[0] * quaternions[0] + quaternions[1] * quaternions[1]) - 1.0f);
    this->euler_angles.pitch = asinf(-2.0f * (quaternions[1] * quaternions[3] - quaternions[0] * quaternions[2]));
    this->euler_angles.roll = atan2f(2.0f * (quaternions[0] * quaternions[1] + quaternions[2] * quaternions[3]), 2.0f * (quaternions[0] * quaternions[0] + quaternions[3] * quaternions[3]) - 1.0f);
    ;
}

void Bmi088::_write_reg(Bmi088RegType_t reg, uint8_t addr, uint8_t data)
{
    SPI_HandleTypeDef *hspi = this->communication_controller.hspi;
    GPIO_TypeDef *cs_port; // 片选端口 (例如 GPIOA)
    uint16_t cs_pin;       // 片选引脚 (例如 GPIO_PIN_4)
    if (reg == BMI088_REG_ACC)
    {
        cs_port = this->communication_controller.gpio_port_acc_cs;
        cs_pin = this->communication_controller.gpio_pin_acc_cs;
    }
    else if (reg == BMI088_REG_GYRO)
    {
        cs_port = this->communication_controller.gpio_port_gyro_cs;
        cs_pin = this->communication_controller.gpio_pin_gyro_cs;
    }

    uint8_t txdata{};
    HAL_GPIO_WritePin(cs_port, cs_pin, GPIO_PIN_RESET); // 拉低片选引脚，开始通信
    txdata = (addr & BMI088_SPI_WRITE_CODE);            // 写操作，清除最高位
    HAL_SPI_Transmit(hspi, &txdata, 1, 1000);           // 发送寄存器地址
    while (HAL_SPI_GetState(hspi) == HAL_SPI_STATE_BUSY_TX)
        ;
    txdata = data;                            // 要写入的数据
    HAL_SPI_Transmit(hspi, &txdata, 1, 1000); // 发送数据
    while (HAL_SPI_GetState(hspi) == HAL_SPI_STATE_BUSY_TX)
        ;
    HAL_Delay(1);                                     // 等待一段时间，确保写入完成
    HAL_GPIO_WritePin(cs_port, cs_pin, GPIO_PIN_SET); // 拉高片选引脚，结束通信
}

void Bmi088::_read_reg(Bmi088RegType_t reg, uint8_t addr, uint8_t *data)
{
    SPI_HandleTypeDef *hspi = this->communication_controller.hspi;
    GPIO_TypeDef *cs_port; // 片选端口 (例如 GPIOA)
    uint16_t cs_pin;       // 片选引脚 (例如 GPIO_PIN_4)
    if (reg == BMI088_REG_ACC)
    {
        cs_port = this->communication_controller.gpio_port_acc_cs;
        cs_pin = this->communication_controller.gpio_pin_acc_cs;
    }
    else if (reg == BMI088_REG_GYRO)
    {
        cs_port = this->communication_controller.gpio_port_gyro_cs;
        cs_pin = this->communication_controller.gpio_pin_gyro_cs;
    }

    HAL_GPIO_WritePin(cs_port, cs_pin, GPIO_PIN_RESET); // 拉低片选引脚，开始通信
    uint8_t txdata = (addr | BMI088_SPI_READ_CODE);     // 读操作，设置最高位
    HAL_SPI_Transmit(hspi, &txdata, 1, 1000);           // 发送寄存器地址
    while (HAL_SPI_GetState(hspi) == HAL_SPI_STATE_BUSY_TX)
        ;
    if (reg == BMI088_REG_ACC)
    {
        HAL_SPI_Receive(hspi, data, 1, 1000); // 加速度计 SPI 读需要丢弃第一个 dummy byte
        while (HAL_SPI_GetState(hspi) == HAL_SPI_STATE_BUSY_RX)
            ;
    }
    HAL_SPI_Receive(hspi, data, 1, 1000); // 接收数据
    while (HAL_SPI_GetState(hspi) == HAL_SPI_STATE_BUSY_RX)
        ;
    HAL_GPIO_WritePin(cs_port, cs_pin, GPIO_PIN_SET); // 拉高片选引脚，结束通信
}

void Bmi088::_read_regs(Bmi088RegType_t reg, uint8_t addr, uint8_t *data, uint16_t len)
{
    SPI_HandleTypeDef *hspi = this->communication_controller.hspi;
    GPIO_TypeDef *cs_port; // 片选端口 (例如 GPIOA)
    uint16_t cs_pin;       // 片选引脚 (例如 GPIO_PIN_4)
    if (reg == BMI088_REG_ACC)
    {
        cs_port = this->communication_controller.gpio_port_acc_cs;
        cs_pin = this->communication_controller.gpio_pin_acc_cs;
    }
    else if (reg == BMI088_REG_GYRO)
    {
        cs_port = this->communication_controller.gpio_port_gyro_cs;
        cs_pin = this->communication_controller.gpio_pin_gyro_cs;
    }

    HAL_GPIO_WritePin(cs_port, cs_pin, GPIO_PIN_RESET); // 拉低片选引脚，开始通信
    uint8_t txdata = (addr | BMI088_SPI_READ_CODE);     // 读操作，设置最高位
    HAL_SPI_Transmit(hspi, &txdata, 1, 1000);           // 发送寄存器地址
    while (HAL_SPI_GetState(hspi) == HAL_SPI_STATE_BUSY_TX)
        ;
    if (reg == BMI088_REG_ACC)
    {
        uint8_t dummy;
        HAL_SPI_Receive(hspi, &dummy, 1, 1000); // 加速度计 SPI 读需要丢弃第一个 dummy byte
        while (HAL_SPI_GetState(hspi) == HAL_SPI_STATE_BUSY_RX)
            ;
    }
    HAL_SPI_Receive(hspi, data, len, 1000); // 接收数据
    while (HAL_SPI_GetState(hspi) == HAL_SPI_STATE_BUSY_RX)
        ;
    HAL_GPIO_WritePin(cs_port, cs_pin, GPIO_PIN_SET); // 拉高片选引脚，结束通信
}

Bmi088Status_t Bmi088::_acc_checkid()
{
    uint8_t chip_id = 0;

    this->_read_reg(BMI088_REG_ACC, ACC_CHIP_ID_ADDR, &chip_id);
    if (chip_id != ACC_CHIP_ID_VAL)
    {
        return BMI088_ACC_CHIP_ID_ERR;
    }

    return BMI088_ERROR_NONE;
}

Bmi088Status_t Bmi088::_gyro_checkid()
{
    uint8_t chip_id = 0;

    this->_read_reg(BMI088_REG_GYRO, GYRO_CHIP_ID_ADDR, &chip_id);
    if (chip_id != GYRO_CHIP_ID_VAL)
    {
        return BMI088_GYRO_CHIP_ID_ERR;
    }

    return BMI088_ERROR_NONE;
}

uint8_t *Bmi088::_get_acc_rx_buffer()
{
    return this->acc_rx_buffer;
}

uint8_t *Bmi088::_get_gyro_rx_buffer()
{
    return this->gyro_rx_buffer;
}

uint8_t *Bmi088::_get_temperature_rx_buffer()
{
    return this->bmi088_temperature._get_temperature_rx_buffer();
}

void Bmi088::pack_bmi088_status_queue(Bmi088StatusQueue_t &status_queue)
{
    status_queue.roll = this->euler_angles.roll;
    status_queue.pitch = this->euler_angles.pitch;
    status_queue.yaw = this->euler_angles.yaw;
}