# CP2102 版本位流实现记录（2026-10-22）

## 实现修改

本次保留三个独立串口开关、Gamma 统计上报、状态 LED 和完整视频处理路径，已完成最终 FPGA 实现并生成可供下载的 sbit。未执行开发板烧录。

- `pose_renderer_tiled.v` 默认分块从 128×64 改为 128×32，减少坐标及输出块 RAM；两个源缓存槽仍各为 2048×256 bit，不缩减姿态范围或源区域容量。
- 结果 RAM 的行装载改为连续同步读流水：首拍发起读，此后每拍保存上一拍数据并发起下一次读，最后排空一拍后提交写命令。原接口及最终写完成后发布的所有权规则保持一致。
- `fram_buf_pose.v` 和 `pose_renderer_tiled.v` 的写突发各存放在 16×256 bit 分布式 RAM 中；`pose_ddr_arbiter.v` 通过 beat 索引读取当前客户端缓冲，不再复制整个突发到 4096 bit 移位寄存器。客户端保持数据直到最后一个有效 WREADY/WLAST 传输完成，期间捕获侧通过 FIFO 回压保护缓冲；支持 AW 与首拍数据同拍接受。
- 分布式 RAM 使用 PDS 支持的 `syn_ramstyle="lut_ram"` 属性，依据为 PDS 随附 `UG990102_ADS_Synthesis_User_Guide.pdf` 第 8.2.18 节。RAM 数据无需复位，状态机、长度和缓冲所有权在复位后保证有效数据先写后读。
- 渲染测试默认跟随 128×32，并补充 128×64 兼容配置，检查连续装载的逐像素结果、回压及错误 LAST 行为。
- 未放宽 HDMI 输入、DDR、setup/hold 或 FIFO Gray 指针偏斜约束。

## 位流与构建证据

交付位流：`bitstream/EmbFPGA_1920_pc_control_20261022.sbit`，器件为 PGL50H-FBG484-6，大小为 2,101,696 bytes。

SHA256：`492e1c3c29606e4e29eb47e5f95704fb1892cc3cc0a970f555cbb3e9bd320b4c`。配置及审计身份见 `bitstream/pc_control_20261022_identity.json`，校验文本见 `bitstream/SHA256_20261022_pc_control.txt`。

独立构建目录：`build_rebuilt/pds_pc_control_write_ram_20261022/`；不可变输入快照、工程设置、最终报告、CDC XML、源码身份、构建日志及仿真日志已归档到 `verification/pds_pc_control_write_ram_20261022/`。快照的 152 个源文件已逐个核对 SHA256，交付位流与构建生成物哈希相同，当前源码与构建输入一致。

仅缩小分块的 `pds_pc_control_tile32_stream_20261022/` 尝试仍存在路由收敛缓慢，已停止；该目录不是交付版本。共享写数据通路重构后约 45 秒完成路由，从编译到位流生成总计 4 分 50 秒。

| 指标 | 最终结果 |
|---|---:|
| 综合 LUT / FF | 14,571 / 15,006 |
| 综合 APM / 等效 DRM18K | 45 / 103 |
| 最终 DRM 位置 | 104 / 134 |
| 最终 LUT（含常量和旁路） | 16,878 / 42,800 |
| 锁存器 | 0 |
| 最终时序摘要 | All Constraints Met |
| 慢角 DDR/渲染 setup 余量 | +0.873 ns |
| 双角、全部域最小 setup / hold 余量 | +0.121 / +0.053 ns |
| FIFO Gray 最大 skew / 约束 | 1.470 / 6.734 ns |

快、慢工作角均包含 setup、hold、recovery、removal、minimum pulse width 检查；4 条 FIFO Gray 总线各 10 位均在两个工作角完成覆盖与偏斜审计。原始最终时序报告为归档中的 `prj_tasks/pnr_1/report_timing/hdmi_ddr3_top.rtr`；两角 skew XML 位于同目录的 `report_db/`。

## 功能与吞吐验证

17 组 PC 控制专项、主 RTL 回归、3 项 PC 协议单元测试及工程清单检查通过。新增测试覆盖共享写数据、AW/首拍同周期、背压、突发长度 1～16、WREADY/WLAST 门控、错误 LAST 后所有权锁定，以及 128×32/128×64 两种分块下的行装载。专项和主回归日志分别归档在 `pc_control/`、`main_rtl/`。

最新完整系统仿真包含 Gamma、RGB565、并发捕获/渲染/显示、32 拍 DDR 命令延迟、25% 数据停顿、共享读写数据通道，以及每 780 拍暂停 35 拍刷新。

| 指标 | 最新源码结果 |
|---|---:|
| 输入帧 / 不同结果发布数 | 28 / 13 |
| 稳态新结果发布率 | 30.000030 fps |
| 最大发布间隔 | 3,333,330 拍（100 MHz） |
| 最慢渲染 | 3,314,614 拍 / 33.14614 ms |
| 捕获 FIFO 峰值 | 15 / 512 个 256 bit 数据字 |
| 显示像素比较 | 51,840,000 次 |
| 覆盖范围 | 11 种姿态、全部 8 种控制掩码 |
| 仿真错误 | 0 |

最新仿真日志及源文件哈希归档为 `simulation/result.log` 和 `simulation/source_identity.json`；测试入口及 bench 副本位于 `simulation/inputs/`。下列命令记录本次实际入口与审计方式：

```powershell
$py = '.\reference\imu_cboard\.venv\Scripts\python.exe'
& $py tests/run_pose_tiled_integration.py --full --frames 28 --preprocess --runtime --shared-payload --refresh-cycles 35 --output build_rebuilt/pc_control_full1080p_write_ram
# 初次构建使用未占用的新目录；本次实际构建命令如下：
& $py tools/build_pose_tiled.py --route --output build_rebuilt/pds_pc_control_write_ram_20261022
# 对已经完成且输入未修改的本次构建执行审计：
& $py tools/build_pose_tiled.py --audit-only --output build_rebuilt/pds_pc_control_write_ram_20261022
# 独立复查已归档的两角 Gray 总线数据：
& $py tools/audit_pose_fifo_cdc.py verification/pds_pc_control_write_ram_20261022/prj_tasks/pnr_1/report_timing/report_db
```

## 板测边界

未执行开发板下载或烧录。整帧吞吐使用行为 DDR 模型，不包含物理 CP2102 和厂商 DDR PHY；串口和配置帧对齐由独立 RTL 测试覆盖。物理 CP2102、LED、实际 DDR 吞吐和 HDMI 画面仍需实板验收，操作步骤见 `20261021_pc_control.md` 第 5 节及 `report/pc_control_protocol.md`。
