# PGL50H HDMI 视频回环工程

## 1. 项目简介

本工程在紫光同创 PGL50H FPGA 上实现 HDMI 视频回环：MS7200 接收 HDMI 信号并输出并行 RGB888 视频，FPGA 完成芯片初始化、启动顺序控制和视频时序转发，再由 MS7210 将并行视频重新发送为 HDMI 信号。

工程当前的主要功能包括：

- 使用 I²C 自动初始化 MS7200 HDMI 接收芯片和 MS7210 HDMI 发送芯片；
- 按“MS7200 先初始化、MS7210 后初始化”的顺序启动两颗芯片；
- 将 MS7200 输出的 RGB888、PCLK、VSYNC、HSYNC 和 DE 转发给 MS7210；
- 对跨时钟域的配置握手、复位释放和视频使能信号进行同步处理；
- 使用 8 个 LED 显示 PLL、复位、芯片初始化和视频回环状态；
- 使用统一的共享引脚复位 MS7200 和 MS7210。

> 本工程只处理 FPGA 与 MS7200/MS7210 之间的并行视频和控制接口，不在 FPGA 内部完成 HDMI TMDS 编解码。

## 2. 硬件与工具

| 项目 | 配置 |
| --- | --- |
| FPGA 系列 | Logos |
| FPGA 器件 | PGL50H |
| 封装 | FBG484 |
| 速度等级 | -6 |
| HDMI 输入芯片 | MS7200 |
| HDMI 输出芯片 | MS7210 |
| 开发工具 | PDS 2025.2 |
| 当前工具路径 | `E:\work\pango\PDS_2025.2-ads\bin` |
| 工程文件 | `hdmi.pds` |
| 顶层模块 | `hdmi_loop_top` |

## 3. 系统结构

```text
                     +---------------- PGL50H FPGA ----------------+
                     |                                               |
HDMI 输入             |  +---------+      +----------------------+  |       HDMI 输出
   |                  |  | MS7200  |      |   hdmi_loop_top      |  |          |
   v                  |  | 配置驱动 |<---->| 启动控制 / 状态指示 |  |          v
+--------+  RGB888    |  +---------+      +----------------------+  |  RGB888 +--------+
| MS7200 |----------->|------------------>| 视频寄存与直接转发   |--|--------->| MS7210 |
| 接收器 | PCLK/同步  |                   +----------------------+  |  PCLK    | 发送器 |
+--------+            |  +---------+               ^                |          +--------+
                      |  | MS7210  |<--------------+                |
                      |  | 配置驱动 |                                |
                      |  +---------+                                |
                      +---------------------------------------------+
```

系统控制状态机依次完成以下操作：

1. 等待 PLL 锁定并同步释放控制域复位；
2. 释放并初始化 MS7200；
3. 等待 MS7200 初始化完成；
4. 初始化 MS7210；
5. 等待 MS7210 初始化完成；
6. 在 HDMI 输入像素时钟域同步视频使能信号，开始输出视频。

## 4. 目录结构

```text
hdmi/
├─ Designs/
│  ├─ hdmi_loop_top.v                  # 工程顶层、启动顺序和视频回环
│  ├─ drivers/iic/
│  │  └─ iic_master.v                  # 通用 I²C 主机
│  └─ hardware/
│     ├─ led/
│     │  └─ led.v                      # LED 输出寄存器驱动
│     ├─ ms7200/
│     │  ├─ ms7200_driver.v            # MS7200 寄存器配置状态机
│     │  └─ ms7200_top.v               # MS7200 复位、配置和 I²C 封装
│     └─ ms7210/
│        ├─ ms7210_driver.v            # MS7210 寄存器配置状态机
│        └─ ms7210_top.v               # MS7210 复位、配置和 I²C 封装
├─ ipcore/
│  └─ pll_50mhz/
│     ├─ pll_50mhz.v                   # PLL 生成文件
│     └─ pll_50mhz.idf                 # PDS PLL IP 描述文件
├─ Constraints/
│  ├─ constraints.md                   # 开发板硬件引脚参考文档
│  ├─ hdmi/
│  │  ├─ hdmi_in.fdc                   # HDMI 输入并行视频约束
│  │  ├─ hdmi_out.fdc                  # HDMI 输出并行视频约束
│  │  ├─ ms7200.fdc                    # MS7200 I²C 约束
│  │  └─ ms7210.fdc                    # MS7210 I²C 约束
│  ├─ led/led.fdc                      # LED 约束
│  ├─ system/system.fdc                # 系统时钟、复位和共享复位引脚
│  ├─ system/system_clk.fdc            # 时钟约束
│  └─ key/key.fdc                      # 保留的按键约束，当前顶层未使用
├─ Simulation/
│  └─ uart_loop_test_top_tb.v          # 历史 UART 测试文件，与当前 HDMI 顶层无关
├─ hdmi.pds                            # PDS 工程文件
├─ impl.tcl                            # PDS 自动生成的实现脚本
└─ README.md                           # 本文档
```

