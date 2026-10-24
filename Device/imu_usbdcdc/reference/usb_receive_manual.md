# STM32 USB CDC 上位机接收说明手册

文档日期：2026-10-24。适用于本仓库当前 `AppJetsonUsbTask` 与 `JetsonUsb` 实现。

本手册说明上位机如何通过 USB 虚拟串口接收 STM32 的三轴姿态数据。协议以实际发送代码为准：固定 **10 字节**，字段顺序为 **yaw、pitch、roll**，小端有符号 Q2048 编码，目标上报频率 **50 Hz**。

## 1. 设备连接与串口设置

将上位机连接到 STM32 固件使用的 USB OTG FS 设备接口，使用支持数据传输的 USB 线。该接口枚举为 CDC 虚拟串口。

| 项目 | 当前配置 |
| --- | --- |
| USB VID | `0x0483` |
| USB PID | `0x5740` |
| 产品名称 | `STM32 Virtual ComPort` |
| Linux / Jetson 端口示例 | `/dev/ttyACM0`，编号以实际枚举结果为准 |
| Windows 端口示例 | `COM5`，编号以设备管理器为准 |
| 上位机建议串口参数 | `115200`、8 数据位、无校验、1 停止位、无软硬件流控 |
| 数据方向 | STM32 → 上位机，二进制姿态状态上报 |

这里的 `115200` 是串口 API 的打开参数。当前 `CDC_Control_FS()` 没有应用波特率、数据位、校验位、停止位及 DTR/RTS 设置，因此这些设置不决定 USB 实际传输速率。不要套用 USART6 的 `921600 bit/s` 配置。

上位机打开设备后直接接收即可，无需发送启动命令、轮询请求或 ACK。当前 USB 接收回调只重新使能接收，没有实现上位机控制指令。

安装 Python 接收示例所需的依赖并查看端口：

```bash
python3 -m pip install pyserial
python3 -m serial.tools.list_ports -v
```

有多个同 VID/PID 设备时，应结合端口路径或设备序列号确认目标设备。

## 2. 上报时机与数据来源

`AppJetsonUsbTask` 的目标运行周期为 20 ms。每次循环非阻塞读取一次 `Bmi088Status2Queue`，成功后更新内部姿态，然后尝试发送一帧。

- USB 已完成配置，且上一笔 CDC 发送已经完成时，才打包并提交发送。
- USB 未连接、未完成配置或发送忙时，跳过本次发送机会；没有逐帧补发或应用层重传机制。
- 队列没有新数据时，继续上报内部保留的姿态值。
- 收到首次队列数据前，内部姿态初值均为 0；启动阶段可能收到全零姿态帧。

因此，50 Hz 是任务目标频率，实际接收间隔可能受 USB 和系统调度影响。收到合法帧仅说明格式和校验通过，不能据此认定传感器已就绪、姿态已更新或数据一定是最新采样。该队列是 FIFO，任务每周期只取一项，也没有清空队列以保证取到最新项。

帧中没有传感器状态、采样时间戳或序号。上位机可以记录本地接收时间，并自行设置无数据超时，例如连续 0.5 s 未收到有效帧时提示通信超时；这一数值是应用建议，不是固件协议规定。

## 3. 数据帧格式

每帧固定为 10 字节，所有偏移从 0 开始：

```text
偏移    0   1    2     3     4     5     6     7     8    9
内容   55  AA  Yaw_L Yaw_H Pit_L Pit_H Rol_L Rol_H  SUM  0D
```

| 偏移 | 长度 / 字节 | 字段 | 说明 |
| ---: | ---: | --- | --- |
| 0 | 1 | 帧头 1 | 固定 `0x55` |
| 1 | 1 | 帧头 2 | 固定 `0xAA` |
| 2 | 2 | yaw | 偏航角，`int16`，小端，数值除以 2048 得到弧度 |
| 4 | 2 | pitch | 俯仰角，`int16`，小端，数值除以 2048 得到弧度 |
| 6 | 2 | roll | 横滚角，`int16`，小端，数值除以 2048 得到弧度 |
| 8 | 1 | SUM | 偏移 2～7 六个字节的累加和，保留低 8 位 |
| 9 | 1 | 帧尾 | 固定 `0x0D` |

该帧没有长度字段、命令字、版本字段或字符串结束符。`0x0D` 是单字节帧尾，没有附加 `0x0A`。

### 3.1 姿态解码

每个角度先读取低字节、再读取高字节，按二进制补码还原为有符号 16 位整数：

```text
u16 = low_byte | (high_byte << 8)
raw = u16                    当 u16 < 32768
raw = u16 - 65536            当 u16 >= 32768

angle_rad = raw / 2048.0
angle_deg = angle_rad × 180 / π
```

