const std = @import("std");

pub const Clock = struct {
  const Self = @This();

  mtimecmp: u64,

  pub inline fn getTime(_: Self) u64 {
    return @intCast(u64, std.time.microTimestamp());
  }

  pub inline fn getMTimeCmp(self: Self) u64 {
    return @intCast(u64, self.mtimecmp);
  }

  pub inline fn setMTimeCmpH(self: *Self, value: u32) void {
    self.mtimecmp = (self.mtimecmp & 0x00000000FFFFFFFF)
      | (@intCast(u64, value) << 32);
  }

  pub inline fn setMTimeCmpL(self: *Self, value: u32) void {
    self.mtimecmp = (self.mtimecmp & 0xFFFFFFFF00000000) | @intCast(u64, value);
  }
};

test "set mtimcmp" {
  var clock = Clock { .mtimecmp = 0x123456789ABCDEF0 };
  clock.setMTimeCmpL(0x01010101);
  try std.testing.expect(clock.getMTimeCmp() == 0x1234567801010101);
  clock.setMTimeCmpH(0xF0F0F0F0);
  try std.testing.expect(clock.getMTimeCmp() == 0xF0F0F0F001010101);
}
