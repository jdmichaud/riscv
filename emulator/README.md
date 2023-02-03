### Resources

Some RISCV assembly program: https://marz.utk.edu/my-courses/cosc230/book/example-risc-v-assembly-programs/

### Tools

https://github.com/cnlohr/mini-rv32ima provides a buildroot that will build the gcc toolchain for RISCV in
```
mini-rv32ima/buildroot/output/host/bin/riscv32-buildroot-linux-uclibc-*
```

Use `riscv32-buildroot-linux-uclibc-as` to compile barebone assembly program.

### Commands

Prepare the toolchain to compile to RISC-V
```bash
make toolchain
```

Compile the emulator:
```bash
zig build-exe -freference-trace riscv.zig
```

Compile device tree source:
```bash
dtc mark1.dts -o mark1.dtb
```

(Try to) Execute linux:
```bash
./riscv --dtb mark1.dtb ../buildroot/output/images/Image
```

Assemble to RISC-V:
```bash
../buildroot/output/host/bin/riscv32-buildroot-linux-uclibc-as tests/strlen.S -r strlen.elf
```

Extract binary instruction from ELF:
```bash
../buildroot/output/host/bin/riscv32-buildroot-linux-uclibc-objcopy -O binary strlen.elf strlen
```

Disassemble RISC-V binary:
```bash
../buildroot/output/host/bin/riscv32-buildroot-linux-uclibc-objdump --disassemble strlen.elf
```

# Tests

In `tests` you will find:
- A bunch of risc-v simple assembly programs.
- A set of test cases from misterjdrg: https://github.com/cnlohr/mini-rv32ima/issues/18#issue-1497937724


DOES NOT WORK
  - some makefile use -nostdlib but are using malloc ??
  - XLEN=32 not taken into account by autoconf and @XLEN@
To generate test:
```bash
export RISCV=$(pwd)/buildroot/output/host/bin/
export XLEN=32
export target_alias=riscv32-linux
git clone https://github.com/riscv/riscv-tests
cd riscv-tests
git submodule update --init --recursive
autoconf
./configure --prefix=/tmp/riscv-tests/target
PATH=$PATH:$RISCV make
make install
```