## 5. 顶层接口

顶层文件为 `Designs/hdmi_loop_top.v`。

### 5.1 参数

| 参数 | 默认值 | 说明 |
| --- | ---: | --- |
| `SYS_CLK_FREQ_HZ` | 50,000,000 | 系统控制时钟频率 |
| `IIC_CLK_FREQ_HZ` | 1,600,000 | I²C 主机四相节拍时钟频率 |
| `IIC_SCL_FREQ_HZ` | 400,000 | I²C SCL 目标频率 |

`iic_master` 每四个 `iic_clk` 周期产生一个完整的 SCL 周期，因此默认配置为 1.6 MHz 节拍时钟和 400 kHz SCL。

### 5.2 端口分组

| 端口 | 方向 | 说明 |
| --- | --- | --- |
| `sys_clk_50mhz` | 输入 | 板载 50 MHz 系统时钟 |
| `sys_rstn` | 输入 | 低有效外部系统复位 |
| `sys_ms72xx_rstn` | 输出 | MS7200 与 MS7210 共用的低有效硬件复位 |
| `sys_ms7200_iic_scl` | 输出 | MS7200 I²C 时钟 |
| `sys_ms7200_iic_sda` | 双向 | MS7200 I²C 数据 |
| `sys_ms7210_iic_scl` | 输出 | MS7210 I²C 时钟 |
| `sys_ms7210_iic_sda` | 双向 | MS7210 I²C 数据 |
| `sys_hdmi_in_pixclk` | 输入 | MS7200 输出的像素时钟 |
| `sys_hdmi_in_vsync` | 输入 | 输入场同步 |
| `sys_hdmi_in_hsync` | 输入 | 输入行同步 |
| `sys_hdmi_in_de` | 输入 | 输入数据有效 |
| `sys_hdmi_in_r/g/b[7:0]` | 输入 | 输入 RGB888 视频数据 |
| `sys_hdmi_out_pixclk` | 输出 | 送往 MS7210 的像素时钟 |
| `sys_hdmi_out_vsync` | 输出 | 输出场同步 |
| `sys_hdmi_out_hsync` | 输出 | 输出行同步 |
| `sys_hdmi_out_de` | 输出 | 输出数据有效 |
| `sys_hdmi_out_r/g/b[7:0]` | 输出 | 输出 RGB888 视频数据 |
| `sys_led[7:0]` | 输出 | 系统状态 LED |

## 6. 时钟与复位

### 6.1 时钟架构

`pll_50mhz` 以板载 50 MHz 时钟为输入，产生两个时钟：

- `clkout0`：50 MHz，供顶层启动状态机、MS7200/MS7210 配置状态机和 LED 模块使用；
- `clkout1`：1.6 MHz，作为两路 I²C 主机的四相节拍时钟。

HDMI 视频数据工作在 `sys_hdmi_in_pixclk` 时钟域。输出像素时钟通过连续赋值直接转发输入像素时钟，避免使用普通组合逻辑门控高速时钟；RGB、VSYNC、HSYNC 和 DE 在输入像素时钟域统一寄存一级后输出。

### 6.2 复位架构

