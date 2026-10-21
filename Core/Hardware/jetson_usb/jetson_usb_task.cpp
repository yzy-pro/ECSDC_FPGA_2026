#include "jetson_usb.hpp"
#include "jetson_usb_task.hpp"
#include "FreeRTOS.h"
#include "task.h"
#include "cmsis_os2.h"
#include <arm_math.h>
#include "main.h"

extern osMessageQueueId_t Bmi088Status2QueueHandle;

// 使用原 JetsonTask2 的姿态队列和通信协议，通过 USB CDC 发送。
JetsonUsb *debug_jetson_usb{};
extern "C" void AppJetsonUsbTask(void *argument)
{
    UNUSED(argument);
    uint32_t period_ticks = pdMS_TO_TICKS(1000 / 50); // 50Hz
    uint32_t next_wake = osKernelGetTickCount();

    static JetsonUsb jetson_usb{};
    debug_jetson_usb = &jetson_usb; // 方便调试用
    jetson_usb.setup();

    for (;;)
    {
        Bmi088StatusQueue_t bmi088_status_queue{};
        if (osMessageQueueGet(Bmi088Status2QueueHandle, &bmi088_status_queue, 0, 0) == osOK)
        {
            jetson_usb.parse_bmi088_status_queue(bmi088_status_queue);
        }
        jetson_usb.control();

        next_wake += period_ticks;
        (void)osDelayUntil(next_wake);
    }
}
