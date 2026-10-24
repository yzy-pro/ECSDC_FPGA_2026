# CP2102 控制与自适应 Gamma 遥测验证

实现日期：2026-10-21；统计支路流水线于 2026-10-22 更新。目标工程：`EmbFPGA.pds`，PGL50H-FBG484-6。

**2026-10-22 最终更新：已生成包含新功能的 `bitstream/EmbFPGA_1920_pc_control_20261022.sbit`，最终双角时序、FIFO CDC 和当前源码身份审计均通过。** 最新 128×32 / 分布式 RAM 写通路版本通过 17 组专项测试、主 RTL 回归及完整 1080p 并发测试，达到 30.000030 fps、最慢渲染 33.14614 ms。以下保留早期功能测试及失败构建过程，最终交付以 [新位流实现记录](20261022_pc_control_sbit.md) 和 `bitstream/pc_control_20261022_identity.json` 为准。尚未实板烧录。

## 1. 功能与硬件依据

使用板载 CP2102 的 R8（FPGA RX）、R9（FPGA TX），115200 bit/s、8-N-1、无流控。依据为 `reference/MES50HP开发板硬件使用手册_1V1.pdf` 第 3.2.4 节、表 3-5；LED 为第 3.4.2 节、表 3-9，高电平点亮。

三位控制掩码按 bit0 / bit1 / bit2 对应镜头去畸变、IMU yaw/pitch 姿态矫正、输入端自动 Gamma，默认 `0x07`。LED1～3 指示系统时钟域已确认的输入帧配置。命令应答、输入帧应用、最终显示采用新配置是三个不同阶段。镜头与姿态都关闭时执行精确同坐标采样；仍保留 RGB565 存储和渲染链路。

Gamma 遥测保存同一完成帧的原始和实际 Gamma 输出亮度和、像素数、原始暗部/高光数、曲线和功能掩码；通过握手快照跨域，约 10 Hz 上报。详细字段和 PC 开发接口见 [`report/pc_control_protocol.md`](../report/pc_control_protocol.md)。

## 2. RTL 与 PC 协议测试

工具：ModelSim 10.6e，`D:/pango/modeltech64_10.6e/win64`；Python 使用项目已有虚拟环境。

```powershell
$py = '.\reference\imu_cboard\.venv\Scripts\python.exe'
& $py tests/test_pc_video_protocol.py
& $py tests/verify_main_contract.py
& $py tests/run_pc_control.py
& $py tests/run_rtl_regressions.py --modelsim 'D:\pango\modeltech64_10.6e\win64'
```

| 检查 | 本次结果 |
|---|---|
| PC 编解码单元测试 | 3 项通过；固定线上字节、分包/粘包/校验恢复、Gamma 字段和关闭时输出 |
| 工程清单与引脚检查 | 通过；主工程、控制源码、IP、默认参数与 CP2102 引脚均有检查 |
| UART 命令与遥测 | 加速参数和实际 50 MHz / 115200 参数均通过；八种掩码、BUSY、SOF、错误包、超时、查询与遥测 |
| 注册 SOF 与开关一致性 | 自动 Gamma 及无 Gamma 两种链路各 25 帧通过；覆盖八种掩码、SOF 首像素、待应用命令、逐像素 Gamma 参考、几何和遥测帧身份 |
| Gamma 算法与整帧统计 | 通过；全部 LUT、场景适应、迟滞、帧级使能、亮度和；1080p 有效像素数 2,073,600，最大亮度和 528,768,000 |
| Gamma 遥测与跨域 | 灰度与彩色两组通过；独立 RGB 数学参考、原始/输出亮度同帧、曲线/使能/掩码、224 bit 快照一致性 |
| 几何开关 | 四种几何组合与兼容配置通过；覆盖块边界、DDR 回压、姿态快照、最终写完成与关闭几何后的末行/末列 |
| 并发全功能切换 | 320×180、32 个输入帧通过；覆盖全部八种掩码和 11 种姿态，共检查 1,670,400 个显示像素 |
| 既有主 RTL 回归 | 通过；IMU、CDC、投影、FIFO、仲裁、串行/分块帧缓存、捕获吞吐、像素/帧边界和历史故障注入 |

`run_pc_control.py` 本次共 15 组仿真，日志在 `build_rebuilt/pc_control/00_*.log`～`14_*.log`。主回归日志在 `build_rebuilt/rtl_a8c7e33009024a6fae2ff6a9c269c7bc/`。320×180 仿真的发布率不能当作 1080p 吞吐。

## 3. 1080p 检查

已完成仅姿态模式的独立 1920×1080 渲染器检查（`RUNTIME=1, CONTROL_MODE=2`），五种姿态逐像素通过：

| yaw / pitch（Q2048） | 100 MHz 渲染拍数 | 时间 |
|---|---:|---:|
| 0 / 0 | 2,686,405 | 26.86405 ms |
| +536 / +536 | 2,545,885 | 25.45885 ms |
| +536 / -536 | 2,546,038 | 25.46038 ms |
| -536 / +536 | 2,543,012 | 25.43012 ms |
| -536 / -536 | 2,543,012 | 25.43012 ms |

日志：`build_rebuilt/pc_control/full1080p_pose_only.log`。这是独立 DDR 模型下的渲染器结果，不能单独证明完整视频链路达到 30 fps。

完整 1080p 并发切换测试已通过，使用本次源码，未借用历史构建的性能结论。包含 Gamma 与 RGB565、并发捕获/渲染/显示、32 拍 DDR 命令延迟、25% 数据停顿、单一共享读写数据通道，以及每 780 拍暂停 35 拍的刷新模型。

