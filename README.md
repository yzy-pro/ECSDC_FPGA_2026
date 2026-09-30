pds工具安装路径：E:\work\pango\PDS_2025.2-ads\bin
modelsim安装路径：D:\pango\modeltech64_10.6e\win64

## Flash 校验值发送工程

板级顶层为 `Designs/flash_read_top.v`，使用板载 50 MHz 时钟和低有效复位。从 Flash 地址 `0x202000` 以 `0x0B` 单线快速读取 32 字节 SHA-256 摘要，经 CP2102 发送一帧：`AA 55`、32 字节原始摘要、摘要字节异或校验、`0D`。串口为 921600 baud、8N1。单线读取只从 Flash IO1 输入数据，不依赖 Quad Enable 位。管脚约束分别见 `Constraints/system`、`Constraints/flash`、`Constraints/cp2102` 和 `Constraints/led`。

PDS 工程入口为 `Build/flash_read_top.tcl`，包含所需 RTL、`ipcore/cp2102_tx_fifo` 和约束；执行后会在 `.tmp_pds_build` 生成工程并完成编译、综合、设备映射。本机可用的 PDS 路径为 `D:\pango\PDS_2025.2-ads\bin`。

ModelSim 完整链路测试为 `Tests/tb_flash_read_top.v`，检查 QSPI 命令和地址、32 字节摘要、UART 帧与片选释放。测试平台内的 FIFO 是与 IP 接口一致的行为模型；实际 PDS 综合使用生成的 FIFO IP。

重建位流后，在 PDS Fabric Configuration 命令行生成 `.sfc`，并将 `.sfc` 烧录到 Flash。用户数据地址 `00202000` 对应 RTL 的 `0x202000`。可在 PowerShell 中执行：

```powershell
& 'D:\pango\PDS_2025.2-ads\bin\cdt_cfg_shell.exe' -file (Resolve-Path 'Build/generate_flash_sfc.tcl').Path
```

等价的 Fabric Configuration 命令为：

```tcl
cfg_gen_sfc -device_name W25Q128Q -opcode 11 -sbit_start_address 0x00000000 -sbit D:/pango/works/ECSDC_FPGA_2026/prj_tasks/pnr_1/generate_bitstream/flash_read_top.sbit -user_address_list { 00202000 } -file_list { D:/pango/works/ECSDC_FPGA_2026/Debug/lut_checksum.bin }
```
