const std = @import("std");

// As configured in the buildroot kernel.
// The Device Tree Blob (DTB) describe the memory as follows:
// 0x00000000 -> 0x80000000: Memory mapped device. This is where the Linux kernel
//                           is going to interact with the devices.
// 0x80000000 -> 0x84000000: The Kernel space. The actual allocatable memory
//                           (here 2GB).
// We are going to extend that memory to create an "invalid" memory region
// which will contain the DTB. The kernel can still access it but cannot let
// programs allocate memory there.
//
// Here we define the global variable which will be used to offset the PC
// anytime memory is accessed.
const CONFIG_PAGE_OFFSET = 0x80000000;
// This must match the content of the DTB if loaded.
const DEFAULT_MEM_SIZE = 0x4000000; // 64 MB

const Options = struct {
  page_offset: u32,
  mem_size: u32,
  exec_filename: []const u8,
  dtb_filename: ?[]const u8,
};

fn println(comptime fmt: []const u8, args: anytype) void {
  std.io.getStdOut().writer().print(fmt ++ "\n", args) catch {};
}

fn get_options(args: [][:0]u8) !Options {
  var i: u8 = 1;
  var page_offset: u32 = 0;
  var mem_size: u32 = DEFAULT_MEM_SIZE;
  var exec_filename: ?[]const u8 = null;
  var dtb_filename: ?[]const u8 = null;
  while (i < args.len) {
    if (std.mem.eql(u8, args[i], "-d") or std.mem.eql(u8, args[i], "--dtb")) {
      i += 1;
      dtb_filename = args[i];
      // If we load a DTB, we are trying to load a kernel. If page_offset is
      // not yet set, set it to the default value.
      // TODO: Read that page offset from the DTB itself instead of relying on a default.
      if (page_offset == 0) {
        page_offset = CONFIG_PAGE_OFFSET;
      }
      i += 1;
    } else if (std.mem.eql(u8, args[i], "-o") or std.mem.eql(u8, args[i], "--page-offset")) {
      i += 1;
      page_offset = try std.fmt.parseInt(u32, args[i], 10);
      i += 1;
    } else if (std.mem.eql(u8, args[i], "-m") or std.mem.eql(u8, args[i], "--memory-size")) {
      i += 1;
      mem_size = try std.fmt.parseInt(u32, args[i], 10);
      i += 1;
    } else { exec_filename = args[i]; i += 1; }
  }
  if (exec_filename) |e_filename| {
    return .{
      .page_offset = page_offset,
      .mem_size = mem_size,
      .exec_filename = e_filename,
      .dtb_filename = dtb_filename,
    };
  }

  println("error: missing parameters. no executable provided", .{});
  println("usage: {s} executable -m <memory_size_in_bytes> -d <dtb_filename> -p <page_offset>", .{ args[0] });
  return error.NoExecutableProvided;
}

const GetInstruction = error {
  UnknownInstruction,
};

const RiscError = error {
  InstructionNotImplemented,
};

// Each RISC-V instruction follows a particular "format". This format describes
// how the instruction is structured in the 32bits of data that compose this
// instruction.
// see riscv-spec-20191213.pdf chapter 2.2 Base Instruction Formats.
pub const InstructionFormat = enum {
  R,
  I,
  S,
  B,
  U,
  J,
};

