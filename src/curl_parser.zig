const std = @import("std");

/// Parsed result of a curl command.
pub const CurlCommand = struct {
    method: []const u8,
    url: []const u8,
    headers: []const Header,
    body: ?[]const u8,
    follow_redirects: bool,

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };
};

/// Parse a curl command string into structured fields.
/// Handles: -X/--request, -H/--header, -d/--data/--data-raw/--data-binary,
///           -L/--location, and the positional URL.
pub fn parse(allocator: std.mem.Allocator, input: []const u8) !CurlCommand {
    var method: []const u8 = "GET";
    var url: ?[]const u8 = null;
    var body: ?[]const u8 = null;
    var follow_redirects: bool = false;
    var headers: std.ArrayList(CurlCommand.Header) = .empty;

    var i: usize = 0;

    // Skip leading "curl" if present
    skipWs(input, &i);
    if (i + 4 <= input.len and std.mem.eql(u8, input[i .. i + 4], "curl")) {
        i += 4;
    }

    while (i < input.len) {
        skipWs(input, &i);
        if (i >= input.len) break;

        // Long options
        if (matchLong(input, i, "--request")) {
            i += "--request".len;
            skipWs(input, &i);
            method = try parseQuotedOrWord(input, &i);
        } else if (matchLong(input, i, "--header")) {
            i += "--header".len;
            skipWs(input, &i);
            const val = try parseQuotedOrWord(input, &i);
            if (splitHeader(val)) |h| {
                try headers.append(allocator, h);
            }
        } else if (matchLong(input, i, "--data-raw") or matchLong(input, i, "--data-binary")) {
            const skip_len: usize = if (matchLong(input, i, "--data-raw")) "--data-raw".len else "--data-binary".len;
            i += skip_len;
            skipWs(input, &i);
            body = try parseQuotedOrWord(input, &i);
            if (std.mem.eql(u8, method, "GET")) method = "POST";
        } else if (matchLong(input, i, "--data")) {
            i += "--data".len;
            skipWs(input, &i);
            body = try parseQuotedOrWord(input, &i);
            if (std.mem.eql(u8, method, "GET")) method = "POST";
        } else if (matchLong(input, i, "--location")) {
            i += "--location".len;
            follow_redirects = true;
        } else if (matchLong(input, i, "--compressed") or matchLong(input, i, "--insecure")) {
            // Skip known but unsupported flags
            while (i < input.len and input[i] != ' ' and input[i] != '\t') : (i += 1) {}
        }
        // Short options
        else if (input[i] == '-' and i + 1 < input.len and input[i + 1] != '-') {
            const flag = input[i + 1];
            i += 2;
            switch (flag) {
                'X' => {
                    skipWs(input, &i);
                    method = try parseQuotedOrWord(input, &i);
                },
                'H' => {
                    skipWs(input, &i);
                    const val = try parseQuotedOrWord(input, &i);
                    if (splitHeader(val)) |h| {
                        try headers.append(allocator, h);
                    }
                },
                'd' => {
                    skipWs(input, &i);
                    body = try parseQuotedOrWord(input, &i);
                    if (std.mem.eql(u8, method, "GET")) method = "POST";
                },
                'L' => {
                    follow_redirects = true;
                },
                'u' => {
                    // -u user:pass — skip (basic auth, not yet supported)
                    skipWs(input, &i);
                    _ = try parseQuotedOrWord(input, &i);
                },
                'k' => {
                    // --insecure short form, skip
                },
                else => {
                    // Skip unknown short option + possible value
                    skipWs(input, &i);
                    if (i < input.len and input[i] != '-') {
                        _ = try parseQuotedOrWord(input, &i);
                    }
                },
            }
        }
        // Positional argument = URL
        else {
            const val = try parseQuotedOrWord(input, &i);
            if (url == null and val.len > 0) {
                url = val;
            }
        }
    }

    return .{
        .method = method,
        .url = url orelse return error.MissingUrl,
        .headers = headers.toOwnedSlice(allocator) catch &.{},
        .body = body,
        .follow_redirects = follow_redirects,
    };
}

/// Parse a quoted string ('...' or "...") or a bare word.
fn parseQuotedOrWord(input: []const u8, pos: *usize) ![]const u8 {
    if (pos.* >= input.len) return error.UnexpectedEnd;

    const ch = input[pos.*];
    if (ch == '\'' or ch == '"') {
        // Quoted string
        const quote = ch;
        pos.* += 1;
        const start = pos.*;
        while (pos.* < input.len) {
            if (input[pos.*] == '\\' and pos.* + 1 < input.len and input[pos.* + 1] == quote) {
                pos.* += 2; // skip escaped quote
            } else if (input[pos.*] == quote) {
                const result = input[start..pos.*];
                pos.* += 1; // skip closing quote
                return result;
            } else {
                pos.* += 1;
            }
        }
        return input[start..pos.*]; // unterminated quote, return what we have
    }

    // Bare word (no quotes)
    const start = pos.*;
    while (pos.* < input.len and input[pos.*] != ' ' and input[pos.*] != '\t') {
        pos.* += 1;
    }
    return input[start..pos.*];
}

fn splitHeader(val: []const u8) ?CurlCommand.Header {
    const colon = std.mem.indexOfScalar(u8, val, ':') orelse return null;
    return .{
        .name = std.mem.trim(u8, val[0..colon], " "),
        .value = std.mem.trim(u8, val[colon + 1 ..], " "),
    };
}

fn matchLong(input: []const u8, pos: usize, flag: []const u8) bool {
    if (pos + flag.len > input.len) return false;
    if (!std.mem.eql(u8, input[pos .. pos + flag.len], flag)) return false;
    // Must be followed by whitespace, '=' or end
    if (pos + flag.len < input.len) {
        const next = input[pos + flag.len];
        return next == ' ' or next == '\t' or next == '=';
    }
    return true;
}

fn skipWs(input: []const u8, pos: *usize) void {
    while (pos.* < input.len and (input[pos.*] == ' ' or input[pos.*] == '\t')) {
        pos.* += 1;
    }
    // Also skip backslash-newline continuations (curl from Postman often has these)
    if (pos.* + 1 < input.len and input[pos.*] == '\\' and input[pos.* + 1] == '\n') {
        pos.* += 2;
        skipWs(input, pos);
    }
}
