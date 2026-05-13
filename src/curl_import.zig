const std = @import("std");
const curl_parser = @import("curl_parser.zig");
const json_util = @import("json.zig");

const CurlEntry = struct {
    name: ?[]const u8,
    curl_line: []const u8,
};

/// Main entry: read a file of curl commands, parse them, and write a collection JSON.
pub fn importFile(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    output_path: []const u8,
    writer: anytype,
) !void {
    // Read input file
    const file = std.fs.cwd().openFile(input_path, .{}) catch {
        try writer.print("Cannot open file: {s}\n", .{input_path});
        return;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch {
        try writer.print("Failed to read file (too large or I/O error).\n", .{});
        return;
    };
    defer allocator.free(content);

    // Preprocess into individual curl entries
    var entries = preprocessLines(allocator, content) catch {
        try writer.print("Out of memory during preprocessing.\n", .{});
        return;
    };
    defer {
        for (entries.items) |e| {
            allocator.free(e.curl_line);
        }
        entries.deinit(allocator);
    }

    if (entries.items.len == 0) {
        try writer.print("No curl commands found in file.\n", .{});
        return;
    }

    // Parse each entry and collect results
    var parsed = std.ArrayList(ParsedRequest).empty;
    defer parsed.deinit(allocator);

    for (entries.items, 0..) |entry, idx| {
        const result = curl_parser.parse(allocator, entry.curl_line) catch |err| {
            try writer.print("Warning: skipping entry {d}: {s}\n", .{ idx, @errorName(err) });
            continue;
        };
        parsed.append(allocator, .{
            .name = entry.name,
            .cmd = result,
        }) catch continue;
    }

    if (parsed.items.len == 0) {
        try writer.print("No valid curl commands parsed.\n", .{});
        return;
    }

    // Derive collection name from input filename
    const collection_name = collectionName(input_path);

    // Write output JSON
    writeCollectionJson(allocator, output_path, collection_name, parsed.items, writer) catch {
        try writer.print("Failed to write output file: {s}\n", .{output_path});
        return;
    };

    try writer.print("Imported {d} request(s) to {s}\n", .{ parsed.items.len, output_path });
    for (parsed.items, 0..) |req, i| {
        try writer.print("  [{d}] {s} {s}\n", .{ i, req.cmd.method, req.cmd.url });
    }
}

const ParsedRequest = struct {
    name: ?[]const u8,
    cmd: curl_parser.CurlCommand,
};

// ── Preprocessing ──────────────────────────────────────────

/// Split file content into individual curl entries, handling:
/// - `\` line continuations
/// - blank-line separators
/// - `#` comment lines as request names
fn preprocessLines(allocator: std.mem.Allocator, content: []const u8) !std.ArrayList(CurlEntry) {
    var result = std.ArrayList(CurlEntry).empty;

    var pending_name: ?[]const u8 = null;
    var line_buf = std.ArrayList(u8).empty;
    defer line_buf.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");

        // Skip empty lines — flush accumulated command
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) {
            if (line_buf.items.len > 0) {
                const owned = try allocator.dupe(u8, line_buf.items);
                try result.append(allocator, .{
                    .name = pending_name,
                    .curl_line = owned,
                });
                line_buf.clearRetainingCapacity();
                pending_name = null;
            }
            continue;
        }

        // Comment line → use as name for next command
        if (trimmed[0] == '#') {
            const comment = std.mem.trim(u8, trimmed[1..], " \t");
            if (comment.len > 0) {
                pending_name = comment;
            }
            continue;
        }

        // Handle backslash continuation
        if (line.len > 0 and line[line.len - 1] == '\\') {
            try line_buf.appendSlice(allocator, std.mem.trimRight(u8, line[0 .. line.len - 1], " \t"));
            try line_buf.append(allocator, ' ');
        } else {
            try line_buf.appendSlice(allocator, line);
            // If not a continuation, could still be a multi-line block — don't flush yet,
            // let the blank line or EOF flush it.
        }
    }

    // Flush remaining
    if (line_buf.items.len > 0) {
        const owned = try allocator.dupe(u8, line_buf.items);
        try result.append(allocator, .{
            .name = pending_name,
            .curl_line = owned,
        });
    }

    return result;
}

