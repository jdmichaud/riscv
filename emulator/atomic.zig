const std = @import("std");
const riscv = @import("riscv.zig");
const debug = @import("debug.zig");

const Instruction = riscv.Instruction;
const InstructionFormat = riscv.InstructionFormat;
const nullHandler = riscv.nullHandler;
const RiscVCPU = riscv.RiscVCPU;
const RiscError = riscv.RiscError;
const fetchR = riscv.fetchR;
const memwrite = riscv.memwrite;
const memread = riscv.memread;
const instructionAddressMisaligned = riscv.instructionAddressMisaligned;

const register_names = debug.register_names;

// riscv-spec-20191213.pdf Chapter 8 "A" Standard Extension for Atomic Instruction
// funct7 is only 5 bits here with bit 0 and 1 taking some parameter values.
// As a consequence we have to quadruple each instruction with 00, 01, 10 and 11
// as suffixes.
pub const a_extension_set = [_]Instruction{
  .{ .name = "LR.W",      .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0001000, .format = InstructionFormat.R, .handler = lrw },
  .{ .name = "LR.W",      .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0001001, .format = InstructionFormat.R, .handler = lrw },
  .{ .name = "LR.W",      .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0001010, .format = InstructionFormat.R, .handler = lrw },
  .{ .name = "LR.W",      .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0001011, .format = InstructionFormat.R, .handler = lrw },
  .{ .name = "SC.W",      .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0001100, .format = InstructionFormat.R, .handler = swc },
  .{ .name = "SC.W",      .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0001101, .format = InstructionFormat.R, .handler = swc },
  .{ .name = "SC.W",      .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0001110, .format = InstructionFormat.R, .handler = swc },
  .{ .name = "SC.W",      .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0001111, .format = InstructionFormat.R, .handler = swc },
  .{ .name = "AMOSWAP.W", .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0000100, .format = InstructionFormat.R, .handler = amoswapw },
  .{ .name = "AMOSWAP.W", .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0000101, .format = InstructionFormat.R, .handler = amoswapw },
  .{ .name = "AMOSWAP.W", .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0000110, .format = InstructionFormat.R, .handler = amoswapw },
  .{ .name = "AMOSWAP.W", .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0000111, .format = InstructionFormat.R, .handler = amoswapw },
  .{ .name = "AMOADD.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0000000, .format = InstructionFormat.R, .handler = amoaddw },
  .{ .name = "AMOADD.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0000001, .format = InstructionFormat.R, .handler = amoaddw },
  .{ .name = "AMOADD.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0000010, .format = InstructionFormat.R, .handler = amoaddw },
  .{ .name = "AMOADD.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0000011, .format = InstructionFormat.R, .handler = amoaddw },
  .{ .name = "AMOXOR.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0010000, .format = InstructionFormat.R, .handler = amoxorw },
  .{ .name = "AMOXOR.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0010001, .format = InstructionFormat.R, .handler = amoxorw },
  .{ .name = "AMOXOR.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0010010, .format = InstructionFormat.R, .handler = amoxorw },
  .{ .name = "AMOXOR.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0010011, .format = InstructionFormat.R, .handler = amoxorw },
  .{ .name = "AMOAND.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0110000, .format = InstructionFormat.R, .handler = amoandw },
  .{ .name = "AMOAND.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0110001, .format = InstructionFormat.R, .handler = amoandw },
  .{ .name = "AMOAND.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0110010, .format = InstructionFormat.R, .handler = amoandw },
  .{ .name = "AMOAND.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0110011, .format = InstructionFormat.R, .handler = amoandw },
  .{ .name = "AMOOR.W",   .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0100000, .format = InstructionFormat.R, .handler = amoorw },
  .{ .name = "AMOOR.W",   .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0100001, .format = InstructionFormat.R, .handler = amoorw },
  .{ .name = "AMOOR.W",   .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0100010, .format = InstructionFormat.R, .handler = amoorw },
  .{ .name = "AMOOR.W",   .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0100011, .format = InstructionFormat.R, .handler = amoorw },
  .{ .name = "AMOMIN.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1000000, .format = InstructionFormat.R, .handler = amominw },
  .{ .name = "AMOMIN.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1000001, .format = InstructionFormat.R, .handler = amominw },
  .{ .name = "AMOMIN.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1000010, .format = InstructionFormat.R, .handler = amominw },
  .{ .name = "AMOMIN.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1000011, .format = InstructionFormat.R, .handler = amominw },
  .{ .name = "AMOMAX.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1010000, .format = InstructionFormat.R, .handler = amomaxw },
  .{ .name = "AMOMAX.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1010001, .format = InstructionFormat.R, .handler = amomaxw },
  .{ .name = "AMOMAX.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1010010, .format = InstructionFormat.R, .handler = amomaxw },
  .{ .name = "AMOMAX.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1010011, .format = InstructionFormat.R, .handler = amomaxw },
  .{ .name = "AMOMINU.W", .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1100000, .format = InstructionFormat.R, .handler = amominuw },
  .{ .name = "AMOMINU.W", .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1100001, .format = InstructionFormat.R, .handler = amominuw },
  .{ .name = "AMOMINU.W", .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1100010, .format = InstructionFormat.R, .handler = amominuw },
  .{ .name = "AMOMINU.W", .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1100011, .format = InstructionFormat.R, .handler = amominuw },
  .{ .name = "AMOMAXU.W", .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1110000, .format = InstructionFormat.R, .handler = amomaxuw },
  .{ .name = "AMOMAXU.W", .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1110001, .format = InstructionFormat.R, .handler = amomaxuw },
  .{ .name = "AMOMAXU.W", .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1110010, .format = InstructionFormat.R, .handler = amomaxuw },
  .{ .name = "AMOMAXU.W", .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1110011, .format = InstructionFormat.R, .handler = amomaxuw },
};

// riscv-spec-20191213.pdf Chapter 8.2 Load-Reserved/Store-Conditional Instructions
// TODO: Not sure if we doing the right thing here
var reservation_set: bool = false;

fn lrw(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: lrw {s}, {s}(0x{x:0>8}), {s}(0x{x:0>8})", .{
    cpu.pc, register_names[params.rd], register_names[params.rs1], cpu.rx[params.rs1],
    register_names[params.rs2], cpu.rx[params.rs2],
  });
  const address = cpu.rx[params.rs1];
  if (address % @sizeOf(u32) == 0) {
    cpu.rx[params.rd] = memread(u32, cpu, address);
    reservation_set = true;
    cpu.rx[0] = 0;
    cpu.pc += 4;
  } else {
    instructionAddressMisaligned(address, cpu);
  }
}

fn swc(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: swc {s}, {s}(0x{x:0>8}), {s}(0x{x:0>8})", .{
    cpu.pc, register_names[params.rd], register_names[params.rs1], cpu.rx[params.rs1],
    register_names[params.rs2], cpu.rx[params.rs2],
  });
  const address = cpu.rx[params.rs1];
  if (address % @sizeOf(u32) == 0) {
    if (reservation_set) {
      memwrite(u32, cpu, address, cpu.rx[params.rs2]);
      cpu.rx[params.rd] = 0;
      reservation_set = false;
    } else {
      cpu.rx[params.rd] = 1; // Non zero value
    }
    cpu.rx[0] = 0;
    cpu.pc += 4;
  } else {
    instructionAddressMisaligned(address, cpu);
  }
}

fn amoswapw(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: amoswapw {s}, {s}(0x{x:0>8}), {s}(0x{x:0>8})", .{
    cpu.pc, register_names[params.rd], register_names[params.rs1], cpu.rx[params.rs1],
    register_names[params.rs2], cpu.rx[params.rs2],
  });
  const address = cpu.rx[params.rs1];
  if (address % @sizeOf(u32) == 0) {
    cpu.rx[params.rd] = memread(u32, cpu, address);
    memwrite(u32, cpu, address, cpu.rx[params.rs2]);
    cpu.rx[0] = 0;
    cpu.pc += 4;
  } else {
    instructionAddressMisaligned(address, cpu);
  }
}

fn amoaddw(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: amoaddw {s}, {s}(0x{x:0>8}), {s}(0x{x:0>8})", .{
    cpu.pc, register_names[params.rd], register_names[params.rs1], cpu.rx[params.rs1],
    register_names[params.rs2], cpu.rx[params.rs2],
  });
  const address = cpu.rx[params.rs1];
  if (address % @sizeOf(u32) == 0) {
    cpu.rx[params.rd] = memread(u32, cpu, address);
    const signed_rd = @bitCast(i32, cpu.rx[params.rd]);
    const signed_rs2 = @bitCast(i32, cpu.rx[params.rs2]);
    memwrite(u32, cpu, address, @bitCast(u32, signed_rd +% signed_rs2));
    cpu.rx[0] = 0;
    cpu.pc += 4;
  } else {
    instructionAddressMisaligned(address, cpu);
  }
}

fn amoxorw(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: amoxorw {s}, {s}(0x{x:0>8}), {s}(0x{x:0>8})", .{
    cpu.pc, register_names[params.rd], register_names[params.rs1], cpu.rx[params.rs1],
    register_names[params.rs2], cpu.rx[params.rs2],
  });
  const address = cpu.rx[params.rs1];
  if (address % @sizeOf(u32) == 0) {
    cpu.rx[params.rd] = memread(u32, cpu, address);
    const result = cpu.rx[params.rd] ^ cpu.rx[params.rs2];
    memwrite(u32, cpu, address, result);
    cpu.rx[0] = 0;
    cpu.pc += 4;
  } else {
    instructionAddressMisaligned(address, cpu);
  }
}

fn amoandw(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: amoandw {s}, {s}(0x{x:0>8}), {s}(0x{x:0>8})", .{
    cpu.pc, register_names[params.rd], register_names[params.rs1], cpu.rx[params.rs1],
    register_names[params.rs2], cpu.rx[params.rs2],
  });
  const address = cpu.rx[params.rs1];
  if (address % @sizeOf(u32) == 0) {
    cpu.rx[params.rd] = memread(u32, cpu, address);
    const result = cpu.rx[params.rd] & cpu.rx[params.rs2];
    memwrite(u32, cpu, address, result);
    cpu.rx[0] = 0;
    cpu.pc += 4;
  } else {
    instructionAddressMisaligned(address, cpu);
  }
}

fn amoorw(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: amoorw {s}, {s}(0x{x:0>8}), {s}(0x{x:0>8})", .{
    cpu.pc, register_names[params.rd], register_names[params.rs1], cpu.rx[params.rs1],
    register_names[params.rs2], cpu.rx[params.rs2],
  });
  const address = cpu.rx[params.rs1];
  if (address % @sizeOf(u32) == 0) {
    cpu.rx[params.rd] = memread(u32, cpu, address);
    const result = cpu.rx[params.rd] | cpu.rx[params.rs2];
    memwrite(u32, cpu, address, result);
    cpu.rx[0] = 0;
    cpu.pc += 4;
  } else {
    instructionAddressMisaligned(address, cpu);
  }
}

fn amominw(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: amominw {s}, {s}(0x{x:0>8}), {s}(0x{x:0>8})", .{
    cpu.pc, register_names[params.rd], register_names[params.rs1], cpu.rx[params.rs1],
    register_names[params.rs2], cpu.rx[params.rs2],
  });
  const address = cpu.rx[params.rs1];
  if (address % @sizeOf(u32) == 0) {
    cpu.rx[params.rd] = memread(u32, cpu, address);
    const result = @bitCast(u32, std.math.min(
      @bitCast(i32, cpu.rx[params.rd]),
      @bitCast(i32, cpu.rx[params.rs2])
    ));
    memwrite(u32, cpu, address, result);
    cpu.rx[0] = 0;
    cpu.pc += 4;
  } else {
    instructionAddressMisaligned(address, cpu);
  }
}

fn amomaxw(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: amomaxw {s}, {s}(0x{x:0>8}), {s}(0x{x:0>8})", .{
    cpu.pc, register_names[params.rd], register_names[params.rs1], cpu.rx[params.rs1],
    register_names[params.rs2], cpu.rx[params.rs2],
  });
  const address = cpu.rx[params.rs1];
  if (address % @sizeOf(u32) == 0) {
    cpu.rx[params.rd] = memread(u32, cpu, address);
    const result = @bitCast(u32, std.math.max(
      @bitCast(i32, cpu.rx[params.rd]),
      @bitCast(i32, cpu.rx[params.rs2])
    ));
    memwrite(u32, cpu, address, result);
    cpu.rx[0] = 0;
    cpu.pc += 4;
  } else {
    instructionAddressMisaligned(address, cpu);
  }
}

fn amominuw(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: amominuw {s}, {s}(0x{x:0>8}), {s}(0x{x:0>8})", .{
    cpu.pc, register_names[params.rd], register_names[params.rs1], cpu.rx[params.rs1],
    register_names[params.rs2], cpu.rx[params.rs2],
  });
  const address = cpu.rx[params.rs1];
  if (address % @sizeOf(u32) == 0) {
    cpu.rx[params.rd] = memread(u32, cpu, address);
    const result = std.math.min(cpu.rx[params.rd], cpu.rx[params.rs2]);
    memwrite(u32, cpu, address, result);
    cpu.rx[0] = 0;
    cpu.pc += 4;
  } else {
    instructionAddressMisaligned(address, cpu);
  }
}

fn amomaxuw(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: amomaxuw {s}, {s}(0x{x:0>8}), {s}(0x{x:0>8})", .{
    cpu.pc, register_names[params.rd], register_names[params.rs1], cpu.rx[params.rs1],
    register_names[params.rs2], cpu.rx[params.rs2],
  });
  const address = cpu.rx[params.rs1];
  if (address % @sizeOf(u32) == 0) {
    cpu.rx[params.rd] = memread(u32, cpu, address);
    const result = std.math.max(cpu.rx[params.rd], cpu.rx[params.rs2]);
    memwrite(u32, cpu, address, result);
    cpu.rx[0] = 0;
    cpu.pc += 4;
  } else {
    instructionAddressMisaligned(address, cpu);
  }
}
