#ifndef PID_H
#define PID_H

#ifdef __cplusplus
extern "C"
{
#endif

    typedef struct
    {
        float kp;           // 比例增益 P
        float ki;           // 积分增益 I
        float min_integral; // 积分项下限
        float max_integral; // 积分项上限
        float kd;           // 微分增益 D（当前实现中通过 d_out 间接体现）
    } PID_para_t;           // PID可调参数结构体

    typedef struct
    {
        float min_output; // 输出下限
        float max_output; // 输出上限

        float max_error; // 积分分离阈值：|error| 超过该值时不积分
        float deadband;  // 误差死区：|error| 小于该值时保持上次输出
    } PID_limitation_t;  // PID限制参数结构体

    typedef struct
    {
        float feedforward; // 前馈增益 FF

        float integral;   // 当前积分累计值（梯形积分）
        float derivative; // 当前误差微分（error - last_error）
        float d_out;      // 滤波后的微分输出项

        float last_error;  // 上一周期误差
        float last_output; // 上一周期控制器输出（死区回退/状态保持）
    } PID_status_t;        // PID状态结构体

    class PID
    {
    public:
        PID();
        virtual ~PID() = default;

        void _set_parameters(const PID_para_t &pid_para, const PID_limitation_t &pid_limitation);

        void _set_values(float current_value, float target_value);
        void _set_feedforward(float feedforward);
        float _get_values();
        void _reset();

        virtual void _calculate_output();
        virtual void _calculate_feedforward();

    protected:
        PID_para_t pid_para;             // PID可调参数
        PID_limitation_t pid_limitation; // PID限制参数
        PID_status_t pid_status;         // PID状态参数
        float current_value;             // 当前值
        float target_value;              // 目标值
        float output_value;              // PID输出值
    };

#ifdef __cplusplus
}
#endif

#endif