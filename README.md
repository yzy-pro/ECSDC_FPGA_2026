# EmbFPGA：1920×1080 IMU 姿态与镜头畸变矫正

当前 Pango Design Suite 工程为根目录的 [`EmbFPGA.pds`](EmbFPGA.pds)，器件为 PGL50H-FBG484-6。活动 RTL、约束和 DDR3 IP 分别位于 `src/`、`src/hdmi_ddr3_top.fdc` 和 `DDR3_50H/`。

## 当前默认配置

- 1920×1080 RGB888 HDMI 输入、RGB565 DDR3 帧缓存及 HDMI 输出，扫描时序为 60 Hz。
- IMU 921600 baud UART 姿态接收；每帧锁定绝对 yaw/pitch，当前默认每轴范围约 ±15°，忽略 roll。
- 使用确认的相机内参与二阶径向畸变系数，执行逐像素逆投影和 128×64 双槽分块渲染；视野外无效采样输出黑色。
- 默认最近邻重采样。双线性选择历史串行路径；该配置不具有分块版本的 30 fps 吞吐验证结果。
- RGB565 转换前执行帧自适应 Gamma，HDMI 扫描以 60 Hz 运行并显示完成的矫正帧。

标定数据保存在 [`calibration/camera_20260930.json`](calibration/camera_20260930.json)。当前候选配置、位流 SHA256 和未板测状态见 [`bitstream/pose15_tiled_gamma_20261010_identity.json`](bitstream/pose15_tiled_gamma_20261010_identity.json)。

## 验证状态

当前源码与仿真验证记录见 [`verification/20261010_pose_tiled_30fps.md`](verification/20261010_pose_tiled_30fps.md)。128×64 分块路径在四组含共享 DDR 数据通道、32 拍延迟、数据停顿和 DDR 刷新压力的完整 1080p 仿真中达到约 30.000030 个不同源帧/秒。最新 PDS 实现报告、双工作角时序、FIFO CDC 审计与对应源码快照位于 [`verification/pds_pose_adaptive_128x64_bounds_pipe_20261010/`](verification/pds_pose_adaptive_128x64_bounds_pipe_20261010/)；报告为 All Constraints Met，DRM 占用 122/134。

以上是 RTL 仿真和 FPGA 布局布线结果。候选位流尚未烧录；实际开发板帧率、端到端延迟、画面稳定性及图像质量仍需实测。

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