// ── JSON Generation ────────────────────────────────────────

fn writeCollectionJson(
    allocator: std.mem.Allocator,
    output_path: []const u8,
    collection_name: []const u8,
    requests: []const ParsedRequest,
    status_writer: anytype,
) !void {
    _ = status_writer;
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();

    var write_buf: [4096]u8 = undefined;
    var fw = file.writer(&write_buf);
    const w = &fw.interface;

    try w.writeAll("{\n");
    try w.writeAll("  \"name\": \"");
    try json_util.writeEscaped(w, collection_name);
    try w.writeAll("\",\n");
    try w.writeAll("  \"requests\": [\n");

    for (requests, 0..) |req, i| {
        if (i > 0) try w.writeAll(",\n");
        try writeRequestItem(allocator, w, req);
    }

    try w.writeAll("\n  ]\n");
    try w.writeAll("}\n");
}

fn writeRequestItem(allocator: std.mem.Allocator, w: anytype, req: ParsedRequest) !void {
    // Item open
    try w.writeAll("    {\n");

    // name
    try w.writeAll("      \"name\": \"");
    if (req.name) |name| {
        try json_util.writeEscaped(w, name);
    } else {
        // Auto-generate: "METHOD /path"
        try w.writeAll(req.cmd.method);
        try w.writeAll(" ");
        try json_util.writeEscaped(w, extractPath(req.cmd.url));
    }
    try w.writeAll("\",\n");

    // request object
    try w.writeAll("      \"request\": {\n");

    // method
    try w.writeAll("        \"method\": \"");
    try w.writeAll(req.cmd.method);
    try w.writeAll("\",\n");

    // url
    try w.writeAll("        \"url\": \"");
    try json_util.writeEscaped(w, req.cmd.url);
    try w.writeAll("\"");

    // headers
    if (req.cmd.headers.len > 0) {
        try w.writeAll(",\n        \"headers\": {\n");
        for (req.cmd.headers, 0..) |h, hi| {
            if (hi > 0) try w.writeAll(",\n");
            try w.writeAll("          \"");
            try json_util.writeEscaped(w, h.name);
            try w.writeAll("\": \"");
            try json_util.writeEscaped(w, h.value);
            try w.writeAll("\"");
        }
        try w.writeAll("\n        }");
    }

    // body
    if (req.cmd.body) |body| {
        try w.writeAll(",\n        \"body\": ");
        if (isValidJson(allocator, body)) {
            try w.writeAll(body);
        } else {
            try w.writeAll("\"");
            try json_util.writeEscaped(w, body);
            try w.writeAll("\"");
        }
    }

    // close request
    try w.writeAll("\n      }\n");

    // close item
    try w.writeAll("    }");
}

fn isValidJson(allocator: std.mem.Allocator, s: []const u8) bool {
    const trimmed = std.mem.trim(u8, s, " \t\n\r");
    if (trimmed.len == 0) return false;
    // Must start with { or [ to be an embedded object/array
    if (trimmed[0] != '{' and trimmed[0] != '[') return false;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = std.json.parseFromSlice(std.json.Value, arena.allocator(), trimmed, .{}) catch return false;
    return true;
}

// ── Helpers ────────────────────────────────────────────────

/// Derive a collection name from the filename (strip directory and extension).
fn collectionName(path: []const u8) []const u8 {
    // Find last path separator
    var start: usize = 0;
    for (path, 0..) |ch, i| {
        if (ch == '/' or ch == '\\') start = i + 1;
    }
    const basename = path[start..];
    // Strip extension
    if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot| {
        return basename[0..dot];
    }
    return basename;
}

/// Extract the path portion from a URL for auto-naming.
/// e.g. "https://api.example.com/users/me" → "/users/me"
fn extractPath(url: []const u8) []const u8 {
    // Skip scheme
    var start: usize = 0;
    if (std.mem.indexOf(u8, url, "://")) |idx| {
        start = idx + 3;
    }
    // Find first '/' after host
    if (std.mem.indexOfScalarPos(u8, url, start, '/')) |slash| {
        return url[slash..];
    }
    return "/";
}