- `sys_rstn` 为低有效外部异步复位；
- PLL 未锁定时，控制逻辑保持复位；
- PLL 锁定后，复位通过两级寄存器在 50 MHz 控制时钟域同步释放；
- I²C 主机的复位释放分别同步到 1.6 MHz I²C 时钟域；
- MS7200 与 MS7210 在电路板上共用 `sys_ms72xx_rstn` 硬件复位引脚；
- 当前共享复位信号由 `ms7200_top` 的复位时序产生，MS7210 顶层内部生成的复位输出不再连接到 FPGA 管脚。

当前 `sys_rstn` 约束在 AB13。根据 `Constraints/constraints.md`，AB13 对应扩展接口 `EX_IO_11N`，并不是文档定义的板载专用复位按键，因此它是本工程自定义的外部低有效复位输入。实际使用时应确保该引脚有确定的默认电平和正确的外部连接。

## 7. 芯片初始化与 I²C 跨时钟域

### 7.1 顶层启动状态机

顶层采用标准三段式状态机，状态定义如下：

| 状态 | 功能 |
| --- | --- |
| `ST_WAIT_PLL` | 等待控制域复位释放 |
| `ST_CONFIG_RX` | 使能 MS7200 复位与初始化模块 |
| `ST_CONFIG_TX` | 保持 MS7200 工作并使能 MS7210 初始化模块 |
| `ST_RUN` | 两颗芯片均初始化完成，允许视频输出 |

MS7200 初始化完成信号为 `sys_ms7200_done`，MS7210 初始化完成信号为 `sys_ms7210_done`。两个信号同时有效且顶层进入 `ST_RUN` 后，才会请求开启视频输出。

### 7.2 MS7200 和 MS7210 封装

`ms7200_top` 与 `ms7210_top` 均包含以下功能：

1. 保持芯片硬件复位；
2. 释放硬件复位并等待器件稳定；
3. 启动寄存器配置状态机；
4. 通过通用 `iic_master` 执行读写；
5. 配置完成后保持 `done` 为高电平。

MS7210 驱动还包含默认 320 ms 的启动等待参数 `STARTUP_WAIT_MS`。如更换芯片版本、晶振或板级电源时序，应结合数据手册重新确认复位和启动等待时间。

### 7.3 I²C 地址

| 芯片 | 7 位设备地址 | 8 位写地址字节 |
| --- | --- | --- |
| MS7200 | `7'h2B` | `8'h56` |
| MS7210 | `7'h59` | `8'hB2` |

驱动模块使用 16 位寄存器地址和 8 位寄存器数据。寄存器初始化表分别保存在 `ms7200_driver.v` 和 `ms7210_driver.v` 中。

### 7.4 跨时钟域处理

芯片配置状态机运行在 50 MHz `sys_clk` 域，I²C 主机运行在 1.6 MHz `iic_clk` 域。跨时钟域接口采用保持型事务请求和忙/完成握手：

- 配置状态机在事务期间保持地址、方向和写数据稳定；
- `iic_start` 保持有效，直到同步返回的 `iic_busy` 表明 I²C 主机已接收请求；
- `iic_busy`、`iic_done` 和读数据用于确认事务状态和推进配置状态机；
- I²C 主机复位使用异步置复位、目标时钟域同步释放的方式。

修改接口时不要把单周期脉冲未经同步直接跨越 50 MHz 与 1.6 MHz 时钟域，否则可能造成事务丢失或重复执行。

## 8. 视频回环行为

配置完成前：

- 输出 RGB 数据为 `0`；
- 输出 VSYNC、HSYNC 和 DE 为 `0`；
- 输出像素时钟仍直接跟随输入像素时钟。

配置完成后：

- 视频使能请求通过两级寄存器同步到输入像素时钟域；
- RGB888、VSYNC、HSYNC 和 DE 在 `sys_hdmi_in_pixclk` 上升沿寄存后输出；
- 数据和同步信号具有一级像素时钟延迟；
- 输出像素时钟直接转发输入像素时钟，不经过寄存或逻辑门控。

该数据通路不进行缩放、帧缓存、色彩空间转换或分辨率转换，因此 HDMI 输出时序跟随 MS7200 解码得到的输入时序。

