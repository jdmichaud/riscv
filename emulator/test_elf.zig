const std = @import("std");
const riscv = @import("riscv.zig");

fn print(comptime fmt: []const u8, args: anytype) void {
  std.io.getStdOut().writer().print(fmt, args) catch {};
}

fn println(comptime fmt: []const u8, args: anytype) void {
  std.io.getStdOut().writer().print(fmt ++ "\n", args) catch {};
}

fn load_elf(allocator: std.mem.Allocator, filename: []const u8, mem: []u8) !void {
  const elf_file = try std.fs.cwd().openFile(filename, .{});
  const elf_hdr = try std.elf.Header.read(elf_file);
  var section_headers = elf_hdr.section_header_iterator(elf_file);
  var section_counter: usize = 0;
  while (section_counter < elf_hdr.shstrndx) : (section_counter += 1) {
      _ = (try section_headers.next()).?;
  }

  const shstrtab_shdr = (try section_headers.next()).?;

  const shstrtab = try allocator.alloc(u8, @intCast(usize, shstrtab_shdr.sh_size));
  errdefer allocator.free(shstrtab);

  const num_read = try elf_file.preadAll(shstrtab, shstrtab_shdr.sh_offset);
  if (num_read != shstrtab.len) return error.EndOfStream;

  // section_headers = elf_hdr.section_header_iterator(elf_file);
  // while (try section_headers.next()) |section| {
  //   const name = std.mem.span(@ptrCast([*:0]const u8, &shstrtab[section.sh_name]));
  //   println("{s} @0x{x:0>8}+0x{x:0>8}(0x{x:0>8})", .{ name, section.sh_addr, section.sh_offset, section.sh_size });
  //   println(" {any}", .{ section });
  // }
  var program_headers = elf_hdr.program_header_iterator(elf_file);
  while (try program_headers.next()) |section| {
    std.log.debug("@0x{x:0>8}(@0x{x:0>8}) -> @0x{x:0>8}(@0x{x:0>8})", .{ section.p_offset, section.p_filesz, section.p_vaddr, section.p_filesz });
    _ = try elf_file.preadAll(mem[section.p_vaddr..section.p_vaddr + section.p_filesz], section.p_offset);
  }
}

pub const std_options = struct {
  pub const log_level = .debug;
  // pub const log_level = .info;
};

pub fn main() !void {
  var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
  const allocator = general_purpose_allocator.allocator();

  const args: [][:0]u8 = try std.process.argsAlloc(allocator);
  defer std.process.argsFree(allocator, args);

  const offset = 0x80000000;
  var mem = try allocator.alloc(u8, 1024 * 1024 * 64); // 4K addressable memory

  var fails: u16 = 0;
  for (args[1..]) |fixture_file| {
    // Create a CPU
    var cpu: riscv.RiscVCPU(u32) = .{
      .pc = offset,
      // Memory as allocated
      .raw_mem = mem,
      // Memory with an "inverse" offset. Accessing mem[page_offset] will access raw_mem[0x0]
      .mem = (mem.ptr - offset)[0..offset + mem.len],
      .csr = riscv.init_csr(u32, &riscv.rv32_initial_csr_values),
    };
    std.mem.set(u8, cpu.raw_mem, 0);

    println("executing {s}...", .{ fixture_file });
    try load_elf(allocator, fixture_file, cpu.mem);
    while (true) {
      if (riscv.cycle(&cpu) catch { fails += 1; break; }) |ret| {
        fails += 1;
        riscv.dump_cpu(cpu);
        switch (ret) {
          riscv.ErrCode.UnknownInstruction => |code| {
            println("error: unknown instruction: 0b{b} (funct3: 0b{b} funct7: 0b{b})", .{
              code.opcode, code.funct3, code.funct7,
            });
            break;
          },
          riscv.ErrCode.InstructionNotImplemented => |payload| {
            println("error: instruction not implemented: {s} (opcode: 0b{b:0>7} funct3: 0b{b:0>3} funct7: 0b{b:0>7})", .{
              payload.inst.name, payload.code.opcode, payload.code.funct3, payload.code.funct7,
            });
            break;
          },
          riscv.ErrCode.InsufficientPrivilegeMode => |payload| {
            println("error: insufficient privilege level for operation: CPU level {} instruction {s}", .{
              payload.priv_level, payload.inst.name,
            });
            break;
          },
          else => {
            println("error: unknown error {any}", .{ ret });
            break;
          },
        }
      }
    }
    println("{} FAILS / {} TOTAL", .{ fails, args.len - 1 });
  }
}
