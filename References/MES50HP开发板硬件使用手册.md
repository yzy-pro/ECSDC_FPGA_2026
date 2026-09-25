# 盘古50 开发板(MES50HP) 硬件使用手册V1.0
> 紫光同创 logos 系列FPGA 开发平台
> 版本日期:2024‑7‑19
> 制作方：深圳市小眼睛科技有限公司
> 联系邮箱: support@meyesemi.com
> QQ 群: 808770961
> 公司网址: www.meyesemi.com
> 微信公众号:小眼睛FPGA
> 购买渠道:小眼睛半导体
> 客服微信:17665247134

## 目录
1. [开发系统介绍](#1-开发系统介绍)
    - 1.1 [开发系统概述](#11-开发系统概述)
    - 1.2 [开发系统简介](#12-开发系统简介)
2. [核心板](#2-核心板)
    - 2.1 [核心板简介](#21-核心板简介)
    - 2.2 [核心板资源](#22-核心板资源)
    - 2.3 [电源](#23-电源)
    - 2.4 [尺寸结构图](#24-尺寸结构图)
3. [扩展底板](#3-扩展底板)
    - 3.1 [扩展底板简介](#31-扩展底板简介)
    - 3.2 [外接通信口](#32-外接通信口)
    - 3.3 [HDMI](#33-hdmi)
    - 3.4 [按键/指示灯/存储接口](#34-按键指示灯存储接口)
    - 3.5 [扩展口](#35-扩展口)
    - 3.6 [供电电源](#36-供电电源)
    - 3.7 [尺寸结构图](#37-尺寸结构图)

# 1、开发系统介绍
## 1.1 开发系统概述
盘古‑50 开发板(MES50HP)采用了**核心板+扩展板**的结构，核心板与扩展板之间使用高速板对板连接器进行连接。

- **核心板**：FPGA+2 颗DDR3+Flash+电源及复位，实现FPGA最小系统、高速数据处理存储。
- FPGA型号：紫光同创40nm工艺 Logos系列 **PGL50H‑6IFBG484**
- DDR3交互最高时钟：400MHz；2颗DDR3位宽32bit，总带宽最高25600Mbps。
- FPGA内置4路HSST高速收发器，每路速率最高6.375Gb/s，适合光纤通信、PCIe通信。
- 电源：多颗EZ8303电源芯片。

底板扩展外设：
- HDMI输入输出图像接口；
- SFP光纤、千兆以太网、PCIe高速通信；
- 40pin IO扩展连接器用于外接模块。

## 1.2 开发系统简介
### 1.2.1 开发系统外设资源
|外设|数量|
| ---- | ---- |
|HDMI输入接口|1|
|HDMI输出接口|1|
|SFP光纤接口|2|
|10/100/1000M以太网口|2|
|PCIe X2接口|1|
|JTAG调试口|1|
|Micro SD卡接口|1|
|PMOD接口|1|
|40pin IO扩展口|1|
|USB转串口(Type‑C)|1|
|用户按键|8|
|用户LED|8|

### 1.2.2 开发系统功能框图
**核心板组成**
- FPGA:PGL50H
- 2片512MB DDR3；128MB QSPI FLASH
- 板载50MHz、125MHz晶振，给系统、HSST收发器提供时钟。

**板上外设细节**
1. **双千兆以太网RJ45**：PHY芯片 RTL8211E，10/100/1000M自适应，全双工。
2. **PCIe X2**：PCI‑Express 2.0，单通道速率5GBaud。
3. **SFP光纤接口×2**：FPGA HSST驱动，每路最高6.375Gb/s。
4. **HDMI输出**：MS7210发送芯片；HDMI1.4b；最高4K@30Hz；采样率300MHz；支持HBR音频。
5. **HDMI输入**：MS7200接收芯片；HDMI1.4b；最高4K@30Hz；采样率300MHz；支持HBR音频。
6. **USB转串口**：CP2102芯片，Type‑C接口，调试通信。
7. **Micro SD卡座**：支持SDIO模式、SPI模式。
8. **EEPROM**：I2C接口 24C02。
9. **JTAG**：10针2.54mm排针，程序下载调试。
10. **PMOD座**：12脚2×6 PMOD接口。
11. **40针扩展口**：5V×1，3.3V×2，GND×3，IO×34。
12. LED×8；用户按键×8，复位按键×1。

# 2、核心板
## 2.1 核心板简介
MES50HP核心板基于紫光同创PGL50H‑6IFBG484，适合高速通信、数据处理采集。
- DDR3：2片MT41K256M16TW‑107:P，单片4Gbit；组合32bit总线；读写带宽25Gbps。
- IO资源：引出195个3.3V普通IO，113个IO电压可配置；12个1.5V IO；4对HSST差分收发+1路高速参考时钟。
- PCB做差分、等长布线；核心板尺寸：**50mm × 58mm**。

## 2.2 核心板资源
### 2.2.1 FPGA
芯片型号：`PGL50H‑6IFBG484` Logos系列，速度等级‑6，工业级温度。

|参数|数值|
| ---- | ---- |
|触发器FF|64200|
|LUT6|42800|
|DRM(18Kbit)|134|
|APM乘法器|84|
|PCIe Gen2|1|
|HSST高速收发器|4路，最大6.375Gb/s|
|速度等级|‑6|
|温度等级|工业级‑40~+100℃|

> Logos型号命名说明
> `PGL50 H‑6 I FBG484`
> - PGL：Logos系列；50：逻辑容量；H：带HSST高速收发器；6：速度等级；I工业温度；FBG484：484引脚封装。

### 2.2.2 时钟
核心板晶振：
1. **125MHz差分有源晶振**：HSST高速收发器参考时钟
    - HSST_CLK_P = A10
    - HSST_CLK_N = B10
2. **50MHz单端有源晶振**：系统全局时钟
    - FPGA_GCLK_50M = P20
3. **27MHz单端有源晶振**：辅助全局时钟
    - FPGA_GCLK_27M = K21

### 2.2.3 DDR3
- 芯片：MT41K256M16TW‑107:P，两片，总容量1GByte；位宽32bit。
- 挂载BANK3；最高时钟400MHz（数据速率800Mbps）；电平标准SSTL‑1.5V。
- PCB做阻抗控制、DDR等长；SGM2054芯片产生VTT(0.75V)、VREF(0.75V)。

> 信号列表文档完整记录：ddr3_addr、ba、cas_n、ck_p/n、cke、cs_n、odt、ras_n、reset_n、we_n；dm[0‑3]；dq[0‑31]；dqs_p/n[0‑3]。

### 2.2.4 FLASH
QSPI Nor Flash，型号W25Q128（128MBit），3.3V。

|信号|FPGA引脚|
| ---- | ---- |
|CS|AA3|
|DQ0|AB20|
|DQ1|AA20|
|DQ2|R13|
|DQ3|T14|
|SCK|Y20|

### 2.2.5 扩展接口
核心板背面4个80Pin板对板高速连接器 J2/J3/J4/J5。
- J2：BANK1 IO（3.3V）
- J3：BANK1+BANK2 IO +5V电源输入，BANK2默认3.3V
- J4：BANK2+BANK3 IO；Bank3为DDR3固定1.5V
- J5：BANK0 IO +4路HSST高速差分收发信号，JTAG信号。

## 2.3 电源
核心板输入：**5V@3A**，来自底板板对板连接器；电源芯片EZ8303。

|电源电压|用途|
| ---- | ---- |
|5.0V|输入电源|
|1.2V|FPGA内核VCC|
|3.3V|IO、晶振、Flash供电|
|VADJ|BANK0可调整IO电压|
|1.5V|DDR3、Bank3 IO电源|
|VTT(0.75V)|DDR3地址控制线终端电压|
|VREF(0.75V)|DDR3参考电压|
|HSST_1.2V|高速收发器PLL、通道电源|

## 2.4 尺寸结构图
核心板物理尺寸：**50.0mm × 58.0mm**

# 3、扩展底板
## 3.1 扩展底板简介
底板外设清单：HDMI IN/OUT、SFP×2、双千兆网口、PCIex2、JTAG、MicroSD、PMOD、40pin扩展口、USB‑UART、8按键、8LED。

## 3.2 外接通信口
### 3.2.1 千兆网口
PHY芯片 RTL8211E，RGMII接口连接FPGA。双网口独立引脚。
> 网口1、网口2包含RX_CLK RX_CTRL RXD[0‑3] TX_CLK TX_CTRL TXD[0‑3] MDC MDIO RSTN完整管脚映射。

### 3.2.2 SFP光纤接口×2
HSST差分信号直连光模块，速率最高6.375Gbps；125MHz差分晶振作为参考时钟。

|信号|FPGA引脚|
| ---- | ---- |
|SFP0_TXP|B14|
|SFP0_TXN|A14|
|SFP0_RXP|D13|
|SFP0_RXN|C13|
|SFP1_TXP|B16|
|SFP1_TXN|A16|
|SFP1_RXP|D15|
|SFP1_RXN|C15|

附加信号：LOS光丢失、SCL/SDA I2C读取光模块信息、TX_DIS光发射关闭。

### 3.2.3 PCIe X2接口
HSST通道0/1作为PCIe收发；参考时钟由PC插槽100MHz供给。

|信号|FPGA引脚|
| ---- | ---- |
|PCIE_TX0P|B6|
|PCIE_TX0N|A6|
|PCIE_RX0P|D7|
|PCIE_RX0N|C7|
|PCIE_TX1P|B8|
|PCIE_TX1N|A8|
|PCIE_RX1P|D9|
|PCIE_RX1N|C9|
|PCIE_refclk_P|A12|
|PCIE_refclk_N|B12|
|PCIE_PERST|A19|
|PCIE_WAKE|D19|

### 3.2.4 USB转串口
CP2102芯片 Type‑C接口。
|信号|FPGA引脚|
| ---- | ---- |
|UART0_TX|R9|
|UART0_RX|R8|

### 3.2.5 JTAG接口
10Pin 2.54mm排针；板上增加ESD保护二极管，防止热插拔损坏FPGA。

## 3.3 HDMI
### 3.3.1 HDMI输入 MS7200
I2C地址：`0x56`；输出24bit并行RGB/YUV像素；4K@30Hz；I2S音频输出。
信号包含PCLK、DE、HSYNC、VSYNC、D[23:0]，IIC_SCL/SDA，复位，I2S音频信号。

### 3.3.2 HDMI输出 MS7210
I2C地址：`0xB2`；接收FPGA输出24bit像素；4K@30Hz，内置EDID。
信号包含PCLK、DE、HSYNC、VSYNC、D[23:0]，IIC_SCL/SDA，复位，I2S音频。

## 3.4 按键/指示灯/存储接口
### 3.4.1 用户按键 K1‑K8
按键低电平有效，内部上拉，按下为低。
|按键|FPGA引脚|
| ---- | ---- |
|KEY1|K18|
|KEY2|L15|
|KEY3|J17|
|KEY4|K16|
|KEY5|J16|
|KEY6|J19|
|KEY7|H20|
|KEY8|H17|

REST：固件重加载复位按键。

### 3.4.2 用户LED
FPGA输出高电平点亮LED。
|LED|FPGA引脚|
| ---- | ---- |
|LED1|B2|
|LED2|A2|
|LED3|B3|
|LED4|A3|
|LED5|C5|
|LED6|A5|
|LED7|F7|
|LED8|F8|

额外指示灯：POWER电源灯、INIT、DONE FPGA状态灯。

### 3.4.3 EEPROM(24C02 2Kbit I2C)
|信号|FPGA引脚|
| ---- | ---- |
|IIC_SCL|F15|
|IIC_SDA|G8|

### 3.4.4 Micro SD卡
支持SPI模式、SDIO模式；3.3V电平。
CLK / CMD / DATA[0‑3] / Card Detect卡检测信号。

## 3.5 扩展口
### 3.5.1 40Pin扩展口
2.54mm间距；5V*1，3.3V*2，GND*3；IO 34路。
> ⚠️警告：FPGA IO为3.3V，**不可直连5V外设，必须增加电平转换芯片，否则烧毁FPGA**。

### 3.5.2 PMOD接口（12Pin 2×6）
BANK2 3.3V电平，外接PMOD模块。

## 3.6 供电电源
> ⚠️底板输入电源规格：**DC 12V**，务必使用配套电源适配器。
- SGM61163：12V转5V；5V通过板对板连接器给核心板供电。
- SGM61032：5V转3.3V，给底板外设供电。

## 3.7 尺寸结构图
文档含底板结构图纸，手册总页数38页。