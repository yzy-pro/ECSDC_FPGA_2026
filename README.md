# EmbFPGA：1920 全幅、IMU Yaw/Pitch 位姿矫正

## 2026-10-10 当前分块路径

顶层默认 `POSE_TILED_ENABLE=1`、`INTERPOLATION_MODE=1`，使用 **128×64 双槽分块缓存**。
yaw/pitch 每轴限幅约 ±15°，保留 IMU 绝对姿态、真实镜头标定、精确逐像素逆投影和视野外黑色输出。
块级突发读源、连续片内采样及突发写回相互重叠，源帧 0/3 交替采集，结果帧 1/2 交替显示。

此前 128×32 完整链路在 32 拍 DDR 延迟下通过 11 组姿态、13 个新帧 **30.000 fps** 测试，
但共享总线和刷新压力下在约 −5° yaw 耗时 33.50 ms，超过预算；当前已增大块高以增加余量。
128×64 已通过四组完整链路压力测试：共享 DDR 数据总线、32 拍命令延迟、25% 数据停顿、
两种刷新模式，自适应预处理开启/关闭均连续发布 13 个不同源帧，稳态 **30.000030 fps**。
最终源码四组测试最慢渲染 32.40717 ms；另一个读取量较高姿态的定向测试为 32.45705 ms。
块容量检查已分级，最终 PDS 双工作角时序和 FIFO CDC 检查通过；100 MHz 渲染域慢角余量 +0.462 ns。
最终实际占用 DRM 122/134，APM 45/84。以上为仿真及实现结果，尚未板测。
默认 `ADAPTIVE_PREPROCESS_ENABLE=1`、`ADAPTIVE_PREPROCESS_MODE=3` 启用帧自适应 Gamma，
在 RGB565 量化之前根据亮度统计选取曲线；原固定显示 Gamma 在此模式下旁路。
自动 Gamma 的独立 1080p60 流水线测试和组合系统 30 fps 压力测试均已通过。
当前源码与测试入口见 [分块实现及验证记录](verification/20261010_pose_tiled_30fps.md)。
待板测位流：[EmbFPGA_1920_pose15_tiled_gamma_20261010_candidate.sbit](bitstream/EmbFPGA_1920_pose15_tiled_gamma_20261010_candidate.sbit)，
[配置与 SHA256](bitstream/pose15_tiled_gamma_20261010_identity.json)。未执行烧录。
双线性或关闭分块参数会回到历史串行路径，其帧率及角度范围与本节不同。

## 2026-10-09 历史串行位姿路径

当前工程位于 `D:\pango\works\EmbFPGA\test\EmbFPGA.pds`，使用 PDS 2025.2-ads。
默认启用 `POSE_CORRECTION_ENABLE=1`，顶层实际实例化 `fram_buf_pose`。
使用参考工程 921600 baud UART 姿态协议；忽略 roll，yaw 绕竖直向上轴按右手定则为正，
pitch 低头为正，使用 IMU 绝对角度。源帧开始时锁定 yaw/pitch，当前范围各约 **±35°**，
超出范围按角度限幅。先做相机射线旋转和透视除法，再应用真实标定的径向/切向畸变模型。
视野外、相机后方及缺少完整插值邻点的位置输出黑色，不再限制源像素偏移为 ±2。

```text
RGB888 → 预处理接口 → RGB565 → DDR 源帧 slot 0
                                  ↓
                     帧姿态投影 → 随机源读取/字缓存 → 最近邻或双线性
                                                        ↓
                    HDMI ← 线性突发读取 ← DDR 矫正帧 slot 1/2
```

采集写和显示读使用最长 16 拍突发，渲染器使用独立单拍随机读写；DDR 仲裁器按真实
WREADY/WLAST、RVALID/RLAST 结束事务。源帧在渲染期间锁定，完整结果仅在 VS 交接，
并在旧读请求和输出 FIFO 排空后释放显示帧。异常输入帧丢弃并重试。
预处理接口已经移到输入 RGB888 转 RGB565 之前，默认旁路；尚未实现自动 Gamma/直方图算法。

