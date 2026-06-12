const HResultError = @This();

/// a win32 HRESULT
hr: i32 = 0,
context: [:0]const u8,
pub fn set(
    self: *HResultError,
    hr: win32.HRESULT,
    context: [:0]const u8,
) error{HResult} {
    self.* = .{ .hr = @bitCast(hr), .context = context };
    return error.HResult;
}
pub fn format(self: HResultError, writer: *std.Io.Writer) error{WriteFailed}!void {
    try writer.print(
        "{s} failed, hresult=0x{x}",
        .{ self.context, @as(u32, @bitCast(self.hr)) },
    );
}

const std = @import("std");
const win32 = @import("win32").everything;
