#ifndef BMI088_HPP
#define BMI088_HPP

#ifdef __cplusplus
extern "C"
{
#endif

#include "gpio.h"
#include "spi.h"

#include "bmi088_temperature.hpp"
#include "bmi088_task.hpp"

#include <stdint.h>

#define BMI088_HSPI hspi1

#define BMI088_ACC_INT_GPIO_Port GPIOC
#define BMI088_ACC_INT_Pin GPIO_PIN_4
#define BMI088_ACC_CS_GPIO_Port GPIOA
#define BMI088_ACC_CS_Pin GPIO_PIN_4

#define BMI088_GYRO_INT_GPIO_Port GPIOC
#define BMI088_GYRO_INT_Pin GPIO_PIN_5
#define BMI088_GYRO_CS_GPIO_Port GPIOB
#define BMI088_GYRO_CS_Pin GPIO_PIN_0

#define BMI088_ACC_INT_EXTI_IRQn EXTI4_IRQn
#define BMI088_GYRO_INT_EXTI_IRQn EXTI9_5_IRQn

#define BMI088_SPI_DMA_GYRO_LENGHT 7
#define BMI088_SPI_DMA_ACC_LENGHT 8

    typedef enum
    {
        BMI088_ERROR_NONE = 0,
        BMI088_ACC_CHIP_ID_ERR = 0x01,
        BMI088_ACC_DATA_ERR = 0x02,
        BMI088_GYRO_CHIP_ID_ERR = 0x04,
        BMI088_GYRO_DATA_ERR = 0x08,
    } Bmi088Status_t;

    typedef struct
    {
        SPI_HandleTypeDef *hspi;         // SPI 句柄
        GPIO_TypeDef *gpio_port_acc_cs;  // 片选端口 (例如 GPIOA)
        uint16_t gpio_pin_acc_cs;        // 片选引脚 (例如 GPIO_PIN_4)
        GPIO_TypeDef *gpio_port_gyro_cs; // 片选端口 (例如 GPIOB)
        uint16_t gpio_pin_gyro_cs;       // 片选引脚 (例如 GPIO_PIN_5)

    } Bmi088CommunicationController_t;

    typedef enum
    {
        BMI088_REG_ACC = 0,
        BMI088_REG_GYRO = 1
    } Bmi088RegType_t;

    typedef struct
    {
        float acceleration_x;
        float acceleration_y;
        float acceleration_z;
    } Bmi088AccData_t;

    typedef struct
    {
        float gyroscope_roll;  // 绕x轴
        float gyroscope_pitch; // 绕y轴
        float gyroscope_yaw;   // 绕z轴
    } Bmi088GyroData_t;

    typedef struct
    {
        float roll;
        float pitch;
        float yaw;
    } Bmi088EulerAngle_t;

    class Bmi088
    {
    public:
        Bmi088(Bmi088CommunicationController_t communication_controller, Bmi088TemperatureCommunicationController_t temperature_communication_controller);
        ~Bmi088();

        Bmi088Status_t setup();
        void control();
        void temp_control();
        void callback();

        static void SPI_TxRxCpltCallback(SPI_HandleTypeDef *hspi);

        static void ACC_GPIO_EXTI_Callback(uint16_t GPIO_Pin);
        static void GYRO_GPIO_EXTI_Callback(uint16_t GPIO_Pin);

        uint8_t *_get_acc_rx_buffer();
        uint8_t *_get_gyro_rx_buffer();
        uint8_t *_get_temperature_rx_buffer();

        void pack_bmi088_status_queue(Bmi088StatusQueue_t &status_queue);

    private:
        Bmi088CommunicationController_t communication_controller;

        Bmi088AccData_t acc_data;
        Bmi088GyroData_t gyro_data;
        Bmi088GyroData_t gyro_bias;

        Bmi088Temperature bmi088_temperature;
        float sensor_time;

        // 驱动函数
        void _write_reg(Bmi088RegType_t reg, uint8_t addr, uint8_t data);
        void _read_reg(Bmi088RegType_t reg, uint8_t addr, uint8_t *data);
        void _read_regs(Bmi088RegType_t reg, uint8_t addr, uint8_t *data, uint16_t len);

        // 校验函数
        Bmi088Status_t _acc_checkid();
        Bmi088Status_t _gyro_checkid();

        float quaternions[4];
        Bmi088EulerAngle_t euler_angles;

        uint8_t acc_rx_buffer[BMI088_SPI_DMA_ACC_LENGHT]{};
        uint8_t gyro_rx_buffer[BMI088_SPI_DMA_GYRO_LENGHT]{};
    };

#ifdef __cplusplus
}
#endif

#endif /* OV7725_H */
