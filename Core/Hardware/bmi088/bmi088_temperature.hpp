#ifndef BMI088_TEMPERATURE_HPP
#define BMI088_TEMPERATURE_HPP

#ifdef __cplusplus
extern "C"
{
#endif

#include "tim.h"
#include <stdint.h>

#include "bmi088_temperature_pid.hpp"

#define BMI088_TEMPERATURE_TIM htim10
#define BMI088_TEMPERATURE_TIM_CHANNEL TIM_CHANNEL_1

#define BMI088_TEMPERATURE_TIMER_TIM htim7 // 定时器

#define BMI088_SPI_DMA_TEMP_LENGHT 4

    typedef struct
    {
        TIM_HandleTypeDef *temperature_htim; // TIM 句柄
        uint32_t temperature_tim_channel;    // TIM 通道 (例如 TIM_CHANNEL_1)

        TIM_HandleTypeDef *timer_htim; //  TIM 句柄
    } Bmi088TemperatureCommunicationController_t;

    typedef struct
    {
        float current_temperature; // 当前温度值
        float target_temperature;  // 目标温度值
        uint32_t output_pulse;     // 控制器输出值
    } Bmi088TemperatureDataController_t;

    class Bmi088Temperature
    {
    public:
        Bmi088Temperature(Bmi088TemperatureCommunicationController_t communication_controller);
        ~Bmi088Temperature();

        void setup();
        void control();
        void callback();

        uint8_t *_get_temperature_rx_buffer();
        void _pid_calculate();

    private:
        Bmi088TemperatureCommunicationController_t communication_controller;
        Bmi088TemperatureDataController_t data_controller;

        Bmi088Temperature_PID temperature_pid;

        uint8_t temperature_rx_buffer[BMI088_SPI_DMA_TEMP_LENGHT]; // 温度数据接收缓冲区

        static void PeriodElapsedCallback(TIM_HandleTypeDef *htim);
    };

#ifdef __cplusplus
}
#endif

#endif