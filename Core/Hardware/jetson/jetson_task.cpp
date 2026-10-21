#include "jetson.hpp"
#include "jetson_task.hpp"
#include "FreeRTOS.h"
#include "task.h"
#include "cmsis_os2.h"
#include <arm_math.h>
#include "main.h"

extern osMessageQueueId_t Bmi088StatusQueueHandle;
// jetson通信task，直接单开线程即可
Jetson *debug_jetson{};
extern "C" void AppJetsonTask(void *argument)
{
    UNUSED(argument);
    uint32_t period_ticks = pdMS_TO_TICKS(1000 / 50); // 50Hz
    uint32_t next_wake = osKernelGetTickCount();

    static Jetson jetson(&JETSON_HUART);
    debug_jetson = &jetson; // 方便调试用
    jetson.setup();

    for (;;)
    {
        {
            Bmi088StatusQueue_t bmi088_status_queue{};
            if (osMessageQueueGet(Bmi088StatusQueueHandle, &bmi088_status_queue, 0, 0) == osOK)
            {
                jetson.parse_bmi088_status_queue(bmi088_status_queue);
            }
        }
        jetson.control();

        next_wake += period_ticks;
        (void)osDelayUntil(next_wake);
    }
}
