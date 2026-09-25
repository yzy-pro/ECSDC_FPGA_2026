#include "cmsis_os.h"
#include "MahonyAHRS.h"
#include <arm_math.h>

#include "bmi088.hpp"
#include "bmi088_task.hpp"
#include "bmi088_reg.h"
#include "bmi088_temperature.hpp"

float debug_yaw_angle = 0.0f;

// void AHRS_init(fp32 quat[4], fp32 accel[3], fp32 mag[3]);
// void AHRS_update(fp32 quat[4], fp32 time, fp32 gyro[3], fp32 accel[3], fp32 mag[3]);
// void get_angle(fp32 quat[4], fp32 *yaw, fp32 *pitch, fp32 *roll);

// fp32 INS_quat[4] = {0.0f, 0.0f, 0.0f, 0.0f};
// fp32 INS_angle[3] = {0.0f, 0.0f, 0.0f}; // euler angle, unit rad.欧拉角 单位 rad
extern osMessageQueueId_t Bmi088AccGpioExtiQueueHandle;
extern osMessageQueueId_t Bmi088GyroGpioExtiQueueHandle;
extern osMessageQueueId_t Bmi088TempPeriodElapsedHandle;

extern osSemaphoreId_t Bmi088SpiSemHandle;
extern osSemaphoreId_t Bmi088GyroBufferSemHandle;
extern osSemaphoreId_t Bmi088AccBufferSemHandle;
extern osSemaphoreId_t Bmi088TempBufferSemHandle;

extern osMessageQueueId_t Bmi088StatusQueueHandle;
extern osMessageQueueId_t Bmi088Status2QueueHandle;

Bmi088 *debug_bmi088{};

extern "C" void AppBmi088Task(void *argument)
{
    UNUSED(argument);
    const uint32_t tick_delay = 1u;
    uint32_t next_wake_tick = osKernelGetTickCount();

    static Bmi088 bmi088(
        Bmi088CommunicationController_t{
            .hspi = &BMI088_HSPI,
            .gpio_port_acc_cs = BMI088_ACC_CS_GPIO_Port,
            .gpio_pin_acc_cs = BMI088_ACC_CS_Pin,
            .gpio_port_gyro_cs = BMI088_GYRO_CS_GPIO_Port,
            .gpio_pin_gyro_cs = BMI088_GYRO_CS_Pin},
        Bmi088TemperatureCommunicationController_t{
            .temperature_htim = &BMI088_TEMPERATURE_TIM,
            .temperature_tim_channel = BMI088_TEMPERATURE_TIM_CHANNEL,
            .timer_htim = &BMI088_TEMPERATURE_TIMER_TIM});
    debug_bmi088 = &bmi088;

    osSemaphoreAcquire(Bmi088SpiSemHandle, 0);
    {
        Bmi088AccBufferPtr_t acc_gpio_exti_queue{};
        acc_gpio_exti_queue.bufferptr = bmi088._get_acc_rx_buffer();
        osMessageQueuePut(Bmi088AccGpioExtiQueueHandle, &acc_gpio_exti_queue, 0, 0);
    }
    {
        Bmi088GyroBufferPtr_t gyro_gpio_exti_queue{};
        gyro_gpio_exti_queue.bufferptr = bmi088._get_gyro_rx_buffer();
        osMessageQueuePut(Bmi088GyroGpioExtiQueueHandle, &gyro_gpio_exti_queue, 0, 0);
    }
    {
        Bmi088TempBufferPtr_t temp_period_elapsed_queue{};
        temp_period_elapsed_queue.bufferptr = bmi088._get_temperature_rx_buffer();
        osMessageQueuePut(Bmi088TempPeriodElapsedHandle, &temp_period_elapsed_queue, 0, 0);
    }

    bmi088.setup();
    osDelay(1000); // 等待 BMI088 上电稳定。

    osSemaphoreRelease(Bmi088SpiSemHandle);
    for (;;)
    {
        bmi088.control();
        bmi088.temp_control();
        bmi088.callback();

        {
            Bmi088StatusQueue_t status_queue{};
            bmi088.pack_bmi088_status_queue(status_queue);
            osMessageQueuePut(Bmi088StatusQueueHandle, &status_queue, 0, 0);
            osMessageQueuePut(Bmi088Status2QueueHandle, &status_queue, 0, 0);
        }
        next_wake_tick += tick_delay;
        osDelayUntil(next_wake_tick);
    };
}

