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
  .{ .name = "AMOSWAP.W", .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0000100, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOSWAP.W", .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0000101, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOSWAP.W", .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0000110, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOSWAP.W", .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0000111, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOADD.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0000000, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOADD.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0000001, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOADD.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0000010, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOADD.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0000011, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOXOR.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0010000, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOXOR.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0010001, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOXOR.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0010010, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOXOR.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0010011, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOAND.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0110000, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOAND.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0110001, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOAND.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0110010, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOAND.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0110011, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOOR.W",   .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0100000, .format = InstructionFormat.R, .handler = amoorw },
  .{ .name = "AMOOR.W",   .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0100001, .format = InstructionFormat.R, .handler = amoorw },
  .{ .name = "AMOOR.W",   .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0100010, .format = InstructionFormat.R, .handler = amoorw },
  .{ .name = "AMOOR.W",   .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b0100011, .format = InstructionFormat.R, .handler = amoorw },
  .{ .name = "AMOMIN.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1000000, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOMIN.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1000001, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOMIN.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1000010, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOMIN.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1000011, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOMAX.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1010000, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOMAX.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1010001, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOMAX.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1010010, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOMAX.W",  .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1010011, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOMINU.W", .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1100000, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOMINU.W", .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1100001, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOMINU.W", .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1100010, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOMINU.W", .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1100011, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOMAXU.W", .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1110000, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOMAXU.W", .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1110001, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOMAXU.W", .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1110010, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AMOMAXU.W", .opcode = 0b0101111, .funct3 = 0b010, .funct7 = 0b1110011, .format = InstructionFormat.R, .handler = nullHandler },
};

// riscv-spec-20191213.pdf Chapter 8.2 Load-Reserved/Store-Conditional Instructions
// TODO: Not sure if we doing the right thing here
var reservation_set: bool = false;

fn lrw(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: amoorw {s}, {s}(0x{x:0>8}), {s}(0x{x:0>8})", .{
    cpu.pc, register_names[params.rd], register_names[params.rs1], cpu.rx[params.rs1],
    register_names[params.rs2], cpu.rx[params.rs2],
  });
  const address = cpu.rx[params.rs1];
  if (address % @sizeOf(u32) == 0) {
    cpu.rx[params.rd] = memread(u32, cpu.mem, address);
    cpu.rx[0] = 0;
    reservation_set = true;
    cpu.pc += 4;
  } else {
    instructionAddressMisaligned(address, cpu);
  }
}

fn swc(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: amoorw {s}, {s}(0x{x:0>8}), {s}(0x{x:0>8})", .{
    cpu.pc, register_names[params.rd], register_names[params.rs1], cpu.rx[params.rs1],
    register_names[params.rs2], cpu.rx[params.rs2],
  });
  const address = cpu.rx[params.rs1];
  if (address % @sizeOf(u32) == 0) {
    if (reservation_set) {
      memwrite(u32, cpu.mem, address, cpu.rx[params.rs2]);
      cpu.rx[params.rd] = 0;
      cpu.pc += 4;
    } else {
      cpu.rx[params.rd] = 1; // Non zero value
    }
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
    cpu.rx[params.rd] = memread(u32, cpu.mem, address);
    cpu.rx[params.rd] |= cpu.rx[params.rs2];
    cpu.rx[0] = 0;
    memwrite(u32, cpu.mem, address, cpu.rx[params.rd]);
    cpu.pc += 4;
  } else {
    instructionAddressMisaligned(address, cpu);
  }
}
