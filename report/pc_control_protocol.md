# CP2102 上位机控制与自适应 Gamma 遥测协议

版本：v1，2026-10-21。适用于当前默认 `EmbFPGA.pds` 的分块姿态矫正配置。

## 1. 硬件连接依据

依据项目内 `reference/MES50HP开发板硬件使用手册_1V1.pdf`：

- 第 3.2.4 节、表 3-5，PDF 第 27 页（印刷页码 26）：板载 CP2102 通过 USB Type-C 与 PC 通信，FPGA 的 `UART0_RX` 为 R8，`UART0_TX` 为 R9。
- 第 3.4.2 节、表 3-9，PDF 第 33～34 页：用户 LED 高电平点亮，LED1～8 分别连接 B2、A2、B3、A3、C5、A5、F7、F8。

工程顶层端口 `pc_uart_rx` 接 R8，`pc_uart_tx` 接 R9，`sys_led[0]`～`sys_led[7]` 按上述顺序对应 LED1～8，已登记在 `src/constraints/hdmi_ddr3_top.fdc`。这里的 TX/RX 从 FPGA 方向命名：PC 发出的数据进入 R8，FPGA 发出的数据由 R9 到 PC。板载 CP2102 与 AB4 上的 IMU UART 是两条独立通道，互不复用；不需要再外接 USB-TTL 模块。

连接开发板的 CP2102 USB Type-C 接口，在操作系统中选择其对应串口，例如 `COM5`。它不是 JTAG 下载口；协议功能必须先综合、生成位流并下载到 FPGA 才能使用。

## 2. 串口参数与默认状态

| 参数 | 值 |
|---|---|
| 波特率 | 115200 bit/s |
| 数据位 / 校验 / 停止位 | 8 / 无 / 1，即 8-N-1 |
| 流控 | 无，禁用 RTS/CTS、DSR/DTR 和 XON/XOFF 流控 |
| 编码 | 二进制帧；不是文本，也不带换行符 |
| 默认功能掩码 | `0x07`，去畸变、姿态矫正、自动 Gamma 全部启用 |
| 默认遥测 | 开启，约 10 包/秒，发送最近完成的输入帧统计 |

设置保存在 FPGA 寄存器中，复位或重新配置后恢复默认值。一个 28 字节遥测负载的完整包为 35 字节，10 Hz 占 350 字节/秒，约 3500 bit/s，低于串口有效容量。串口上报统计结果，不传输图像、逐像素坐标或完整直方图。

## 3. 三个开关的含义

使用一个 3 bit 掩码原子设置三个功能，高 5 bit 必须为零：

| 位 | 功能 | 1 | 0 |
|---|---|---|---|
| bit0 | 镜头去畸变 | 启用已标定的 k1/k2/p1/p2 镜头模型 | 径向缩放为 1、切向偏移为 0，仍可独立保留姿态变换 |
| bit1 | 自适应姿态矫正 | 使用源帧 SOF 时锁存的 IMU yaw/pitch | 将该源帧的 yaw/pitch 置零，镜头模型仍由 bit0 决定 |
| bit2 | 自适应 Gamma | 应用自动选出的 Gamma 曲线 | 保留流水线延迟，输出原始 RGB，继续统计和计算场景目标 |

镜头与姿态都关闭时走精确同坐标采样，保留最末行/列，避免通过定点投影往返产生额外黑边。该模式仍经过 RGB565 帧存储和既有渲染/显示链路；它不是 RGB888 直接 HDMI 旁路。Gamma 关闭时不会自动启用历史显示端固定 Gamma。

| 掩码 | 工作模式 |
|---|---|
| `0x00` | 三项全部关闭 |
| `0x01` | 仅镜头去畸变 |
| `0x02` | 仅姿态矫正 |
| `0x03` | 镜头去畸变 + 姿态矫正 |
| `0x04` | 仅自动 Gamma |
| `0x05` | 镜头去畸变 + 自动 Gamma |
| `0x06` | 姿态矫正 + 自动 Gamma |
| `0x07` | 三项全部开启 |