**HDMI 时序仍是 1080p60；本版完整矫正帧更新率达不到 30/60 fps。**
最终源码整帧仿真已通过；在约 +30° yaw/−20° pitch、最近邻模式、100 MHz 行为模型下，
渲染耗时约 178.067 ms/帧（约 5.6 fps，尚未计入整机采集/等待/真实 DDR 争用）。
渲染期间跳过新的源帧，输出重复最近的完整结果。本版是大角度功能接入版本，不能作为赛题实时指标验收结果。
实现、测试及构建状态见 [大角度接入记录](verification/20261009_pose_large_angle.md)。

完整 PDS 构建已于 2026-10-09 20:03 完成，时序及快/慢工作角 FIFO CDC 检查均通过，
构建前后源码哈希一致。2026-10-10 已归档待板测候选
[EmbFPGA_1920_IMU_pose35_20261009_candidate.sbit](bitstream/EmbFPGA_1920_IMU_pose35_20261009_candidate.sbit)，
[SHA256 与配置记录](bitstream/SHA256_20261009_pose35.txt)。此候选尚未烧录或板测。

RTL 保留 `POSE_CORRECTION_ENABLE=0` 的历史八分区路径及 `UNDISTORT_ENABLE=0` 的线性 DDR 路径。
当前构建检查及四组 FIFO CDC 约束针对默认大角度路径；重新构建历史路径需同步调整这些专属检查/约束。
新路径和旧路径都支持 `INTERPOLATION_MODE=1` 最近邻、`0` 双线性。
实验 `pose_frame_bank_allocator`、`pose_tile_read_scheduler` 未接入新路径，新路径使用独立帧所有权和字缓存。
它们的历史测试及此前小偏移位流不能证明新路径的正确性。
更高吞吐分块方案及预算分别见 [架构设计](verification/20261009_pose_tile_architecture.md)、
[60 fps 评估](verification/20261009_pose_1080p60.md)。

```powershell
$py = '.\reference\imu_cboard\.venv\Scripts\python.exe'
& $py tests\run_rtl_regressions.py --modelsim 'D:\pango\modeltech64_10.6e\win64'
powershell -NoProfile -ExecutionPolicy Bypass -File .\build_test.ps1 -Run full
```

回归的 `--full-raster` 选项仍测试历史八分区路径，新路径由 `tb_fram_buf_pose` 等测试覆盖。
以下 9 月构建、缓存和位流信息均为历史基线，不代表当前源码的验证结果。

## 工程入口与版本状态

实际工程：`C:\FPGA\test\EmbFPGA.pds`。不要打开同目录的空模板 `test.pds`。生成器和全部源文件、DDR IP、约束均在此目录内，不依赖外部 Git 工作区。

2026-09-30 已接入用户确认的正确标定和八分区缓存。当前是待板测实现，不是已确认无频闪的稳定版；此前 72 行旧标定记录仅作为历史资料。当前结果见 [八分区实现与验证记录](verification/20260930_eight_band.md)。

- PDS 2022.2-SP3，PGL50H-FBG484-6；顶层 `hdmi_ddr3_top`。
- 输入、DDR 帧存储及输出均为 1920×1080，不做 1920→1440→1920 缩放。
- RGB888 输入 → RGB565 存储/去畸变 → RGB565 转 RGB888 → 原版 gamma → HDMI。
- 默认最近邻，保留可选双线性模式；不通过裁剪或降低颜色精度减少 RAM。
- 当前去畸变数据和同步链延迟为 20 拍；线性模式仍为 2 拍。
- 新层级包含 `u_undistort_rd_buf/u_band_cache`，不应包含 `u_scale_in/u_scale_out`。

## 标定与缓存

标定权威输入：`calibration/camera_20260930.json`。

