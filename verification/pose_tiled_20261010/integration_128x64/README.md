# 128×64 分块姿态矫正完整链路压力测试

四组测试全部 PASS，结果表见 [summary.json](summary.json)。每个子目录保存原始 ModelSim
日志、参数和输入 SHA256；归档时所有输入与当前源码一致。生产 RTL 使用精确逐像素投影、
最近邻采样、双槽源块缓存，yaw/pitch 范围约 ±15°。

输入/显示均为完整 1920×1080、2200×1125 的 60 Hz 光栅，渲染与 DDR 为 100 MHz。
行为 DDR 模型使用 32 拍命令延迟、25% 随机 payload 停顿，以及读写共享的单 beat 数据通道。
分别施加 35/780 和 250/6120 拍的刷新阻塞，测试自动 Gamma 关闭、开启两种情况。
Gamma 组包括实际输入寄存器、Gamma 模块及 RGB565 转换，数学 LUT 参考独立计算。

| 自动 Gamma | 刷新暂停/间隔 | 最长渲染 | 稳态不同源帧发布率 |
|---|---|---:|---:|
| 关闭 | 35/780 | 32.39052 ms | 30.000030 fps |
| 关闭 | 250/6120 | 32.23799 ms | 30.000030 fps |
| 开启 | 35/780 | 32.39819 ms | 30.000030 fps |
| 开启 | 250/6120 | 32.25491 ms | 30.000030 fps |

各组输入 28 帧，发布 13 个不同源帧的结果；最长发布间隔 3,333,330 拍。
11 个姿态包括零、四组双轴极限、四组单轴极限、yaw=±179 Q2048 的中间姿态。
每组检查 51,840,000 个显示像素，采集、源帧身份、采样、帧槽所有权及协议检查全部通过。
Gamma 实际渲染曲线为 0、1、2、3、4、6，其余曲线由独立 Gamma 回归覆盖。

复现自动 Gamma + 35/780 压力组（从工程根目录执行，输出到新目录）：

```powershell
& reference/imu_cboard/.venv/Scripts/python.exe tests/run_pose_tiled_integration.py --full --latency 32 --shared-payload --refresh-cycles 35 --refresh-interval 780 --preprocess --output build_rebuilt/recheck_pose_adaptive_h64_refresh35
```

250/6120 组改变两个刷新参数；关闭 Gamma 组去掉 `--preprocess`，另选输出目录。
这些结果证明指定竞争模型下的功能和吞吐，不是板测，也不是所有真实 DDR 调度的最坏耗时上界。
最终布线时序和硬件验证状态见 [主记录](../../20261010_pose_tiled_30fps.md)。
