# Tests

## asm

`asm` contains some RISC-V assembly program that can be compile with `as` from
the buildroot cross-compile toolchain:
```bash
../../buildroot/output/host/bin/riscv32-linux-as asm/strlen.S -o strlen.elf
```
This produces an ELF file which is not directly understandable by the emulator.
You must extract the binary instruction from the ELF this way:
```bash
../buildroot/output/host/bin/riscv32-linux-objcopy -O binary strlen.elf strlen
```

## json

[misterjdrg published](https://github.com/cnlohr/mini-rv32ima/issues/18) a list
of test cases to tests Rv64I instructions. In order to facilitate the test, the
file is split by instruction with `extract-test.js` into the `json` folder.

⚠️ Note that these test case were written for the 64 bits instruction set. Some
tests will then fail but this does not necessarily indicate a bug.

Here is the command to execute all the testable instructions:
```bash
zig build-exe -freference-trace test.zig && \
  ./test tests/json/jal tests/json/jalr tests/json/add tests/json/addi \
  tests/json/beq tests/json/lb tests/json/sb tests/json/lui tests/json/bne \
  tests/json/bltu tests/json/bgeu tests/json/lh tests/json/lw tests/json/lbu \
  tests/json/lhu tests/json/sh tests/json/sw tests/json/auipc tests/json/sltiu \
  tests/json/xori tests/json/ori tests/json/andi tests/json/sub \
  tests/json/sltu tests/json/xor tests/json/or tests/json/xor
```

## riscv-tests

These are the "official tests". The process to get those test is a little involved
and is encapuslated in a Dockerfile with some instructions.

Tests instructions:
```bash
zig build-exe -freference-trace test_elf.zig && ./test_elf $(find tests/riscv-tests/isa/ -executable -type f -name 'rv32ui-p-*')
```

Tests failure modes:
```bash
zig build-exe -freference-trace test_elf.zig && ./test_elf $(find tests/riscv-tests/isa/ -executable -type f -name 'rv32m*-p-*')
```
