# EmbFPGA：1920×1080 IMU 姿态与镜头畸变矫正

当前 Pango Design Suite 工程为根目录的 [`EmbFPGA.pds`](EmbFPGA.pds)，器件为 PGL50H-FBG484-6。应用 RTL 和约束位于 `src/`；PLL、帧缓存 RAM 和 DDR3 等厂商 IP 集中在 `ipcore/`，并通过各 IP 的 `.idf` 描述文件登记到 PDS 的 IP 列表。

## 当前默认配置

- 1920×1080 RGB888 HDMI 输入、RGB565 DDR3 帧缓存及 HDMI 输出，扫描时序为 60 Hz。
- IMU 921600 baud UART 姿态接收；每帧锁定绝对 yaw/pitch，当前默认每轴范围约 ±15°，忽略 roll。
- 使用确认的相机内参与二阶径向畸变系数，执行逐像素逆投影和 128×32 双槽分块渲染；源缓存仍为每槽 2048 个 256 bit 数据字，视野外无效采样输出黑色。
- 默认最近邻重采样。双线性选择历史串行路径；该配置不具有分块版本的 30 fps 吞吐验证结果。
- RGB565 转换前执行帧自适应 Gamma，HDMI 扫描以 60 Hz 运行并显示完成的矫正帧。

标定数据保存在 [`calibration/camera_20260930.json`](calibration/camera_20260930.json)。当前位流为 [`bitstream/EmbFPGA_1920_pc_control_20261022.sbit`](bitstream/EmbFPGA_1920_pc_control_20261022.sbit)，配置、SHA256 和未板测状态见 [`bitstream/pc_control_20261022_identity.json`](bitstream/pc_control_20261022_identity.json)。

## 验证状态

2026-10-22 的 CP2102 版本已完成综合、布局布线及位流生成，最终快/慢角时序为 **All Constraints Met**，FIFO Gray 偏斜与当前源码身份审计通过。通过客户端持有的分布式 RAM 突发缓冲消除重复宽寄存器，并改为 128×32 分块；综合占用 14,571 LUT、15,006 FF、103 个等效 DRM18K，最终占用 104/134 个 DRM 位置。最新完整 1080p 并发压力测试达到 30.000030 fps，最慢渲染 33.14614 ms。详细证据见 [`verification/20261022_pc_control_sbit.md`](verification/20261022_pc_control_sbit.md)。

原有 2026-10-10 候选版本的验证记录见 [`verification/20261010_pose_tiled_30fps.md`](verification/20261010_pose_tiled_30fps.md)。该版本的 128×64 分块路径在四组含共享 DDR 数据通道、32 拍延迟、数据停顿和 DDR 刷新压力的完整 1080p 仿真中达到约 30.000030 个不同源帧/秒。该候选的 PDS 实现报告、双工作角时序、FIFO CDC 审计与对应源码快照位于 [`verification/pds_pose_adaptive_128x64_bounds_pipe_20261010/`](verification/pds_pose_adaptive_128x64_bounds_pipe_20261010/)；报告为 All Constraints Met，DRM 占用 122/134。新增 CP2102 版本的验证结果单独记录于 [`verification/20261021_pc_control.md`](verification/20261021_pc_control.md)。

以上是 RTL 仿真和 FPGA 布局布线结果。候选位流尚未烧录；实际开发板帧率、端到端延迟、画面稳定性及图像质量仍需实测。

## CP2102 上位机控制

新增板载 CP2102 双向串口（115200，8-N-1）：独立切换镜头去畸变、IMU 姿态矫正和自适应 Gamma，前三个用户 LED 指示已在输入帧边界应用的开关状态。默认三项开启，约 10 Hz 上报 Gamma 曲线、原始/增强后亮度及暗部/高光统计。协议字段、引脚依据、应用时序及 Python 示例见 [上位机协议说明](report/pc_control_protocol.md)，命令行工具为 `tools/pc_video_control.py`。

当前位流包含上述功能，已通过 17 组专项测试、主 RTL 回归、完整 1080p 并发压力测试和最终 FPGA 实现审计；尚未实板烧录。2026-10-10 历史候选不包含新协议。最新构建及验证结果见 [位流实现记录](verification/20261022_pc_control_sbit.md)，串口与 LED 的板测步骤见 [CP2102 验证记录](verification/20261021_pc_control.md)。

## 回归与构建

在 Windows PowerShell 中运行主要 RTL 回归：

```powershell
$py = '.\reference\imu_cboard\.venv\Scripts\python.exe'
& $py tests\run_rtl_regressions.py --modelsim 'D:\pango\modeltech64_10.6e\win64'
```

自适应 Gamma 仿真：

```powershell
& $py tests\run_adaptive_gamma.py
```

使用 PDS GUI 打开根目录 `EmbFPGA.pds`。项目文件清单使用相对路径并引用本目录中的源文件；测试模板 `test.pds` 不是主工程。`build_test.ps1` 可用于检查及构建项目，`tools/build_pose_tiled.py` 提供隔离的分块工程构建和结果审计流程。

RTL 回归和离线分析产物写入已忽略的 `build_rebuilt/`；该目录可随时从仓库测试脚本重新生成，无需作为工程源码备份。

## ????

- `src/top/`???????????????????
- `src/board/`?MS72xx HDMI ????? I?C ?????
- `src/imu/`?IMU UART ????????????????????
- `src/video/timing/`????????/???????
- `src/video/preprocess/`?????????/??? Gamma?
- `src/video/format/`?RGB888/RGB565 ???????
- `src/video/frame_buffer/`?DDR ?????????
- `src/video/undistort/`?????????????????
- `src/video/pose/`?????????????DDR ????????
- `src/constraints/`?PDS/FDC ????????
- `ipcore/`?Pango PLL???? RAM?DDR3 IP ??? `.idf` ?????

`EmbFPGA.pds` ??????????? RTL ??????????? `generate_project.ps1` ? `tests/`?`tools/` ???????
