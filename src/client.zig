const std = @import("std");
const curl = @import("curl");
const c = curl.libcurl;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const RequestOptions = struct {
    method: @import("config.zig").Method,
    url: []const u8,
    headers: []const Header = &.{},
    body: ?[]const u8 = null,
    follow_redirects: bool = false,
};

pub const Response = struct {
    status: u32,
    body: ?[]const u8,
    duration_ms: u64,
    headers_raw: ?[]const u8,
    http_version: []const u8,
    redirect_url: []const u8,
    time_dns_ms: i64,
    time_connect_ms: i64,
    time_ssl_ms: i64,
    time_send_ms: i64,
    time_wait_ms: i64,
    time_receive_ms: i64,
    server_ip: []const u8,

    pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
        if (self.body) |b| allocator.free(b);
        if (self.headers_raw) |h| allocator.free(h);
        allocator.free(self.http_version);
        allocator.free(self.redirect_url);
        allocator.free(self.server_ip);
    }
};

const WriteContext = struct {
    buf: std.ArrayList(u8),
    allocator: std.mem.Allocator,
};

pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    /// Pointer to a cancellation flag. When `true`, in-flight requests abort.
    /// Owned by the caller (typically the REPL's signal handler).
    cancelled: *bool,

    pub fn init(allocator: std.mem.Allocator, cancelled: *bool) !HttpClient {
        if (c.curl_global_init(c.CURL_GLOBAL_ALL) != c.CURLE_OK) {
            return error.CurlInitFailed;
        }
        return .{ .allocator = allocator, .cancelled = cancelled };
    }

    pub fn deinit(self: *HttpClient) void {
        _ = self;
        c.curl_global_cleanup();
    }

    pub fn execute(self: *HttpClient, opts: RequestOptions) !Response {
        const handle = c.curl_easy_init() orelse return error.CurlHandleInitFailed;
        defer c.curl_easy_cleanup(handle);

        // URL
        const url_z = try self.allocator.dupeZ(u8, opts.url);
        defer self.allocator.free(url_z);
        _ = c.curl_easy_setopt(handle, c.CURLOPT_URL, url_z.ptr);

        // Method
        switch (opts.method) {
            .GET => {},
            .POST => {
                _ = c.curl_easy_setopt(handle, c.CURLOPT_POST, @as(c_long, 1));
                if (opts.body == null) {
                    _ = c.curl_easy_setopt(handle, c.CURLOPT_POSTFIELDSIZE, @as(c_long, 0));
                }
            },
            .PUT => _ = c.curl_easy_setopt(handle, c.CURLOPT_CUSTOMREQUEST, "PUT"),
            .DELETE => _ = c.curl_easy_setopt(handle, c.CURLOPT_CUSTOMREQUEST, "DELETE"),
            .PATCH => _ = c.curl_easy_setopt(handle, c.CURLOPT_CUSTOMREQUEST, "PATCH"),
            .HEAD => _ = c.curl_easy_setopt(handle, c.CURLOPT_NOBODY, @as(c_long, 1)),
            .OPTIONS => _ = c.curl_easy_setopt(handle, c.CURLOPT_CUSTOMREQUEST, "OPTIONS"),
        }

        // Detect body encoding type from Content-Type header
        const body_type = detectBodyType(opts.headers);

        // Headers — for multipart, skip user Content-Type (libcurl sets it with boundary)
        var header_list: ?*c.struct_curl_slist = null;
        defer if (header_list) |hl| c.curl_slist_free_all(hl);

        for (opts.headers) |h| {
            if (body_type == .multipart and std.ascii.eqlIgnoreCase(h.name, "content-type")) continue;
            const header_str = try std.fmt.allocPrintSentinel(self.allocator, "{s}: {s}", .{ h.name, h.value }, 0);
            defer self.allocator.free(header_str);
            header_list = c.curl_slist_append(header_list, header_str.ptr);
        }
        if (header_list) |hl| {
            _ = c.curl_easy_setopt(handle, c.CURLOPT_HTTPHEADER, hl);
        }

        // Body — dispatch by Content-Type
        var body_z: ?[:0]u8 = null;
        defer if (body_z) |bz| self.allocator.free(bz);

        var mime_handle: ?*c.curl_mime = null;
        defer if (mime_handle) |mh| c.curl_mime_free(mh);

        if (opts.body) |body| {
            switch (body_type) {
                .raw => {
                    body_z = try self.allocator.dupeZ(u8, body);
                    _ = c.curl_easy_setopt(handle, c.CURLOPT_POSTFIELDS, body_z.?.ptr);
                    _ = c.curl_easy_setopt(handle, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len)));
                },
                .form_urlencoded => {
                    if (buildFormUrlEncoded(self.allocator, handle, body)) |encoded| {
                        body_z = encoded;
                        _ = c.curl_easy_setopt(handle, c.CURLOPT_POSTFIELDS, body_z.?.ptr);
                        _ = c.curl_easy_setopt(handle, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(encoded.len)));
                    } else {
                        // Fallback: send body as-is
                        body_z = try self.allocator.dupeZ(u8, body);
                        _ = c.curl_easy_setopt(handle, c.CURLOPT_POSTFIELDS, body_z.?.ptr);
                        _ = c.curl_easy_setopt(handle, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len)));
                    }
                },
                .multipart => {
                    if (buildMultipart(self.allocator, handle, body)) |mh| {
                        mime_handle = mh;
                        _ = c.curl_easy_setopt(handle, c.CURLOPT_MIMEPOST, mh);
                    } else {
                        // Fallback: send body as-is
                        body_z = try self.allocator.dupeZ(u8, body);
                        _ = c.curl_easy_setopt(handle, c.CURLOPT_POSTFIELDS, body_z.?.ptr);
                        _ = c.curl_easy_setopt(handle, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len)));
                    }
                },
            }
        }

        // Response body buffer
        var response_ctx = WriteContext{
            .buf = .empty,
            .allocator = self.allocator,
        };
        errdefer response_ctx.buf.deinit(self.allocator);

        _ = c.curl_easy_setopt(handle, c.CURLOPT_WRITEFUNCTION, writeCallback);
        _ = c.curl_easy_setopt(handle, c.CURLOPT_WRITEDATA, &response_ctx);

        // Response header buffer
        var header_ctx = WriteContext{
            .buf = .empty,
            .allocator = self.allocator,
        };
        errdefer header_ctx.buf.deinit(self.allocator);

        _ = c.curl_easy_setopt(handle, c.CURLOPT_HEADERFUNCTION, writeCallback);
        _ = c.curl_easy_setopt(handle, c.CURLOPT_HEADERDATA, &header_ctx);

        // Follow redirects
        if (opts.follow_redirects) {
            _ = c.curl_easy_setopt(handle, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
        }

        // Cancellation via progress callback
        _ = c.curl_easy_setopt(handle, c.CURLOPT_NOPROGRESS, @as(c_long, 0));
        _ = c.curl_easy_setopt(handle, c.CURLOPT_XFERINFOFUNCTION, progressCallback);
        _ = c.curl_easy_setopt(handle, c.CURLOPT_XFERINFODATA, self.cancelled);

        // Timeout
        _ = c.curl_easy_setopt(handle, c.CURLOPT_TIMEOUT, @as(c_long, 30));

        // Timing
        var timer = try std.time.Timer.start();

        const res = c.curl_easy_perform(handle);
        const duration_ns = timer.read();
        const duration_ms = duration_ns / std.time.ns_per_ms;

        if (res != c.CURLE_OK) {
            if (res == c.CURLE_ABORTED_BY_CALLBACK) {
                return error.CurlAbortedByCallback;
            }
            return error.CurlRequestFailed;
        }

        // Status code
        var status_code: c_long = 0;
        _ = c.curl_easy_getinfo(handle, c.CURLINFO_RESPONSE_CODE, &status_code);

        // HTTP version
        var http_ver: c_long = 0;
        _ = c.curl_easy_getinfo(handle, c.CURLINFO_HTTP_VERSION, &http_ver);
        const http_version_str: []const u8 = switch (http_ver) {
            c.CURL_HTTP_VERSION_1_0 => "HTTP/1.0",
            c.CURL_HTTP_VERSION_1_1 => "HTTP/1.1",
            c.CURL_HTTP_VERSION_2_0 => "HTTP/2",
            c.CURL_HTTP_VERSION_3 => "HTTP/3",
            else => "HTTP/1.1",
        };
        const http_version = try self.allocator.dupe(u8, http_version_str);

        // Redirect URL
        var redirect_ptr: ?[*:0]const u8 = null;
        _ = c.curl_easy_getinfo(handle, c.CURLINFO_REDIRECT_URL, &redirect_ptr);
        const redirect_url = if (redirect_ptr) |p|
            try self.allocator.dupe(u8, std.mem.sliceTo(p, 0))
        else
            try self.allocator.dupe(u8, "");

        // Server IP
        var ip_ptr: ?[*:0]const u8 = null;
        _ = c.curl_easy_getinfo(handle, c.CURLINFO_PRIMARY_IP, &ip_ptr);
        const server_ip = if (ip_ptr) |p|
            try self.allocator.dupe(u8, std.mem.sliceTo(p, 0))
        else
            try self.allocator.dupe(u8, "");

        // Timing breakdown
        var t_namelookup: f64 = 0;
        var t_connect: f64 = 0;
        var t_appconnect: f64 = 0;
        var t_pretransfer: f64 = 0;
        var t_starttransfer: f64 = 0;
        var t_total: f64 = 0;
        _ = c.curl_easy_getinfo(handle, c.CURLINFO_NAMELOOKUP_TIME, &t_namelookup);
        _ = c.curl_easy_getinfo(handle, c.CURLINFO_CONNECT_TIME, &t_connect);
        _ = c.curl_easy_getinfo(handle, c.CURLINFO_APPCONNECT_TIME, &t_appconnect);
        _ = c.curl_easy_getinfo(handle, c.CURLINFO_PRETRANSFER_TIME, &t_pretransfer);
        _ = c.curl_easy_getinfo(handle, c.CURLINFO_STARTTRANSFER_TIME, &t_starttransfer);
        _ = c.curl_easy_getinfo(handle, c.CURLINFO_TOTAL_TIME, &t_total);

        const dns_ms: i64 = @intFromFloat(t_namelookup * 1000.0);
        const connect_ms: i64 = @intFromFloat((t_connect - t_namelookup) * 1000.0);
        const ssl_ms: i64 = if (t_appconnect > 0)
            @intFromFloat((t_appconnect - t_connect) * 1000.0)
        else
            -1;
        const send_ms: i64 = @intFromFloat((t_pretransfer - (if (t_appconnect > 0) t_appconnect else t_connect)) * 1000.0);
        const wait_ms: i64 = @intFromFloat((t_starttransfer - t_pretransfer) * 1000.0);
        const receive_ms: i64 = @intFromFloat((t_total - t_starttransfer) * 1000.0);

        return .{
            .status = @intCast(status_code),
            .body = if (response_ctx.buf.items.len > 0) try response_ctx.buf.toOwnedSlice(self.allocator) else null,
            .duration_ms = duration_ms,
            .headers_raw = if (header_ctx.buf.items.len > 0) try header_ctx.buf.toOwnedSlice(self.allocator) else null,
            .http_version = http_version,
            .redirect_url = redirect_url,
            .server_ip = server_ip,
            .time_dns_ms = dns_ms,
            .time_connect_ms = connect_ms,
            .time_ssl_ms = ssl_ms,
            .time_send_ms = send_ms,
            .time_wait_ms = wait_ms,
            .time_receive_ms = receive_ms,
        };
    }
};

