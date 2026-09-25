#include "jetson.hpp"
#include <arm_math.h>
#include <string.h>

// 将角度归一化到 [-pi, pi]。
static float jetson_wrap(float angle_rad)
{
    float wrapped_angle = fmodf(angle_rad + M_PI, 2.0f * M_PI);
    if (wrapped_angle < 0.0f)
    {
        wrapped_angle += 2.0f * M_PI;
    }
    return wrapped_angle - M_PI;
}

// 将大端 q100 字节解码为 double。
// static float jetson_orin_uint162float(uint8_t msb, uint8_t lsb)
// {
//     int16_t raw = (int16_t)(((uint16_t)lsb << 8U) | (uint16_t)msb);

//     return static_cast<float>(raw) / 2048.0f;
// }

// 将 float 编码为小端 q2048 字节。
static void jetson_float2uint16(uint8_t &msb, uint8_t &lsb, float value)
{
    float value_q2048 = value * 2048.0f;

    if (value_q2048 > 32767.0f)
    {
        value_q2048 = 32767.0f;
    }
    else if (value_q2048 < -32768.0f)
    {
        value_q2048 = -32768.0f;
    }

    if (value_q2048 >= 0.0f)
    {
        value_q2048 += 0.5f;
    }
    else
    {
        value_q2048 -= 0.5f;
    }

    int16_t value_u16 = static_cast<int16_t>(value_q2048);

    lsb = static_cast<uint8_t>((static_cast<uint16_t>(value_u16) >> 8U) & 0xFFU);
    msb = static_cast<uint8_t>(static_cast<uint16_t>(value_u16) & 0xFFU);
}

static uint8_t jetson_generate_checksum(const uint8_t *data, size_t length)
{
    uint8_t checksum = 0;
    for (size_t i = 0; i < length; ++i)
    {
        checksum += data[i];
    }
    return checksum;
}

Jetson::Jetson(UART_HandleTypeDef *huart)
{
    this->huart = huart;
    memset(&this->gimbal_status, 0, sizeof(this->gimbal_status));
    memset(this->_tx_data, 0, sizeof(this->_tx_data));
}

void Jetson::setup()
{
    ;
}

void Jetson::control()
{
    // 这里可以添加控制逻辑
    this->_pack_tx_data();
    HAL_UART_Transmit_DMA(this->huart, this->_tx_data, sizeof(this->_tx_data));
}

#define JETSON_TX_FRAME_HEADER_1 0x55
#define JETSON_TX_FRAME_HEADER_2 0xAA
#define JETSON_TX_FRAME_TAIL 0x0D
void Jetson::_pack_tx_data()
{
    this->_tx_data[0] = JETSON_TX_FRAME_HEADER_1;
    this->_tx_data[1] = JETSON_TX_FRAME_HEADER_2;

    jetson_float2uint16(this->_tx_data[2], this->_tx_data[3], jetson_wrap(this->gimbal_status.yaw));
    jetson_float2uint16(this->_tx_data[4], this->_tx_data[5], jetson_wrap(this->gimbal_status.pitch));
    jetson_float2uint16(this->_tx_data[6], this->_tx_data[7], jetson_wrap(this->gimbal_status.roll));

    this->_tx_data[8] = jetson_generate_checksum(&this->_tx_data[2], JETSON_TX_FRAME_SIZE - 4);

    this->_tx_data[9] = JETSON_TX_FRAME_TAIL;
}

void Jetson::parse_bmi088_status_queue(const Bmi088StatusQueue_t &queue)
{
    this->gimbal_status.roll = queue.roll;
    this->gimbal_status.pitch = queue.pitch;
    this->gimbal_status.yaw = queue.yaw;
}