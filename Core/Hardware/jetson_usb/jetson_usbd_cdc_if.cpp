#include "jetson_usbd_cdc_if.hpp"
#include "cmsis_os2.h"
#include "usbd_cdc_if.h"

extern USBD_HandleTypeDef hUsbDeviceFS;

// int8_t jetson_CDC_Init_FS(void)
// {
//     /* USER CODE BEGIN 3 */
//     /* Set Application Buffers */
//     USBD_CDC_SetTxBuffer(&hUsbDeviceFS, UserTxBufferFS, 0);
//     USBD_CDC_SetRxBuffer(&hUsbDeviceFS, UserRxBufferFS);
//     return (USBD_OK);
//     /* USER CODE END 3 */
// }

int8_t jetson_CDC_DeInit_FS(void)
{
    /* USER CODE BEGIN 4 */
    return (USBD_OK);
    /* USER CODE END 4 */
}

int8_t jetson_CDC_Control_FS(uint8_t cmd, uint8_t *pbuf, uint16_t length)
{
    /* USER CODE BEGIN 5 */
    switch (cmd)
    {
    case CDC_SEND_ENCAPSULATED_COMMAND:

        break;

    case CDC_GET_ENCAPSULATED_RESPONSE:

        break;

    case CDC_SET_COMM_FEATURE:

        break;

    case CDC_GET_COMM_FEATURE:

        break;

    case CDC_CLEAR_COMM_FEATURE:

        break;

        /*******************************************************************************/
        /* Line Coding Structure                                                       */
        /*-----------------------------------------------------------------------------*/
        /* Offset | Field       | Size | Value  | Description                          */
        /* 0      | dwDTERate   |   4  | Number |Data terminal rate, in bits per second*/
        /* 4      | bCharFormat |   1  | Number | Stop bits                            */
        /*                                        0 - 1 Stop bit                       */
        /*                                        1 - 1.5 Stop bits                    */
        /*                                        2 - 2 Stop bits                      */
        /* 5      | bParityType |  1   | Number | Parity                               */
        /*                                        0 - None                             */
        /*                                        1 - Odd                              */
        /*                                        2 - Even                             */
        /*                                        3 - Mark                             */
        /*                                        4 - Space                            */
        /* 6      | bDataBits  |   1   | Number Data bits (5, 6, 7, 8 or 16).          */
        /*******************************************************************************/
    case CDC_SET_LINE_CODING:

        break;

    case CDC_GET_LINE_CODING:

        break;

    case CDC_SET_CONTROL_LINE_STATE:

        break;

    case CDC_SEND_BREAK:

        break;

    default:
        break;
    }

    return (USBD_OK);
    /* USER CODE END 5 */
}

int8_t jetson_CDC_Receive_FS(uint8_t *Buf, uint32_t *Len)
{
    // uint32_t rx_len = (Len == NULL) ? 0U : *Len;
    // if (Buf != NULL && rx_len > 0U)
    // {
    //     jetson_orin_usb_receive_bytes(Buf, rx_len);
    // }

    // if (Buf != NULL)
    // {
    //     USBD_CDC_SetRxBuffer(&hUsbDeviceFS, Buf);
    //     (void)USBD_CDC_ReceivePacket(&hUsbDeviceFS);
    // }

    return (USBD_OK);
}

uint8_t jetson_CDC_Transmit_FS(uint8_t *Buf, uint16_t Len)
{
    if (Buf == NULL || Len == 0U)
    {
        return USBD_FAIL;
    }

    USBD_CDC_HandleTypeDef *hcdc = (USBD_CDC_HandleTypeDef *)hUsbDeviceFS.pClassData;
    if (hcdc == NULL)
    {
        return USBD_FAIL;
    }
    if (hcdc->TxState != 0U)
    {
        return USBD_BUSY;
    }

    USBD_CDC_SetTxBuffer(&hUsbDeviceFS, Buf, Len);
    return USBD_CDC_TransmitPacket(&hUsbDeviceFS);
}

int8_t jetson_CDC_TransmitCplt_FS(uint8_t *Buf, uint32_t *Len, uint8_t epnum)
{
    uint8_t result = USBD_OK;
    /* USER CODE BEGIN 13 */
    UNUSED(Buf);
    UNUSED(Len);
    UNUSED(epnum);
    /* USER CODE END 13 */
    return result;
}