fn writeCallback(data: [*]const u8, size: usize, nmemb: usize, user_data: *WriteContext) callconv(.c) usize {
    const total = size * nmemb;
    user_data.buf.appendSlice(user_data.allocator, data[0..total]) catch return 0;
    return total;
}

/// curl progress callback: reads the cancelled flag passed via XFERINFODATA.
fn progressCallback(clientp: ?*anyopaque, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t) callconv(.c) c_int {
    if (clientp) |ptr| {
        const flag: *bool = @ptrCast(@alignCast(ptr));
        if (flag.*) return 1; // abort
    }
    return 0;
}

// ── Body encoding helpers ──────────────────────────────────

const BodyType = enum { raw, form_urlencoded, multipart };

fn detectBodyType(headers: []const Header) BodyType {
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
            const val = h.value;
            if (std.mem.indexOf(u8, val, "x-www-form-urlencoded") != null) return .form_urlencoded;
            if (std.mem.indexOf(u8, val, "multipart/form-data") != null) return .multipart;
            break;
        }
    }
    return .raw;
}

/// Parse a JSON body string as an object and encode as "k1=v1&k2=v2".
/// Returns null if body is not a valid JSON object (caller should fallback).
fn buildFormUrlEncoded(allocator: std.mem.Allocator, handle: *c.CURL, body: []const u8) ?[:0]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, aa, body, .{}) catch return null;
    if (parsed.value != .object) return null;

    var buf = std.ArrayList(u8).empty;

    var it = parsed.value.object.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) buf.append(allocator, '&') catch return null;
        first = false;

        // URL-encode key
        const key_z = allocator.dupeZ(u8, entry.key_ptr.*) catch return null;
        defer allocator.free(key_z);
        const esc_key = c.curl_easy_escape(handle, key_z.ptr, @intCast(entry.key_ptr.*.len));
        if (esc_key == null) return null;
        defer c.curl_free(esc_key);
        const esc_key_slice = std.mem.sliceTo(esc_key.?, 0);
        buf.appendSlice(allocator, esc_key_slice) catch return null;

        buf.append(allocator, '=') catch return null;

        // Get value as string
        const val_str = jsonValueToString(aa, entry.value_ptr.*) catch return null;
        const val_z = allocator.dupeZ(u8, val_str) catch return null;
        defer allocator.free(val_z);
        const esc_val = c.curl_easy_escape(handle, val_z.ptr, @intCast(val_str.len));
        if (esc_val == null) return null;
        defer c.curl_free(esc_val);
        const esc_val_slice = std.mem.sliceTo(esc_val.?, 0);
        buf.appendSlice(allocator, esc_val_slice) catch return null;
    }

    // Produce a sentinel-terminated result owned by `allocator`
    buf.append(allocator, 0) catch return null;
    const slice = buf.toOwnedSlice(allocator) catch return null;
    // slice includes trailing 0; convert to [:0]u8
    return slice[0 .. slice.len - 1 :0];
}

