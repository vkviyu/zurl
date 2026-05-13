const std = @import("std");
const client = @import("client.zig");
const config = @import("config.zig");
const json = @import("json.zig");

/// A recorded request/response pair for HAR export.
pub const HarEntry = struct {
    // Request info
    method: []const u8,
    url: []const u8,
    req_headers: []const client.Header,
    req_body: ?[]const u8,
    req_header_size: i64,
    req_body_size: i64,
    // Response info
    response: client.Response,
    // Timestamp
    started_iso: []const u8,

    pub fn deinit(self: *HarEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        allocator.free(self.url);
        for (self.req_headers) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        allocator.free(self.req_headers);
        if (self.req_body) |b| allocator.free(b);
        self.response.deinit(allocator);
        allocator.free(self.started_iso);
    }
};

/// Write a complete HAR 1.2 JSON file from a list of entries.
pub fn exportHar(
    allocator: std.mem.Allocator,
    entries: []const HarEntry,
    file_path: []const u8,
) !void {
    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();

    var write_buf: [8192]u8 = undefined;
    var fw = file.writer(&write_buf);
    const w = &fw.interface;

    try w.writeAll("{\n");
    try w.writeAll("  \"log\": {\n");
    try w.writeAll("    \"version\": \"1.2\",\n");
    try w.writeAll("    \"creator\": {\n");
    try w.writeAll("      \"name\": \"zurl\",\n");
    try w.writeAll("      \"version\": \"0.1.0\"\n");
    try w.writeAll("    },\n");
    try w.writeAll("    \"entries\": [\n");

    for (entries, 0..) |entry, idx| {
        if (idx > 0) try w.writeAll(",\n");
        try writeEntry(allocator, w, entry);
    }

    try w.writeAll("\n    ]\n");
    try w.writeAll("  }\n");
    try w.writeAll("}\n");
}

