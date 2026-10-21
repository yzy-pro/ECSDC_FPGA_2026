#ifndef JETSON_USB_CDC_H
#define JETSON_USB_CDC_H

#ifdef __cplusplus
extern "C"
{
#endif
#include <stdint.h>

    int8_t jetson_CDC_Init_FS(void);
    int8_t jetson_CDC_DeInit_FS(void);
    int8_t jetson_CDC_Control_FS(uint8_t cmd, uint8_t *pbuf, uint16_t length);
    int8_t jetson_CDC_Receive_FS(uint8_t *pbuf, uint32_t *Len);
    uint8_t jetson_CDC_Transmit_FS(uint8_t *Buf, uint16_t Len);
    int8_t jetson_CDC_TransmitCplt_FS(uint8_t *pbuf, uint32_t *Len, uint8_t epnum);

#ifdef __cplusplus
}
#endif

#endif /* JETSON_ORIN_H */