/// Parse a JSON body string as an object and build a libcurl MIME multipart.
/// Supports file upload via {"file": "path"} syntax.
/// Returns null if body is not a valid JSON object (caller should fallback).
fn buildMultipart(allocator: std.mem.Allocator, handle: *c.CURL, body: []const u8) ?*c.curl_mime {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, aa, body, .{}) catch return null;
    if (parsed.value != .object) return null;

    const mime = c.curl_mime_init(handle) orelse return null;

    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        const part = c.curl_mime_addpart(mime) orelse {
            c.curl_mime_free(mime);
            return null;
        };

        // Set part name
        const name_z = allocator.dupeZ(u8, entry.key_ptr.*) catch {
            c.curl_mime_free(mime);
            return null;
        };
        defer allocator.free(name_z);
        _ = c.curl_mime_name(part, name_z.ptr);

        const val = entry.value_ptr.*;

        // Check for file upload: {"file": "path"}
        if (val == .object) {
            if (val.object.get("file")) |file_val| {
                if (file_val == .string) {
                    const path_z = allocator.dupeZ(u8, file_val.string) catch {
                        c.curl_mime_free(mime);
                        return null;
                    };
                    defer allocator.free(path_z);
                    _ = c.curl_mime_filedata(part, path_z.ptr);
                    continue;
                }
            }
        }

        // Regular field: convert value to string
        const val_str = jsonValueToString(aa, val) catch {
            c.curl_mime_free(mime);
            return null;
        };
        _ = c.curl_mime_data(part, val_str.ptr, val_str.len);
    }

    return mime;
}

/// Convert a JSON value to a string representation for form fields.
fn jsonValueToString(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .bool => |b| if (b) "true" else "false",
        .null => "null",
        else => try std.fmt.allocPrint(allocator, "{any}", .{std.json.fmt(value, .{})}),
    };
}
