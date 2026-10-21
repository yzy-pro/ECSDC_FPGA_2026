# 2026-09-29：更正修改目标到 test/EmbFPGA.pds

## 修改位置

实际工程为 `C:\FPGA\test\EmbFPGA.pds`，顶层为 `hdmi_ddr3_top`。
此前修改落在外部 `EmbFPGA_repo`，未更新用户实际使用的这份工程；本轮已更正目标，不再把外部工程的结果冒充本地工程结果。

改前核查发现：本地 top 仍有 `u_scale_in/u_scale_out` 实例，两处 H_NUM 都为 1440，项目生成器仍加入旧缩放源文件，且 DDR 读完成条件尚未等待有效尾拍。

## 安全与范围

- 完整备份相关源码/工程/脚本/测试/报告/码流到 `backup_before_direct1920_20260929_151210`。
- 只对本目录应用 9 月 19 日控制基线下的 1920/RGB888 适配，更新实际 `.pds` 和生成器，不只是修改文件名。
- 保持 DDR IP、板级引脚不变；本地 DDR RTL 和两个顶层 wrapper 已与参考逐文件校验相同。
- 原始空模板 `test.pds` 不修改；实际工程入口仍叫 `EmbFPGA.pds`。
- 不自动烧录硬件，不覆盖历史 stable 码流，不在本轮修改或推送外部 Git 仓库。

## 已执行的软件验证

- 实际本地工程源文件列表检查通过：90 个 RTL 文件、一个 FDC；均位于 `test` 内，不引用 `EmbFPGA_repo`。
- 输入三帧 1920 像素配对、65536 种 RGB565→RGB888、独立 DE 延迟/复位、DDR 尾拍暂停、6800 缓存字回填及帧边界事务排空均通过。
- 故意恢复提前完成和循环槽混叠时，回归检测到错误并拒绝。
- 9 月 19 日坐标参考和当前默认系数逐样本匹配；既有非零系数数学回归也通过。
- 标定和缓存表检查通过，最大需求 72 行。

## 硬件验证边界

当前仍不能声称板上频闪已经消失。独立输出 DE、恢复基线控制、取消缩放和正确缓存尺寸是在代码层面降低风险；DDR 实际供数延迟、桥片输入相位与板级信号质量需板测。

## 本地实现与整帧仿真

- 直接执行 `C:\FPGA\test\build_test.ps1 -Run report_timing`，构建的是 `C:\FPGA\test\EmbFPGA.pds`。
- 2026-09-29 15:20:50 的本地报告为 `All Constraints Met`，不是引用外部工程报告。
- 本次运行的日志、报告及源码 SHA256 身份在 `verification/pds2022_20260929_151544/`，生成前后源码身份一致。
- 实际本地 RTL 完整一帧测试通过：2,073,600 个最终像素及同数量四邻点检查匹配，带 DDR 返回暂停、首行预取期限断言、1920×1080 行列数量检查。该测试是有界 DDR 服务模型，不包含真实 PHY/板级波形。
- 核心时序裕量（ns）：输入 setup slow/fast = 1.466/0.121；像素 setup slow/fast = 0.060/1.802；DDR setup slow/fast = 2.190/4.305；输入 hold slow/fast = 0.311/0.239；像素 hold slow/fast = 0.189/0.123；DDR hold slow/fast = 0.171/0.100。
- 已约束的 recovery/removal/pulse-width 检查也通过，但时序余量较小，且 I2C/DDR 外部端口等仍有外部延迟未完整约束的警告，不能称作板上无频闪保证。

完整码流生成通过 `build_test.ps1 -Run full` 在本地再次实现，生成后还需检查其最终报告与校验值，不能只沿用上面的报告。

## 本地候选码流已生成

2026-09-29 15:28:15，本目录 `EmbFPGA.pds` 的完整实现与码流生成完成。最终报告时间为 15:26:56，已重新确认 `All Constraints Met`，上述主要时序裕量不变。构建前后源码身份一致。

- 实际工程：`C:\FPGA\test\EmbFPGA.pds`。
- 本地生成文件：`C:\FPGA\test\generate_bitstream\hdmi_ddr3_top.sbit`。
- 明确命名的候选：`C:\FPGA\test\bitstream\EmbFPGA_1920_RGB888_20260929_candidate.sbit`。
- SHA256：`ca814b0f4d6d9a0e452679722b74bb51b90f8f13c13ecdac2fa1c19dd6f61fac`。
- 本次完整运行记录：`verification/pds2022_20260929_152202/`，包含日志、最终报告和源文件身份。

这个候选来自本地实际工程本轮构建，没有将外部仓库的 `.sbit` 复制过来充当构建结果。未执行 JTAG 烧录，仍需板上验证。本轮未修改或推送外部 Git 仓库。