运行时几何开关针对默认 `UNDISTORT_ENABLE=1`、`POSE_CORRECTION_ENABLE=1`、`POSE_TILED_ENABLE=1`、`INTERPOLATION_MODE=1` 的分块路径实现，Gamma 开关要求自动预处理模式。修改综合参数后应先读取 `available_mask`；尝试启用不支持的位会返回“不支持”状态。历史串行、静态带缓存、线性或直接 HDMI 旁路配置不具有相同的运行时三开关能力。对 `available_mask` 为 0 的位，协议掩码和对应 LED 不表示历史静态功能的实际执行状态，上位机应将该控件标为“不支持”。

## 4. 帧边界生效与 LED 指示

SET 命令通过校验后先修改 `requested_mask`。配置经握手邮箱跨入 HDMI 输入时钟域，在下一次检测到的输入 SOF 原子应用；目标端确认返回后更新 `applied_mask`。SOF 从输入 I/O 寄存器后检测，Gamma 在该 SOF 采样即将提交的掩码，几何链路随后锁存已提交掩码，保证同帧一致且不增加视频流水线延迟。若命令距离 SOF 太近而同步尚未完成，则在之后的 SOF 应用。

已采集帧的姿态和镜头开关随源帧保留，已处理或正在处理的帧保持原配置。上位机应区分：

1. ACK 的 `result=0`：命令已接收。
2. `pending=0` 且 `applied_mask=requested_mask`：输入帧配置已生效。
3. 屏幕上出现新配置的结果：还需等待该源帧采集、渲染和显示交接；当前协议没有提供“屏幕已切换”的专门确认。

没有 HDMI 输入时钟或没有 SOF 时，命令可以接收，但保持 pending；此时可继续查询状态和控制遥测，不能覆盖仍待应用的开关命令。再次 SET 返回 BUSY。

| LED | 引脚 | 含义 |
|---|---|---|
| LED1 / `sys_led[0]` | B2 | `applied_mask.bit0`，镜头去畸变启用 |
| LED2 / `sys_led[1]` | A2 | `applied_mask.bit1`，姿态矫正启用 |
| LED3 / `sys_led[2]` | B3 | `applied_mask.bit2`，自动 Gamma 启用 |
| LED4～8 | A3、C5、A5、F7、F8 | 当前保留，熄灭 |

LED 表示已应用的功能使能，不表示 DDR 初始化完成、视频有效、Gamma 非恒等曲线或当前屏幕内容。默认前三灯亮；Gamma 曲线为 1.00 时，Gamma 使能灯仍然亮。

## 5. 通用帧格式

所有多字节整数均为小端序，无符号。各命令及响应采用相同包格式：

| 偏移 | 长度 | 字段 | 说明 |
|---:|---:|---|---|
| 0 | 1 | SYNC0 | 固定 `0xA5` |
| 1 | 1 | SYNC1 | 固定 `0x5A` |
| 2 | 1 | VERSION | 固定 `0x01` |
| 3 | 1 | TYPE | 命令/消息类型 |
| 4 | 1 | SEQUENCE | 主机命令序号或遥测序号，8 bit 循环 |
| 5 | 1 | LENGTH | 负载字节数，不含包头和校验 |
| 6 | LENGTH | PAYLOAD | 见各类型说明 |
| 6+LENGTH | 1 | CHECKSUM | 从 VERSION 到负载末尾逐字节 XOR |

总长度为 `7+LENGTH`。校验不包含 `A5 5A`。负载可以包含任意字节，包括 `A5 5A`，应在已识别包内严格按长度接收。

FPGA 接收器只接受长度 0 或 1 的主机命令。错误版本、长度大于 1、错误 XOR 和半包超时会丢弃该包并增加接收错误计数，不改变功能配置。包内两字节之间超过约 20 ms 会超时。上位机应连续写入整个包；无响应时清理自身残留半包并以新序号重试，重试可使用 0.5～2 秒响应超时。必须一次只保留一个未收到 STATUS 的主机请求；FPGA 的响应等待缓冲不是无限队列。

## 6. 主机命令

| TYPE | 名称 | 负载 | 返回 |
|---|---|---|---|
| `0x10` | SET_FEATURES | 1 字节，功能掩码 `0x00`～`0x07` | STATUS，seq 与请求相同 |
| `0x11` | GET_STATUS | 0 字节 | STATUS，seq 与请求相同 |
| `0x12` | SET_STREAM | 1 字节，0=关闭定时遥测，1=开启 | STATUS，seq 与请求相同 |
| `0x13` | GET_SNAPSHOT | 0 字节 | STATUS；已有统计时另外排队发送一包 GAMMA_STATS |

