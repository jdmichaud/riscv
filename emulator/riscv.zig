const std = @import("std");
const csr = @import("csr.zig");
const mul = @import("mul.zig");
const debug = @import("debug.zig");
const register_names = debug.register_names;
const println = debug.println;

// Re-export some csr api.
pub const rv32_initial_csr_values = csr.rv32_initial_csr_values;
pub const init_csr = csr.init_csr;

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
  page_offset: u32, // -p,--page-offset
  mem_size: u32, // -m,--mempory-size
  exec_filename: []const u8,
  dtb_filename: ?[]const u8, // -d,--dtb
};

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

pub const RiscError = error {
  InstructionNotImplemented,
  InsufficientPrivilegeMode,
  UnhandledTrapVectorMode,
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

pub const Instruction = struct {
  const Self = @This();

  name: []const u8,
  opcode: u8,
  funct3: ?u8,
  funct7: ?u8,
  format: InstructionFormat,
  handler: *const fn(self: Self, cpu: *RiscVCPU(u32), packets: u32) RiscError!void,
};

// The base RiscVCPU(u32) instruction set only deal with integer. No floating point, not even multiplication
// and division, which comes in separate extensions.
// Note that instruction's opcodes are spread around. You have the opcode field
// (7bits) but some instructions will also have additional bits (funct3 and funct7) to be decoded.
// see riscv-spec-20191213.pdf chapter 24 RV32/64 Instruction Set Listings
const base_instruction_set = [_]Instruction{
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
  .{ .name = "XORI",    .opcode = 0b0010011, .funct3 = 0b100, .funct7 = null,      .format = InstructionFormat.I, .handler = xori },
  .{ .name = "ORI",     .opcode = 0b0010011, .funct3 = 0b110, .funct7 = null,      .format = InstructionFormat.I, .handler = ori },
  .{ .name = "ANDI",    .opcode = 0b0010011, .funct3 = 0b111, .funct7 = null,      .format = InstructionFormat.I, .handler = andi },
  .{ .name = "SLLI",    .opcode = 0b0010011, .funct3 = 0b001, .funct7 = 0b0000000, .format = InstructionFormat.I, .handler = slli },
  .{ .name = "SRLI",    .opcode = 0b0010011, .funct3 = 0b101, .funct7 = 0b0000000, .format = InstructionFormat.I, .handler = srli },
  .{ .name = "SRAI",    .opcode = 0b0010011, .funct3 = 0b101, .funct7 = 0b0100000, .format = InstructionFormat.I, .handler = srai },
  .{ .name = "ADD",     .opcode = 0b0110011, .funct3 = 0b000, .funct7 = 0b0000000, .format = InstructionFormat.R, .handler = add },
  .{ .name = "SUB",     .opcode = 0b0110011, .funct3 = 0b000, .funct7 = 0b0100000, .format = InstructionFormat.R, .handler = sub },
  .{ .name = "SLL",     .opcode = 0b0110011, .funct3 = 0b001, .funct7 = 0b0000000, .format = InstructionFormat.R, .handler = sll },
  .{ .name = "SLT",     .opcode = 0b0110011, .funct3 = 0b010, .funct7 = 0b0000000, .format = InstructionFormat.R, .handler = slt },
  .{ .name = "SLTU",    .opcode = 0b0110011, .funct3 = 0b011, .funct7 = 0b0000000, .format = InstructionFormat.R, .handler = sltu },
  .{ .name = "XOR",     .opcode = 0b0110011, .funct3 = 0b100, .funct7 = 0b0000000, .format = InstructionFormat.R, .handler = xor },
  .{ .name = "SRL",     .opcode = 0b0110011, .funct3 = 0b101, .funct7 = 0b0000000, .format = InstructionFormat.R, .handler = srl },
  .{ .name = "SRA",     .opcode = 0b0110011, .funct3 = 0b101, .funct7 = 0b0100000, .format = InstructionFormat.R, .handler = sra },
  .{ .name = "OR",      .opcode = 0b0110011, .funct3 = 0b110, .funct7 = 0b0000000, .format = InstructionFormat.R, .handler = or_ },
  .{ .name = "AND",     .opcode = 0b0110011, .funct3 = 0b111, .funct7 = 0b0000000, .format = InstructionFormat.R, .handler = and_ },
  .{ .name = "FENCE",   .opcode = 0b0001111, .funct3 = 0b000, .funct7 = null,      .format = InstructionFormat.I, .handler = noop },
  .{ .name = "ECALL",   .opcode = 0b1110011, .funct3 = 0b000, .funct7 = null,      .format = InstructionFormat.I, .handler = ecall },
  .{ .name = "MRET",    .opcode = 0b1110011, .funct3 = 0b000, .funct7 = 0b0011000, .format = InstructionFormat.I, .handler = mret },
};

// riscv-spec-20191213.pdf Chapter 3 "Zifencei" Instruction-Fence Fetch
const zifencei_set = [_]Instruction{
  .{ .name = "FENCE.I", .opcode = 0b0001111, .funct3 = 0b001, .funct7 = null,      .format = InstructionFormat.I, .handler = noop },
};

// riscv-spec-20191213.pdf Chapter 9 "Zicsr" Control and Status Register (CSR) instructions
const zicsr_set = [_]Instruction{
  .{ .name = "CSRRW",   .opcode = 0b1110011, .funct3 = 0b001, .funct7 = null,      .format = InstructionFormat.I, .handler = csrrw },
  .{ .name = "CSRRS",   .opcode = 0b1110011, .funct3 = 0b010, .funct7 = null,      .format = InstructionFormat.I, .handler = csrrs },
  .{ .name = "CSRRC",   .opcode = 0b1110011, .funct3 = 0b011, .funct7 = null,      .format = InstructionFormat.I, .handler = csrrc },
  .{ .name = "CSRRWI",  .opcode = 0b1110011, .funct3 = 0b101, .funct7 = null,      .format = InstructionFormat.I, .handler = csrrwi },
  .{ .name = "CSRRSI",  .opcode = 0b1110011, .funct3 = 0b110, .funct7 = null,      .format = InstructionFormat.I, .handler = csrrsi },
  .{ .name = "CSRRCI",  .opcode = 0b1110011, .funct3 = 0b111, .funct7 = null,      .format = InstructionFormat.I, .handler = csrrci },
};

// A RiscVCPU(T) RISC-V processor is a program counter of Tbits width, 32 Tbits
// registrers (with register 0 always equal 0), the 4K CSR registry file and the
// associated memory, See riscv-spec-20191213.pdf chapter 2.1 Programer's model
// for the base integer ISA.
pub fn RiscVCPU(comptime T: type) type {
  return struct {
    const _t = T;

    pc: T = 0,
    rx: [32]T = [_]u32{ 0 } ** 32,
    raw_mem: []u8,
    mem: []u8,
    priv_level: u7 = @enumToInt(csr.PrivilegeMode.MACHINE),
    csr: [4096]T = [_]u32{ 0 } ** 4096,
  };
}

// Instructions have format from which will depend how parameters to the
// instructions are fetched.
// See riscv-spec-20191213.pdf Ch. 2.2 Base Instruction Format.
pub fn fetchJ(packets: u32) struct { rd: u5, imm: u32 } {
  // 0b00000000 00000000 0000XXXX X0000000
  const rd = (packets & 0x00000F80) >> 7;
  // You will note that we should shift by 12, 21, 10 and 1. But for some
  // reason, the imm in the J format always has its lowest bit to 0...
  const imm =
    (packets & 0b10000000000000000000000000000000) >> 11 |
    (packets & 0b01111111111000000000000000000000) >> 20 |
    (packets & 0b00000000000100000000000000000000) >> 9 |
    (packets & 0b00000000000011111111000000000000)
  ;
  return .{ .rd = @intCast(u5, rd), .imm = imm };
}

pub fn fetchR(packets: u32) struct { rd: u5, rs1: u5, rs2: u5, funct7: u7 } {
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

pub fn fetchI(packets: u32) struct { rd: u5, rs1: u5, imm: u32 } {
  // 0biiiiiiii iiii1111 1fffrrrr rooooooo
  const rd = (packets & 0x00000F80) >> 7;
  const rs1 = (packets & 0x000F8000) >> 15;
  var imm = (packets & 0xFFF00000) >> 20;
  return .{ .rd = @intCast(u5, rd), .rs1 = @intCast(u5, rs1), .imm = imm };
}

pub fn fetchB(packets: u32) struct { rs1: u5, rs2: u5, imm: u32 } {
  // 0biiiiiii2 22221111 1fffiiii iooooooo
  const rs1 = (packets & 0x000F8000) >> 15;
  const rs2 = (packets & 0x01F00000) >> 20;
  var imm = (packets & 0x80000000) >> 19 |
    (packets & 0x7E000000) >> 20 |
    (packets & 0x00000F00) >> 7  |
    (packets & 0x00000080) << 4
  ;
  return .{
    .rs1 = @intCast(u5, rs1),
    .rs2 = @intCast(u5, rs2),
    .imm = imm,
  };
}

pub fn fetchS(packets: u32) struct { rs1: u5, rs2: u5, imm: u32 } {
  // 0biiiiiii2 22221111 1fffiiii iooooooo
  const rs1 = (packets & 0x000F8000) >> 15;
  const rs2 = (packets & 0x01F00000) >> 20;
  const imm = (packets & 0x00000F80) >> 7 |
    (packets & 0xFE000000) >> 20
  ;
  return .{
    .rs1 = @intCast(u5, rs1),
    .rs2 = @intCast(u5, rs2),
    .imm = imm,
  };
}

pub fn fetchU(packets: u32) struct { rd: u5, imm: u32 } {
  // 0biiiiiiii iiiiiiii iiiirrrr rooooooo
  const rd = (packets & 0x00000F80) >> 7;
  const imm = (packets & 0xFFFFF000) >> 12;
  return .{
    .rd = @intCast(u5, rd),
    .imm = imm,
  };
}

fn computeTrapAddress(comptime T: type, cpu: *RiscVCPU(T)) RiscError!T {
  // Check mtvec MODE field
  if ((cpu.csv[0x305] & 0x00000003) != 0) {
    return RiscError.UnhandledTrapVectorMode;
  }
  // riscv-privileged-20211203.pdf Ch. 3.1.7 Machine Trap-Vector Base-Address (mtvec)
  return cpu.csv[0x305];
}

pub fn nullHandler(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = cpu;
  _ = instruction;
  _ = packets;
  return RiscError.InstructionNotImplemented;
}

fn noop(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  _ = packets;
  cpu.pc += 4;
}

fn lui(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchU(packets);
  std.log.debug("0x{x:0>8}: lui x{}, imm (0x{x:0>8})", .{ cpu.pc, params.rd, params.imm });
  cpu.rx[params.rd] = (params.imm << 12) & 0xFFFFF000;
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn auipc(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchU(packets);
  std.log.debug("0x{x:0>8}: auipc {s}, 0x{x:0>8} ({s} <= 0x{x:0>8})", .{
    cpu.pc, register_names[params.rd], params.imm, register_names[params.rd],
    cpu.pc +% ((params.imm << 12) & 0xFFFFF000),
  });
  cpu.rx[params.rd] = cpu.pc +% ((params.imm << 12) & 0xFFFFF000);
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn jal(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchJ(packets);
  const offset = if (params.imm & 0x00100000 == 0) params.imm else (params.imm | 0xFFF00000);
  std.log.debug("0x{x:0>8}: jal rd (0x{x:0>8}), offset (0x{x:0>8})", .{ cpu.pc, params.rd, offset });
  const nextpc = cpu.pc +% offset;
  if (nextpc % @sizeOf(u32) == 0) {
    cpu.rx[params.rd] = cpu.pc + 4;
    cpu.rx[0] = 0;
    cpu.pc = nextpc;
  } else {
    instructionAddressMisaligned(nextpc, cpu);
  }
}

fn jalr(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchI(packets);
  std.log.debug("0x{x:0>8}: jalr x{}(0x{x:0>8}), x{}(0x{x:0>8}), 0x{x:0>8}", .{
    cpu.pc, params.rd, cpu.rx[params.rd], params.rs1, cpu.rx[params.rs1], params.imm,
  });
  const pc = cpu.pc;
  const offset = if (params.imm & 0x00000800 == 0) params.imm else (params.imm | 0xFFFFF800);
  const nextpc = (cpu.rx[params.rs1] +% offset) & 0xFFFFFFFE;
  if (nextpc % @sizeOf(u32) == 0) {
    cpu.rx[params.rd] = pc + 4;
    cpu.rx[0] = 0;
    cpu.pc = nextpc;
  } else {
    instructionAddressMisaligned(nextpc, cpu);
  }
}

fn beq(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchB(packets);
  std.log.debug("0x{x:0>8}: beq x{}(0x{x:0>8}), x{}(0x{x:0>8}), 0x{x:0>8} ({})", .{
    cpu.pc, params.rs1, cpu.rx[params.rs1], params.rs2, cpu.rx[params.rs2], params.imm, params.imm,
  });
  if (cpu.rx[params.rs1] == cpu.rx[params.rs2]) {
    const offset = if (params.imm & 0x00001000 == 0) params.imm else (params.imm | 0xFFFFF000);
    const nextpc = cpu.pc +% offset;
    if (nextpc % @sizeOf(u32) == 0) {
      cpu.pc = nextpc;
    } else {
      instructionAddressMisaligned(nextpc, cpu);
    }
  } else {
    cpu.pc += 4;
  }
}

fn bne(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchB(packets);
  std.log.debug("0x{x:0>8}: bne x{}(0x{x:0>8}), x{}(0x{x:0>8}), 0x{x:0>8} ({})", .{
    cpu.pc, params.rs1, cpu.rx[params.rs1], params.rs2, cpu.rx[params.rs2], params.imm, params.imm,
  });
  if (cpu.rx[params.rs1] != cpu.rx[params.rs2]) {
    const offset = if (params.imm & 0x00001000 == 0) params.imm else (params.imm | 0xFFFFF000);
    const nextpc = cpu.pc +% offset;
    if (nextpc % @sizeOf(u32) == 0) {
      cpu.pc = nextpc;
    } else {
      instructionAddressMisaligned(nextpc, cpu);
    }
  } else {
    cpu.pc += 4;
  }
}

fn blt(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchB(packets);
  std.log.debug("0x{x:0>8}: blt {s}(0x{x:0>8}), {s}(0x{x:0>8}), 0x{x:0>8} ({})", .{
    cpu.pc, register_names[params.rs1], cpu.rx[params.rs1], register_names[params.rs2], cpu.rx[params.rs2], params.imm, params.imm,
  });
  if (@bitCast(i32, cpu.rx[params.rs1]) < @bitCast(i32, cpu.rx[params.rs2])) {
    const offset = if (params.imm & 0x00001000 == 0) params.imm else (params.imm | 0xFFFFF000);
    const nextpc = cpu.pc +% offset;
    if (nextpc % @sizeOf(u32) == 0) {
      cpu.pc = nextpc;
    } else {
      instructionAddressMisaligned(nextpc, cpu);
    }
  } else {
    cpu.pc += 4;
  }
}

fn bge(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchB(packets);
  std.log.debug("0x{x:0>8}: bge {s}(0x{x:0>8}), {s}(0x{x:0>8}), 0x{x:0>8} ({})", .{
    cpu.pc, register_names[params.rs1], cpu.rx[params.rs1], register_names[params.rs2], cpu.rx[params.rs2], params.imm, params.imm,
  });
  if (@bitCast(i32, cpu.rx[params.rs1]) >= @bitCast(i32, cpu.rx[params.rs2])) {
    const offset = if (params.imm & 0x00001000 == 0) params.imm else (params.imm | 0xFFFFF000);
    const nextpc = cpu.pc +% offset;
    if (nextpc % @sizeOf(u32) == 0) {
      cpu.pc = nextpc;
    } else {
      instructionAddressMisaligned(nextpc, cpu);
    }
  } else {
    cpu.pc += 4;
  }
}

fn bltu(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchB(packets);
  std.log.debug("0x{x:0>8}: bltu x{}(0x{x:0>8}), x{}(0x{x:0>8}), 0x{x:0>8} ({})", .{
    cpu.pc, params.rs1, cpu.rx[params.rs1], params.rs2, cpu.rx[params.rs2], params.imm, params.imm,
  });
  if (cpu.rx[params.rs1] < cpu.rx[params.rs2]) {
    const offset = if (params.imm & 0x00001000 == 0) params.imm else (params.imm | 0xFFFFF000);
    const nextpc = cpu.pc +% offset;
    if (nextpc % @sizeOf(u32) == 0) {
      cpu.pc = nextpc;
    } else {
      instructionAddressMisaligned(nextpc, cpu);
    }
  } else {
    cpu.pc += 4;
  }
}

fn bgeu(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchB(packets);
  std.log.debug("0x{x:0>8}: bgeu x{}(0x{x:0>8}), x{}(0x{x:0>8}), 0x{x:0>8} ({})", .{
    cpu.pc, params.rs1, cpu.rx[params.rs1], params.rs2, cpu.rx[params.rs2], params.imm, params.imm,
  });
  if (cpu.rx[params.rs1] >= cpu.rx[params.rs2]) {
    const offset = if (params.imm & 0x00001000 == 0) params.imm else (params.imm | 0xFFFFF000);
    const nextpc = cpu.pc +% offset;
    if (nextpc % @sizeOf(u32) == 0) {
      cpu.pc = nextpc;
    } else {
      instructionAddressMisaligned(nextpc, cpu);
    }
  } else {
    cpu.pc += 4;
  }
}

fn addi(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchI(packets);
  std.log.debug("0x{x:0>8}: addi {s}, {s}(0x{x:0>8}), 0x{x:0>8}", .{
    cpu.pc, register_names[params.rd], register_names[params.rs1], cpu.rx[params.rs1], params.imm,
  });
  const imm: u32 = if (params.imm & 0x00000800 == 0) params.imm else (params.imm | 0xFFFFF800);
  cpu.rx[params.rd] = cpu.rx[params.rs1] +% imm;
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn lb(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchI(packets);
  std.log.debug("0x{x:0>8}: lb x{}, x{}(0x{x:0>8} + 0x{x:0>8} = 0x{x:0>8}) [0x{x:0>8}]", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.imm,
    cpu.rx[params.rs1] + params.imm, cpu.mem[cpu.rx[params.rs1] + params.imm],
  });
  const offset = if (params.imm & 0x00000800 == 0) params.imm else (params.imm | 0xFFFFF800);
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
  std.log.debug("0x{x:0>8}: lh x{}, x{}(0x{x:0>8} + 0x{x:0>8} = 0x{x:0>8}) [0x{x:0>8}]", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.imm,
    cpu.rx[params.rs1] + params.imm, cpu.mem[cpu.rx[params.rs1] + params.imm],
  });
  const offset = if (params.imm & 0x00000800 == 0) params.imm else (params.imm | 0xFFFFF800);
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
  std.log.debug("0x{x:0>8}: lw x{}, x{}(0x{x:0>8} + 0x{x:0>8} = 0x{x:0>8})", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.imm,
    cpu.rx[params.rs1] + params.imm,
  });
  const offset = if (params.imm & 0x00000800 == 0) params.imm else (params.imm | 0xFFFFF800);
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
  std.log.debug("0x{x:0>8}: lbu x{}, x{}(0x{x:0>8} + 0x{x:0>8} = 0x{x:0>8}) [0x{x:0>8}]", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.imm,
    cpu.rx[params.rs1] + params.imm, cpu.mem[cpu.rx[params.rs1] + params.imm],
  });
  const offset = if (params.imm & 0x00000800 == 0) params.imm else (params.imm | 0xFFFFF800);
  const address = cpu.rx[params.rs1] +% offset;
  cpu.rx[params.rd] = cpu.mem[address];
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn lhu(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchI(packets);
  std.log.debug("0x{x:0>8}: lhu x{}, x{}(0x{x:0>8} + 0x{x:0>8} = 0x{x:0>8}) [0x{x:0>8}]", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.imm,
    cpu.rx[params.rs1] + params.imm, cpu.mem[cpu.rx[params.rs1] + params.imm],
  });
  const offset = if (params.imm & 0x00000800 == 0) params.imm else (params.imm | 0xFFFFF800);
  const address = cpu.rx[params.rs1] +% offset;
  cpu.rx[params.rd] = @as(u32, cpu.mem[address]) | (@as(u32, cpu.mem[address + 1]) << 8);
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn sb(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchS(packets);
  std.log.debug("0x{x:0>8}: sb x{}(0x{x:0>8}), x{}(0x{x:0>8} + 0x{x:0>8} = 0x{x:0>8})", .{
    cpu.pc, params.rs2, cpu.rx[params.rs2], params.rs1, cpu.rx[params.rs1], params.imm, cpu.rx[params.rs1] + params.imm,
  });
  const offset = if (params.imm & 0x00000800 == 0) params.imm else (params.imm | 0xFFFFF800);
  cpu.mem[cpu.rx[params.rs1] +% offset] = @intCast(u8, cpu.rx[params.rs2] & 0x000000FF);
  cpu.pc += 4;
}

fn sh(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchS(packets);
  std.log.debug("0x{x:0>8}: sh x{}(0x{x:0>8}), x{}(0x{x:0>8} + 0x{x:0>8} = 0x{x:0>8})", .{
    cpu.pc, params.rs2, cpu.rx[params.rs2], params.rs1, cpu.rx[params.rs1], params.imm, cpu.rx[params.rs1] + params.imm,
  });
  const offset = if (params.imm & 0x00000800 == 0) params.imm else (params.imm | 0xFFFFF800);
  const address = cpu.rx[params.rs1] +% offset;
  const value = cpu.rx[params.rs2];
  cpu.mem[address] = @intCast(u8, value & 0x000000FF);
  cpu.mem[address + 1] = @intCast(u8, (value & 0x0000FF00) >> 8);
  cpu.pc += 4;
}

fn sw(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchS(packets);
  std.log.debug("0x{x:0>8}: sw x{}(0x{x:0>8}), x{}(0x{x:0>8} + 0x{x:0>8} = 0x{x:0>8})", .{
    cpu.pc, params.rs2, cpu.rx[params.rs2], params.rs1, cpu.rx[params.rs1], params.imm, cpu.rx[params.rs1] + params.imm,
  });
  const offset = if (params.imm & 0x00000800 == 0) params.imm else (params.imm | 0xFFFFF800);
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
  std.log.debug("0x{x:0>8}: slti x{}, x{}(0x{x:0>8}), 0x{x:0>8}", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.imm,
  });
  const imm: i32 = @bitCast(i32, if (params.imm & 0x00000800 == 0) params.imm else (params.imm | 0xFFFFF800));
  cpu.rx[params.rd] = if (@bitCast(i32, cpu.rx[params.rs1]) < imm) 1 else 0;
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn sltiu(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchI(packets);
  std.log.debug("0x{x:0>8}: sltiu x{}, x{}(0x{x:0>8}), 0x{x:0>8}", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.imm,
  });
  const imm = if (params.imm & 0x00000800 == 0) params.imm else (params.imm | 0xFFFFF800);
  cpu.rx[params.rd] = if (cpu.rx[params.rs1] < imm) 1 else 0;
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn xori(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchI(packets);
  std.log.debug("0x{x:0>8}: xori x{}, x{}(0x{x:0>8}), 0x{x:0>8}", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.imm,
  });
  const imm = if (params.imm & 0x00000800 == 0) params.imm else (params.imm | 0xFFFFF800);
  cpu.rx[params.rd] = cpu.rx[params.rs1] ^ imm;
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn ori(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchI(packets);
  std.log.debug("0x{x:0>8}: ori x{}, x{}(0x{x:0>8}), 0x{x:0>8}", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.imm,
  });
  const imm = if (params.imm & 0x00000800 == 0) params.imm else (params.imm | 0xFFFFF800);
  cpu.rx[params.rd] = cpu.rx[params.rs1] | imm;
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn andi(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchI(packets);
  std.log.debug("0x{x:0>8}: andi x{}, x{}(0x{x:0>8}), 0x{x:0>8}", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.imm,
  });
  const imm = if (params.imm & 0x00000800 == 0) params.imm else (params.imm | 0xFFFFF800);
  cpu.rx[params.rd] = cpu.rx[params.rs1] & imm;
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn slli(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchI(packets);
  std.log.debug("0x{x:0>8}: slli x{}, x{}(0x{x:0>8}), 0x{x:0>8}", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.imm,
  });
  const imm: u5 = @intCast(u5, params.imm & 0x0000001F);
  cpu.rx[params.rd] = cpu.rx[params.rs1] << imm;
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn srli(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchI(packets);
  std.log.debug("0x{x:0>8}: srli x{}, x{}(0x{x:0>8}), 0x{x:0>8}", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.imm,
  });
  const imm: u5 = @intCast(u5, params.imm & 0x0000001F);
  cpu.rx[params.rd] = cpu.rx[params.rs1] >> imm;
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn srai(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchI(packets);
  std.log.debug("0x{x:0>8}: srai x{}, x{}(0x{x:0>8}), 0x{x:0>8}", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.imm,
  });
  const imm: u5 = @intCast(u5, params.imm & 0x0000001F);
  // Right shift will copy the original sign bit into the shift if the operand is signed.
  cpu.rx[params.rd] = @bitCast(u32, @bitCast(i32, cpu.rx[params.rs1]) >> imm);
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn add(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: add x{}, x{}(0x{x:0>8}), x{}(0x{x:0>8})", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.rs2, cpu.rx[params.rs2],
  });
  cpu.rx[params.rd] = cpu.rx[params.rs1] +% cpu.rx[params.rs2];
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn sub(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: sub x{}, x{}(0x{x:0>8}), x{}(0x{x:0>8})", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.rs2, cpu.rx[params.rs2],
  });
  cpu.rx[params.rd] = cpu.rx[params.rs1] -% cpu.rx[params.rs2];
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn sll(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: sll x{}, x{}(0x{x:0>8}), x{}(0x{x:0>8})", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.rs2, cpu.rx[params.rs2],
  });
  const shift: u5 = @intCast(u5, cpu.rx[params.rs2] & 0x0000001F);
  cpu.rx[params.rd] = cpu.rx[params.rs1] << shift;
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn slt(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: slt x{}, x{}(0x{x:0>8}), x{}(0x{x:0>8})", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.rs2, cpu.rx[params.rs2],
  });
  cpu.rx[params.rd] = if (@bitCast(i32, cpu.rx[params.rs1]) < @bitCast(i32, cpu.rx[params.rs2])) 1 else 0;
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn sltu(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: sltu x{}, x{}(0x{x:0>8}), x{}(0x{x:0>8})", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.rs2, cpu.rx[params.rs2],
  });
  cpu.rx[params.rd] = if (cpu.rx[params.rs1] < cpu.rx[params.rs2]) 1 else 0;
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn xor(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: xor x{}, x{}(0x{x:0>8}), x{}(0x{x:0>8})", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.rs2, cpu.rx[params.rs2],
  });
  cpu.rx[params.rd] = cpu.rx[params.rs1] ^ cpu.rx[params.rs2];
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn srl(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: srl x{}, x{}(0x{x:0>8}), x{}(0x{x:0>8})", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.rs2, cpu.rx[params.rs2],
  });
  const shift: u5 = @intCast(u5, cpu.rx[params.rs2] & 0x0000001F);
  cpu.rx[params.rd] = cpu.rx[params.rs1] >> shift;
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn sra(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: sra x{}, x{}(0x{x:0>8}), x{}(0x{x:0>8})", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.rs2, cpu.rx[params.rs2],
  });
  const shift: u5 = @intCast(u5, cpu.rx[params.rs2] & 0x0000001F);
  cpu.rx[params.rd] = @bitCast(u32, @bitCast(i32, cpu.rx[params.rs1]) >> shift);
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn or_(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: or x{}, x{}(0x{x:0>8}), x{}(0x{x:0>8})", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.rs2, cpu.rx[params.rs2],
  });
  cpu.rx[params.rd] = cpu.rx[params.rs1] | cpu.rx[params.rs2];
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn and_(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchR(packets);
  std.log.debug("0x{x:0>8}: and x{}, x{}(0x{x:0>8}), x{}(0x{x:0>8})", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.rs2, cpu.rx[params.rs2],
  });
  cpu.rx[params.rd] = cpu.rx[params.rs1] & cpu.rx[params.rs2];
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

