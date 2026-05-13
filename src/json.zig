const std = @import("std");

/// Write a JSON-escaped string (without surrounding quotes) to the writer.
/// Handles: " \ \n \r \t and control chars < 0x20.
pub fn writeEscaped(writer: anytype, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try writer.print("\\u{x:0>4}", .{ch});
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
}

/// Write N spaces to the writer.
pub fn writeSpaces(writer: anytype, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try writer.writeByte(' ');
}

/// Write N levels of 2-space indentation.
pub fn writeIndent(writer: anytype, depth: usize) !void {
    var d: usize = 0;
    while (d < depth) : (d += 1) {
        try writer.writeAll("  ");
    }
}