GET_SNAPSHOT 返回最新已完成帧，不触发额外采集。STATUS 优先发送，已经开始发送的遥测包不会中途打断，所以 ACK 前可能先收到一包遥测。开启定时遥测时，一次 GET_SNAPSHOT 可能与原本待发送的遥测合并成一包。遥测序号独立于命令序号，不能用遥测 seq 匹配命令 ACK。

示例（十六进制，seq=`0x01`）：

```text
三项全开： A5 5A 01 10 01 01 07 16
三项全关： A5 5A 01 10 01 01 00 11
查询状态： A5 5A 01 11 01 00 11
关闭遥测： A5 5A 01 12 01 01 00 13
读取快照： A5 5A 01 13 01 00 13
```

## 7. STATUS：TYPE=0x80

负载固定 8 字节，完整包 15 字节。seq 回显请求序号。表中偏移相对于 PAYLOAD：

| 偏移 | 字段 | 说明 |
|---:|---|---|
| 0 | result | 本次命令处理结果 |
| 1 | requested_mask | 最新已接受的目标掩码 |
| 2 | applied_mask | 输入 SOF 应用并已返回确认的掩码 |
| 3 | pending | 1=配置尚未完成应用确认；0=无待应用配置 |
| 4 | available_mask | 综合配置支持的运行时功能位，默认 `0x07` |
| 5 | stream_enabled | 定时遥测是否开启 |
| 6 | has_stats | 当前复位以来是否收到过有效 Gamma 帧统计 |
| 7 | receive_errors_mod256 | 包格式/XOR/超时等接收错误计数低 8 bit |

`result`：0=成功；1=未知命令；2=负载长度错误；3=数值非法；4=前一配置仍在等待应用，BUSY；5=请求了不支持的功能；6=尚无有效帧统计。STATUS 负载在处理请求时保存，是该时刻的状态快照。

SET 的成功响应通常携带 `pending=1`，即使 SOF 在响应发送前已完成应用。上位机应继续 GET_STATUS 查询，不能把旧 ACK 中的 pending 当作持续实时状态。若想修改一个功能，应基于 requested_mask 做位操作，生成完整三位掩码再 SET，避免清掉其他功能。

## 8. GAMMA_STATS：TYPE=0x81

负载固定 28 字节，完整包 35 字节。统计基于原始输入 RGB888 和 Gamma 输出 RGB888，在 RGB565 量化与几何矫正之前获得；不是最终 HDMI 画面的统计。统计只累计 DE 有效像素，空白消隐不参与。

| 负载偏移 | 长度 | 字段 | 含义 |
|---:|---:|---|---|
| 0 | 4 | frame_index | 完成的非空输入帧统计编号，从 0 开始，32 bit 循环 |
| 4 | 4 | raw_luma_sum | 该帧原始近似亮度累计值 |
| 8 | 4 | pixel_count | 该帧有效像素数，正常 1080p 为 2,073,600 |
| 12 | 4 | dark_count | 原始亮度 `<48` 的像素数 |
| 16 | 4 | highlight_count | 原始亮度 `>=208` 的像素数 |
| 20 | 4 | corrected_luma_sum | 该帧实际 Gamma 输出近似亮度累计值；Gamma 关闭时与原始值相同 |
| 24 | 1 | active_curve | 该统计帧使用的曲线编号 0～6 |
| 25 | 1 | target_curve | 关闭该统计帧时的目标曲线编号 0～6 |
| 26 | 1 | gamma_enabled | 该统计帧是否实际启用 Gamma，0/1 |
| 27 | 1 | frame_mask | 该统计帧的输入功能掩码，含三项开关 |

亮度定义为 `Y=(R+2*G+B)>>2`，范围 0～255，是统计代理量，不是严格的光度学或 YCbCr 测量。上位机可计算：

```text
mean_before = raw_luma_sum / pixel_count
mean_after = corrected_luma_sum / pixel_count
dark_ratio = dark_count / pixel_count
highlight_ratio = highlight_count / pixel_count
```

