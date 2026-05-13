const std = @import("std");
const json_util = @import("json.zig");

/// Pretty-print response body based on Content-Type.
pub fn printPretty(allocator: std.mem.Allocator, body: []const u8, headers_raw: ?[]const u8, writer: anytype) !void {
    var is_json = false;
    var is_html = false;

    if (headers_raw) |raw| {
        var start: usize = 0;
        for (raw, 0..) |ch, i| {
            if (ch == '\n') {
                var line = raw[start..i];
                if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
                start = i + 1;
                if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                    const name = std.mem.trim(u8, line[0..colon], " ");
                    const value = std.mem.trim(u8, line[colon + 1 ..], " ");
                    if (std.ascii.eqlIgnoreCase(name, "content-type")) {
                        if (std.mem.indexOf(u8, value, "json") != null) is_json = true;
                        if (std.mem.indexOf(u8, value, "html") != null) is_html = true;
                        break;
                    }
                }
            }
        }
    }

    if (!is_json and !is_html and body.len > 0) {
        const trimmed = std.mem.trimLeft(u8, body, " \t\n\r");
        if (trimmed.len > 0 and (trimmed[0] == '{' or trimmed[0] == '[')) is_json = true;
        if (trimmed.len > 0 and trimmed[0] == '<') is_html = true;
    }

    if (is_json) {
        try prettyJson(allocator, body, writer);
    } else if (is_html) {
        try prettyHtml(body, writer);
    } else {
        try writer.print("{s}\n", .{body});
    }
}

fn prettyJson(allocator: std.mem.Allocator, body: []const u8, writer: anytype) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        try writer.print("{s}\n", .{body});
        return;
    };
    defer parsed.deinit();
    try writeJsonValue(writer, parsed.value, 0);
    try writer.print("\n", .{});
}

fn writeJsonValue(writer: anytype, value: std.json.Value, depth: usize) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.print("{s}", .{if (b) "true" else "false"}),
        .integer => |n| try writer.print("{d}", .{n}),
        .float => |f| try writer.print("{d}", .{f}),
        .string => |s| {
            try writer.writeByte('"');
            try json_util.writeEscaped(writer, s);
            try writer.writeByte('"');
        },
        .array => |arr| {
            if (arr.items.len == 0) {
                try writer.writeAll("[]");
                return;
            }
            try writer.writeAll("[\n");
            for (arr.items, 0..) |item, i| {
                try json_util.writeIndent(writer, depth + 1);
                try writeJsonValue(writer, item, depth + 1);
                if (i + 1 < arr.items.len) try writer.writeByte(',');
                try writer.writeByte('\n');
            }
            try json_util.writeIndent(writer, depth);
            try writer.writeByte(']');
        },
        .object => |obj| {
            if (obj.count() == 0) {
                try writer.writeAll("{}");
                return;
            }
            try writer.writeAll("{\n");
            var it = obj.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try writer.writeAll(",\n");
                first = false;
                try json_util.writeIndent(writer, depth + 1);
                try writer.writeByte('"');
                try json_util.writeEscaped(writer, entry.key_ptr.*);
                try writer.writeAll("\": ");
                try writeJsonValue(writer, entry.value_ptr.*, depth + 1);
            }
            try writer.writeByte('\n');
            try json_util.writeIndent(writer, depth);
            try writer.writeByte('}');
        },
        .number_string => |s| try writer.writeAll(s),
    }
}

fn prettyHtml(body: []const u8, writer: anytype) !void {
    var depth: usize = 0;
    var i: usize = 0;
    var line_start = true;
    while (i < body.len) {
        if (body[i] == '<') {
            const tag_start = i;
            while (i < body.len and body[i] != '>') : (i += 1) {}
            if (i < body.len) i += 1;
            const tag = body[tag_start..i];

            const is_closing = tag.len > 1 and tag[1] == '/';
            const is_self_closing = tag.len > 2 and tag[tag.len - 2] == '/';
            const is_special = tag.len > 1 and (tag[1] == '!' or tag[1] == '?');

            if (is_closing and depth > 0) depth -= 1;

            if (line_start) try json_util.writeIndent(writer, depth);
            try writer.writeAll(tag);
            try writer.writeByte('\n');
            line_start = true;

            if (!is_closing and !is_self_closing and !is_special) {
                const void_tags = [_][]const u8{ "br", "hr", "img", "input", "meta", "link", "area", "base", "col", "embed", "source", "track", "wbr" };
                var is_void = false;
                for (void_tags) |vt| {
                    if (tag.len > vt.len + 1 and tag[1] == vt[0]) {
                        const tag_name_end = std.mem.indexOfAny(u8, tag[1..], " \t>") orelse (tag.len - 1);
                        const tag_name = tag[1 .. 1 + tag_name_end];
                        if (std.ascii.eqlIgnoreCase(tag_name, vt)) {
                            is_void = true;
                            break;
                        }
                    }
                }
                if (!is_void) depth += 1;
            }
        } else if (body[i] == '\n' or body[i] == '\r') {
            i += 1;
            if (i < body.len and body[i - 1] == '\r' and body[i] == '\n') i += 1;
            line_start = true;
        } else {
            const text_start = i;
            while (i < body.len and body[i] != '<' and body[i] != '\n') : (i += 1) {}
            const text = std.mem.trim(u8, body[text_start..i], " \t\r");
            if (text.len > 0) {
                if (line_start) try json_util.writeIndent(writer, depth);
                try writer.writeAll(text);
                try writer.writeByte('\n');
                line_start = true;
            }
        }
    }
}
