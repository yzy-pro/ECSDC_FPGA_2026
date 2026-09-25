# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "pyserial>=3.5",
# ]
# ///

"""PC端UART收发回环测试脚本。

使用示例：
    uv run Debug/uart_loop_test.py --list
    uv run Debug/uart_loop_test.py --port COM15
    uv run Debug/uart_loop_test.py --port COM15 --count 1000 --verbose
"""

from __future__ import annotations

import argparse
import random
import sys
import time
from dataclasses import dataclass

import serial
from serial.tools import list_ports


DEFAULT_BAUD_RATE = 921_600
DEFAULT_TIMEOUT = 1.0
DEFAULT_COUNT = 100


@dataclass
class TestStatistics:
    """保存本次回环测试的统计信息。"""

    total: int = 0
    passed: int = 0
    failed: int = 0
    timeout: int = 0
    elapsed: float = 0.0


def positive_int(value: str) -> int:
    """解析大于零的整数命令行参数。"""

    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("必须为大于零的整数")
    return number


def non_negative_float(value: str) -> float:
    """解析大于等于零的浮点数命令行参数。"""

    number = float(value)
    if number < 0:
        raise argparse.ArgumentTypeError("必须为大于等于零的数")
    return number


def build_argument_parser() -> argparse.ArgumentParser:
    """创建命令行参数解析器。"""

    parser = argparse.ArgumentParser(
        description="通过PC串口测试FPGA UART收发回环功能。",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--port",
        help="串口名称，例如COM15；省略时若只检测到一个串口则自动选择",
    )
    parser.add_argument(
        "--baud",
        type=positive_int,
        default=DEFAULT_BAUD_RATE,
        help="串口波特率",
    )
    parser.add_argument(
        "--count",
        type=positive_int,
        default=DEFAULT_COUNT,
        help="发送并校验的字节数量",
    )
    parser.add_argument(
        "--timeout",
        type=non_negative_float,
        default=DEFAULT_TIMEOUT,
        help="等待每个回环字节的超时时间，单位为秒",
    )
    parser.add_argument(
        "--interval",
        type=non_negative_float,
        default=0.0,
        help="每轮测试完成后的额外间隔，单位为秒",
    )
    parser.add_argument(
        "--seed",
        type=int,
        help="随机数种子；指定后可以复现相同的测试数据",
    )
    parser.add_argument(
        "--pattern",
        choices=("random", "increment", "fixed"),
        default="random",
        help="测试数据模式：随机、递增或固定字节",
    )
    parser.add_argument(
        "--value",
        type=lambda text: int(text, 0),
        default=0x55,
        help="fixed模式发送的字节，支持0x55等写法",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="逐字节打印发送和接收结果",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="列出可用串口后退出",
    )
    return parser


def available_ports() -> list[list_ports.ListPortInfo]:
    """返回当前系统检测到的串口列表。"""

    return sorted(list_ports.comports(), key=lambda item: item.device)


def print_ports(ports: list[list_ports.ListPortInfo]) -> None:
    """打印串口设备及其描述信息。"""

    if not ports:
        print("未检测到可用串口。")
        return

    print("检测到以下串口：")
    for port in ports:
        details = port.description or "无设备描述"
        hardware_id = port.hwid or "无硬件标识"
        print(f"  {port.device:<8} {details} [{hardware_id}]")


def select_port(requested_port: str | None) -> str:
    """使用显式参数或自动检测结果选择串口。"""

    if requested_port:
        return requested_port

    ports = available_ports()
    if len(ports) == 1:
        selected = ports[0].device
        print(f"自动选择唯一检测到的串口：{selected}")
        return selected

    print_ports(ports)
    if not ports:
        raise RuntimeError("请连接串口设备，或使用--port指定串口。")
    raise RuntimeError("检测到多个串口，请使用--port明确指定测试端口。")


def build_test_byte(
    index: int,
    pattern: str,
    fixed_value: int,
    random_source: random.Random,
) -> int:
    """根据指定的数据模式生成一个测试字节。"""

    if pattern == "increment":
        return index & 0xFF
    if pattern == "fixed":
        return fixed_value & 0xFF
    return random_source.randrange(256)


