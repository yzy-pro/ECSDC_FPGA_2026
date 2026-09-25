#ifndef JETSON_USB_H
#define JETSON_USB_H

#include <stdint.h>
#include "usart.h"

#include "bmi088_task.hpp"

#define JETSON_HUART huart6
#define JETSON_HUART2 huart1
#define JETSON_TX_FRAME_SIZE 10

typedef struct
{
    float yaw;
    float pitch;
    float roll;
} GimbalStatus_t;

// int a11 = sizeof(WflyEt08a_data_t);

class Jetson
{
public:
    Jetson(UART_HandleTypeDef *huart);
    ~Jetson() = default;

    void setup();
    void control();
    void callback();

    void parse_bmi088_status_queue(const Bmi088StatusQueue_t &queue);

private:
    UART_HandleTypeDef *huart;

    GimbalStatus_t gimbal_status;
    uint8_t _tx_data[JETSON_TX_FRAME_SIZE];
    void _pack_tx_data();
};

#ifdef __cplusplus
extern "C"
{
#endif

#ifdef __cplusplus
}
#endif

#endif /* JETSON_ORIN_H */
