const std = @import("std");

/// Parsed collection from a JSON file
pub const Collection = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    requests: []const RequestItem,
    arena: std.heap.ArenaAllocator,

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Collection {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024); // 1MB max
        defer allocator.free(content);

        return parseJson(allocator, content);
    }

    pub fn parseJson(allocator: std.mem.Allocator, json_str: []const u8) !Collection {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const aa = arena.allocator();

        const parsed = try std.json.parseFromSlice(std.json.Value, aa, json_str, .{});
        const root = parsed.value;

        if (root != .object) return error.InvalidFormat;

        const name = blk: {
            const v = root.object.get("name") orelse return error.MissingName;
            if (v != .string) return error.InvalidName;
            break :blk v.string;
        };

        const requests_val = root.object.get("requests") orelse return error.MissingRequests;
        if (requests_val != .array) return error.InvalidRequests;

        var requests: std.ArrayList(RequestItem) = .empty;
        for (requests_val.array.items) |item| {
            try requests.append(aa, try parseRequestItem(aa, item));
        }

        return .{
            .allocator = allocator,
            .name = name,
            .requests = try requests.toOwnedSlice(aa),
            .arena = arena,
        };
    }

    pub fn deinit(self: *Collection) void {
        self.arena.deinit();
    }
};

pub const RequestItem = struct {
    name: []const u8,
    request: HttpRequest,
    capture: ?[]const CaptureEntry = null,
    sse: ?SseConfig = null,
};

pub const HttpRequest = struct {
    method: Method,
    url: []const u8,
    path_params: ?[]const KV = null,
    headers: ?[]const KV = null,
    raw_body: ?[]const u8 = null,
};

pub const KV = struct {
    name: []const u8,
    value: []const u8,
};

pub const CaptureEntry = struct {
    name: []const u8,
    path: []const u8,
};

pub const SseConfig = struct {
    timeout_ms: u32 = 30000,
    stop_after: ?u32 = null,
    stop_on_event: ?[]const u8 = null,
};

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,

    pub fn fromString(s: []const u8) !Method {
        // Support case-insensitive matching
        var upper_buf: [8]u8 = undefined;
        if (s.len > upper_buf.len) return error.UnknownMethod;
        const upper = upper_buf[0..s.len];
        for (s, 0..) |ch, i| {
            upper[i] = std.ascii.toUpper(ch);
        }
        const map = std.StaticStringMap(Method).initComptime(.{
            .{ "GET", .GET },
            .{ "POST", .POST },
            .{ "PUT", .PUT },
            .{ "DELETE", .DELETE },
            .{ "PATCH", .PATCH },
            .{ "HEAD", .HEAD },
            .{ "OPTIONS", .OPTIONS },
        });
        return map.get(upper) orelse error.UnknownMethod;
    }
};

fn parseRequestItem(allocator: std.mem.Allocator, value: std.json.Value) !RequestItem {
    if (value != .object) return error.InvalidRequestItem;
    const obj = value.object;

    const name = blk: {
        const v = obj.get("name") orelse return error.MissingRequestName;
        if (v != .string) return error.InvalidRequestName;
        break :blk v.string;
    };

    const req_val = obj.get("request") orelse return error.MissingRequest;
    const request = try parseHttpRequest(allocator, req_val);

    var capture: ?[]const CaptureEntry = null;
    if (obj.get("capture")) |cap_val| {
        if (cap_val == .object) {
            var entries: std.ArrayList(CaptureEntry) = .empty;
            var it = cap_val.object.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* == .string) {
                    try entries.append(allocator, .{
                        .name = entry.key_ptr.*,
                        .path = entry.value_ptr.string,
                    });
                }
            }
            capture = try entries.toOwnedSlice(allocator);
        }
    }

    var sse: ?SseConfig = null;
    if (obj.get("sse")) |sse_val| {
        if (sse_val == .object) {
            sse = .{};
            if (sse_val.object.get("timeout_ms")) |v| {
                if (v == .integer) sse.?.timeout_ms = @intCast(v.integer);
            }
            if (sse_val.object.get("stop_after")) |v| {
                if (v == .integer) sse.?.stop_after = @intCast(v.integer);
            }
            if (sse_val.object.get("stop_on_event")) |v| {
                if (v == .string) sse.?.stop_on_event = v.string;
            }
        }
    }

    return .{
        .name = name,
        .request = request,
        .capture = capture,
        .sse = sse,
    };
}

fn parseHttpRequest(allocator: std.mem.Allocator, value: std.json.Value) !HttpRequest {
    if (value != .object) return error.InvalidHttpRequest;
    const obj = value.object;

    const method = blk: {
        const v = obj.get("method") orelse return error.MissingMethod;
        if (v != .string) return error.InvalidMethod;
        break :blk try Method.fromString(v.string);
    };

    const url = blk: {
        const v = obj.get("url") orelse return error.MissingUrl;
        if (v != .string) return error.InvalidUrl;
        break :blk v.string;
    };

    // Parse pathParams
    var path_params: ?[]const KV = null;
    if (obj.get("pathParams")) |pp_val| {
        if (pp_val == .object) {
            var params: std.ArrayList(KV) = .empty;
            var it = pp_val.object.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* == .string) {
                    try params.append(allocator, .{
                        .name = entry.key_ptr.*,
                        .value = entry.value_ptr.string,
                    });
                }
            }
            path_params = try params.toOwnedSlice(allocator);
        }
    }

    // Parse headers
    var headers: ?[]const KV = null;
    if (obj.get("headers")) |h_val| {
        if (h_val == .object) {
            var hdrs: std.ArrayList(KV) = .empty;
            var it = h_val.object.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* == .string) {
                    try hdrs.append(allocator, .{
                        .name = entry.key_ptr.*,
                        .value = entry.value_ptr.string,
                    });
                }
            }
            headers = try hdrs.toOwnedSlice(allocator);
        }
    }

    // Serialize body back to JSON string for later interpolation
    var raw_body: ?[]const u8 = null;
    if (obj.get("body")) |body_val| {
        raw_body = try stringifyJson(allocator, body_val);
    }

    return .{
        .method = method,
        .url = url,
        .path_params = path_params,
        .headers = headers,
        .raw_body = raw_body,
    };
}

fn stringifyJson(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return try std.json.Stringify.valueAlloc(allocator, value, .{});
}
