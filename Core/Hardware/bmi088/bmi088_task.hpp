#ifndef BMI088_TASK_H
#define BMI088_TASK_H

#ifdef __cplusplus
extern "C"
{
#endif

    typedef struct
    {
        uint8_t *bufferptr;
    } Bmi088AccBufferPtr_t;

    typedef struct
    {
        uint8_t *bufferptr;
    } Bmi088GyroBufferPtr_t;

    typedef struct
    {
        uint8_t *bufferptr;
    } Bmi088TempBufferPtr_t;

    typedef struct
    {
        float roll;
        float pitch;
        float yaw;
    } Bmi088StatusQueue_t;

#ifdef __cplusplus
}
#endif

#endif /* OV7725_H */