## 9. LED 状态定义

顶层只生成 `led_cmd`，具体 LED 寄存驱动统一由 `Designs/hardware/led/led.v` 完成，便于后续修改极性、闪烁或复用逻辑。

当前 LED 为高电平点亮：

| LED | FPGA 引脚 | 含义 |
| --- | --- | --- |
| LED0 | B2 | PLL 已锁定且 50 MHz 控制域复位已释放 |
| LED1 | A2 | MS7200/MS7210 共享硬件复位已释放 |
| LED2 | B3 | 保留，固定熄灭 |
| LED3 | A3 | 保留，固定熄灭 |
| LED4 | C5 | 两颗芯片初始化完成，视频回环已请求启用 |
| LED5 | A5 | 保留，固定熄灭 |
| LED6 | F7 | MS7210 初始化完成 |
| LED7 | F8 | MS7200 初始化完成 |

正常启动时，LED7 应先点亮，随后 LED6 和 LED4 点亮。如果 LED7 或 LED6 长时间不亮，应优先检查相应芯片的供电、复位、I²C 上拉、电气连接和设备地址。

## 10. 主要引脚约束

所有当前接口使用 3.3 V LVCMOS33。完整电气属性以 `Constraints/` 目录中的 FDC 文件为准。

### 10.1 系统与 I²C

| 信号 | FPGA 引脚 | 说明 |
| --- | --- | --- |
| `sys_clk_50mhz` | P20 | 50 MHz 系统时钟 |
| `sys_rstn` | AB13 | 工程自定义低有效复位输入 |
| `sys_ms72xx_rstn` | R17 | MS7200/MS7210 共享硬件复位 |
| `sys_ms7200_iic_scl` | V19 | MS7200 I²C SCL |
| `sys_ms7200_iic_sda` | V20 | MS7200 I²C SDA |
| `sys_ms7210_iic_scl` | P17 | MS7210 I²C SCL |
| `sys_ms7210_iic_sda` | P18 | MS7210 I²C SDA |

I²C SDA 使用开漏方式，板级必须具有合适的上拉电阻。SCL 当前由 FPGA 推挽输出。

### 10.2 HDMI 输入并行接口

下表中的总线引脚均按 `[7]` 到 `[0]` 的顺序列出。

| 信号 | FPGA 引脚 |
| --- | --- |
| `sys_hdmi_in_pixclk` | AA12 |
| `sys_hdmi_in_vsync` | W13 |
| `sys_hdmi_in_hsync` | V13 |
| `sys_hdmi_in_de` | U13 |
| `sys_hdmi_in_b[7:0]` | AB17, AA16, AB16, Y16, W15, T15, U15, U14 |
| `sys_hdmi_in_g[7:0]` | W17, Y18, AB18, AA18, AB19, W18, V17, Y17 |
| `sys_hdmi_in_r[7:0]` | Y14, W14, AB14, AA14, V15, U16, AB15, Y15 |

### 10.3 HDMI 输出并行接口

下表中的总线引脚均按 `[7]` 到 `[0]` 的顺序列出。

| 信号 | FPGA 引脚 |
| --- | --- |
| `sys_hdmi_out_pixclk` | M22 |
| `sys_hdmi_out_vsync` | W20 |
| `sys_hdmi_out_hsync` | Y21 |
| `sys_hdmi_out_de` | Y22 |
| `sys_hdmi_out_b[7:0]` | P19, R19, R22, R20, T22, T21, V22, V21 |
| `sys_hdmi_out_g[7:0]` | L17, K20, L19, N15, M16, M18, M17, M21 |
| `sys_hdmi_out_r[7:0]` | H19, H22, H21, K22, J20, J22, N19, K17 |

## 11. 构建工程

### 11.1 使用 PDS 图形界面

1. 启动 `E:\work\pango\PDS_2025.2-ads\bin\pds.exe`；
2. 打开工程根目录下的 `hdmi.pds`；
3. 确认目标器件为 PGL50H、FBG484、速度等级 -6；
4. 确认顶层模块为 `hdmi_loop_top`；
5. 依次运行 Compile、Synthesize、Device Map、Place、Route、Timing Report 和 Generate Bitstream；
6. 检查综合、布局布线和时序报告后再下载到开发板。