extern "C" void HAL_GPIO_EXTI_Callback(uint16_t GPIO_Pin)
{
    if (GPIO_Pin == BMI088_ACC_INT_Pin)
    {
        ::Bmi088::ACC_GPIO_EXTI_Callback(GPIO_Pin);
    }
    else if (GPIO_Pin == BMI088_GYRO_INT_Pin)
    {
        ::Bmi088::GYRO_GPIO_EXTI_Callback(GPIO_Pin);
    }
}

void Bmi088::ACC_GPIO_EXTI_Callback(uint16_t GPIO_Pin)
{
    static uint8_t tx_buffer[BMI088_SPI_DMA_ACC_LENGHT] = {(BMI088_SPI_READ_CODE | ACC_X_LSB_ADDR), 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};
    static uint8_t *rx_buffer;

    if (rx_buffer == nullptr)
    {
        Bmi088AccBufferPtr_t acc_gpio_exti_queue{};
        if (osMessageQueueGet(Bmi088AccGpioExtiQueueHandle, &acc_gpio_exti_queue, 0, 0) == osOK)
        {
            rx_buffer = acc_gpio_exti_queue.bufferptr;
            osMessageQueueDelete(Bmi088AccGpioExtiQueueHandle);
        }
    }

    if (GPIO_Pin == BMI088_ACC_INT_Pin)
    {
        if (osSemaphoreAcquire(Bmi088SpiSemHandle, 0) == osOK)
        {
            if (osSemaphoreAcquire(Bmi088AccBufferSemHandle, 0) == osOK)
            {
                HAL_GPIO_WritePin(BMI088_ACC_CS_GPIO_Port, BMI088_ACC_CS_Pin, GPIO_PIN_RESET);
                if (HAL_SPI_TransmitReceive_DMA(&BMI088_HSPI, tx_buffer, rx_buffer, BMI088_SPI_DMA_ACC_LENGHT) != HAL_OK)
                {
                    Error_Handler();
                }
            }
            else
            {
                osSemaphoreRelease(Bmi088SpiSemHandle);
            }
        }
        else
        {
            return;
        }
    }
}

void Bmi088::GYRO_GPIO_EXTI_Callback(uint16_t GPIO_Pin)
{
    static uint8_t tx_buffer[BMI088_SPI_DMA_GYRO_LENGHT] = {(BMI088_SPI_READ_CODE | GYRO_RATE_X_LSB_ADDR), 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};
    static uint8_t *rx_buffer{};

    if (rx_buffer == nullptr)
    {
        Bmi088GyroBufferPtr_t gyro_gpio_exti_queue{};
        if (osMessageQueueGet(Bmi088GyroGpioExtiQueueHandle, &gyro_gpio_exti_queue, 0, 0) == osOK)
        {
            rx_buffer = gyro_gpio_exti_queue.bufferptr;
            osMessageQueueDelete(Bmi088GyroGpioExtiQueueHandle);
        }
    }

    if (GPIO_Pin == BMI088_GYRO_INT_Pin)
    {
        if (osSemaphoreAcquire(Bmi088SpiSemHandle, 0) == osOK)
        {
            if (osSemaphoreAcquire(Bmi088GyroBufferSemHandle, 0) == osOK)
            {
                HAL_GPIO_WritePin(BMI088_GYRO_CS_GPIO_Port, BMI088_GYRO_CS_Pin, GPIO_PIN_RESET);

                if (HAL_SPI_TransmitReceive_DMA(&BMI088_HSPI, tx_buffer, rx_buffer, BMI088_SPI_DMA_GYRO_LENGHT) != HAL_OK)
                {
                    Error_Handler();
                }
            }
            else
            {
                osSemaphoreRelease(Bmi088SpiSemHandle);
            }
        }
        else
        {
            return;
        }
    }
}

