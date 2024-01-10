const std = @import("std");
const riscv = @import("riscv.zig");
const mul = @import("mul.zig");
const atomic = @import("atomic.zig");

const StatementType = enum {
  csr_value,
  freg_value,
  xreg_value,
  pc_value,
  memory_value,
};
const Extension = enum {
  C,
  D,
  F,
  I,
  M,
};
const Statement = struct {
  type: StatementType,
  index: ?u16 = null,
  value: []const u8,
  size: ?u8 = null,
  address: ?u32 = null,
};

// Struct describing a test case to deserialize.
const TestCase = struct {
  extension: Extension,
  instruction: Instruction,
  text_encoding: []const u8,
  binary_encoding: []const u8,
  initials: []Statement,
  asserts: []Statement,
};

fn print(comptime fmt: []const u8, args: anytype) void {
  std.io.getStdOut().writer().print(fmt, args) catch {};
}

fn println(comptime fmt: []const u8, args: anytype) void {
  std.io.getStdOut().writer().print(fmt ++ "\n", args) catch {};
}

fn assertEqual(rhs: anytype, lhs: anytype, msg: []const u8) !void {
  if (rhs != lhs) {
    println("error: assertEqual failed: 0x{x:0>8} is not equal to 0x{x:0>8} {s}", .{ rhs, lhs, msg });
    return error.Assert;
  }
}

fn unzip(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
  var in_stream = std.io.fixedBufferStream(data);

  var gzip_stream = try std.compress.gzip.decompress(allocator, in_stream.reader());
  defer gzip_stream.deinit();

  // Read and decompress the whole file
  const buf = try gzip_stream.reader().readAllAlloc(allocator, std.math.maxInt(usize));
  return buf;
}

pub const std_options = struct {
  // pub const log_level = .debug;
  pub const log_level = .info;
};

fn load_fixture(allocator: std.mem.Allocator, filename: []const u8)
  !struct { parsed_data: []TestCase, skip_list: std.AutoHashMap(usize, bool) } {
  println("inflating {s}.json.gz...", .{ filename });
  // Load test cases
  const jsonfilename = try std.fmt.allocPrint(allocator, "{s}{s}", .{ filename, ".json.gz"});
  var file = try std.fs.cwd().openFile(jsonfilename, .{});
  defer file.close();
  // Map it in memory
  const file_size = try file.getEndPos();
  const buffer = try std.os.mmap(
    null,
    file_size,
    std.os.PROT.READ,
    std.os.MAP.SHARED,
    file.handle,
    0,
  );
  defer std.os.munmap(buffer);
  // Unzip it
  const content = try unzip(allocator, buffer);
  defer allocator.free(content);
  // var content = buffer;
  // Parse it
  println("parsing {s}.json.gz...", .{ filename });
  const parsed_data = try std.json.parseFromSlice([]TestCase, allocator, content, .{
    .ignore_unknown_fields = true,
  });
  var skip_list = std.AutoHashMap(usize, bool).init(allocator);
  // Load skip
  _ = blk: {
    const skip_filename = try std.fmt.allocPrint(allocator, "{s}{s}", .{ filename, ".skip"});
    println("loading {s}...", .{ skip_filename });
    var skipfile = std.fs.cwd().openFile(skip_filename, .{}) catch { break :blk; };
    defer skipfile.close();
    // Map it in memory
    const skipfile_size = try skipfile.getEndPos();
    const skipbuffer = try std.os.mmap(
      null,
      skipfile_size,
      std.os.PROT.READ,
      std.os.MAP.SHARED,
      skipfile.handle,
      0,
    );
    defer std.os.munmap(skipbuffer);
    // Split on ',' to ArrayList
    var splits = std.mem.split(u8, skipbuffer, ",");
    while (splits.next()) |split| {
      const skip = std.mem.trim(u8, try allocator.dupe(u8, split), "\n\r ");
      try skip_list.put(try std.fmt.parseInt(usize, skip, 10), true);
    }
  };

  return .{
    .parsed_data = parsed_data.value, // leaks but we don't care
    .skip_list = skip_list,
  };
}