// The base RiscVCPU(u32) instruction set only deal with integer. No floating point, not even multiplication
// and division, which comes in separate extensions.
// Note that instruction's opcodes are spread around. You have the opcode field
// (7bits) but some instructions will also have additional bits (funct3 and funct7) to be decoded.
// see riscv-spec-20191213.pdf chapter 24 RV32/64 Instruction Set Listings
const instructionSet = [_]Instruction{
  .{ .name = "LUI",     .opcode = 0b0110111, .funct3 = null,  .funct7 = null,      .format = InstructionFormat.U, .handler = lui },
  .{ .name = "AUIPC",   .opcode = 0b0010111, .funct3 = null,  .funct7 = null,      .format = InstructionFormat.U, .handler = auipc },
  .{ .name = "JAL",     .opcode = 0b1101111, .funct3 = null,  .funct7 = null,      .format = InstructionFormat.J, .handler = jal },
  .{ .name = "JALR",    .opcode = 0b1100111, .funct3 = 0b000, .funct7 = null,      .format = InstructionFormat.I, .handler = jalr },
  .{ .name = "BEQ",     .opcode = 0b1100011, .funct3 = 0b000, .funct7 = null,      .format = InstructionFormat.B, .handler = beq },
  .{ .name = "BNE",     .opcode = 0b1100011, .funct3 = 0b001, .funct7 = null,      .format = InstructionFormat.B, .handler = bne },
  .{ .name = "BLT",     .opcode = 0b1100011, .funct3 = 0b100, .funct7 = null,      .format = InstructionFormat.B, .handler = blt },
  .{ .name = "BGE",     .opcode = 0b1100011, .funct3 = 0b101, .funct7 = null,      .format = InstructionFormat.B, .handler = bge },
  .{ .name = "BLTU",    .opcode = 0b1100011, .funct3 = 0b110, .funct7 = null,      .format = InstructionFormat.B, .handler = bltu },
  .{ .name = "BGEU",    .opcode = 0b1100011, .funct3 = 0b111, .funct7 = null,      .format = InstructionFormat.B, .handler = bgeu },
  .{ .name = "LB",      .opcode = 0b0000011, .funct3 = 0b000, .funct7 = null,      .format = InstructionFormat.I, .handler = lb },
  .{ .name = "LH",      .opcode = 0b0000011, .funct3 = 0b001, .funct7 = null,      .format = InstructionFormat.I, .handler = lh },
  .{ .name = "LW",      .opcode = 0b0000011, .funct3 = 0b010, .funct7 = null,      .format = InstructionFormat.I, .handler = lw },
  .{ .name = "LBU",     .opcode = 0b0000011, .funct3 = 0b100, .funct7 = null,      .format = InstructionFormat.I, .handler = lbu },
  .{ .name = "LHU",     .opcode = 0b0000011, .funct3 = 0b101, .funct7 = null,      .format = InstructionFormat.I, .handler = lhu },
  .{ .name = "SB",      .opcode = 0b0100011, .funct3 = 0b000, .funct7 = null,      .format = InstructionFormat.S, .handler = sb },
  .{ .name = "SH",      .opcode = 0b0100011, .funct3 = 0b001, .funct7 = null,      .format = InstructionFormat.S, .handler = sh },
  .{ .name = "SW",      .opcode = 0b0100011, .funct3 = 0b010, .funct7 = null,      .format = InstructionFormat.S, .handler = sw },
  .{ .name = "ADDI",    .opcode = 0b0010011, .funct3 = 0b000, .funct7 = null,      .format = InstructionFormat.I, .handler = addi },
  .{ .name = "SLTI",    .opcode = 0b0010011, .funct3 = 0b010, .funct7 = null,      .format = InstructionFormat.I, .handler = slti },
  .{ .name = "SLTIU",   .opcode = 0b0010011, .funct3 = 0b011, .funct7 = null,      .format = InstructionFormat.I, .handler = sltiu },
  .{ .name = "XORI",    .opcode = 0b0010011, .funct3 = 0b100, .funct7 = null,      .format = InstructionFormat.I, .handler = nullHandler },
  .{ .name = "ORI",     .opcode = 0b0010011, .funct3 = 0b110, .funct7 = null,      .format = InstructionFormat.I, .handler = nullHandler },
  .{ .name = "ANDI",    .opcode = 0b0010011, .funct3 = 0b111, .funct7 = null,      .format = InstructionFormat.I, .handler = nullHandler },
  .{ .name = "SLLI",    .opcode = 0b0010011, .funct3 = 0b001, .funct7 = 0b0000000, .format = InstructionFormat.I, .handler = nullHandler },
  .{ .name = "SRLI",    .opcode = 0b0010011, .funct3 = 0b101, .funct7 = 0b0000000, .format = InstructionFormat.I, .handler = nullHandler },
  .{ .name = "SRAI",    .opcode = 0b0010011, .funct3 = 0b101, .funct7 = 0b0100000, .format = InstructionFormat.I, .handler = nullHandler },
  .{ .name = "ADD",     .opcode = 0b0110011, .funct3 = 0b000, .funct7 = 0b0000000, .format = InstructionFormat.R, .handler = add },
  .{ .name = "SUB",     .opcode = 0b0110011, .funct3 = 0b000, .funct7 = 0b0100000, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "SLL",     .opcode = 0b0110011, .funct3 = 0b001, .funct7 = 0b0000000, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "SLT",     .opcode = 0b0110011, .funct3 = 0b010, .funct7 = 0b0000000, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "SLTU",    .opcode = 0b0110011, .funct3 = 0b011, .funct7 = 0b0000000, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "XOR",     .opcode = 0b0110011, .funct3 = 0b100, .funct7 = 0b0000000, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "SRL",     .opcode = 0b0110011, .funct3 = 0b101, .funct7 = 0b0000000, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "SRA",     .opcode = 0b0110011, .funct3 = 0b101, .funct7 = 0b0100000, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "OR",      .opcode = 0b0110011, .funct3 = 0b110, .funct7 = 0b0000000, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "AND",     .opcode = 0b0110011, .funct3 = 0b111, .funct7 = 0b0000000, .format = InstructionFormat.R, .handler = nullHandler },
  .{ .name = "FENCE",   .opcode = 0b0001111, .funct3 = 0b000, .funct7 = null,      .format = InstructionFormat.I, .handler = nullHandler },
  .{ .name = "FENCE.I", .opcode = 0b0001111, .funct3 = 0b001, .funct7 = null,      .format = InstructionFormat.I, .handler = nullHandler },
  .{ .name = "ECALL",   .opcode = 0b1110011, .funct3 = null,  .funct7 = null,      .format = InstructionFormat.I, .handler = ecall       },
};