例如 `D0 FB` 对应 `0xFBD0`，有符号原始值为 `-1072`，解码后约为 `-29.9908°`。不能按无符号整数、浮点数字节或大端顺序解码。

发送端在编码前将角度归一化至 `[-π, π)`，再乘以 2048，按最接近整数取整；恰好位于半整数时向远离 0 的方向取整。编码函数还包含 `int16` 范围限幅，归一化后的正常角度不会触及该限幅。

分辨率为 `1/2048 rad ≈ 0.027976°`。由于量化，解码边界可能约为 `±180.0005°`，不能使用严格的 `[-180°, 180°)` 范围检查来拒绝这些合法边界值。角度跨越归一化边界时会产生约 360° 的数值跳变，计算角速度或连续轨迹时需要处理角度回绕。

### 3.2 校验规则

```python
expected_checksum = sum(frame[2:8]) & 0xFF
valid = (
    len(frame) == 10
    and frame[:2] == b"\x55\xAA"
    and frame[8] == expected_checksum
    and frame[9] == 0x0D
)
```

校验累加的是 **6 个无符号载荷字节**，不包括帧头、校验字节自身和帧尾。它是 8 位累加和，不是异或校验或 CRC，也不能检测所有数据错误。

## 4. 对照样例

输入姿态 `yaw=90°、pitch=-30°、roll=15°`，按当前编码规则得到：

| 字段 | 有符号原始值 | 16 位十六进制 | 线上字节顺序 |
| --- | ---: | --- | --- |
| yaw | 3217 | `0x0C91` | `91 0C` |
| pitch | -1072 | `0xFBD0` | `D0 FB` |
| roll | 536 | `0x0218` | `18 02` |

```text
SUM = (0x91 + 0x0C + 0xD0 + 0xFB + 0x18 + 0x02) & 0xFF = 0x82
完整帧：55 AA 91 0C D0 FB 18 02 82 0D
解码值：yaw≈90.0003°，pitch≈-29.9908°，roll≈14.9954°
```

全零姿态帧为：

```text
55 AA 00 00 00 00 00 00 00 0D
```

## 5. 连续字节流的接收方法

USB CDC 在上位机表现为连续字节流。一次 `read()` 可能得到半帧、一帧或多帧，USB 传输边界不能代替应用层分帧。

1. 将新收到的字节追加到缓存。
2. 搜索连续帧头 `55 AA`，丢弃帧头之前的字节。
3. 找不到完整帧头时，仅保留缓存末尾可能存在的单字节 `55`，等待下一次数据。
4. 找到帧头但剩余不足 10 字节时，保留缓存并继续接收。
5. 取前 10 字节，检查帧尾与校验和。
6. 检查通过后输出三个姿态角，删除这 10 字节，继续解析缓存中的下一帧。
7. 检查失败时仅丢弃一个字节，再重新搜索帧头，避免跳过后续有效帧。

载荷或校验字段中也可能出现 `55 AA`、`0D`。不要使用 `readline()`、按回车分包、文本解码或遇到任意 `55 AA` 就截断当前帧。断线重连时应清空旧接收缓存，重新寻找帧头。

## 6. Python 接收参考实现

将下面代码保存为 `receive_usb.py`。解析器仅使用 Python 标准库，实际打开串口时需要 `pyserial`。

```python
import argparse
import math
import struct
import time


class FrameParser:
    def __init__(self):
        self.buffer = bytearray()

    def feed(self, data):
        """输入任意分块的 bytes，返回 (yaw_rad, pitch_rad, roll_rad) 列表。"""
        self.buffer.extend(data)
        frames = []
        while True:
            index = self.buffer.find(b"\x55\xAA")
            if index < 0:
                # 保留跨两次 read() 的帧头首字节。
                keep = self.buffer[-1:] if self.buffer.endswith(b"\x55") else b""
                self.buffer.clear()
                self.buffer.extend(keep)
                break
            if index:
                del self.buffer[:index]
            if len(self.buffer) < 10:
                break

            frame = bytes(self.buffer[:10])
            if frame[9] != 0x0D or frame[8] != (sum(frame[2:8]) & 0xFF):
                del self.buffer[0]
                continue

            raw = struct.unpack_from("<hhh", frame, 2)
            frames.append(tuple(value / 2048.0 for value in raw))
            del self.buffer[:10]
        return frames


def main():
    import serial

    cli = argparse.ArgumentParser(description="接收 STM32 USB CDC 三轴姿态")
    cli.add_argument("port", help="例如 /dev/ttyACM0 或 COM5")
    args = cli.parse_args()
    parser = FrameParser()
    with serial.Serial(
        port=args.port, baudrate=115200, bytesize=serial.EIGHTBITS,
        parity=serial.PARITY_NONE, stopbits=serial.STOPBITS_ONE,
        timeout=0.2, xonxoff=False, rtscts=False, dsrdtr=False,
    ) as device:
        while True:
            data = device.read(min(device.in_waiting or 1, 4096))
            for yaw, pitch, roll in parser.feed(data):
                # 本地解析时间，不是 STM32 采样时间。
                print(
                    f"t={time.monotonic():.3f}s "
                    f"yaw={math.degrees(yaw):.4f} deg "
                    f"pitch={math.degrees(pitch):.4f} deg "
                    f"roll={math.degrees(roll):.4f} deg"
                )


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
```

