const std = @import("std");
const client = @import("client.zig");
const config = @import("config.zig");
const interpolate = @import("interpolate.zig");
const har = @import("har.zig");
const env_mod = @import("env.zig");
const cache_mod = @import("cache.zig");

/// Unified request execution engine.
/// Consolidates the three previously duplicated execution paths:
///   1. Collection request (config.RequestItem)
///   2. Inline CLI request
///   3. Cache entry replay
pub const Executor = struct {
    allocator: std.mem.Allocator,
    http_client: *client.HttpClient,
    history: *std.ArrayList(har.HarEntry),
    capture_vars: *interpolate.CaptureMap,

    pub fn init(
        allocator: std.mem.Allocator,
        http_client: *client.HttpClient,
        history: *std.ArrayList(har.HarEntry),
        capture_vars: *interpolate.CaptureMap,
    ) Executor {
        return .{
            .allocator = allocator,
            .http_client = http_client,
            .history = history,
            .capture_vars = capture_vars,
        };
    }

    /// A request prepared for execution (all fields are raw templates).
    pub const Request = struct {
        method: config.Method,
        method_str: []const u8,
        url_template: []const u8,
        headers: []const Header,
        body_template: ?[]const u8 = null,
        follow_redirects: bool = false,
        path_params: ?[]const config.KV = null,
        /// If set, captures will be extracted from the response JSON.
        captures: ?[]const config.CaptureEntry = null,

        pub const Header = struct {
            name: []const u8,
            value_template: []const u8,
        };
    };

    /// Result of execution, for callers that need post-processing.
    pub const ExecResult = struct {
        status: u32,
        duration_ms: u64,
        body: ?[]const u8,
        headers_raw: ?[]const u8,
    };

    /// Execute a request: interpolate templates, send via HTTP, print output,
    /// record to history, and return basic result info.
    pub fn execute(
        self: *Executor,
        req: Request,
        env_store: *env_mod.EnvStore,
        writer: anytype,
        pretty: bool,
    ) !ExecResult {
        // Interpolate URL
        const url = try interpolate.resolve(self.allocator, req.url_template, env_store, req.path_params, self.capture_vars);
        defer self.allocator.free(url);

        // Interpolate headers
        var headers_buf: [32]client.Header = undefined;
        var header_count: usize = 0;
        for (req.headers) |h| {
            if (header_count >= headers_buf.len) break;
            const val = try interpolate.resolve(self.allocator, h.value_template, env_store, null, self.capture_vars);
            headers_buf[header_count] = .{ .name = h.name, .value = val };
            header_count += 1;
        }
        defer {
            for (headers_buf[0..header_count]) |h| self.allocator.free(h.value);
        }

        // Interpolate body
        var body: ?[]const u8 = null;
        defer if (body) |b| self.allocator.free(b);
        if (req.body_template) |raw| {
            body = try interpolate.resolve(self.allocator, raw, env_store, null, self.capture_vars);
        }

        // Execute HTTP request
        const result = try self.http_client.execute(.{
            .method = req.method,
            .url = url,
            .headers = headers_buf[0..header_count],
            .body = body,
            .follow_redirects = req.follow_redirects,
        });
        defer result.deinit(self.allocator);

        // Print response
        try writer.print("HTTP {d}  ({d}ms)\n", .{ result.status, result.duration_ms });
        if (result.body) |resp_body| {
            if (pretty) {
                const format = @import("format.zig");
                try format.printPretty(self.allocator, resp_body, result.headers_raw, writer);
            } else {
                try writer.print("{s}\n", .{resp_body});
            }
        }

        // Variable captures → stored in capture_vars (separate from env)
        if (req.captures) |captures| {
            for (captures) |cap| {
                if (result.body) |resp_body| {
                    if (extractJsonPath(self.allocator, resp_body, cap.path)) |value| {
                        // Remove old value if exists
                        if (self.capture_vars.fetchRemove(cap.name)) |removed| {
                            self.allocator.free(removed.key);
                            self.allocator.free(removed.value);
                        }
                        const k = try self.allocator.dupe(u8, cap.name);
                        const v = try self.allocator.dupe(u8, value);
                        try self.capture_vars.put(k, v);
                        try writer.print("  captured ${s} = {s}\n", .{ cap.name, value });
                        self.allocator.free(value);
                    } else |_| {
                        try writer.print("  capture failed: {s}\n", .{cap.path});
                    }
                }
            }
        }

        // Record to history (best-effort)
        recordHistory(
            self.allocator,
            self.history,
            req.method_str,
            url,
            headers_buf[0..header_count],
            body,
            &result,
        );

        return .{
            .status = result.status,
            .duration_ms = result.duration_ms,
            .body = if (result.body) |b| (self.allocator.dupe(u8, b) catch null) else null,
            .headers_raw = if (result.headers_raw) |h| (self.allocator.dupe(u8, h) catch null) else null,
        };
    }

    /// Build a Request from a config.RequestItem (collection request).
    /// Caller must provide a scratch buffer for header conversion.
    pub fn fromRequestItem(req_item: config.RequestItem, hdr_buf: []Request.Header) Request {
        const hdrs = req_item.request.headers orelse &.{};
        var count: usize = 0;
        for (hdrs) |h| {
            if (count >= hdr_buf.len) break;
            hdr_buf[count] = .{ .name = h.name, .value_template = h.value };
            count += 1;
        }
        return .{
            .method = req_item.request.method,
            .method_str = @tagName(req_item.request.method),
            .url_template = req_item.request.url,
            .headers = hdr_buf[0..count],
            .body_template = req_item.request.raw_body,
            .path_params = req_item.request.path_params,
            .captures = req_item.capture,
        };
    }

    /// Build a Request from a CacheEntry (replay).
    /// Caller must provide a scratch buffer for header conversion.
    pub fn fromCacheEntry(ce: cache_mod.CacheEntry, hdr_buf: []Request.Header) !Request {
        const method = config.Method.fromString(ce.method) catch return error.InvalidMethod;
        var count: usize = 0;
        for (ce.headers) |h| {
            if (count >= hdr_buf.len) break;
            hdr_buf[count] = .{ .name = h.name, .value_template = h.value };
            count += 1;
        }
        return .{
            .method = method,
            .method_str = ce.method,
            .url_template = ce.url_template,
            .headers = hdr_buf[0..count],
            .body_template = ce.body,
        };
    }
};