// ecall is the equivalent of raising an interruption. In fact, interruptions
// can use ecall as a template.
fn ecall(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchI(packets);
  if (params.imm == 1) {
    // EBREAK
    return RiscError.InstructionNotImplemented;
  }
  std.log.debug("0x{x:0>8}: ecall", .{ cpu.pc });
  exception(@enumToInt(csr.MCauseExceptionCode.MachineModeEnvCall), 0, cpu);
}

fn mret(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  _ = packets;
  std.log.debug("0x{x:0>8}: mret mpec = 0x{x:0>8}", .{ cpu.pc, cpu.csr[0x341] });
  // riscv-privileged-20211203.pdf Ch. 3.1.6 Machine Status Register (mstatus)
  // Set privilege mode to Machine Previous Privilege (MPP) mode as set in the mstatus register.
  cpu.priv_level = @intCast(u3, (csr.csrRegistry[csr.mstatus].get(cpu.*) & 0x00001800) >> 11);
  cpu.priv_level = 0x3; // Force Machine mode which is the only mode implemented right now.
  // Set Machine Previous Interrupt Enabled (MPIE) to 1.
  csr.csrRegistry[csr.mstatus].set(cpu, csr.csrRegistry[csr.mstatus].get(cpu.*) | 0x00000080);
  // Set Machine Previous Privilege (MPP) to least privilege mode (now Machine).
  csr.csrRegistry[csr.mstatus].set(cpu, csr.csrRegistry[csr.mstatus].get(cpu.*) | 0x00001800);
  cpu.pc = cpu.csr[0x341]; // mepc csr
  checkForInterrupt(cpu); // riscv-privileged-20211203.pdf Ch. 3.1.9
}

