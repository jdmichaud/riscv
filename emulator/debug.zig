const std = @import("std");
const csr = @import("csr.zig");
const RiscVCPU = @import("riscv.zig").RiscVCPU;

pub fn println(comptime fmt: []const u8, args: anytype) void {
  std.io.getStdOut().writer().print(fmt ++ "\n", args) catch {};
}

pub const register_names = [_][]const u8{
  "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1", "a0", "a1",
  "a2", "a3", "a4", "a5", "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7", "s8",
  "s9", "s10", "s11", "t3", "t4", "t5", "t6",
};

pub fn dump_cpu(cpu: RiscVCPU(u32)) void {
  println("{s: <6} = 0x{x:0>8} {s: <6} = 0x{x:0>8} {s: <7} = 0x{x:0>8} {s: <6} = 0x{x:0>8}", .{ register_names[0 ], cpu.rx[0 ], register_names[8 ], cpu.rx[8 ], register_names[16], cpu.rx[16], register_names[24], cpu.rx[24] });
  println("{s: <6} = 0x{x:0>8} {s: <6} = 0x{x:0>8} {s: <7} = 0x{x:0>8} {s: <6} = 0x{x:0>8}", .{ register_names[1 ], cpu.rx[1 ], register_names[9 ], cpu.rx[9 ], register_names[17], cpu.rx[17], register_names[25], cpu.rx[25] });
  println("{s: <6} = 0x{x:0>8} {s: <6} = 0x{x:0>8} {s: <7} = 0x{x:0>8} {s: <6} = 0x{x:0>8}", .{ register_names[2 ], cpu.rx[2 ], register_names[10], cpu.rx[10], register_names[18], cpu.rx[18], register_names[26], cpu.rx[26] });
  println("{s: <6} = 0x{x:0>8} {s: <6} = 0x{x:0>8} {s: <7} = 0x{x:0>8} {s: <6} = 0x{x:0>8}", .{ register_names[3 ], cpu.rx[3 ], register_names[11], cpu.rx[11], register_names[19], cpu.rx[19], register_names[27], cpu.rx[27] });
  println("{s: <6} = 0x{x:0>8} {s: <6} = 0x{x:0>8} {s: <7} = 0x{x:0>8} {s: <6} = 0x{x:0>8}", .{ register_names[4 ], cpu.rx[4 ], register_names[12], cpu.rx[12], register_names[20], cpu.rx[20], register_names[28], cpu.rx[28] });
  println("{s: <6} = 0x{x:0>8} {s: <6} = 0x{x:0>8} {s: <7} = 0x{x:0>8} {s: <6} = 0x{x:0>8}", .{ register_names[5 ], cpu.rx[5 ], register_names[13], cpu.rx[13], register_names[21], cpu.rx[21], register_names[29], cpu.rx[29] });
  println("{s: <6} = 0x{x:0>8} {s: <6} = 0x{x:0>8} {s: <7} = 0x{x:0>8} {s: <6} = 0x{x:0>8}", .{ register_names[6 ], cpu.rx[6 ], register_names[14], cpu.rx[14], register_names[22], cpu.rx[22], register_names[30], cpu.rx[30] });
  println("{s: <6} = 0x{x:0>8} {s: <6} = 0x{x:0>8} {s: <7} = 0x{x:0>8} {s: <6} = 0x{x:0>8}", .{ register_names[7 ], cpu.rx[7 ], register_names[15], cpu.rx[15], register_names[23], cpu.rx[23], register_names[31], cpu.rx[31] });
  println("pc     = 0x{x:0>8}", .{ cpu.pc });
  println("mstatus= 0x{x:0>8} mtvec  = 0x{x:0>8} mscratch = 0x{x:0>8} mtval = 0x{x:0>8}", .{ cpu.csr[csr.mstatus], cpu.csr[csr.mtvec], cpu.csr[csr.mscratch], cpu.csr[csr.mtval] });
  println("mepc   = 0x{x:0>8} mcause = 0x{x:0>8}      mip = 0x{x:0>8}   mie = 0x{x:0>8}", .{ cpu.csr[csr.mepc], cpu.csr[csr.mcause], cpu.csr[csr.mip], cpu.csr[csr.mie] });
}
