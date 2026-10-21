#ifndef BMI088_TEMPERATURE_PID_HPP
#define BMI088_TEMPERATURE_PID_HPP

#include "pid.hpp"

#ifdef __cplusplus
extern "C"
{
#endif

    class Bmi088Temperature_PID : public PID
    {
    public:
        Bmi088Temperature_PID();
        ~Bmi088Temperature_PID() = default;

        // void _calculate_output();
        // void _calculate_feedforward();

    private:
    };

#ifdef __cplusplus
}
#endif

#endif