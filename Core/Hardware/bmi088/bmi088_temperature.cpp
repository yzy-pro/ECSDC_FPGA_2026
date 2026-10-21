#include "bmi088_temperature.hpp"
#include "bmi088_reg.h"

Bmi088Temperature::Bmi088Temperature(Bmi088TemperatureCommunicationController_t communication_controller)
    : communication_controller(communication_controller)
{
    this->data_controller.current_temperature = 36.0f;
    this->data_controller.target_temperature = 36.0f;
    this->data_controller.output_pulse = 0;

    // 初始化 PID 控制器
    PID_para_t pid_para = {
        .kp = 1200.0f,
        .ki = 5.0f,
        .min_integral = -0.0f,
        .max_integral = 4400.0f,
        .kd = 0.0f,
    };
    PID_limitation_t pid_limitation = {
        .min_output = 0.0f,
        .max_output = 4900.0f,
        .max_error = 0.0f,
        .deadband = 0.0f,
    };
    this->temperature_pid._set_parameters(pid_para, pid_limitation);
}

Bmi088Temperature::~Bmi088Temperature()
{
    ; // Destructor implementation (if needed)
}

void Bmi088Temperature::setup()
{
    __HAL_TIM_SET_COMPARE(this->communication_controller.temperature_htim, this->communication_controller.temperature_tim_channel, this->data_controller.output_pulse);
    HAL_TIM_PWM_Start(this->communication_controller.temperature_htim, this->communication_controller.temperature_tim_channel);

    HAL_TIM_RegisterCallback(this->communication_controller.timer_htim, HAL_TIM_PERIOD_ELAPSED_CB_ID, this->PeriodElapsedCallback);
    HAL_TIM_Base_Start_IT(this->communication_controller.timer_htim);
}

void Bmi088Temperature::control()
{
    int16_t temp_int11;

    temp_int11 = (static_cast<int16_t>(this->temperature_rx_buffer[2]) << 3) | (static_cast<int16_t>(this->temperature_rx_buffer[3]) >> 5);
    if (temp_int11 > 1023)
    {
        temp_int11 -= 2048;
    }

    this->data_controller.current_temperature = temp_int11 * TEMP_UNIT + TEMP_BIAS;
}

void Bmi088Temperature::callback()
{

    __HAL_TIM_SetCompare(this->communication_controller.temperature_htim, this->communication_controller.temperature_tim_channel, this->data_controller.output_pulse);
}

uint8_t *Bmi088Temperature::_get_temperature_rx_buffer()
{
    return this->temperature_rx_buffer;
}

void Bmi088Temperature::_pid_calculate()
{
    this->temperature_pid._set_values(this->data_controller.current_temperature, this->data_controller.target_temperature);

    this->temperature_pid._calculate_output();

    this->data_controller.output_pulse = static_cast<uint32_t>(this->temperature_pid._get_values());
}