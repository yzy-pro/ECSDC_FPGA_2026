#include "pid.hpp"
#include <arm_math.h>

PID::PID()
{
    ;
}

void PID::_set_parameters(const PID_para_t &pid_para, const PID_limitation_t &pid_limitation)
{
    this->pid_para = pid_para;
    this->pid_limitation = pid_limitation;
}

void PID::_set_values(float current_value, float target_value)
{
    this->current_value = current_value;
    this->target_value = target_value;
}

void PID::_set_feedforward(float feedforward)
{
    this->pid_status.feedforward = feedforward;
}

float PID::_get_values()
{
    return this->output_value;
}

void PID::_reset()
{
    this->pid_status.integral = 0.0f;
    this->pid_status.derivative = 0.0f;
    this->pid_status.d_out = 0.0f;

    this->pid_status.last_error = 0.0f;
    this->pid_status.last_output = 0.0f;

    this->output_value = 0.0f;
}

void PID::_calculate_output()
{
    float error = this->target_value - this->current_value;

    // 死区处理
    if (fabs(error) < this->pid_limitation.deadband)
    {
        this->output_value = this->pid_status.last_output;
        return;
    }

    // 积分分离
    if (fabs(error) < this->pid_limitation.max_error)
    {
        this->pid_status.integral += error;
        // 积分限幅
        if (this->pid_status.integral > this->pid_para.max_integral)
        {
            this->pid_status.integral = this->pid_para.max_integral;
        }
        else if (this->pid_status.integral < this->pid_para.min_integral)
        {
            this->pid_status.integral = this->pid_para.min_integral;
        }
    }

    // 微分计算
    this->pid_status.derivative = error - this->pid_status.last_error;

    // PID输出计算
    float output = (this->pid_para.kp * error) + (this->pid_para.ki * this->pid_status.integral) + (this->pid_para.kd * this->pid_status.d_out) + (this->pid_status.feedforward);

    // 输出限幅
    if (output > this->pid_limitation.max_output)
    {
        output = this->pid_limitation.max_output;
    }
    else if (output < this->pid_limitation.min_output)
    {
        output = this->pid_limitation.min_output;
    }

    // 更新状态
    this->output_value = output;
    this->pid_status.last_error = error;
    this->pid_status.last_output = output;
}

void PID::_calculate_feedforward()
{
    this->pid_status.feedforward = 0.0f;
}

// void PID::_calculate_incremental_pid()
// {
//     float error = this->target_value - this->current_value;

//     // 死区处理
//     if (fabs(error) < this->pid_limitation.deadband)
//     {
//         this->output_value = this->pid_status.last_output;
//         return;
//     }

//     // 积分分离
//     if (fabs(error) < this->pid_limitation.max_error)
//     {
//         this->pid_status.integral += error;
//         // 积分限幅
//         if (this->pid_status.integral > this->pid_para.max_integral)
//         {
//             this->pid_status.integral = this->pid_para.max_integral;
//         }
//         else if (this->pid_status.integral < this->pid_para.min_integral)
//         {
//             this->pid_status.integral = this->pid_para.min_integral;
//         }
//     }

//     // 微分计算
//     this->pid_status.derivative = error - this->pid_status.last_error;

//     // 增量PID输出计算
//     float delta_output = (this->pid_para.kp * (error - this->pid_status.last_error)) + (this->pid_para.ki * error) + (this->pid_para.kd * (this->pid_status.derivative - this->pid_status.last_error)) + (this->pid_status.feedforward);

//     // 更新输出值
//     float output = this->output_value + delta_output;

//     // 输出限幅
//     if (output > this->pid_limitation.max_output)
//     {
//         output = this->pid_limitation.max_output;
//     }
//     else if (output < this->pid_limitation.min_output)
//     {
//         output = this->pid_limitation.min_output;
//     }

//     // 更新状态
//     this->output_value = output;
//     this->pid_status.last_error = error;
//     this->pid_status.last_output = output;
// }