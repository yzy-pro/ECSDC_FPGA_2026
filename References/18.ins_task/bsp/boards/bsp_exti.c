#include "bsp_exti.h"
#include "main.h"

#define BSP_EXTI_MAX_LINES 16U

typedef struct
{
    uint8_t used;
    uint16_t pin;
    bsp_exti_callback_t callback;
    void *context;
} bsp_exti_entry_t;

static bsp_exti_entry_t s_exti_table[BSP_EXTI_MAX_LINES];

static uint32_t BSP_EXTI_PinToIndex(uint16_t GPIO_Pin)
{
    for (uint32_t i = 0; i < BSP_EXTI_MAX_LINES; i++)
    {
        if (GPIO_Pin == (uint16_t)(1U << i))
        {
            return i;
        }
    }

    return BSP_EXTI_MAX_LINES;
}

HAL_StatusTypeDef BSP_EXTI_RegisterCallback(uint16_t GPIO_Pin, bsp_exti_callback_t callback, void *context)
{
    uint32_t index = BSP_EXTI_PinToIndex(GPIO_Pin);
    if (index >= BSP_EXTI_MAX_LINES || callback == NULL)
    {
        return HAL_ERROR;
    }

    s_exti_table[index].used = 1U;
    s_exti_table[index].pin = GPIO_Pin;
    s_exti_table[index].callback = callback;
    s_exti_table[index].context = context;
    return HAL_OK;
}

HAL_StatusTypeDef BSP_EXTI_UnregisterCallback(uint16_t GPIO_Pin)
{
    uint32_t index = BSP_EXTI_PinToIndex(GPIO_Pin);
    if (index >= BSP_EXTI_MAX_LINES)
    {
        return HAL_ERROR;
    }

    s_exti_table[index].used = 0U;
    s_exti_table[index].pin = 0U;
    s_exti_table[index].callback = NULL;
    s_exti_table[index].context = NULL;
    return HAL_OK;
}

void BSP_EXTI_DispatchCallback(uint16_t GPIO_Pin)
{
    uint32_t index = BSP_EXTI_PinToIndex(GPIO_Pin);
    if (index >= BSP_EXTI_MAX_LINES)
    {
        return;
    }

    if (s_exti_table[index].used && s_exti_table[index].callback != NULL)
    {
        s_exti_table[index].callback(s_exti_table[index].context);
    }
}
