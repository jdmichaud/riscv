const std = @import("std");

pub const Clock = struct {
  const Self = @This();

  mtimecmp: u64,

  pub fn getTime(_: Self) u64 {
    return @intCast(u64, std.time.microTimestamp());
  }

  pub fn getMTimeCmp(self: Self) u64 {
    return @intCast(u64, self.mtimecmp);
  }

  pub fn setMTimeCmpH(self: *Self, value: u32) void {
    self.mtimecmp &= (0xFFFFFFFF00000000 | @intCast(u64, value) << 32);
  }

  pub fn setMTimeCmpL(self: *Self, value: u32) void {
    self.mtimecmp &= (0x00000000FFFFFFFF | value);
  }
};
