const std = @import("std");
const env_mod = @import("env.zig");
const config = @import("config.zig");

pub const CaptureMap = std.StringHashMap([]const u8);

/// Resolve variable references in a template string.
///   {{VAR}}   — environment variable (user-managed config)
///   $var      — capture variable (auto-extracted from responses)
///   {param}   — path parameter (from collection)
pub fn resolve(
    allocator: std.mem.Allocator,
    template: []const u8,
    env_store: *env_mod.EnvStore,
    path_params: ?[]const config.KV,
    capture_vars: ?*const CaptureMap,
) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < template.len) {
        // Check for {{VAR}} — environment variable
        if (i + 1 < template.len and template[i] == '{' and template[i + 1] == '{') {
            const start = i + 2;
            const end = std.mem.indexOf(u8, template[start..], "}}") orelse {
                try result.append(allocator, template[i]);
                i += 1;
                continue;
            };
            const var_name = template[start .. start + end];
            if (env_store.getVar(var_name)) |val| {
                try result.appendSlice(allocator, val);
            } else {
                // Keep unresolved placeholder
                try result.appendSlice(allocator, template[i .. start + end + 2]);
            }
            i = start + end + 2;
            continue;
        }

        // Check for $var — capture variable
        // Match $identifier (letters, digits, underscore)
        if (template[i] == '$' and i + 1 < template.len and isIdentStart(template[i + 1])) {
            const start = i + 1;
            var end_pos = start;
            while (end_pos < template.len and isIdentChar(template[end_pos])) {
                end_pos += 1;
            }
            const var_name = template[start..end_pos];
            if (capture_vars) |cv| {
                if (cv.get(var_name)) |val| {
                    try result.appendSlice(allocator, val);
                    i = end_pos;
                    continue;
                }
            }
            // Keep unresolved $var as-is
            try result.appendSlice(allocator, template[i..end_pos]);
            i = end_pos;
            continue;
        }

        // Check for {param} (single braces, not double)
        if (template[i] == '{' and (i + 1 >= template.len or template[i + 1] != '{')) {
            const start = i + 1;
            const end = std.mem.indexOfScalar(u8, template[start..], '}') orelse {
                try result.append(allocator, template[i]);
                i += 1;
                continue;
            };
            const param_name = template[start .. start + end];

            // First try path_params, then env vars
            var found: ?[]const u8 = null;
            if (path_params) |params| {
                for (params) |p| {
                    if (std.mem.eql(u8, p.name, param_name)) {
                        found = p.value;
                        break;
                    }
                }
            }
            if (found == null) {
                found = env_store.getVar(param_name);
            }

            if (found) |val| {
                const resolved_val = try resolve(allocator, val, env_store, null, capture_vars);
                defer allocator.free(resolved_val);
                try result.appendSlice(allocator, resolved_val);
            } else {
                try result.appendSlice(allocator, template[i .. start + end + 1]);
            }
            i = start + end + 1;
            continue;
        }

        try result.append(allocator, template[i]);
        i += 1;
    }

    return try result.toOwnedSlice(allocator);
}

fn isIdentStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}
