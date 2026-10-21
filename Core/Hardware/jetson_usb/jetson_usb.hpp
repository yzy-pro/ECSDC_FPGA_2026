#ifndef JETSON_USB_HPP
#define JETSON_USB_HPP

#include <stdint.h>
#include "bmi088_task.hpp"

#define JETSON_USB_TX_FRAME_SIZE 10

typedef struct
{
    float yaw;
    float pitch;
    float roll;
} JetsonUsbGimbalStatus_t;

class JetsonUsb
{
public:
    JetsonUsb();
    ~JetsonUsb() = default;

    void setup();
    void control();
    void callback();

    void parse_bmi088_status_queue(const Bmi088StatusQueue_t &queue);

private:
    JetsonUsbGimbalStatus_t gimbal_status;
    uint8_t _tx_data[JETSON_USB_TX_FRAME_SIZE];
    void _pack_tx_data();
};

#ifdef __cplusplus
extern "C"
{
#endif

#ifdef __cplusplus
}
#endif

#endif /* JETSON_USB_HPP */