// ── Helpers ──────────────────────────────────────────────

/// JSONPath extraction supporting nested paths.
/// Supports: $.field, $.a.b.c, $.arr[0], $.arr[0].name
pub fn extractJsonPath(allocator: std.mem.Allocator, json_str: []const u8, path: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, path, "$")) return error.UnsupportedJsonPath;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    // Navigate the path: skip "$" then walk "." separated segments
    var current = parsed.value;
    var remaining = path[1..]; // skip "$"

    while (remaining.len > 0) {
        // skip leading dot
        if (remaining[0] == '.') remaining = remaining[1..];
        if (remaining.len == 0) break;

        // Find next segment boundary (. or [)
        var seg_end: usize = 0;
        while (seg_end < remaining.len and remaining[seg_end] != '.' and remaining[seg_end] != '[') {
            seg_end += 1;
        }

        if (seg_end > 0) {
            // Object field lookup
            const field = remaining[0..seg_end];
            if (current != .object) return error.NotAnObject;
            current = current.object.get(field) orelse return error.FieldNotFound;
            remaining = remaining[seg_end..];
        }

        // Handle array index [N]
        if (remaining.len > 0 and remaining[0] == '[') {
            const close = std.mem.indexOfScalar(u8, remaining, ']') orelse return error.InvalidArrayIndex;
            const idx_str = remaining[1..close];
            const idx = std.fmt.parseInt(usize, idx_str, 10) catch return error.InvalidArrayIndex;
            if (current != .array) return error.NotAnArray;
            if (idx >= current.array.items.len) return error.IndexOutOfRange;
            current = current.array.items[idx];
            remaining = remaining[close + 1 ..];
        }
    }

    return switch (current) {
        .string => |s| try allocator.dupe(u8, s),
        .integer => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
        .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .bool => |b| try allocator.dupe(u8, if (b) "true" else "false"),
        .null => try allocator.dupe(u8, "null"),
        else => error.UnsupportedValueType,
    };
}

/// Duplicate response data and record as a HAR history entry.
fn recordHistory(
    allocator: std.mem.Allocator,
    history: *std.ArrayList(har.HarEntry),
    method: []const u8,
    url: []const u8,
    req_headers: []const client.Header,
    req_body: ?[]const u8,
    result: *const client.Response,
) void {
    const dup_method = allocator.dupe(u8, method) catch return;
    const dup_url = allocator.dupe(u8, url) catch return;
    const dup_body = if (req_body) |b| (allocator.dupe(u8, b) catch return) else null;

    var dup_headers = allocator.alloc(client.Header, req_headers.len) catch return;
    for (req_headers, 0..) |h, i| {
        dup_headers[i] = .{
            .name = allocator.dupe(u8, h.name) catch return,
            .value = allocator.dupe(u8, h.value) catch return,
        };
    }

    const dup_resp = client.Response{
        .status = result.status,
        .body = if (result.body) |b| (allocator.dupe(u8, b) catch return) else null,
        .duration_ms = result.duration_ms,
        .headers_raw = if (result.headers_raw) |h| (allocator.dupe(u8, h) catch return) else null,
        .http_version = allocator.dupe(u8, result.http_version) catch return,
        .redirect_url = allocator.dupe(u8, result.redirect_url) catch return,
        .server_ip = allocator.dupe(u8, result.server_ip) catch return,
        .time_dns_ms = result.time_dns_ms,
        .time_connect_ms = result.time_connect_ms,
        .time_ssl_ms = result.time_ssl_ms,
        .time_send_ms = result.time_send_ms,
        .time_wait_ms = result.time_wait_ms,
        .time_receive_ms = result.time_receive_ms,
    };

    const iso_time = har.nowIso8601(allocator) catch return;

    var req_header_size: i64 = 0;
    for (req_headers) |h| {
        req_header_size += @intCast(h.name.len + 2 + h.value.len + 2);
    }
    const req_body_size: i64 = if (req_body) |b| @intCast(b.len) else 0;

    history.append(allocator, .{
        .method = dup_method,
        .url = dup_url,
        .req_headers = dup_headers,
        .req_body = dup_body,
        .req_header_size = req_header_size,
        .req_body_size = req_body_size,
        .response = dup_resp,
        .started_iso = iso_time,
    }) catch return;
}
