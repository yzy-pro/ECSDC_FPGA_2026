#include "jetson.hpp"
#include "jetson_task2.hpp"
#include "FreeRTOS.h"
#include "task.h"
#include "cmsis_os2.h"
#include <arm_math.h>
#include "main.h"

extern osMessageQueueId_t Bmi088Status2QueueHandle;
// jetson通信task，直接单开线程即可
Jetson *debug_jetson2{};
extern "C" void AppJetsonTask2(void *argument)
{
    UNUSED(argument);
    uint32_t period_ticks = pdMS_TO_TICKS(1000 / 50); // 50Hz
    uint32_t next_wake = osKernelGetTickCount();

    static Jetson jetson(&JETSON_HUART2);
    debug_jetson2 = &jetson; // 方便调试用
    jetson.setup();

    for (;;)
    {
        {
            Bmi088StatusQueue_t bmi088_status_queue{};
            if (osMessageQueueGet(Bmi088Status2QueueHandle, &bmi088_status_queue, 0, 0) == osOK)
            {
                jetson.parse_bmi088_status_queue(bmi088_status_queue);
            }
        }
        jetson.control();

        next_wake += period_ticks;
        (void)osDelayUntil(next_wake);
    }
}