fn csrrs(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchI(packets);
  std.log.debug("0x{x:0>8}: csrrs x{}, x{}(0x{x:0>8}), 0x{x:0>8} ({s})", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.imm, csr.csrRegistry[params.imm].name,
  });
  if (cpu.priv_level < (csr.csrRegistry[params.imm].flags & csr.ModeMask)) {
    return RiscError.InsufficientPrivilegeMode;
  }
  const initial_value = cpu.rx[params.rs1];
  cpu.rx[params.rd] = cpu.csr[params.imm];
  if (csr.csrRegistry[params.imm].flags & @enumToInt(csr.Flags.WRITE) != 0) {
    csr.csrRegistry[params.imm].set(cpu, csr.csrRegistry[params.imm].get(cpu.*) | initial_value);
  }
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn csrrc(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchI(packets);
  std.log.debug("0x{x:0>8}: csrrs x{}, x{}(0x{x:0>8}), 0x{x:0>8} ({s})", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.imm, csr.csrRegistry[params.imm].name,
  });
  if (cpu.priv_level < (csr.csrRegistry[params.imm].flags & csr.ModeMask)) {
    return RiscError.InsufficientPrivilegeMode;
  }
  const initial_value = cpu.rx[params.rs1];
  cpu.rx[params.rd] = cpu.csr[params.imm];
  if (csr.csrRegistry[params.imm].flags & @enumToInt(csr.Flags.WRITE) != 0) {
    csr.csrRegistry[params.imm].set(cpu, csr.csrRegistry[params.imm].get(cpu.*) & (~initial_value));
  }
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn csrrw(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchI(packets);
  std.log.debug("0x{x:0>8}: csrrw x{}, x{}(0x{x:0>8}), 0x{x:0>8} ({s})", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.imm, csr.csrRegistry[params.imm].name,
  });
  if (cpu.priv_level < (csr.csrRegistry[params.imm].flags & csr.ModeMask)) {
    return RiscError.InsufficientPrivilegeMode;
  }
  const initial_value = cpu.rx[params.rs1];
  cpu.rx[params.rd] = cpu.csr[params.imm];
  if (csr.csrRegistry[params.imm].flags & @enumToInt(csr.Flags.WRITE) != 0) {
    csr.csrRegistry[params.imm].set(cpu, initial_value);
  }
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn csrrwi(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchI(packets);
  std.log.debug("0x{x:0>8}: csrrwi x{}, x{}(0x{x:0>8}), 0x{x:0>8} ({s})", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.imm, csr.csrRegistry[params.imm].name,
  });
  if (cpu.priv_level < (csr.csrRegistry[params.imm].flags & csr.ModeMask)) {
    return RiscError.InsufficientPrivilegeMode;
  }
  const initial_value = params.rs1;
  cpu.rx[params.rd] = csr.csrRegistry[params.imm].get(cpu.*);
  if (csr.csrRegistry[params.imm].flags & @enumToInt(csr.Flags.WRITE) != 0) {
    csr.csrRegistry[params.imm].set(cpu, initial_value);
  }
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn csrrsi(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchI(packets);
  std.log.debug("0x{x:0>8}: csrrs x{}, x{}(0x{x:0>8}), 0x{x:0>8} ({s})", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.imm, csr.csrRegistry[params.imm].name,
  });
  if (cpu.priv_level < (csr.csrRegistry[params.imm].flags & csr.ModeMask)) {
    return RiscError.InsufficientPrivilegeMode;
  }
  const initial_value = params.rs1;
  cpu.rx[params.rd] = cpu.csr[params.imm];
  if (csr.csrRegistry[params.imm].flags & @enumToInt(csr.Flags.WRITE) != 0) {
    csr.csrRegistry[params.imm].set(cpu, csr.csrRegistry[params.imm].get(cpu.*) | initial_value);
  }
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