运行方式：

```bash
# Linux / Jetson
python3 receive_usb.py /dev/ttyACM0

# Windows
python receive_usb.py COM5
```

此示例用于基础接收，按 Ctrl+C 退出。串口拔出或打开失败时会报错退出；正式上位机可增加串口异常处理、有效帧超时监测及重连逻辑，重连后新建解析器。

## 7. 联调排查与姿态使用

| 现象 | 检查内容 |
| --- | --- |
| 找不到虚拟串口 | 确认连接的是 STM32 USB 设备接口、USB 线支持数据、固件已运行 USB 初始化；检查系统枚举和驱动 |
| Linux 打开端口提示权限不足 | 检查设备文件所属组及当前用户串口访问权限，按系统要求配置权限后重新登录 |
| 端口被占用 | 关闭占用同一端口的串口助手或其他接收程序 |
| 设备已枚举但没有有效帧 | 确认固件运行 `AppJetsonUsbTask`，打印原始十六进制数据，核对是否为本手册的 10 字节格式 |
| 姿态数值非常大或负角度错误 | 核对小端、`int16` 补码、除以 2048；先解出弧度，再按需转为角度 |
| 持续帧尾或校验失败 | 核对帧尾偏移 9、校验偏移 8、校验范围 2～7，并检查是否错误使用旧的 8 字节解析器 |
| 上电后短时间全零，或姿态持续不变 | USB 帧没有传感器就绪标志；检查 BMI088 初始化及姿态队列是否更新，不能仅凭有效帧判断传感器正常 |
| 接收间隔超过 20 ms | 排查 USB 发送忙、连接状态、主机读取和调度；固件不会为每个遗漏周期补发 |
| 跨越 ±180° 时数值突变 | 发送前做了角度归一化，需要在应用中按用途处理回绕 |

姿态值来自 BMI088 的 Mahony 姿态解算。代码中陀螺仪轴标注为 roll 绕 x、pitch 绕 y、yaw 绕 z，但通信帧没有携带安装方向、外部参考坐标系、旋转顺序或零点配置。接入机器人、相机或 ROS 坐标系前，应结合传感器安装和解算实现，通过实际转动确认轴映射及正方向。当前解算调用的磁力计输入为零，不能将 yaw 直接当作已校准的绝对航向。

## 8. 源码依据与已有脚本差异

| 源文件 | 对应内容 |
| --- | --- |
| [jetson_usb_task.cpp](jetson_usb_task.cpp) | 20 ms 任务周期、姿态队列读取、周期发送调用 |
| [jetson_usb.hpp](jetson_usb.hpp) | 10 字节发送缓冲区定义 |
| [jetson_usb.cpp](jetson_usb.cpp) | 字段布局、小端编码、角度归一化、校验和、发送条件 |
| [usbd_desc.c](../../../USB_DEVICE/App/usbd_desc.c) | VID、PID、USB 产品名称 |
| [usbd_cdc_if.c](../../../USB_DEVICE/App/usbd_cdc_if.c) | 实际注册的 CDC 接口、线路设置处理和接收回调 |
| [bmi088_task.cpp](../bmi088/bmi088_task.cpp)、[bmi088.cpp](../bmi088/bmi088.cpp) | 姿态队列来源及姿态解算 |

截至本手册日期，[Debug/debug_usb_host.py](../../../Debug/debug_usb_host.py) 仍采用旧的 **8 字节 yaw/pitch** 格式，其帧尾位置、校验位置和校验范围均与当前 USB 固件不一致；不能直接用于验证当前 10 字节协议。即使旧脚本自身自检通过，也不能证明其兼容当前固件。接收端应采用本手册的三轴解析方式。

[原串口协议文档](../jetson/serial_comm.md) 的 10 字节载荷布局与当前 USB 上报一致，但其中 USART6 接口和串口波特率设置不适用于此 USB 链路。本手册不定义新的协议版本号，线上帧本身也不提供版本识别字段。
