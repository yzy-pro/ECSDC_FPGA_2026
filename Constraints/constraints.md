# MES50HP(盘古50) FPGA开发板硬件引脚约束手册
> 文档来源：MES50HP开发板硬件使用手册 V1.0
> FPGA型号：PGL50H‑6IFBG484 紫光同创 Logos，工业级
> 架构：核心板 + 扩展底板；IO默认3.3V；Bank3固定1.5V(DDR3)；Bank0支持VADJ可调IO电压

## 目录
- [1 全局时钟](#1‑全局时钟)
- [2 DDR3 引脚约束 Bank3(1.5V)](#2‑ddr3‑引脚约束‑bank315v)
- [3 QSPI FLASH 引脚约束](#3‑qspi‑flash‑引脚约束)
- [4 HDMI‑IN MS7200 接收芯片](#4‑hdmi‑in‑ms7200‑接收芯片)
- [5 HDMI‑OUT MS7210 发送芯片](#5‑hdmi‑out‑ms7210‑发送芯片)
- [6 双千兆以太网 RGMII](#6‑双千兆以太网‑rgmii)
- [7 SFP光纤 HSST高速收发器](#7‑sfp光纤‑hsst高速收发器)
- [8 PCIe X2 高速接口](#8‑pcie‑x2‑高速接口)
- [9 UART(CP2102 USB转串口)](#9‑uartcp2102‑usb转串口)
- [10 用户按键 KEY](#10‑用户按键‑key)
- [11 用户LED](#11‑用户led)
- [12 EEPROM 24C02(I2C)](#12‑eeprom‑24c02i2c)
- [13 Micro‑SD卡](#13‑micro‑sd卡)
- [14 JTAG调试接口](#14‑jtag调试接口)
- [15 40PIN扩展口](#15‑40pin扩展口)
- [16 PMOD扩展口](#16‑pmod扩展口)
- [17 Bank电源电平说明](#17‑bank电源电平说明)
- [附录：紫光同创XDC约束示例片段](#附录紫光同创xdc约束示例片段)

---

## 1 全局时钟
| 信号名称 | FPGA引脚 | 描述 |
|---|---|---|
| FPGA_GCLK_50M | P20 | 50MHz 单端晶振，系统主时钟 |
| FPGA_GCLK_27M | K21 | 27MHz 单端晶振 |
| HSST_CLK_P | A10 | HSST高速收发器差分参考时钟P，125MHz |
| HSST_CLK_N | B10 | HSST高速收发器差分参考时钟N，125MHz |

## 2 DDR3 引脚约束 Bank3(1.5V)
> DDR3芯片：MT41K256M16TW‑107，两片，32bit位宽；Bank3固定SSTL15电平。

| 信号 | FPGA引脚 | 信号 | FPGA引脚 |
|---|---|---|---|
| ddr3_addr[0] | N6 | ddr3_addr[14] | T3 |
| ddr3_addr[1] | R4 | ddr3_addr[15] | R7 |
| ddr3_addr[2] | P6 | ddr3_ba[0] | F5 |
| ddr3_addr[3] | F3 | ddr3_ba[1] | W4 |
| ddr3_addr[4] | V5 | ddr3_ba[2] | N7 |
| ddr3_addr[5] | E4 | ddr3_cas_n | H8 |
| ddr3_addr[6] | V3 | ddr3_ck_n | T5 |
| ddr3_addr[7] | D2 | ddr3_ck_p | T6 |
| ddr3_addr[8] | U4 | ddr3_cke | Y3 |
| ddr3_addr[9] | P5 | ddr3_cs_n | G6 |
| ddr3_addr[10] | P8 | ddr3_odt | G7 |
| ddr3_addr[11] | T4 | ddr3_ras_n | J7 |
| ddr3_addr[12] | P7 | ddr3_reset_n | C1 |
| ddr3_addr[13] | P4 | ddr3_we_n | H6 |
| ddr3_dm[0] | W3 | ddr3_dm[2] | K2 |
| ddr3_dm[1] | L1 | ddr3_dm[3] | G1 |
| ddr3_dq[0] | U1 | ddr3_dq[16] | K4 |
| ddr3_dq[1] | U3 | ddr3_dq[17] | K1 |
| ddr3_dq[2] | T2 | ddr3_dq[18] | J3 |
| ddr3_dq[3] | Y2 | ddr3_dq[19] | L4 |
| ddr3_dq[4] | T1 | ddr3_dq[20] | K3 |
| ddr3_dq[5] | Y1 | ddr3_dq[21] | M3 |
| ddr3_dq[6] | M7 | ddr3_dq[22] | J1 |
| ddr3_dq[7] | W1 | ddr3_dq[23] | M4 |
| ddr3_dq[8] | P1 | ddr3_dq[24] | J6 |
| ddr3_dq[9] | M2 | ddr3_dq[25] | F1 |
| ddr3_dq[10] | R1 | ddr3_dq[26] | K7 |
| ddr3_dq[11] | M1 | ddr3_dq[27] | F2 |
| ddr3_dq[12] | P2 | ddr3_dq[28] | H5 |
| ddr3_dq[13] | L3 | ddr3_dq[29] | H3 |
| ddr3_dq[14] | P3 | ddr3_dq[30] | J4 |
| ddr3_dq[15] | N4 | ddr3_dq[31] | G3 |
| ddr3_dqs_p[0] | V2 | ddr3_dqs_n[0] | V1 |
| ddr3_dqs_p[1] | N3 | ddr3_dqs_n[1] | N1 |
| ddr3_dqs_p[2] | M6 | ddr3_dqs_n[2] | L6 |
| ddr3_dqs_p[3] | E3 | ddr3_dqs_n[3] | E1 |

## 3 QSPI FLASH 引脚约束
> FLASH型号 W25Q128JVEIQ，3.3V电平

| 信号名称 | FPGA引脚 |
|---|---|
| spi_cs | AA3 |
| spi_dq0(DI) | AB20 |
| spi_dq1(DO) | AA20 |
| spi_dq2(WP) | R13 |
| spi_dq3(HOLD) | T14 |
| spi_sck | Y20 |

## 4 HDMI‑IN MS7200 接收芯片
> SA引脚拉GND；I2C从地址：`0x56`；IO电平3.3V；MS7200：HDMI输入转并行DVOUT输出给FPGA。

| 信号 | FPGA视角方向 | FPGA引脚 |
|---|---|---|
| HD_RX_PCLK | input | AA12 |
| HD_RX_VS | input | W13 |
| HD_RX_HS | input | V13 |
| HD_RX_DE | input | U13 |
| HD_RX_D[0] | input | U14 |
| HD_RX_D[1] | input | U15 |
| HD_RX_D[2] | input | T15 |
| HD_RX_D[3] | input | W15 |
| HD_RX_D[4] | input | Y16 |
| HD_RX_D[5] | input | AB16 |
| HD_RX_D[6] | input | AA16 |
| HD_RX_D[7] | input | AB17 |
| HD_RX_D[8] | input | Y17 |
| HD_RX_D[9] | input | V17 |
| HD_RX_D[10] | input | W18 |
| HD_RX_D[11] | input | AB19 |
| HD_RX_D[12] | input | AA18 |
| HD_RX_D[13] | input | AB18 |
| HD_RX_D[14] | input | Y18 |
| HD_RX_D[15] | input | W17 |
| HD_RX_D[16] | input | Y15 |
| HD_RX_D[17] | input | AB15 |
| HD_RX_D[18] | input | U16 |
| HD_RX_D[19] | input | V15 |
| HD_RX_D[20] | input | AA14 |
| HD_RX_D[21] | input | AB14 |
| HD_RX_D[22] | input | W14 |
| HD_RX_D[23] | input | Y14 |
| HD_SCL | output | V19 |
| HD_SDA | inout | V20 |
| HD_RX_SC_MC | input | T18 |
| HD_RX_MU_MC | input | W22 |
| HD_RX_I2S1 | input | R16 |
| HD_RX_I2S0 | input | R15 |
| HD_RX_WS_SP | input | T19 |
| HD_RX_RSTN | output | R17 |
| HD_RX_INT | input | T17 |

## 5 HDMI‑OUT MS7210 发送芯片
> SA上拉；I2C从地址 `0xB2`；IO电平3.3V；FPGA输出并行视频给到MS7210，输出HDMI。

| 信号 | FPGA视角方向 | FPGA引脚 |
|---|---|---|
| HD_TX_PCLK | output | M22 |
| HD_TX_VS | output | W20 |
| HD_TX_HS | output | Y21 |
| HD_TX_DE | output | Y22 |
| HD_TX_D[0] | output | V21 |
| HD_TX_D[1] | output | V22 |
| HD_TX_D[2] | output | T21 |
| HD_TX_D[3] | output | T22 |
| HD_TX_D[4] | output | R20 |
| HD_TX_D[5] | output | R22 |
| HD_TX_D[6] | output | R19 |
| HD_TX_D[7] | output | P19 |
| HD_TX_D[8] | output | M21 |
| HD_TX_D[9] | output | M17 |
| HD_TX_D[10] | output | M18 |
| HD_TX_D[11] | output | M16 |
| HD_TX_D[12] | output | N15 |
| HD_TX_D[13] | output | L19 |
| HD_TX_D[14] | output | K20 |
| HD_TX_D[15] | output | L17 |
| HD_TX_D[16] | output | K17 |
| HD_TX_D[17] | output | N19 |
| HD_TX_D[18] | output | J22 |
| HD_TX_D[19] | output | J20 |
| HD_TX_D[20] | output | K22 |
| HD_TX_D[21] | output | H21 |
| HD_TX_D[22] | output | H22 |
| HD_TX_D[23] | output | H19 |
| HDMI_TX_SCL | output | P17 |
| HDMI_TX_SDA | inout | P18 |
| HD_TX_SC_MC | output | W22 |
| HD_TX_I2S1 | output | P21 |
| HD_TX_I2S0 | output | U22 |
| HD_TX_WS | output | U19 |
| HD_TX_RSTN | output | R17 |
| HD_TX_INT | input | U20 |

## 6 双千兆以太网 RGMII
PHY芯片 RTL8211E，RGMII接口。

### 网口1
| 信号 | FPGA引脚 |
|---|---|
| RX_CLK | F14 |
| RX_CTRL | F9 |
| RXD[3] | H13 |
| RXD[2] | G13 |
| RXD[1] | H11 |
| RXD[0] | H10 |
| TX_CLK | G16 |
| TX_CTRL | B18 |
| TXD[3] | A18 |
| TXD[2] | C18 |
| TXD[1] | D17 |
| TXD[0] | F17 |
| MDC | A20 |
| MDIO | C19 |
| PHY_RSTN | B20 |

### 网口2
| 信号 | FPGA引脚 |
|---|---|
| RX_CLK | M19 |
| RX_CTRL | B21 |
| RXD[3] | F18 |
| RXD[2] | D22 |
| RXD[1] | D21 |
| RXD[0] | B22 |
| TX_CLK | C20 |
| TX_CTRL | F22 |
| TXD[3] | F21 |
| TXD[2] | E22 |
| TXD[1] | E20 |
| TXD[0] | C22 |
| MDC | G20 |
| MDIO | G22 |
| PHY_RSTN | F19 |

## 7 SFP光纤 HSST高速收发器
> HSST每路最大速率6.375Gbps；差分高速信号。

| 信号名称 | FPGA引脚 |
|---|---|
| SFP0_TXP | B14 |
| SFP0_TXN | A14 |
| SFP0_RXP | D13 |
| SFP0_RXN | C13 |
| SFP0_LOS | E16 |
| SFP0_SCL | G15 |
| SFP0_SDA | H14 |
| SFP0_TX_DIS | H12 |
| SFP1_TXP | B16 |
| SFP1_TXN | A16 |
| SFP1_RXP | D15 |
| SFP1_RXN | C15 |
| SFP1_LOS | D18 |
| SFP1_SCL | C17 |
| SFP1_SDA | A17 |
| SFP1_TX_DIS | F16 |

## 8 PCIe X2 高速接口
> PCIe Gen2 x2；单通道速率5G Baud。

| 信号名称 | FPGA引脚 |
|---|---|
| PCIE_TX0P | B6 |
| PCIE_TX0N | A6 |
| PCIE_TX1P | B8 |
| PCIE_TX1N | A8 |
| PCIE_RX0P | D7 |
| PCIE_RX0N | C7 |
| PCIE_RX1P | D9 |
| PCIE_RX1N | C9 |
| PCIE_refclk_P | A12 |
| PCIE_refclk_N | B12 |
| PCIE_PERST | A19 |
| PCIE_WAKE | D19 |

## 9 UART(CP2102 USB转串口)
| 信号 | FPGA引脚 |
|---|---|
| UART0_TX | R9 |
| UART0_RX | R8 |

## 10 用户按键 KEY
> 按键：按下为低电平；内部上拉。

| 信号 | FPGA引脚 |
|---|---|
| KEY1 | K18 |
| KEY2 | L15 |
| KEY3 | J17 |
| KEY4 | K16 |
| KEY5 | J16 |
| KEY6 | J19 |
| KEY7 | H20 |
| KEY8 | H17 |

## 11 用户LED
> FPGA输出高电平，LED点亮。

| 信号 | FPGA引脚 |
|---|---|
| LED1 | B2 |
| LED2 | A2 |
| LED3 | B3 |
| LED4 | A3 |
| LED5 | C5 |
| LED6 | A5 |
| LED7 | F7 |
| LED8 | F8 |

## 12 EEPROM 24C02(I2C)
| 信号 | FPGA引脚 |
|---|---|
| IIC_SCL | F15 |
| IIC_SDA | G8 |

## 13 Micro‑SD卡
| 信号 | FPGA引脚 |
|---|---|
| SD_CLK | C4 |
| SD_CMD | A4 |
| SD_DATA0 | D5 |
| SD_DATA1 | D4 |
| SD_DATA2 | E6 |
| SD_DATA3 | E5 |
| SD_DETECT | G9 |

## 14 JTAG调试接口
| 信号 | FPGA引脚 |
|---|---|
| TDI | E18 |
| TCK | A21 |
| TMS | D20 |
| TDO | G17 |

## 15 40PIN扩展口
> Bank2，默认3.3V电平；不要直接接5V外设，需要电平转换。

| 引脚编号 | 网络名 | FPGA引脚 | 引脚编号 | 网络名 | FPGA引脚 |
|---|---|---|---|---|---|
| 1 | GND | - | 2 | 5V0 | - |
| 3 | EX_IO_11N | AB13 | 4 | EX_IO_11P | Y13 |
| 5 | EX_IO_9N | AB11 | 6 | EX_IO_9P | Y11 |
| 7 | EX_IO_10N | W11 | 8 | EX_IO_10P | V11 |
| 9 | EX_IO_12N | AB10 | 10 | EX_IO_12P | AA10 |
| 11 | EX_IO_15N | Y10 | 12 | EX_IO_15P | W10 |
| 13 | EX_IO_16N | T11 | 14 | EX_IO_16P | R11 |
| 15 | EX_IO_7N | Y12 | 16 | EX_IO_7P | W12 |
| 17 | EX_IO_8N | U12 | 18 | EX_IO_8P | T12 |
| 19 | EX_IO_14N | U10 | 20 | EX_IO_14P | T10 |
| 21 | EX_IO_13N | AB9 | 22 | EX_IO_13P | Y9 |
| 23 | EX_IO_17N | V9 | 24 | EX_IO_17P | U9 |
| 25 | EX_IO_3N | AB4 | 26 | EX_IO_3P | AA4 |
| 27 | EX_IO_4N | AB5 | 28 | EX_IO_4P | Y5 |
| 29 | EX_IO_5N | Y6 | 30 | EX_IO_5P | W6 |
| 31 | EX_IO_6N | AB6 | 32 | EX_IO_6P | AA6 |
| 33 | EX_IO_2N | AB7 | 34 | EX_IO_2P | Y7 |
| 35 | GND | - | 36 | GND | - |
| 37 | GND | - | 38 | GND | - |
| 39 | A3V3 | - | 40 | A3V3 | - |

## 16 PMOD扩展口
> Bank2，3.3V电平。

| PMOD引脚 | 网络名 | FPGA引脚 | PMOD引脚 | 网络名 | FPGA引脚 |
|---|---|---|---|---|---|
| 1 | D1_N | AB6 | 2 | D1_P | AA6 |
| 3 | D2_N | AB7 | 4 | D2_P | Y7 |
| 5 | D3_N | Y8 | 6 | D3_P | W9 |
| 7 | D4_N | U6 | 8 | D4_P | T7 |
| 9 | GND | - | 10 | GND | - |
| 11 | A3V3 | - | 12 | A3V3 | - |

## 17 Bank电源电平说明
| Bank | 电压 | 用途 |
|---|---|---|
| BANK0 | VADJ可调(默认3.3V) | J5板对板连接器、JTAG、LED |
| BANK1 | 3.3V | J2板对板连接器 |
| BANK2 | 3.3V | J3板对板、40PIN、PMOD |
| BANK3 | **1.5V固定** | DDR3存储器，不可修改 |
| HSST_LANE | HSST_1.2V | 高速收发器供电 |
| 内核VCC | 1.2V | FPGA核心逻辑 |

> ⚠️重要提醒：Bank3电压硬件固定1.5V，用户不可修改；外部IO禁止直接接5V信号，需要电平转换芯片。

## 附录：紫光同创XDC约束示例片段
```xdc
# 系统时钟
create_clock -name clk_50m  -period 20.000 [get_ports P20]
create_clock -name clk_27m  -period 37.037 [get_ports K21]

# IO电平设置示例，Bank0默认3.3V
set_property IOSTANDARD LV33 [get_ports {LED* KEY*}]
set_property IOSTANDARD LV33 [get_ports {HD_RX_* HD_TX_*}]

# 输入上拉示例
set_property PULLUP TRUE [get_ports {KEY*}]