fn csrrci(instruction: Instruction, cpu: *RiscVCPU(u32), packets: u32) RiscError!void {
  _ = instruction;
  const params = fetchI(packets);
  std.log.debug("0x{x:0>8}: csrrs x{}, x{}(0x{x:0>8}), 0x{x:0>8} ({s})", .{
    cpu.pc, params.rd, params.rs1, cpu.rx[params.rs1], params.imm, csr.csrRegistry[params.imm].name,
  });
  if (cpu.priv_level < (csr.csrRegistry[params.imm].flags & csr.ModeMask)) {
    return RiscError.InsufficientPrivilegeMode;
  }
  const initial_value = params.rs1;
  cpu.rx[params.rd] = cpu.csr[params.imm];
  if (csr.csrRegistry[params.imm].flags & @enumToInt(csr.Flags.WRITE) != 0) {
    csr.csrRegistry[params.imm].set(cpu, csr.csrRegistry[params.imm].get(cpu.*) & (~initial_value));
  }
  cpu.rx[0] = 0;
  cpu.pc += 4;
}

// This functor will create a function that will sort the instruction set at
// compile time and unroll a for loop to accelerate the search of instruction.
pub fn makeDecoder(comptime instruction_set: []const Instruction) fn(opcode: u8, funct3: u8, funct7: u8) GetInstruction!Instruction {
  const _inner = struct {
    // https://github.com/ziglang/zig/blob/6b3f59c3a735ddbda3b3a62a0dfb5d55fa045f57/lib/std/comptime_string_map.zig
    pub fn decode(opcode: u8, funct3: u8, funct7: u8) GetInstruction!Instruction {
      const precomputed = comptime blk: {
        // @setEvalBranchQuota(2000);
        var sorted_opcodes = instruction_set[0..].*;
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
  };

  return _inner.decode;
}

const decode = makeDecoder(&base_instruction_set ++ zifencei_set ++ zicsr_set ++ mul.m_extension_set);

const Code = struct { opcode: u8, funct3: u8, funct7: u8 };

pub inline fn fetch(packet: u32) Code {
  const opcode: u8 = @intCast(u8, 0x7F & packet);
  const funct3: u8 = @intCast(u8, (0x7000 & packet) >> 12);
  const funct7: u8 = @intCast(u8, (0xFE000000 & packet) >> 25);

  return .{
    .opcode = opcode,
    .funct3 = funct3,
    .funct7 = funct7,
  };
}

pub const ErrCode = union(enum) {
  UnknownInstruction: Code,
  InstructionNotImplemented: struct { code: Code, inst: Instruction },
  InsufficientPrivilegeMode: struct { code: Code, inst: Instruction, priv_level: u7, },
  UnhandledTrapVectorMode: struct { code: Code },
};

// riscv-privileged-20211203.pdf Ch. 3.1.9
pub fn checkForInterrupt(cpu: *RiscVCPU(u32)) void {
  const mip = csr.csrRegistry[csr.mip].get(cpu.*);
  if (mip != 0) { // is an interrupt is pending?
    if (cpu.priv_level == @enumToInt(csr.PrivilegeMode.MACHINE) and // If in Machine mode
      (csr.csrRegistry[csr.mstatus].get(cpu.*) & csr.MstatusBits.MIE) != 0) { // and interrupts are enabled
      // Fetch the pending interrupt
      const mie = csr.csrRegistry[csr.mie].get(cpu.*);
      // Priority order: MEI, MSI, MTI, SEI, SSI, STI according to riscv-privileged-20211203.pdf Ch. 3.1.9
      if ((mip & mie & 11) != 0) { // External (hardware) interrupt
        interrupt(@enumToInt(csr.MCauseInterruptCode.MachineExternalInterrupt) & 0x80000000, 0, cpu);
      }
      if ((mip & mie &  3) != 0) { // Software interrupt
        interrupt(@enumToInt(csr.MCauseInterruptCode.MachineSoftwareInterrupt) & 0x80000000, 0, cpu);
      }
      if ((mip & mie &  7) != 0) { // Timer interrupt
        interrupt(@enumToInt(csr.MCauseInterruptCode.MachineTimerInterrupt) & 0x80000000, 0, cpu);
      }

      // const SSIP = mip &  1;
      // const STIP = (mip &  5) and (mie &  5);
      // const SEIP = (mip &  9) and (mie &  9);
    }
  }
}

fn interrupt(cause: u32, mtval: u32, cpu: *RiscVCPU(u32)) void {
  // TODO: What should be done on interrupt? The same thing as an exception?
  exception(cause, mtval, cpu);
}

fn exception(cause: u32, mtval: u32, cpu: *RiscVCPU(u32)) void {
  // From https://mullerlee.cyou/2020/07/09/riscv-exception-interrupt/
  // update mcause with is_interupt and exception_code
  csr.csrRegistry[csr.mcause].set(cpu, cause);
  // update mtval with exception-specific information
  // according to riscv-privileged-20211203.pdf Ch. 3.1.16, mtval contains information on error 0 otherwise.
  csr.csrRegistry[csr.mtval].set(cpu, mtval);
  // update mstatus with current mode (also riscv-privileged-20211203.pdf Ch. 3.1.6.1 Privileged and Global Interrupt-enable Stack in mstatus)
  csr.csrRegistry[csr.mstatus].set(cpu, csr.csrRegistry[csr.mstatus].get(cpu.*) | (@intCast(u32, cpu.priv_level) << 11));
  // update mstatus to disable interrupt
  csr.csrRegistry[csr.mstatus].set(cpu, csr.csrRegistry[csr.mstatus].get(cpu.*) & 0xFFFFFFF7);
  // update mepc with current instruction address (also riscv-privileged-20211203.pdf Ch. 3.3.1 Environment Call and Breakpoint)
  csr.csrRegistry[csr.mepc].set(cpu, cpu.pc);
  // Guessed from https://jborza.com/emulation/2021/04/22/ecalls-and-syscalls.html. Where is this documented?
  cpu.pc = csr.csrRegistry[csr.mtvec].get(cpu.*);
}

fn illegalInstruction(packets: u32, cpu: *RiscVCPU(u32)) void {
  if (std_options.log_level == .debug) {
    const code = fetch(packets);
    std.log.debug("Illegal instruction 0x{x:0>8} @ 0x{x:0>8} (opcode: 0b{b} funct3: 0b{b} funct7: 0b{b})", .{
      packets, cpu.pc, code.opcode, code.funct3, code.funct7,
    });
  }
  exception(@enumToInt(csr.MCauseExceptionCode.IllegalInstruction), packets, cpu);
}

fn instructionAddressMisaligned(badaddress: u32, cpu: *RiscVCPU(u32)) void {
  std.log.debug("Instruction address misaligned @ 0x{x:0>8}", .{ cpu.pc });
  exception(@enumToInt(csr.MCauseExceptionCode.InstructionAddressMisaligned), badaddress, cpu);
}

fn incrementCycle(cpu: *RiscVCPU(u32)) void {
  cpu.csr[0xB00] = cpu.csr[0xB00] +% 1;
  if (cpu.csr[0xB00] == 0) {
    cpu.csr[0xB80] = cpu.csr[0xB80] +% 1;
  }
  // TODO: minstret is probably not equal to cycle though.
  cpu.csr[0xB02] = cpu.csr[0xB00];
  cpu.csr[0xB82] = cpu.csr[0xB80];
  // if (cpu.csr[0xB00] % 1000000 == 0) {
  //   debug.dump_cpu(cpu.*);
  // }
}

pub fn cycle(cpu: *RiscVCPU(u32)) !?ErrCode {
  // If we do not handle compressed instruction, all instructions address must be aligned
  if (cpu.pc % @sizeOf(u32) != 0) {
    instructionAddressMisaligned(cpu.pc, cpu);
  }
  var packets: u32 = cpu.mem[cpu.pc] |
    @as(u32, cpu.mem[cpu.pc + 1]) << 8 |
    @as(u32, cpu.mem[cpu.pc + 2]) << 16 |
    @as(u32, cpu.mem[cpu.pc + 3]) << 24;

  const code = fetch(packets);
  const inst = decode(code.opcode, code.funct3, code.funct7) catch |err| {
    _ = switch (err) {
      GetInstruction.UnknownInstruction => {
        illegalInstruction(packets, cpu);
      },
    };
    return null;
  };
  inst.handler(inst, cpu, packets) catch |err| {
    _ = switch (err) {
      RiscError.InstructionNotImplemented => {
        return ErrCode{ .InstructionNotImplemented = .{ .code = code, .inst = inst } };
      },
      RiscError.InsufficientPrivilegeMode => {
        return ErrCode{ .InsufficientPrivilegeMode = .{ .code = code, .inst = inst, .priv_level = cpu.priv_level } };
      },
      RiscError.UnhandledTrapVectorMode => {
        return ErrCode{ .UnhandledTrapVectorMode = .{ .code = code } };
      },
    };
    return err;
  };
  // TODO: Find a way to keep x0 always equal to 0 in a better way.
  cpu.rx[0] = 0x0;
  incrementCycle(cpu);
  return null;
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

pub const std_options = struct {
  // pub const log_level = .debug;
  pub const log_level = .info;
};

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
    .csr = init_csr(u32, &rv32_initial_csr_values),
  };
  defer allocator.free(cpu.raw_mem);

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
    allocator.free(cpu.raw_mem);
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
    std.log.debug("dtb_addr 0x{x:0>8} options.page_offset 0x{x:0>8}", .{ dtb_addr, options.page_offset });
    cpu.rx[11] = dtb_addr; // a1
  }
  // Load the executable at the memory start
  std.mem.copy(u8, cpu.raw_mem, executable);
  std.os.munmap(executable);

  // Start the emulation.
  while (true) {
    if (try cycle(&cpu)) |ret| {
      switch (ret) {
        ErrCode.UnknownInstruction => |code| {
          debug.dump_cpu(cpu);
          println("error: unknown instruction: 0b{b} (funct3: 0b{b} funct7: 0b{b})", .{
            code.opcode, code.funct3, code.funct7,
          });
          return 1;
        },
        ErrCode.InstructionNotImplemented => |payload| {
          debug.dump_cpu(cpu);
          println("error: instruction not implemented: {s} (opcode: 0b{b} funct3: 0b{b} funct7: 0b{b})", .{
            payload.inst.name, payload.code.opcode, payload.code.funct3, payload.code.funct7,
          });
          return 2;
        },
        ErrCode.InsufficientPrivilegeMode => |payload| {
          debug.dump_cpu(cpu);
          println("error: insufficient privilege level for operation: CPU level {} instruction {s}", .{
            payload.priv_level, payload.inst.name,
          });
          return 3;
        },
        ErrCode.UnhandledTrapVectorMode => |payload| {
          debug.dump_cpu(cpu);
          println("error: Unhandled trap vector mode {any}", .{ payload });
          return 4;
        },
      }
    }
  }

  return 0;
}
