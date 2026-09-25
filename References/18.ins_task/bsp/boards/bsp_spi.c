#include "bsp_spi.h"
#include "main.h"
#include "spi.h"

extern SPI_HandleTypeDef hspi1;

void SPI1_DMA_init(uint32_t tx_buf, uint32_t rx_buf, uint16_t num)
{
    HAL_SPI_DMAStop(&hspi1);
    __HAL_SPI_ENABLE(&hspi1);
    (void)tx_buf;
    (void)rx_buf;
    (void)num;
}

void SPI1_DMA_enable(uint32_t tx_buf, uint32_t rx_buf, uint16_t ndtr)
{
    if (HAL_SPI_TransmitReceive_DMA(&hspi1, (uint8_t *)tx_buf, (uint8_t *)rx_buf, ndtr) != HAL_OK)
    {
        Error_Handler();
    }
}
