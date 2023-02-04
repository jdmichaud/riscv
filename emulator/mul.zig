const std = @import("std");
const riscv = @import("riscv.zig");
const debug = @import("debug.zig");

const Instruction = riscv.Instruction;
const InstructionFormat = riscv.InstructionFormat;
const nullHandler = riscv.nullHandler;
const RiscVCPU = riscv.RiscVCPU;
const RiscError = riscv.RiscError;
const fetchR = riscv.fetchR;

const register_names = debug.register_names;

// riscv-spec-20191213.pdf Chapter 7 "M" Standard Extension for Integer Multiplication and Division
pub const m_extension_set = [_]Instruction{
  .{ .name = "MUL",     .opcode = 0b0110011, .funct3 = 0b000, .funct7 = 0b0000001, .format = InstructionFormat.R, .handler = mul },
  .{ .name = "MULH",    .opcode = 0b0110011, .funct3 = 0b001, .funct7 = 0b0000001, .format = InstructionFormat.R, .handler = mulh },
  .{ .name = "MULHSU",  .opcode = 0b0110011, .funct3 = 0b010, .funct7 = 0b0000001, .format = InstructionFormat.R, .handler = mulhsu },
  .{ .name = "MULHU",   .opcode = 0b0110011, .funct3 = 0b011, .funct7 = 0b0000001, .format = InstructionFormat.R, .handler = mulhu },
  .{ .name = "DIV",     .opcode = 0b0110011, .funct3 = 0b100, .funct7 = 0b0000001, .format = InstructionFormat.R, .handler = div },
  .{ .name = "DIVU",    .opcode = 0b0110011, .funct3 = 0b101, .funct7 = 0b0000001, .format = InstructionFormat.R, .handler = divu },
  .{ .name = "REM",     .opcode = 0b0110011, .funct3 = 0b110, .funct7 = 0b0000001, .format = InstructionFormat.R, .handler = rem },
  .{ .name = "REMU",    .opcode = 0b0110011, .funct3 = 0b111, .funct7 = 0b0000001, .format = InstructionFormat.R, .handler = remu },
};

fn mul(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: mul {s}, {s}(0x{x:0>8}), {s}(0x{x:0>8})", .{
    cpu.pc, register_names[params.rd], register_names[params.rs1], cpu.rx[params.rs1],
    register_names[params.rs2], cpu.rx[params.rs2],
  });
  cpu.rx[params.rd] = cpu.rx[params.rs1] *% cpu.rx[params.rs2];
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn mulh(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: mulh {s}, {s}(0x{x:0>8}), {s}(0x{x:0>8})", .{
    cpu.pc, register_names[params.rd], register_names[params.rs1], cpu.rx[params.rs1],
    register_names[params.rs2], cpu.rx[params.rs2],
  });
  const result: u64 = @bitCast(u64,
    @intCast(i64, @bitCast(i32, cpu.rx[params.rs1])) *%
    @intCast(i64, @bitCast(i32, cpu.rx[params.rs2]))
  );
  cpu.rx[params.rd] = @intCast(u32, (result & 0xFFFFFFFF00000000) >> 32);
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn mulhsu(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: mulhsu {s}, {s}(0x{x:0>8}), {s}(0x{x:0>8})", .{
    cpu.pc, register_names[params.rd], register_names[params.rs1], cpu.rx[params.rs1],
    register_names[params.rs2], cpu.rx[params.rs2],
  });
  const rs1signed: u64 = @bitCast(u64, @intCast(i64, @bitCast(i32, cpu.rx[params.rs1])));
  const rs2unsigned: u64 = @intCast(u64, @bitCast(u32, cpu.rx[params.rs2]));
  const result: u64 = rs1signed *% rs2unsigned;
  cpu.rx[params.rd] = @intCast(u32, (result & 0xFFFFFFFF00000000) >> 32);
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn mulhu(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: mulhu {s}, {s}(0x{x:0>8}), {s}(0x{x:0>8})", .{
    cpu.pc, register_names[params.rd], register_names[params.rs1], cpu.rx[params.rs1],
    register_names[params.rs2], cpu.rx[params.rs2],
  });
  const result: u64 = @intCast(u64, cpu.rx[params.rs1]) *% @intCast(u64, cpu.rx[params.rs2]);
  cpu.rx[params.rd] = @intCast(u32, result >> 32);
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn div(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: div {s}, {s}(0x{x:0>8}), {s}(0x{x:0>8})", .{
    cpu.pc, register_names[params.rd], register_names[params.rs1], cpu.rx[params.rs1],
    register_names[params.rs2], cpu.rx[params.rs2],
  });
  if (cpu.rx[params.rs2] != 0) {
    const res: i64 = @divTrunc(
      @intCast(i64, @bitCast(i32, cpu.rx[params.rs1])),
      @intCast(i64, @bitCast(i32, cpu.rx[params.rs2]))
    );
    cpu.rx[params.rd] = @intCast(u32, res & 0x00000000FFFFFFFF);
  } else {
    cpu.rx[params.rd] = 0xFFFFFFFF;
  }
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn divu(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: divu {s}, {s}(0x{x:0>8}), {s}(0x{x:0>8})", .{
    cpu.pc, register_names[params.rd], register_names[params.rs1], cpu.rx[params.rs1],
    register_names[params.rs2], cpu.rx[params.rs2],
  });
  if (cpu.rx[params.rs2] != 0) {
    cpu.rx[params.rd] = cpu.rx[params.rs1] / cpu.rx[params.rs2];
  } else {
    cpu.rx[params.rd] = 0xFFFFFFFF;
  }
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn rem(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: rem {s}, {s}(0x{x:0>8}), {s}(0x{x:0>8})", .{
    cpu.pc, register_names[params.rd], register_names[params.rs1], cpu.rx[params.rs1],
    register_names[params.rs2], cpu.rx[params.rs2],
  });
  if (cpu.rx[params.rs2] != 0) {
    const res: i64 = @rem(
      @intCast(i64, @bitCast(i32, cpu.rx[params.rs1])),
      @intCast(i64, @bitCast(i32, cpu.rx[params.rs2]))
    );
    cpu.rx[params.rd] = @intCast(u32, res & 0x00000000FFFFFFFF);
  } else {
    cpu.rx[params.rd] = cpu.rx[params.rs1];
  }
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn remu(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: remu {s}, {s}(0x{x:0>8}), {s}(0x{x:0>8})", .{
    cpu.pc, register_names[params.rd], register_names[params.rs1], cpu.rx[params.rs1],
    register_names[params.rs2], cpu.rx[params.rs2],
  });
  if (cpu.rx[params.rs2] != 0) {
    cpu.rx[params.rd] = cpu.rx[params.rs1] % cpu.rx[params.rs2];
  } else {
    cpu.rx[params.rd] = cpu.rx[params.rs1];
  }
  cpu.rx[0] = 0;
  cpu.pc += 4;}
