# LUT BIN 文件格式说明

本文档说明 `convert_to_bin.m` 生成的 `lut.bin` 如何在 FPGA 或上位机中解析和使用。

## 1. 文件概览

该文件由 `1920 × 1080` 个 32 位数据组成：

```text
像素数量 = 1920 × 1080 = 2,073,600
每个像素 = 4 字节
文件大小 = 8,294,400 字节
```

每个 32 位数据对应一个输出图像像素，扫描顺序为逐行扫描：

```text
(x=0, y=0), (x=1, y=0), ... (x=1919, y=0),
(x=0, y=1), ...                         ,
...
(x=1919, y=1079)
```

第 `n` 个 32 位字对应的输出像素坐标为：

```text
y = n / 1920
x = n % 1920
```

其中 `/` 为整数除法，`%` 为取余。

## 2. 32 位数据位域

每个数据的位域如下：

```text
31                         21 20                       10 9       5 4       0
+----------------------------+---------------------------+---------+---------+
|       x_int（11 bit）       |       y_int（11 bit）      |x_frac(5)|y_frac(5)|
+----------------------------+---------------------------+---------+---------+
```

打包公式为：

```text
word[31:21] = x_int
word[20:10] = y_int
word[9:5]   = x_frac
word[4:0]   = y_frac
```

等价的组合公式：

```c
word = (x_int << 21) | (y_int << 10) | (x_frac << 5) | y_frac;
```

字段含义：

- `x_int`：原始输入图像中需要采样的整数 x 坐标。
- `y_int`：原始输入图像中需要采样的整数 y 坐标。
- `x_frac`：x 方向小数部分，5 位定点数，缩放因子为 `32`。
- `y_frac`：y 方向小数部分，5 位定点数，缩放因子为 `32`。

因此实际采样坐标约为：

```text
x_source = x_int + x_frac / 32
y_source = y_int + y_frac / 32
```

## 3. 坐标基准

`undistort_image.m` 内部使用 MATLAB 的 1 基坐标，当前 `convert_to_bin.m` 中：

```matlab
convert_to_zero_based = false;
```

因此默认生成的 BIN 中，`x_int` 和 `y_int` 是 1 基坐标。例如：

```text
MATLAB 坐标 (1, 1) → BIN 中 x_int=1, y_int=1
```

如果 FPGA 图像存储器使用 0 基地址，应在 `convert_to_bin.m` 中改为：

```matlab
convert_to_zero_based = true;
```

此时：

```text
MATLAB 坐标 (1, 1) → BIN 中 x_int=0, y_int=0
```

FPGA 端必须与该设置保持一致，不能一边使用 1 基、一边使用 0 基。

## 4. 字节序

脚本默认使用：

```matlab
byte_order = "ieee-le";
```

即每个 32 位字按小端格式写入文件。假设某个字为：

```text
word = 0x12345678
```

文件中的 4 个连续字节为：

```text
78 56 34 12
```

如果 FPGA Flash 控制器按照大端字节顺序读取，需要将脚本改为：

```matlab
byte_order = "ieee-be";
```

或者在 FPGA 读取 4 个字节后进行字节交换。注意：这里的字节序与位域定义是两个不同问题；位域始终按 32 位 `word[31:0]` 定义。

## 5. FPGA 端解析

从 Flash 读取一个 32 位 `word` 后，可按如下方式取出字段：

```verilog
wire [10:0] x_int  = word[31:21];
wire [10:0] y_int  = word[20:10];
wire [4:0]  x_frac = word[9:5];
wire [4:0]  y_frac = word[4:0];
```

如果 FPGA 需要 0 基坐标，而 BIN 使用的是默认 1 基坐标：

```verilog
wire [10:0] x_addr = x_int - 11'd1;
wire [10:0] y_addr = y_int - 11'd1;
```

输入图像一行宽度为 `1920` 时，整数像素地址为：

```verilog
pixel_addr = y_addr * 1920 + x_addr;
```

双线性插值的四个权重可以由两个 5 位小数部分计算，不需要在 BIN 中额外存储四个权重。令：

```text
fx = x_frac
fy = y_frac
```

则四个权重（未除以 1024）为：

```text
w00 = (32-fx) * (32-fy)   // 左上/整数坐标位置
w10 =     fx  * (32-fy)   // 右上
w01 = (32-fx) *     fy    // 左下
w11 =     fx  *     fy    // 右下
```

插值结果为：

```text
value = (p00*w00 + p10*w10 + p01*w01 + p11*w11) >> 10
```

其中 `p00、p10、p01、p11` 是输入图像四个相邻像素。坐标越界时应进行边界限制（clamp）或使用项目中约定的边界策略。

## 6. C/C++ 解析示例

```c
#include <stdint.h>

uint32_t word;
fread(&word, sizeof(word), 1, fp);  // 仅适用于主机也是小端

uint16_t x_int  = (word >> 21) & 0x7ff;
uint16_t y_int  = (word >> 10) & 0x7ff;
uint8_t  x_frac = (word >> 5)  & 0x1f;
uint8_t  y_frac =  word        & 0x1f;

uint32_t w00 = (32 - x_frac) * (32 - y_frac);
uint32_t w10 =      x_frac  * (32 - y_frac);
uint32_t w01 = (32 - x_frac) *      y_frac;
uint32_t w11 =      x_frac  *      y_frac;
```

如果主机字节序与 BIN 不同，应先将 4 个字节组装为正确的 32 位 `word`，再执行上述移位操作。

## 7. MATLAB 端验证示例

```matlab
fid = fopen("lut.bin", "r", "ieee-le");
words = fread(fid, inf, "uint32=>uint32");
fclose(fid);

assert(numel(words) == 1920 * 1080);

x_int  = bitand(bitshift(words, -21), uint32(2047));
y_int  = bitand(bitshift(words, -10), uint32(2047));
x_frac = bitand(bitshift(words, -5),  uint32(31));
y_frac = bitand(words, uint32(31));

% 第 n 个字对应的输出坐标
n = uint32(0);
x = mod(n, 1920);
y = floor(double(n) / 1920);
```

## 8. 生成和烧录流程

1. 运行 `undistort_image` 或 `main.m`，生成新的 `lut.mat`。
2. 确认 `convert_to_bin.m` 中的坐标基准和字节序与 FPGA 设计一致。
3. 运行 `convert_to_bin.m`，生成 `lut.bin`。
4. 检查文件大小应为 `8,294,400` 字节。
5. 将 BIN 写入 Flash，并让 FPGA 按连续 32 位字读取。

建议在首次烧录前，用 MATLAB 或 Python 读取 BIN 的前几个字，与原始 `lut.mat` 对比，确认字节序、坐标基准和像素扫描顺序均正确。