```text
fx=748.4469  fy=748.0773
cx=944.9033  cy=522.3963
k1=0.0099   k2=-0.0434
p1=0        p2=0
```

源图像横向分成 8 个 240 像素区域，各区分配源行数：
`50, 46, 18, 10, 10, 20, 58, 48`。

缓存合并为两组 `1950×272 bit` 奇偶 RAM。每区每行有效 15 beat，DDR 以固定 16 beat 请求获取数据和插值邻点。分区表提前两行预取，同时保留上一行尚未退出流水线的数据。

表生成器核对 2,073,600 个像素，并联合覆盖浮点、当前定点及规范化 Q5 映射。修改标定不能只手改常数；当前生成器会拒绝与已验证布局不符的参数。

```powershell
python tools/generate_undistort_cache.py
python tests/verify_cache_windows_1920.py
```

`tools/audit_camera_calibration.py` 仅保留作历史整行缓存模型的分析入口，不用于判定当前八分区结构是否可用。

## 构建

在本目录执行：

```powershell
.\build_test.ps1 -Run full
```

只跑时序可用 `-Run report_timing`，只编译可用 `-Run compile`。脚本生成本目录的 `EmbFPGA.pds`、校验标定/缓存表、保存源文件身份，然后调用 PDS。

- 当前通过的完整构建：`verification/pds2022_20260930_172335/`。
- 时序：`All Constraints Met`；整个工程 DRM18K 为 88/134。
- 原始码流：`generate_bitstream/hdmi_ddr3_top.sbit`。
- 本轮待板测候选：[EmbFPGA_1920_RGB888_8band_20260930_candidate.sbit](bitstream/EmbFPGA_1920_RGB888_8band_20260930_candidate.sbit)，校验值见 `bitstream/SHA256_20260930_8band.txt`；旧候选未覆盖。
- 必须同时检查本次新报告、错误日志、码流时间戳、构建前后源码身份及回归结果。
- 不自动连接 JTAG 或烧录。

```powershell
python tools/build_identity.py verification/pds2022_20260930_172335/source_identity.json --check
```

输入时序预算和板级约束未放宽；原工程部分外部端口仍存在未完整指定外部延迟的警告。时序通过不能代替桥片相位、DDR 实际延迟和画面稳定性板测。

## 回归测试

```powershell
python tests/run_rtl_regressions.py --iverilog <iverilog.exe> --vvp <vvp.exe>
python tests/run_rtl_regressions.py --full-raster --frames 3 --iverilog <iverilog.exe> --vvp <vvp.exe>
python tests/run_rtl_regressions.py --full-raster --frames 1 --bilinear --iverilog <iverilog.exe> --vvp <vvp.exe>
```

涵盖输入像素配对、RGB 扩展、20/2 拍 DE、命令尾拍、真实读命令适配器与 `rd_ctrl`、缓存 halo、帧重启、坐标运算及错误注入。完整光栅测试使用不同像素/DDR 时钟、带 bank/行/列标记的像素及有界返回停顿；不模拟真实 DDR PHY。最终测试状态和日志位置以验证记录为准。

本轮快速回归、默认最近邻连续 3 帧（6,220,800 像素）、双线性完整 1 帧（2,073,600 像素）均通过。原始日志归档在 `verification/eight_band_20260930/`。本轮实现作为待板测候选归档；提交身份以所在仓库的 Git 记录为准，尚未板测。

9 月 19 日参考 RTL 保留在 `reference/sept19_6be49a4/`。历史 1440 测试不是本版本的验证入口。

## 备份及旧码流

改造前远端恢复标签：`backup/pre-8band-20260930`，对应提交 `7a18551`。

原始本地备份已移到 `C:\FPGA\archive_20260930\backup_before_direct1920_20260929_151210`。此前的 `EmbFPGA_1920_RGB888_20260929_candidate.sbit` 和更老的 `hdmi_ddr3_undistort_stable.sbit` 均不包含本轮正确标定与八分区实现，不能用它们验证本轮效果。



