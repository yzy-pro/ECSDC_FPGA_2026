#ifndef BSP_EXTI_H
#define BSP_EXTI_H

#include "stm32f4xx_hal.h"

typedef void (*bsp_exti_callback_t)(void *context);

HAL_StatusTypeDef BSP_EXTI_RegisterCallback(uint16_t GPIO_Pin, bsp_exti_callback_t callback, void *context);
HAL_StatusTypeDef BSP_EXTI_UnregisterCallback(uint16_t GPIO_Pin);
void BSP_EXTI_DispatchCallback(uint16_t GPIO_Pin);

#endif