// A RiscVCPU(T) RISC-V processor is a program counter of Tbits width, 32 Tbits
// registrers (with register 0 always equal 0) and the associated memory.
// see riscv-spec-20191213.pdf chapter 2.1 Programer's model for base integer ISA.
pub fn RiscVCPU(comptime T: type) type {
  return struct {
    const _t = T;

    pc: T,
    rx: [32]T,
    raw_mem: []u8,
    mem: []u8,
  };
}

fn fetchJ(packets: u32) struct { rd: u5, offset: u21 } {
  // 0b00000000 00000000 0000XXXX X0000000
  const rd = (packets & 0x00000F80) >> 7;
  // You will note that we should shift by 12, 21, 10 and 1. But for some
  // reason, the imm in the J format always has its lowest bit to 0...
  const offset =
    (packets & 0b10000000000000000000000000000000) >> 11 |
    (packets & 0b01111111111000000000000000000000) >> 20 |
    (packets & 0b00000000000100000000000000000000) >> 9 |
    (packets & 0b00000000000011111111000000000000)
  ;
  // TODO: Extend sign?
  return .{ .rd = @intCast(u5, rd), .offset = @intCast(u21, offset) };
}

fn fetchR(packets: u32) struct { rd: u5, rs1: u5, rs2: u5, funct7: u7 } {
  // 0bFFFFFFF2 22221111 1fffrrrr rooooooo
  const rd = (packets & 0x00000F80) >> 7;
  const rs1 = (packets & 0x000F8000) >> 15;
  const rs2 = (packets & 0x01F00000) >> 20;
  const funct7 = (packets & 0xFE000000) >> 25;
  return .{
    .rd = @intCast(u5, rd),
    .rs1 = @intCast(u5, rs1),
    .rs2 = @intCast(u5, rs2),
    .funct7 = @intCast(u7, funct7),
  };
}

fn fetchI(packets: u32) struct { rd: u5, rs1: u5, imm: u12 } {
  // 0biiiiiiii iiii1111 1fffrrrr rooooooo
  const rd = (packets & 0x00000F80) >> 7;
  const rs1 = (packets & 0x000F8000) >> 15;
  var imm = (packets & 0xFFF00000) >> 20;
  // if (imm & 0x00000800 != 0) imm = imm | 0xFFFFF800;
  return .{ .rd = @intCast(u5, rd), .rs1 = @intCast(u5, rs1), .imm = @intCast(u12, imm) };
}

fn fetchB(packets: u32) struct { rs1: u5, rs2: u5, imm: u13 } {
  // 0biiiiiii2 22221111 1fffiiii iooooooo
  const rs1 = (packets & 0x000F8000) >> 15;
  const rs2 = (packets & 0x01F00000) >> 20;
  var imm = (packets & 0x80000000) >> 19 |
    (packets & 0x7E000000) >> 20 |
    (packets & 0x00000F00) >> 7  |
    (packets & 0x00000080) << 4
  ;
  // sign extension
  if (imm & 0x00001000 != 0) imm = imm | 0xFFFFF000;
  return .{
    .rs1 = @intCast(u5, rs1),
    .rs2 = @intCast(u5, rs2),
    .imm = @intCast(u13, imm & 0x00001FFF),
  };
}

fn fetchS(packets: u32) struct { rs1: u5, rs2: u5, imm: u12 } {
  // 0biiiiiii2 22221111 1fffiiii iooooooo
  const rs1 = (packets & 0x000F8000) >> 15;
  const rs2 = (packets & 0x01F00000) >> 20;
  const imm = (packets & 0x00000F80) >> 7 |
    (packets & 0xFE000000) >> 20
  ;
  return .{
    .rs1 = @intCast(u5, rs1),
    .rs2 = @intCast(u5, rs2),
    .imm = @intCast(u12, imm),
  };
}

fn fetchU(packets: u32) struct { rd: u5, imm: u20 } {
  // 0biiiiiiii iiiiiiii iiiirrrr rooooooo
  const rd = (packets & 0x00000F80) >> 7;
  const imm = (packets & 0xFFFFF000) >> 12;
  return .{
    .rd = @intCast(u5, rd),
    .imm = @intCast(u20, imm),
  };
}