### 11.2 使用命令行

PDS 命令行工具支持工程文件或 Tcl 脚本，例如在工程根目录执行：

```powershell
& 'E:\work\pango\PDS_2025.2-ads\bin\pds_shell.exe' -project '.\hdmi.pds'
```

也可以运行当前自动生成的实现脚本：

```powershell
& 'E:\work\pango\PDS_2025.2-ads\bin\pds_shell.exe' -file '.\impl.tcl'
```

`impl.tcl` 是 PDS 根据操作历史自动生成的脚本，包含本机绝对路径，并可能保留重复的任务调用。将工程复制到其他目录或计算机后，应重新从 PDS 导出脚本或修改其中的路径，不建议把它当作完全可移植的构建入口。

## 12. 当前验证情况

截至 2026 年 9 月 27 日，当前 RTL 和约束已在 PDS 2025.2 下完成以下检查：

- 顶层 RTL 编译和层次展开成功；
- 加载 HDMI、I²C、LED、系统和时钟约束后综合成功；
- 工具识别 71 个顶层 I/O；
- 未发现无效封装引脚、重复引脚占用或约束端口不存在错误；
- 综合资源摘要约为 569 个 LUT、356 个寄存器；
- 50 MHz 系统控制时钟的最小 setup slack 约为 14.87 ns；
- 1.6 MHz I²C 节拍时钟约束已被工具识别。

PDS 对少量封装引脚可能给出 `share pin` 提示，该信息表示器件封装管脚具有复用属性，不等同于引脚冲突错误。仍应结合最终布局布线报告和开发板原理图逐项确认。

## 13. 注意事项与已知限制

- `Constraints/key/key.fdc` 为保留文件，当前 `hdmi_loop_top` 没有 `sys_key` 端口，活动约束集中不应启用该文件；
- `Simulation/uart_loop_test_top_tb.v` 是历史 UART 工程测试文件，不能作为当前 HDMI 回环功能的仿真结果；
- 当前工程尚未提供面向 MS7200、MS7210 和 I²C 从设备行为的完整仿真模型，芯片初始化仍需通过 I²C 逻辑分析和板级测试确认；
- 当前时钟 FDC 主要约束 50 MHz 系统时钟及 PLL 生成时钟，HDMI 输入像素时钟及输入/输出接口时序需要根据实际视频格式、板级走线和芯片数据手册进一步完善；
- `iic_error` 目前在 I²C 主机内部产生，但没有连接到顶层 LED 或调试接口，初始化异常时建议增加错误状态锁存和超时机制；
- 输出像素时钟为输入像素时钟直接转发。若后续目标频率较高，应评估专用时钟资源、输出时钟路径和源同步时序约束；
- 修改 MS7200/MS7210 寄存器表时，应保持事务地址、方向和数据在 I²C 事务完成前稳定；
- 更换开发板、FPGA 封装或硬件版本后，必须重新对照原理图和 `Constraints/constraints.md` 检查全部 FDC 引脚。

## 14. 上板调试建议

建议按以下顺序定位问题：

1. 确认 50 MHz 输入时钟和外部 `sys_rstn` 电平正确；
2. 观察 LED0 和 LED1，确认 PLL 锁定并释放共享硬件复位；
3. 用示波器或逻辑分析仪检查两路 I²C 的 SCL、SDA、ACK 和总线频率；
4. 观察 LED7，确认 MS7200 初始化完成；
5. 观察 LED6，确认 MS7210 初始化完成；
6. 观察 LED4，确认顶层已进入视频回环状态；
7. 检查 MS7200 输出端是否存在稳定的 PCLK、DE、VSYNC、HSYNC 和 RGB 数据；
8. 检查 FPGA 到 MS7210 的并行视频时序和引脚映射；
9. 最后检查 HDMI 输入源、显示器兼容性以及 MS7210 输出端的电气连接。