分母为 0 时应显示无效，而不是强行置零。两个比例均来自增强前图像，不能用它们当作增强后的暗部或高光比例。

曲线公式为 `y=round(255*(x/255)^exponent)`：

| 编号 | 指数 | 作用 |
|---:|---:|---|
| 0 | 0.50 | 较强提亮 |
| 1 | 0.65 | 提亮 |
| 2 | 0.80 | 温和提亮 |
| 3 | 1.00 | 恒等 |
| 4 | 1.25 | 温和压暗 |
| 5 | 1.55 | 压暗 |
| 6 | 1.90 | 较强压暗 |

FPGA 先对原始帧分类，连续两次分类相同才更新目标，每个 SOF 最多向目标移动一档。因此 active_curve 和 target_curve 可以不同；关闭 Gamma 后算法仍继续适应，但 `gamma_enabled=0` 时上述曲线不作用于输出，应以上报的 corrected_luma_sum 展示实际结果。

帧统计用握手快照跨域，避免多字节值撕裂。串口仅以 10 Hz 发送最新统计，跳过中间输入帧是正常降采样；若输入停止，还会重复最新快照。上位机应结合本地接收时间和 frame_index 判定新鲜度，不能仅凭收到数据认定视频仍在更新。统计帧编号也不等于矫正器最终显示的帧编号。

## 9. PC 端接收与示例工具

仓库提供 `tools/pc_video_control.py`，含不依赖 GUI 框架的编码、增量解包、状态解析和 Gamma 统计解析函数。硬件串口访问需要 Python 和 `pyserial`，协议编码器本身只依赖标准库。

```powershell
python -m pip install pyserial
python tools/pc_video_control.py --port COM5
python tools/pc_video_control.py --port COM5 --mask 0x07 --watch 10
python tools/pc_video_control.py --port COM5 --mask 0x03 --snapshot
python tools/pc_video_control.py --port COM5 --stream off
```

工具按行打印 JSON；设置功能时先等待命令 ACK，再查询 pending 和 applied_mask。无视频 SOF 时会报告“命令已接受但未应用”。可直接复用 `encode_packet`、`PacketDecoder`、`decode_status`、`decode_gamma` 开发 PyQt、C# 或其他上位机。

建议 UI 设置三个独立开关，显示 requested/applied/pending 三种状态；展示 Gamma 曲线编号、实际启用、增强前后平均亮度、原始暗部/高光比例、输入帧统计编号和本地数据时间。串口可能发生分包、粘包或包前噪声，接收器应按同步字、版本、长度和校验重组，不能假定一次 `read()` 对应一个包。

## 10. 验证与使用边界

相关实现位于 `src/control/`；几何开关随源帧穿过 `fram_buf_pose`，并在分块渲染启动时锁定。验证入口：

```powershell
$py = '.\reference\imu_cboard\.venv\Scripts\python.exe'
& $py tests/test_pc_video_protocol.py
& $py tests/run_pc_control.py
& $py tests/verify_main_contract.py
```

测试覆盖串口实际位流与 50 MHz/115200 参数、三个开关组合、SOF 应用和 BUSY、非法命令/校验/超时、遥测开关、Gamma 原始及输出亮度帧对齐、快照 CDC、几何关闭后的完整边界像素，以及带 DDR 争用的并发渲染。新增注册 SOF 连接测试分别验证自动 Gamma 与无 Gamma 链路的帧级一致性。生成的仿真产物在 `build_rebuilt/pc_control/`，本次结果汇总与板测步骤见 [`verification/20261021_pc_control.md`](../verification/20261021_pc_control.md)。

2026-10-22 已生成包含本协议的位流 `bitstream/EmbFPGA_1920_pc_control_20261022.sbit`，最终快/慢角时序、FIFO Gray 偏斜和当前源码身份审计均通过。17 组专项测试、主 RTL 回归及完整 1080p 并发测试通过；后者达到 30.000030 fps，最慢渲染 33.14614 ms。构建输入、报告、测试日志与位流身份见 [最新位流实现记录](../verification/20261022_pc_control_sbit.md)。尚未烧录或进行 CP2102/LED 实物联调，板测应使用上述新位流；2026-10-10 历史位流不包含本协议。协议不改变 roll 忽略、约 ±15°姿态范围、最近邻采样和视野外黑色输出的既有边界。