const Instruction = struct {
  const Self = @This();

  name: []const u8,
  opcode: u8,
  funct3: ?u8,
  funct7: ?u8,
  format: InstructionFormat,
  handler: *const fn(self: Self, cpu: *RiscVCPU(u32), packets: u32) RiscError!void,
};

fn nullHandler(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = cpu;
  _ = instruction;
  _ = packets;
  return RiscError.InstructionNotImplemented;
}

fn lui(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchU(packets);
  std.log.debug("jal rd (0x{x:8>0}), imm (0x{x:8>0})", .{ params.rd, params.imm });
  cpu.rx[params.rd] = @intCast(u32, params.imm) << 12 & 0xFFFFF000;
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn auipc(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchU(packets);
  std.log.debug("auipc rd (0x{x:8>0}), imm (0x{x:8>0})", .{ params.rd, params.imm });
  cpu.rx[params.rd] = cpu.pc +% (@intCast(u32, params.imm) << 12 & 0xFFFFF000);
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn jal(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchJ(packets);
  const signedOffset: i21 = @bitCast(i21, params.offset);
  std.log.debug("jal rd (0x{x}), offset (0x{x})", .{ params.rd, signedOffset });
  cpu.rx[params.rd] = cpu.pc + 4;
  // We can't add a signed to an unsigned. We need to convert the i21 to a i32
  // to extend the 2'complement then bitcast it to a u32. Then the addition
  // kind of work.
  cpu.pc +%= @bitCast(u32, @as(i32, signedOffset));
}

fn jalr(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchI(packets);
  std.log.debug("jalr x{}(0x{x}), x{}(0x{x}, 0x{x}", .{
    params.rd, cpu.rx[params.rd], params.rs1, cpu.rx[params.rs1], params.imm,
  });
  // We can't add a signed to an unsigned. We need to convert the i21 to a i32
  // to extend the 2'complement then bitcast it to a u32. Then the addition
  // kind of work.
  const pc = cpu.pc;
  cpu.pc = (cpu.rx[params.rs1] +% @bitCast(u32, @as(i32, @bitCast(i12, params.imm)))) & 0xFFFFFFFE;
  cpu.rx[params.rd] = pc + 4;
  cpu.rx[0] = 0;
}

fn beq(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchB(packets);
  std.log.debug("beq x{}(0x{x}), x{}(0x{x}), 0x{x} ({})", .{
    params.rs1, cpu.rx[params.rs1], params.rs2, cpu.rx[params.rs2], params.imm,
    @as(i32, @bitCast(i13, params.imm)),
  });
  if (cpu.rx[params.rs1] == cpu.rx[params.rs2]) {
    cpu.pc = cpu.pc +% @bitCast(u32, @as(i32, @bitCast(i13, params.imm)));
  } else {
    cpu.pc += 4;
  }
}

fn bne(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchB(packets);
  std.log.debug("bne x{}(0x{x}), x{}(0x{x}), 0x{x} ({})", .{
    params.rs1, cpu.rx[params.rs1], params.rs2, cpu.rx[params.rs2], params.imm,
    @as(i32, @bitCast(i13, params.imm)),
  });
  if (cpu.rx[params.rs1] != cpu.rx[params.rs2]) {
    cpu.pc = cpu.pc +% @bitCast(u32, @as(i32, @bitCast(i13, params.imm)));
  } else {
    cpu.pc += 4;
  }
}

fn blt(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchB(packets);
  std.log.debug("blt x{}(0x{x}), x{}(0x{x}), 0x{x} ({})", .{
    params.rs1, cpu.rx[params.rs1], params.rs2, cpu.rx[params.rs2], params.imm,
    @as(i32, @bitCast(i13, params.imm)),
  });
  if (@bitCast(i32, cpu.rx[params.rs1]) < @bitCast(i32, cpu.rx[params.rs2])) {
    cpu.pc = cpu.pc +% @bitCast(u32, @as(i32, @bitCast(i13, params.imm)));
  } else {
    cpu.pc += 4;
  }
}

fn bge(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchB(packets);
  std.log.debug("bge x{}(0x{x}), x{}(0x{x}), 0x{x} ({})", .{
    params.rs1, cpu.rx[params.rs1], params.rs2, cpu.rx[params.rs2], params.imm,
    @as(i32, @bitCast(i13, params.imm)),
  });
  if (@bitCast(i32, cpu.rx[params.rs1]) >= @bitCast(i32, cpu.rx[params.rs2])) {
    cpu.pc = cpu.pc +% @bitCast(u32, @as(i32, @bitCast(i13, params.imm)));
  } else {
    cpu.pc += 4;
  }
}

fn bltu(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchB(packets);
  std.log.debug("bltu x{}(0x{x}), x{}(0x{x}), 0x{x} ({})", .{
    params.rs1, cpu.rx[params.rs1], params.rs2, cpu.rx[params.rs2], params.imm,
    @as(i32, @bitCast(i13, params.imm)),
  });
  if (cpu.rx[params.rs1] < cpu.rx[params.rs2]) {
    cpu.pc = cpu.pc +% @bitCast(u32, @as(i32, @bitCast(i13, params.imm)));
  } else {
    cpu.pc += 4;
  }
}

fn bgeu(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchB(packets);
  std.log.debug("bgeu x{}(0x{x}), x{}(0x{x}), 0x{x} ({})", .{
    params.rs1, cpu.rx[params.rs1], params.rs2, cpu.rx[params.rs2], params.imm,
    @as(i32, @bitCast(i13, params.imm)),
  });
  if (cpu.rx[params.rs1] >= cpu.rx[params.rs2]) {
    cpu.pc = cpu.pc +% @bitCast(u32, @as(i32, @bitCast(i13, params.imm)));
  } else {
    cpu.pc += 4;
  }
}


fn add(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("add x{}, x{}(0x{x}), x{}(0x{x})", .{
    params.rd, params.rs1, cpu.rx[params.rs1], params.rs2, cpu.rx[params.rs2],
  });
  cpu.rx[params.rd] = cpu.rx[params.rs1] +% cpu.rx[params.rs2];
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn addi(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchI(packets);
  std.log.debug("addi x{}, x{}(0x{x}), 0x{x}", .{
    params.rd, params.rs1, cpu.rx[params.rs1], params.imm,
  });
  cpu.rx[params.rd] = cpu.rx[params.rs1] +% @bitCast(u32, @intCast(i32, @bitCast(i12, params.imm)));
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn lb(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchI(packets);
  std.log.debug("lb x{}, x{}(0x{x} + 0x{x:0>8} = 0x{x:0>8}) [0x{x:0>8}]", .{
    params.rd, params.rs1, cpu.rx[params.rs1], params.imm,
    cpu.rx[params.rs1] + params.imm, cpu.mem[cpu.rx[params.rs1] + params.imm],
  });
  const offset = @bitCast(u32, @intCast(i32, @bitCast(i12, params.imm)));
  cpu.rx[params.rd] = cpu.mem[cpu.rx[params.rs1] +% offset];
  if (cpu.rx[params.rd] & 0x00000080 != 0) { // signed?
    // sign extension
    cpu.rx[params.rd] |= 0xFFFFFF80;
  }
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn lh(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchI(packets);
  std.log.debug("lh x{}, x{}(0x{x} + 0x{x:0>8} = 0x{x:0>8}) [0x{x:0>8}]", .{
    params.rd, params.rs1, cpu.rx[params.rs1], params.imm,
    cpu.rx[params.rs1] + params.imm, cpu.mem[cpu.rx[params.rs1] + params.imm],
  });
  const offset = @bitCast(u32, @intCast(i32, @bitCast(i12, params.imm)));
  const address = cpu.rx[params.rs1] +% offset;
  cpu.rx[params.rd] = @as(u32, cpu.mem[address]) | (@as(u32, cpu.mem[address + 1]) << 8);
  if (cpu.rx[params.rd] & 0x00008000 != 0) { // signed?
    // sign extension
    cpu.rx[params.rd] |= 0xFFFF8000;
  }
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn lw(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchI(packets);
  std.log.debug("lw x{}, x{}(0x{x} + 0x{x:0>8} = 0x{x:0>8}) [0x{x:0>8}]", .{
    params.rd, params.rs1, cpu.rx[params.rs1], params.imm,
    cpu.rx[params.rs1] + params.imm, cpu.mem[cpu.rx[params.rs1] + params.imm],
  });
  const offset = @bitCast(u32, @intCast(i32, @bitCast(i12, params.imm)));
  const address = cpu.rx[params.rs1] +% offset;
  cpu.rx[params.rd] = @as(u32, cpu.mem[address]) |
    (@as(u32, cpu.mem[address + 1]) << 8) |
    (@as(u32, cpu.mem[address + 2]) << 16) |
    (@as(u32, cpu.mem[address + 3]) << 24)
  ;
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn lbu(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchI(packets);
  std.log.debug("lbu x{}, x{}(0x{x} + 0x{x:0>8} = 0x{x:0>8}) [0x{x:0>8}]", .{
    params.rd, params.rs1, cpu.rx[params.rs1], params.imm,
    cpu.rx[params.rs1] + params.imm, cpu.mem[cpu.rx[params.rs1] + params.imm],
  });
  const offset = @bitCast(u32, @intCast(i32, @bitCast(i12, params.imm)));
  cpu.rx[params.rd] = cpu.mem[cpu.rx[params.rs1] +% offset];
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn lhu(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchI(packets);
  std.log.debug("lhu x{}, x{}(0x{x} + 0x{x:0>8} = 0x{x:0>8}) [0x{x:0>8}]", .{
    params.rd, params.rs1, cpu.rx[params.rs1], params.imm,
    cpu.rx[params.rs1] + params.imm, cpu.mem[cpu.rx[params.rs1] + params.imm],
  });
  const offset = @bitCast(u32, @intCast(i32, @bitCast(i12, params.imm)));
  const address = cpu.rx[params.rs1] +% offset;
  cpu.rx[params.rd] = @as(u32, cpu.mem[address]) | (@as(u32, cpu.mem[address + 1]) << 8);
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn sb(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchS(packets);
  std.log.debug("sb x{}(0x{x:0>8}), x{}(0x{x} + 0x{x:0>8} = 0x{x:0>8})", .{
    params.rs2, cpu.rx[params.rs2], params.rs1, cpu.rx[params.rs1], params.imm, cpu.rx[params.rs1] + params.imm,
  });
  const offset = @bitCast(u32, @intCast(i32, @bitCast(i12, params.imm)));
  cpu.mem[cpu.rx[params.rs1] +% offset] = @intCast(u8, cpu.rx[params.rs2] & 0x000000FF);
  cpu.pc += 4;
}

fn sh(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchS(packets);
  std.log.debug("sh x{}(0x{x:0>8}), x{}(0x{x} + 0x{x:0>8} = 0x{x:0>8})", .{
    params.rs2, cpu.rx[params.rs2], params.rs1, cpu.rx[params.rs1], params.imm, cpu.rx[params.rs1] + params.imm,
  });
  const offset = @bitCast(u32, @intCast(i32, @bitCast(i12, params.imm)));
  const address = cpu.rx[params.rs1] +% offset;
  const value = cpu.rx[params.rs2];
  cpu.mem[address] = @intCast(u8, value & 0x000000FF);
  cpu.mem[address + 1] = @intCast(u8, (value & 0x0000FF00) >> 8);
  cpu.pc += 4;
}

fn sw(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchS(packets);
  std.log.debug("sw x{}(0x{x:0>8}), x{}(0x{x} + 0x{x:0>8} = 0x{x:0>8})", .{
    params.rs2, cpu.rx[params.rs2], params.rs1, cpu.rx[params.rs1], params.imm, cpu.rx[params.rs1] + params.imm,
  });
  const offset = @bitCast(u32, @intCast(i32, @bitCast(i12, params.imm)));
  const address = cpu.rx[params.rs1] +% offset;
  const value = cpu.rx[params.rs2];
  cpu.mem[address] = @intCast(u8, value & 0x000000FF);
  cpu.mem[address + 1] = @intCast(u8, (value & 0x0000FF00) >> 8);
  cpu.mem[address + 2] = @intCast(u8, (value & 0x00FF0000) >> 16);
  cpu.mem[address + 3] = @intCast(u8, (value & 0xFF000000) >> 24);
  cpu.pc += 4;
}

fn slti(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchI(packets);
  std.log.debug("slti x{}, x{}(0x{x}, 0x{x:0>8}", .{
    params.rd, params.rs1, cpu.rx[params.rs1], params.imm,
  });
  cpu.rx[params.rd] = if (@bitCast(i32, cpu.rx[params.rs1]) < @intCast(i32, @bitCast(i12, params.imm))) 1 else 0;
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn sltiu(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchI(packets);
  std.log.debug("sltiu x{}, x{}(0x{x}, 0x{x:0>8}", .{
    params.rd, params.rs1, cpu.rx[params.rs1], params.imm,
  });
  println(" {} < {} 0b{b}", .{ cpu.rx[params.rs1], params.imm, params.imm });
  cpu.rx[params.rd] = if (cpu.rx[params.rs1] < params.imm) 1 else 0;
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn ecall(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = cpu;
  _ = instruction;
  const param = fetchI(packets);
  std.log.debug("ecall rd (0x{x}), rs1 (0x{x}), imm (0x{x})", .{ param.rd, param.rs1, param.imm });
  return RiscError.InstructionNotImplemented;
}

fn dump_cpu(cpu: RiscVCPU(u32)) void {
  println("x0  = 0x{x:0>8} x8  = 0x{x:0>8} x16 = 0x{x:0>8} x24 = 0x{x:0>8}", .{ cpu.rx[0 ], cpu.rx[8 ], cpu.rx[16], cpu.rx[24] });
  println("x1  = 0x{x:0>8} x9  = 0x{x:0>8} x17 = 0x{x:0>8} x25 = 0x{x:0>8}", .{ cpu.rx[1 ], cpu.rx[9 ], cpu.rx[17], cpu.rx[25] });
  println("x2  = 0x{x:0>8} x10 = 0x{x:0>8} x18 = 0x{x:0>8} x26 = 0x{x:0>8}", .{ cpu.rx[2 ], cpu.rx[10], cpu.rx[18], cpu.rx[26] });
  println("x3  = 0x{x:0>8} x11 = 0x{x:0>8} x19 = 0x{x:0>8} x27 = 0x{x:0>8}", .{ cpu.rx[3 ], cpu.rx[11], cpu.rx[19], cpu.rx[27] });
  println("x4  = 0x{x:0>8} x12 = 0x{x:0>8} x20 = 0x{x:0>8} x28 = 0x{x:0>8}", .{ cpu.rx[4 ], cpu.rx[12], cpu.rx[20], cpu.rx[28] });
  println("x5  = 0x{x:0>8} x13 = 0x{x:0>8} x21 = 0x{x:0>8} x29 = 0x{x:0>8}", .{ cpu.rx[5 ], cpu.rx[13], cpu.rx[21], cpu.rx[29] });
  println("x6  = 0x{x:0>8} x14 = 0x{x:0>8} x22 = 0x{x:0>8} x30 = 0x{x:0>8}", .{ cpu.rx[6 ], cpu.rx[14], cpu.rx[22], cpu.rx[30] });
  println("x7  = 0x{x:0>8} x15 = 0x{x:0>8} x23 = 0x{x:0>8} x31 = 0x{x:0>8}", .{ cpu.rx[7 ], cpu.rx[15], cpu.rx[23], cpu.rx[31] });
  println("pc  = 0x{x:0>8}", .{ cpu.pc });
}

// https://github.com/ziglang/zig/blob/6b3f59c3a735ddbda3b3a62a0dfb5d55fa045f57/lib/std/comptime_string_map.zig
pub fn decode(opcode: u8, funct3: u8, funct7: u8) !Instruction {
  const precomputed = comptime blk: {
    @setEvalBranchQuota(2000);
    var sorted_opcodes = instructionSet;
    const asc = (struct {
      fn asc(context: void, a: Instruction, b: Instruction) bool {
        _ = context;
        const afunct3 = a.funct3 orelse 0;
        const bfunct3 = b.funct3 orelse 0;
        const afunct7 = a.funct7 orelse 0;
        const bfunct7 = b.funct7 orelse 0;
        // What a mess...
        return a.opcode > b.opcode or (a.opcode == b.opcode and (afunct3 == bfunct3 and afunct7 > bfunct7) or afunct3 > bfunct3);
      }
    }).asc;
    std.sort.sort(Instruction, &sorted_opcodes, {}, asc);
    // @compileLog(sorted_opcodes);
    break :blk .{
      .max_opcode = sorted_opcodes[0].opcode,
      .min_opcode = sorted_opcodes[sorted_opcodes.len - 1].opcode,
      .sorted_opcodes = sorted_opcodes,
    };
  };
  if (opcode < precomputed.min_opcode or opcode > precomputed.max_opcode) {
    return GetInstruction.UnknownInstruction;
  }

  comptime var i: comptime_int = 0;
  inline while (true) {
    if (precomputed.sorted_opcodes[i].opcode == opcode) {
      if (precomputed.sorted_opcodes[i].funct3 == null or precomputed.sorted_opcodes[i].funct3 == funct3) {
        if (precomputed.sorted_opcodes[i].funct7 == null or precomputed.sorted_opcodes[i].funct7 == funct7) {
          return precomputed.sorted_opcodes[i];
        }
      }
    }
    i += 1;
    if (i >= precomputed.sorted_opcodes.len) {
      return GetInstruction.UnknownInstruction;
    }
  }
}

pub inline fn fetch(packet: u32) struct { opcode: u8, funct3: u8, funct7: u8 } {
  const opcode: u8 = @intCast(u8, 0x7F & packet);
  const funct3: u8 = @intCast(u8, (0x7000 & packet) >> 12);
  const funct7: u8 = @intCast(u8, (0xFE000000 & packet) >> 25);

  return .{
    .opcode = opcode,
    .funct3 = funct3,
    .funct7 = funct7,
  };
}

fn cycle(cpu: *RiscVCPU(u32)) !void {
  var packets: u32 = cpu.mem[cpu.pc] |
    @as(u32, cpu.mem[cpu.pc + 1]) << 8 |
    @as(u32, cpu.mem[cpu.pc + 2]) << 16 |
    @as(u32, cpu.mem[cpu.pc + 3]) << 24;
  std.log.debug("0x{x:0>8} @ 0x{x:0>8}", .{ packets, cpu.pc });

  const code = fetch(packets);
  const inst = decode(code.opcode, code.funct3, code.funct7) catch |err| {
    dump_cpu(cpu.*);
    _ = switch (err) {
      GetInstruction.UnknownInstruction => {
        println("error: unknown instruction: 0b{b} (funct3: 0b{b} funct7: 0b{b})", .{
          code.opcode, code.funct3, code.funct7,
        });
      },
    };
    return err;
  };
  inst.handler(inst, cpu, packets) catch |err| {
    dump_cpu(cpu.*);
    _ = switch (err) {
      RiscError.InstructionNotImplemented => {
        println("error: instruction not implemented: {s} (opcode: 0b{b} funct3: 0b{b} funct7: 0b{b})", .{
          inst.name, code.opcode, code.funct3, code.funct7,
        });
      },
    };
    return err;
  };
  // TODO: Find a way to keep x0 always equal to 0 in a better way.
  cpu.rx[0] = 0x0;
}

fn loadfile(filename: []const u8) ![]align(std.mem.page_size) u8 {
  var file = try std.fs.cwd().openFile(filename, .{});
  defer file.close();

  const file_size = try file.getEndPos();
  const buffer = try std.os.mmap(
    null,
    file_size,
    std.os.PROT.READ,
    std.os.MAP.SHARED,
    file.handle,
    0,
  );
  errdefer std.os.munmap(buffer);

  return buffer;
}

pub fn main() !u8 {
  var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
  const allocator = general_purpose_allocator.allocator();

  const args: [][:0]u8 = try std.process.argsAlloc(allocator);
  defer std.process.argsFree(allocator, args);

  var options = get_options(args) catch {
    return 1;
  };

  // Create the CPU.
  var mem = try allocator.alloc(u8, options.mem_size); // might change if a DTB is loaded.
  var cpu: RiscVCPU(u32) = .{
    .pc = options.page_offset,
    .rx = [_]u32{ 0 } ** 32,
    // Memory as allocated
    .raw_mem = mem,
    // Memory with an "inverse" offset. Accessing mem[page_offset] will access raw_mem[0x0]
    .mem = (mem.ptr - options.page_offset)[0..options.page_offset + options.mem_size],
  };
  defer allocator.free(cpu.mem);

  // Load the executable (or kernel)
  const executable = loadfile(options.exec_filename) catch |err| {
    _ = switch (err) {
      error.FileNotFound => { println("error: {s} not found", .{ options.exec_filename }); },
      else => { println("error: can't open file {s}", .{ args[1] }); },
    };
    return 1;
  };
  // If no DTB is provided we just keep that address to 0.
  var dtb_addr: u32 = 0;
  if (options.dtb_filename) |dtb_filename| {
    // Load the DTB.
    const dtb = loadfile(dtb_filename) catch |err| {
      _ = switch (err) {
        error.FileNotFound => { println("error: {s} not found", .{ dtb_filename }); },
        else => { println("error: can't open file {s}", .{ args[1] }); },
      };
      return 1;
    };
    // Expand memory to make room for the DTB.
    options.mem_size = options.mem_size + @intCast(u32, dtb.len);
    allocator.free(cpu.mem);
    cpu.raw_mem = try allocator.alloc(u8, options.mem_size);
    cpu.mem = (cpu.raw_mem.ptr - options.page_offset)[0..options.page_offset + options.mem_size];
    // Load the DTB at the end of the memory to ensure that the kernel never
    // write to the it (basically making it readonly).
    dtb_addr = @intCast(u32, cpu.mem.len - dtb.len);
    std.mem.copy(u8, cpu.mem[dtb_addr..], dtb);
    std.os.munmap(dtb);
    // According to https://www.sifive.com/blog/all-aboard-part-6-booting-a-risc-v-linux-kernel
    // linux expects the core id in a0 and the address to the DTB in a1.
    cpu.rx[10] = 0; // a0
    cpu.rx[11] = dtb_addr + options.page_offset; // a1
  }
  // Load the executable at the memory start
  std.mem.copy(u8, cpu.mem, executable);
  std.os.munmap(executable);

  cpu.mem[0xF00] = 0x74; // t
  cpu.mem[0xF01] = 0x65; // e
  cpu.mem[0xF02] = 0x73; // s
  cpu.mem[0xF03] = 0x74; // t
  cpu.mem[0xF04] = 0x00; // t
  cpu.rx[10] = 0xF05;
  cpu.rx[11] = 0xF00;

  // Start the emulation.
  while (true) {
    try cycle(&cpu);
  }

  return 0;
}