fn writeEntry(allocator: std.mem.Allocator, w: anytype, entry: HarEntry) !void {
    try w.writeAll("      {\n");

    // startedDateTime
    try w.writeAll("        \"startedDateTime\": \"");
    try writeJsonStr(w, entry.started_iso);
    try w.writeAll("\",\n");

    // time
    try w.print("        \"time\": {d},\n", .{entry.response.duration_ms});

    // request
    try w.writeAll("        \"request\": {\n");
    try w.writeAll("          \"method\": \"");
    try writeJsonStr(w, entry.method);
    try w.writeAll("\",\n");
    try w.writeAll("          \"url\": \"");
    try writeJsonStr(w, entry.url);
    try w.writeAll("\",\n");
    try w.writeAll("          \"httpVersion\": \"");
    try writeJsonStr(w, entry.response.http_version);
    try w.writeAll("\",\n");

    // request cookies (parse from Cookie header)
    try w.writeAll("          \"cookies\": [],\n");

    // request headers
    try w.writeAll("          \"headers\": [\n");
    for (entry.req_headers, 0..) |h, i| {
        if (i > 0) try w.writeAll(",\n");
        try w.writeAll("            { \"name\": \"");
        try writeJsonStr(w, h.name);
        try w.writeAll("\", \"value\": \"");
        try writeJsonStr(w, h.value);
        try w.writeAll("\" }");
    }
    try w.writeAll("\n          ],\n");

    // queryString - parse from URL
    try w.writeAll("          \"queryString\": [");
    try writeQueryString(allocator, w, entry.url);
    try w.writeAll("],\n");

    // postData
    if (entry.req_body) |body| {
        try w.writeAll("          \"postData\": {\n");
        // Find Content-Type from request headers
        var mime: []const u8 = "application/octet-stream";
        for (entry.req_headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
                mime = h.value;
                break;
            }
        }
        try w.writeAll("            \"mimeType\": \"");
        try writeJsonStr(w, mime);
        try w.writeAll("\",\n");
        try w.writeAll("            \"text\": \"");
        try writeJsonStr(w, body);
        try w.writeAll("\"\n");
        try w.writeAll("          },\n");
    }

    // headersSize, bodySize
    try w.print("          \"headersSize\": {d},\n", .{entry.req_header_size});
    try w.print("          \"bodySize\": {d}\n", .{entry.req_body_size});
    try w.writeAll("        },\n");

    // response
    try w.writeAll("        \"response\": {\n");
    try w.print("          \"status\": {d},\n", .{entry.response.status});
    try w.writeAll("          \"statusText\": \"");
    try writeJsonStr(w, httpStatusText(entry.response.status));
    try w.writeAll("\",\n");
    try w.writeAll("          \"httpVersion\": \"");
    try writeJsonStr(w, entry.response.http_version);
    try w.writeAll("\",\n");

    // response cookies
    try w.writeAll("          \"cookies\": [],\n");

    // response headers - parse from headers_raw
    try w.writeAll("          \"headers\": [\n");
    if (entry.response.headers_raw) |raw| {
        try writeRawHeaders(w, raw);
    }
    try w.writeAll("\n          ],\n");

    // content
    try w.writeAll("          \"content\": {\n");
    const body_size: i64 = if (entry.response.body) |b| @intCast(b.len) else 0;
    try w.print("            \"size\": {d},\n", .{body_size});
    // Determine mimeType from response headers
    var resp_mime: []const u8 = "";
    if (entry.response.headers_raw) |raw| {
        resp_mime = findHeaderValue(raw, "content-type") orelse "";
    }
    try w.writeAll("            \"mimeType\": \"");
    try writeJsonStr(w, resp_mime);
    try w.writeAll("\"");
    if (entry.response.body) |body| {
        try w.writeAll(",\n");
        // Check if body is valid text
        if (isTextContent(resp_mime)) {
            try w.writeAll("            \"text\": \"");
            try writeJsonStr(w, body);
            try w.writeAll("\"\n");
        } else {
            // Base64 encode binary content
            const encoded = try base64Encode(allocator, body);
            defer allocator.free(encoded);
            try w.writeAll("            \"text\": \"");
            try w.writeAll(encoded);
            try w.writeAll("\",\n");
            try w.writeAll("            \"encoding\": \"base64\"\n");
        }
    } else {
        try w.writeAll("\n");
    }
    try w.writeAll("          },\n");

    // redirectURL
    try w.writeAll("          \"redirectURL\": \"");
    try writeJsonStr(w, entry.response.redirect_url);
    try w.writeAll("\",\n");

    // headersSize, bodySize
    const resp_headers_size: i64 = if (entry.response.headers_raw) |h| @intCast(h.len) else -1;
    try w.print("          \"headersSize\": {d},\n", .{resp_headers_size});
    try w.print("          \"bodySize\": {d}\n", .{body_size});
    try w.writeAll("        },\n");

    // cache
    try w.writeAll("        \"cache\": {},\n");

    // timings
    try w.writeAll("        \"timings\": {\n");
    try w.print("          \"blocked\": 0,\n", .{});
    try w.print("          \"dns\": {d},\n", .{entry.response.time_dns_ms});
    try w.print("          \"connect\": {d},\n", .{entry.response.time_connect_ms});
    try w.print("          \"send\": {d},\n", .{entry.response.time_send_ms});
    try w.print("          \"wait\": {d},\n", .{entry.response.time_wait_ms});
    try w.print("          \"receive\": {d},\n", .{entry.response.time_receive_ms});
    try w.print("          \"ssl\": {d}\n", .{entry.response.time_ssl_ms});
    try w.writeAll("        }");

    // serverIPAddress
    if (entry.response.server_ip.len > 0) {
        try w.writeAll(",\n        \"serverIPAddress\": \"");
        try writeJsonStr(w, entry.response.server_ip);
        try w.writeAll("\"");
    }

    try w.writeAll("\n      }");
}

// ── Helpers ──────────────────────────────────────────────

const writeJsonStr = json.writeEscaped;

