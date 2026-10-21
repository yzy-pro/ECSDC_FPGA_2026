openocd -f interface/jlink.cfg \
    -c "transport select swd" \
    -f target/stm32f4x.cfg \
    -c "program ./build/Debug/master.elf verify reset exit"
# 第一行选烧录器
# 第二行选目标芯片
# 第三行选烧录文件