void Bmi088Temperature::PeriodElapsedCallback(TIM_HandleTypeDef *htim)
{
    static uint8_t tx_buffer[BMI088_SPI_DMA_TEMP_LENGHT] = {(BMI088_SPI_READ_CODE | TEMP_MSB_ADDR), 0xFF, 0xFF, 0xFF};
    static uint8_t *rx_buffer{};

    if (rx_buffer == nullptr)
    {
        Bmi088TempBufferPtr_t temp_period_elapsed_queue{};
        if (osMessageQueueGet(Bmi088TempPeriodElapsedHandle, &temp_period_elapsed_queue, 0, 0) == osOK)
        {
            rx_buffer = temp_period_elapsed_queue.bufferptr;
            osMessageQueueDelete(Bmi088TempPeriodElapsedHandle);
        }
    }

    if (htim->Instance == BMI088_TEMPERATURE_TIMER_TIM.Instance)
    {
        if (osSemaphoreAcquire(Bmi088SpiSemHandle, 0) == osOK)
        {
            if (osSemaphoreAcquire(Bmi088TempBufferSemHandle, 0) == osOK)
            {
                HAL_GPIO_WritePin(BMI088_ACC_CS_GPIO_Port, BMI088_ACC_CS_Pin, GPIO_PIN_RESET);

                if (HAL_SPI_TransmitReceive_DMA(&BMI088_HSPI, tx_buffer, rx_buffer, BMI088_SPI_DMA_TEMP_LENGHT) != HAL_OK)
                {
                    Error_Handler();
                }
            }
            else
            {
                osSemaphoreRelease(Bmi088SpiSemHandle);
            }
        }
    }
}

void Bmi088::SPI_TxRxCpltCallback(SPI_HandleTypeDef *hspi)
{
    if (hspi->Instance == BMI088_HSPI.Instance)
    {
        {
            osSemaphoreRelease(Bmi088SpiSemHandle);

            if (osSemaphoreAcquire(Bmi088GyroBufferSemHandle, 0) != osOK)
            {
                HAL_GPIO_WritePin(BMI088_GYRO_CS_GPIO_Port, BMI088_GYRO_CS_Pin, GPIO_PIN_SET);
                osSemaphoreRelease(Bmi088GyroBufferSemHandle);
            }
            else
            {
                osSemaphoreRelease(Bmi088GyroBufferSemHandle);
            }

            if (osSemaphoreAcquire(Bmi088AccBufferSemHandle, 0) != osOK)
            {
                HAL_GPIO_WritePin(BMI088_ACC_CS_GPIO_Port, BMI088_ACC_CS_Pin, GPIO_PIN_SET);
                osSemaphoreRelease(Bmi088AccBufferSemHandle);
            }
            else
            {
                osSemaphoreRelease(Bmi088AccBufferSemHandle);
            }

            if (osSemaphoreAcquire(Bmi088TempBufferSemHandle, 0) != osOK)
            {
                HAL_GPIO_WritePin(BMI088_ACC_CS_GPIO_Port, BMI088_ACC_CS_Pin, GPIO_PIN_SET);
                osSemaphoreRelease(Bmi088TempBufferSemHandle);
            }
            else
            {
                osSemaphoreRelease(Bmi088TempBufferSemHandle);
            }
        }
    }
}

// void AHRS_update(fp32 quat[4], fp32 time, fp32 gyro[3], fp32 accel[3], fp32 mag[3])
// {

// }

// void get_angle(fp32 q[4], fp32 *yaw, fp32 *pitch, fp32 *roll)
// {

// }