| 指标 | 本次仿真结果 |
|---|---:|
| 输入帧 / 不同结果发布数 | 28 / 13 |
| 稳态不同结果发布率 | 30.000030 fps |
| 最大结果发布间隔 | 3,333,330 个 100 MHz 时钟，即 33.33330 ms |
| 最慢单帧渲染 | 3,224,331 个 100 MHz 时钟，即 32.24331 ms |
| 捕获 FIFO 峰值 | 8 / 512 个 256 bit 数据字 |
| 显示像素比较次数（包含重复显示） | 51,840,000 |
| 姿态 / 开关覆盖 | 11 种姿态、全部 8 种掩码 |
| 仿真错误 | 0 |

日志及测试源码哈希见 `build_rebuilt/pc_control_full1080p_runtime/result.log` 和 `source_identity.json`。该系统测试直接驱动帧级开关，不含物理 UART 和厂商 DDR PHY；UART 及配置 SOF 对齐由第 2 节的专门测试覆盖。它证明所列行为模型下的 RTL 吞吐，不能替代实物 DDR 性能与图像测量。复现入口：

```powershell
& $py tests/run_pose_tiled_integration.py --full --frames 28 --preprocess --runtime --shared-payload --refresh-cycles 35 --output build_rebuilt/pc_control_full1080p_runtime
```

## 4. FPGA 构建与时序

早期试构建 `build_rebuilt/pds_pc_control_20261021/` 暴露了外部 VS 直接进入控制寄存器的零周期输入 setup 违例，已终止该构建。修复使用现有输入 I/O 寄存器后的 SOF，并让 Gamma 在同一 SOF 采样即将提交的掩码；未放宽 HDMI 输入时序约束。该早期目录不作为可用位流证据。

注册 SOF 版本 `build_rebuilt/pds_pc_control_registered_20261021/` 已完成综合，LUT 17,996 / 42,800、寄存器 27,144 / 64,200、APM 45 / 84、DRM18K 等效 121 / 134，无锁存器；但布线收敛缓慢，未完成最终时序审计，已终止该试构建。该目录不是可用位流证据。

2026-10-22 在统计支路增加一级亮度寄存，将 Gamma ROM/RGB 加权与 32 bit 累加器分开；同一完成帧的元数据相应延迟，协议与视频路径延迟不变。15 组专项测试已针对该改动全部重跑通过。当前构建目录为 `build_rebuilt/pds_pc_control_pipelined_20261022/`，其中 `input_snapshot/`、`source_identity.json` 与构建日志保存真实输入。

当前版本综合资源：LUT 17,991 / 42,800（42.04%）、寄存器 27,293 / 64,200（42.51%）、APM 45 / 84、DRM18K 等效 121 / 134（90.30%），无锁存器。输入时钟域综合 setup 已无违例。标准布线构建长时间未能收敛，终止时仍有 1,444 个未布通连接，未得到完整路由和最终双角时序结论。

相同 RTL 和约束的快速布线尝试位于 `build_rebuilt/pds_pc_control_fast_20261022/`，因仍存在较多未布通连接而终止。另一次关闭控制链共享的尝试位于 `build_rebuilt/pds_pc_control_nocontrolchain_20261022/`，但 PDS 保存后未保留该关闭选项，路由中间结果与快速模式相同，已终止，不作为不同策略通过的证据。

还分别尝试了布局扩散等级 3 和 4，目录为 `build_rebuilt/pds_pc_control_spread3_20261022/`、`build_rebuilt/pds_pc_control_spread4_20261022/`。策略依据为 PDS 随附 `UG990004_Tcl_Command_User_Guide.pdf` 第 4.92 节的 `plc_decongestion` 选项；该手册对资源占用超过 70% 的设计建议选择 0～4。构建脚本增加显式策略参数并在输入快照中记录，仅改变物理实现搜索策略。两轮均完成综合和布局，布线前 setup 的最小裕量为 0.121 ns，但路由仍有拥塞，已终止，未完成最终双角时序与位流审计。

上述失败尝试结束时，尚未取得通过最终审计的新位流；这些目录仅用于追溯，不能作为可用位流证据。之后的分块与共享写数据通路改造已完成最终实现和全部审计，详见本文件开头的最终更新及新位流实现记录。板测仍应使用经身份核对的新位流。

```powershell
# 用新目录执行后续尝试；以下命令不是已通过的构建结果：
& $py tools/build_pose_tiled.py --route --place-decongestion 4 --output build_rebuilt/pc_control_next_attempt
# 仅在所有流程完成后审计；当前试构建不满足此条件：
& $py tools/build_pose_tiled.py --audit-only --output build_rebuilt/pc_control_next_attempt
```

## 5. 板上验收

本次没有下载 FPGA 或执行物理串口/LED 测试。板测应使用通过最终时序和源码身份审计的新位流；历史位流不包含 CP2102 功能。

1. 下载新位流，连接 CP2102 Type-C，选择对应 COM 口；确认默认前三个 LED 亮。
2. GET_STATUS 核对 `available_mask=0x07`。依次设置 `0x00`～`0x07`，等待 `pending=0` 和 `applied_mask` 确认，核对 LED 和画面。
3. 输入暗场、亮场及混合场，核对曲线、帧号、亮度均值与比例；关闭 Gamma 时确认输出亮度和等于输入，其他开关独立有效。
4. 改变 IMU 姿态，验证姿态开启时跟随、关闭时 yaw/pitch 为零；单独关闭镜头模型，观察已标定去畸变的变化。
5. 移除或停止 HDMI 输入，确认不再产生新统计编号；定时遥测可重复旧快照，SET 可能保持 pending。恢复视频后确认配置在帧边界应用。
6. 保留最终位流哈希、串口日志和视频测试条件，测量实际帧率、响应时间及长期运行稳定性。