fn writeRawHeaders(w: anytype, raw: []const u8) !void {
    var first = true;
    var start: usize = 0;
    for (raw, 0..) |ch, i| {
        if (ch == '\n') {
            var line = raw[start..i];
            // Strip trailing \r
            if (line.len > 0 and line[line.len - 1] == '\r') {
                line = line[0 .. line.len - 1];
            }
            start = i + 1;

            // Skip empty lines and HTTP status line
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, "HTTP/")) continue;

            if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                const name = std.mem.trim(u8, line[0..colon], " ");
                const value = std.mem.trim(u8, line[colon + 1 ..], " ");
                if (!first) try w.writeAll(",\n");
                first = false;
                try w.writeAll("            { \"name\": \"");
                try writeJsonStr(w, name);
                try w.writeAll("\", \"value\": \"");
                try writeJsonStr(w, value);
                try w.writeAll("\" }");
            }
        }
    }
}

fn findHeaderValue(raw: []const u8, target_name: []const u8) ?[]const u8 {
    var start: usize = 0;
    for (raw, 0..) |ch, i| {
        if (ch == '\n') {
            var line = raw[start..i];
            if (line.len > 0 and line[line.len - 1] == '\r') {
                line = line[0 .. line.len - 1];
            }
            start = i + 1;
            if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                const name = std.mem.trim(u8, line[0..colon], " ");
                if (std.ascii.eqlIgnoreCase(name, target_name)) {
                    return std.mem.trim(u8, line[colon + 1 ..], " ");
                }
            }
        }
    }
    return null;
}

fn writeQueryString(allocator: std.mem.Allocator, w: anytype, url: []const u8) !void {
    _ = allocator;
    const qmark = std.mem.indexOfScalar(u8, url, '?') orelse return;
    const query = url[qmark + 1 ..];
    // Strip fragment
    const end = std.mem.indexOfScalar(u8, query, '#') orelse query.len;
    const qs = query[0..end];

    var first = true;
    var iter_start: usize = 0;
    var i: usize = 0;
    while (i <= qs.len) : (i += 1) {
        if (i == qs.len or qs[i] == '&') {
            const pair = qs[iter_start..i];
            iter_start = i + 1;
            if (pair.len == 0) continue;
            if (!first) try w.writeAll(",\n");
            first = false;
            try w.writeAll("\n            { \"name\": \"");
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                try writeJsonStr(w, pair[0..eq]);
                try w.writeAll("\", \"value\": \"");
                try writeJsonStr(w, pair[eq + 1 ..]);
            } else {
                try writeJsonStr(w, pair);
                try w.writeAll("\", \"value\": \"");
            }
            try w.writeAll("\" }");
        }
    }
}

fn isTextContent(mime: []const u8) bool {
    if (mime.len == 0) return true;
    if (std.mem.startsWith(u8, mime, "text/")) return true;
    if (std.mem.indexOf(u8, mime, "json") != null) return true;
    if (std.mem.indexOf(u8, mime, "xml") != null) return true;
    if (std.mem.indexOf(u8, mime, "javascript") != null) return true;
    if (std.mem.indexOf(u8, mime, "html") != null) return true;
    return false;
}

fn base64Encode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const encoder = std.base64.standard;
    const len = encoder.Encoder.calcSize(data.len);
    const buf = try allocator.alloc(u8, len);
    _ = encoder.Encoder.encode(buf, data);
    return buf;
}

fn httpStatusText(code: u32) []const u8 {
    return switch (code) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        409 => "Conflict",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        else => "",
    };
}

/// Get current time as ISO 8601 string
pub fn nowIso8601(allocator: std.mem.Allocator) ![]const u8 {
    const ts = std.time.timestamp();
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const day = epoch_seconds.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch_seconds.getDaySeconds();

    return try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{
        year_day.year,
        @as(u32, @intFromEnum(month_day.month)),
        @as(u32, month_day.day_index) + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    });
}