pub fn main() !u8 {
  var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
  const allocator = general_purpose_allocator.allocator();

  const args: [][:0]u8 = try std.process.argsAlloc(allocator);
  defer std.process.argsFree(allocator, args);

  // Create a CPU
  const mem = try allocator.alloc(u8, std.math.pow(u64, 2, 32)); // 4G addressable memory
  var cpu: riscv.RiscVCPU(u32) = .{
    // Memory as allocated
    .raw_mem = mem,
    .mem = mem,
    .csr = riscv.init_csr(u32, &riscv.rv32_initial_csr_values),
  };

  const decode = riscv.makeDecoder(
    &riscv.base_instruction_set
    ++ riscv.zifencei_set
    ++ riscv.zicsr_set
    ++ mul.m_extension_set
    ++ atomic.a_extension_set
  );

  for (args[1..]) |fixture_file| {
    // Open the file
    // const test_filename = "tests/toto.json";
    const fixture = try load_fixture(allocator, fixture_file);

    // Go through the test cases
    mainloop: for (fixture.parsed_data, 0..) |testCase, i| {
      print("{} {s}", .{ i, testCase.text_encoding });
      if (fixture.skip_list.get(i) != null) {
        println(" skipped (skip list)", .{});
        continue :mainloop;
      }
      // Setup preconditions
      for (testCase.initials) |initial| {
        switch (initial.type) {
          .csr_value => unreachable,
          .freg_value => unreachable,
          .xreg_value => {
            const parsed = try std.fmt.parseInt(u64, initial.value, 0);
            if (parsed & 0xFFFFFFFF00000000 != 0xFFFFFFFF00000000 and
              parsed & 0xFFFFFFFF00000000 != 0) {
              // This is a 64 bits tests, skip it.
              println(" skipped (64 bits)", .{});
              continue :mainloop;
            }
            const value = @as(u32, @intCast(0x00000000FFFFFFFF & parsed));
            const register = initial.index.?;
            cpu.rx[register] = value;
          },
          .pc_value => {
            cpu.pc = @as(u32, @intCast(try std.fmt.parseInt(u64, initial.value, 0)));
          },
          .memory_value => {
            switch (initial.size.?) {
              1 => {
                cpu.mem[initial.address.?] = try std.fmt.parseInt(u8, initial.value, 0);
              },
              2 => {
                const value = try std.fmt.parseInt(u16, initial.value, 0);
                cpu.mem[initial.address.?] = @as(u8, @intCast(value & 0x00FF));
                cpu.mem[initial.address.? + 1] = @as(u8, @intCast((value & 0xFF00) >> 8));
              },
              4 => {
                const value = try std.fmt.parseInt(u32, initial.value, 0);
                cpu.mem[initial.address.?] = @as(u8, @intCast(value & 0x000000FF));
                cpu.mem[initial.address.? + 1] = @as(u8, @intCast((value & 0x0000FF00) >> 8));
                cpu.mem[initial.address.? + 2] = @as(u8, @intCast((value & 0x00FF0000) >> 16));
                cpu.mem[initial.address.? + 3] = @as(u8, @intCast((value & 0xFF000000) >> 24));
              },
              else => unreachable,
            }
          },
        }
      }
      // Execute the instruction
      const packets = try std.fmt.parseInt(u32, testCase.binary_encoding, 0);
      const code = riscv.fetch(packets);
      const inst = try decode(code.opcode, code.funct3, code.funct7);
      try inst.handler(inst, &cpu, packets);
      // Check the expectation
      for (testCase.asserts) |assert| {
        switch (assert.type) {
          .csr_value => unreachable,
          .freg_value => unreachable,
          .xreg_value => {
            const value = @as(u32, @intCast(0x00000000FFFFFFFF & try std.fmt.parseInt(u64, assert.value, 0)));
            const register = assert.index.?;
            try assertEqual(cpu.rx[register], @as(u32, @intCast(value)),
              try std.fmt.allocPrint(allocator, "xreg {} does not have the correct value", .{ register }));
          },
          .pc_value => {
            try assertEqual(cpu.pc, try std.fmt.parseInt(u32, assert.value, 0),
              "pc does not have the correct value");
          },
          .memory_value => {
            const address = assert.address.?;
            switch (assert.size.?) {
              1 => {
                try assertEqual(cpu.mem[address], try std.fmt.parseInt(u8, assert.value, 0),
                  try std.fmt.allocPrint(allocator, "mem@0x{x:0>8} does not have the correct value", .{ address }));
              },
              2 => {
                const value = try std.fmt.parseInt(u16, assert.value, 0);
                try assertEqual(cpu.mem[address], value & 0x00FF,
                  try std.fmt.allocPrint(allocator, "mem@0x{x:0>8} does not have the correct value", .{ address }));
                try assertEqual(cpu.mem[address + 1], (value & 0xFF00) >> 8,
                  try std.fmt.allocPrint(allocator, "mem@0x{x:0>8} does not have the correct value", .{ address + 1 }));
              },
              4 => {
                const value = try std.fmt.parseInt(u32, assert.value, 0);
                try assertEqual(cpu.mem[address], value & 0x000000FF,
                  try std.fmt.allocPrint(allocator, "mem@0x{x:0>8} does not have the correct value", .{ address }));
                try assertEqual(cpu.mem[address + 1], (value & 0x0000FF00) >> 8,
                  try std.fmt.allocPrint(allocator, "mem@0x{x:0>8} does not have the correct value", .{ address + 1 }));
                try assertEqual(cpu.mem[address + 2], (value & 0x00FF0000) >> 16,
                  try std.fmt.allocPrint(allocator, "mem@0x{x:0>8} does not have the correct value", .{ address + 2 }));
                try assertEqual(cpu.mem[address + 3], (value & 0xFF000000) >> 24,
                  try std.fmt.allocPrint(allocator, "mem@0x{x:0>8} does not have the correct value", .{ address + 3 }));
              },
              else => unreachable,
            }

          },
        }
      }
      println(" OK", .{});
    }
  }

  return 0;
}