def read_one_byte(port: serial.Serial, timeout: float) -> bytes:
    """在给定总超时时间内读取一个字节。"""

    deadline = time.monotonic() + timeout
    while True:
        data = port.read(1)
        if data:
            return data
        if time.monotonic() >= deadline:
            return b""


def run_loopback_test(
    port: serial.Serial,
    count: int,
    timeout: float,
    interval: float,
    pattern: str,
    fixed_value: int,
    seed: int | None,
    verbose: bool,
) -> TestStatistics:
    """执行逐字节UART回环测试并返回统计结果。"""

    statistics = TestStatistics(total=count)
    random_source = random.Random(seed)
    started_at = time.monotonic()

    # 丢弃打开串口前后可能残留的数据，避免影响第一次比较。
    port.reset_input_buffer()
    port.reset_output_buffer()

    for index in range(count):
        transmitted = build_test_byte(index, pattern, fixed_value, random_source)
        port.write(bytes((transmitted,)))
        port.flush()

        received_data = read_one_byte(port, timeout)
        if not received_data:
            statistics.failed += 1
            statistics.timeout += 1
            print(
                f"[{index + 1:>6}/{count}] 超时："
                f"发送0x{transmitted:02X}，未收到回环数据"
            )
        else:
            received = received_data[0]
            if received == transmitted:
                statistics.passed += 1
                if verbose:
                    print(
                        f"[{index + 1:>6}/{count}] 通过："
                        f"发送0x{transmitted:02X}，接收0x{received:02X}"
                    )
            else:
                statistics.failed += 1
                print(
                    f"[{index + 1:>6}/{count}] 失败："
                    f"发送0x{transmitted:02X}，接收0x{received:02X}"
                )

        if interval > 0:
            time.sleep(interval)

    statistics.elapsed = time.monotonic() - started_at
    return statistics


def print_summary(statistics: TestStatistics) -> None:
    """打印回环测试汇总结果。"""

    success_rate = (
        statistics.passed / statistics.total * 100
        if statistics.total
        else 0.0
    )
    throughput = (
        statistics.total / statistics.elapsed
        if statistics.elapsed > 0
        else 0.0
    )

    print("\n========== UART回环测试结果 ==========")
    print(f"测试总数：{statistics.total}")
    print(f"通过数量：{statistics.passed}")
    print(f"失败数量：{statistics.failed}")
    print(f"超时数量：{statistics.timeout}")
    print(f"成功率  ：{success_rate:.2f}%")
    print(f"耗时    ：{statistics.elapsed:.3f}秒")
    print(f"测试速率：{throughput:.2f}字节/秒")
    print("测试结论：" + ("通过" if statistics.failed == 0 else "失败"))


def main() -> int:
    """解析参数、打开串口并执行测试。"""

    parser = build_argument_parser()
    arguments = parser.parse_args()

    if not 0 <= arguments.value <= 0xFF:
        parser.error("--value必须在0x00到0xFF之间")

    if arguments.list:
        print_ports(available_ports())
        return 0

    try:
        port_name = select_port(arguments.port)
        print(
            f"打开串口 {port_name}：{arguments.baud} baud，"
            "8位数据位，无校验，1位停止位"
        )
        print(
            f"测试数量：{arguments.count}，数据模式：{arguments.pattern}，"
            f"单字节超时：{arguments.timeout:.3f}秒"
        )

        with serial.Serial(
            port=port_name,
            baudrate=arguments.baud,
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE,
            timeout=min(arguments.timeout, 0.05),
            write_timeout=arguments.timeout,
            xonxoff=False,
            rtscts=False,
            dsrdtr=False,
        ) as uart_port:
            statistics = run_loopback_test(
                port=uart_port,
                count=arguments.count,
                timeout=arguments.timeout,
                interval=arguments.interval,
                pattern=arguments.pattern,
                fixed_value=arguments.value,
                seed=arguments.seed,
                verbose=arguments.verbose,
            )

        print_summary(statistics)
        return 0 if statistics.failed == 0 else 1

    except serial.SerialException as error:
        print(f"串口操作失败：{error}", file=sys.stderr)
        return 2
    except RuntimeError as error:
        print(f"错误：{error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("\n用户中止测试。", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