const Instruction = enum {
  add, addi, addiw, addw, @"and", andi, auipc, beq, bge, bgeu, blt, bltu, bne, cadd,
  caddi, caddi16sp, caddi4spn, caddiw, caddw, cand, candi, cbeqz, cbnez, cj,
  cjalr, cjr, cld, cldsp, cli, clui, clw, clwsp, cmv, cor, csd, csdsp, cslli,
  csrai, csrli, csub, csubw, csw, cswsp, cxor, div, divu, divuw, divw, fadd_d,
  fadd_s, fclass_d, fclass_s, fcvt_d_l, fcvt_d_lu, fcvt_d_s, fcvt_d_w, fcvt_d_wu,
  fcvt_l_d, fcvt_lu_d, fcvt_s_d, fcvt_s_w, fcvt_s_wu, fcvt_w_d, fcvt_w_s,
  fcvt_wu_d, fcvt_wu_s, fdiv_d, fdiv_s, fence, feq_d, feq_s, fld, fle_d, fle_s,
  flt_d, flt_s, flw, fmadd_d, fmadd_s, fmax_d, fmax_s, fmin_d, fmin_s, fmsub_d,
  fmsub_s, fmul_d, fmul_s, fmv_d_x, fmv_w_x, fmv_x_d, fmv_x_w, fnmadd_d,
  fnmadd_s, fnmsub_d, fnmsub_s, fsd, fsgnj_d, fsgnjn_d, fsgnjn_s, fsgnj_s,
  fsgnjx_d, fsgnjx_s, fsqrt_d, fsqrt_s, fsub_d, fsub_s, fsw, jal, jalr, lb,
  lbu, ld, lh, lhu, lui, lw, lwu, mul, mulh, mulhsu, mulhu, mulw, @"or", ori, rem,
  remu, remuw, remw, sb, sd, sh, sll, slli, slliw, sllw, slt, slti, sltiu, sltu,
  sra, srai, sraiw, sraw, srl, srli, srliw, srlw, sub, subw, sw, xor, xori,
};
