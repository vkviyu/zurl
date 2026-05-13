const std = @import("std");
const json = @import("json.zig");
const env_mod = @import("env.zig");
const cache_mod = @import("cache.zig");
const CacheEntry = cache_mod.CacheEntry;

const default_file = "zurl.json";

/// Get the config file path from ZURLENV env var or default.
pub fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    if (std.posix.getenv("ZURLENV")) |p| {
        return try allocator.dupe(u8, p);
    }
    return try allocator.dupe(u8, default_file);
}

/// Save the full application state (envs + cache + groups) to zurl.json.
pub fn saveToDisk(
    allocator: std.mem.Allocator,
    env_store: *env_mod.EnvStore,
    cache_store: *cache_mod.CacheStore,
) !void {
    const file_path = try getConfigPath(allocator);
    defer allocator.free(file_path);

    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();

    var write_buf: [8192]u8 = undefined;
    var fw = file.writer(&write_buf);
    const w = &fw.interface;

    try w.writeAll("{\n");

    // active
    if (env_store.active_name) |name| {
        try w.writeAll("  \"active\": \"");
        try json.writeEscaped(w, name);
        try w.writeAll("\",\n");
    } else {
        try w.writeAll("  \"active\": null,\n");
    }

    // cache_limit
    try w.print("  \"cache_limit\": {d},\n", .{cache_store.cache_limit});

    // envs
    try w.writeAll("  \"envs\": {\n");
    var env_it = env_store.envs.iterator();
    var env_first = true;
    while (env_it.next()) |env_entry| {
        if (!env_first) try w.writeAll(",\n");
        env_first = false;

        const env_name = env_entry.key_ptr.*;
        try w.writeAll("    \"");
        try json.writeEscaped(w, env_name);
        try w.writeAll("\": {\n");

        // vars
        try w.writeAll("      \"vars\": {");
        var var_it = env_entry.value_ptr.iterator();
        var var_first = true;
        while (var_it.next()) |var_entry| {
            if (!var_first) try w.writeByte(',');
            var_first = false;
            try w.writeAll("\n        \"");
            try json.writeEscaped(w, var_entry.key_ptr.*);
            try w.writeAll("\": \"");
            try json.writeEscaped(w, var_entry.value_ptr.*);
            try w.writeByte('"');
        }
        if (!var_first) try w.writeByte('\n');
        if (var_first) try w.writeByte('\n');
        try w.writeAll("      },\n");

        // cache
        const cache_entries = cache_store.getEnvCache(env_name);
        try w.writeAll("      \"cache\": [\n");
        if (cache_entries) |entries| {
            for (entries, 0..) |ce, ci| {
                if (ci > 0) try w.writeAll(",\n");
                try writeCacheEntryJson(w, ce, 8);
            }
            if (entries.len > 0) try w.writeByte('\n');
        }
        try w.writeAll("      ],\n");

        // groups
        const groups = cache_store.getEnvGroups(env_name);
        try w.writeAll("      \"groups\": {");
        if (groups) |grps| {
            var grp_it = grps.iterator();
            var grp_first = true;
            while (grp_it.next()) |grp_entry| {
                if (!grp_first) try w.writeByte(',');
                grp_first = false;
                try w.writeAll("\n        \"");
                try json.writeEscaped(w, grp_entry.key_ptr.*);
                try w.writeAll("\": [\n");
                for (grp_entry.value_ptr.items, 0..) |ce, ci| {
                    if (ci > 0) try w.writeAll(",\n");
                    try writeCacheEntryJson(w, ce, 10);
                }
                if (grp_entry.value_ptr.items.len > 0) try w.writeByte('\n');
                try w.writeAll("        ]");
            }
            if (!grp_first) try w.writeByte('\n');
            if (grp_first) try w.writeByte('\n');
        } else {
            try w.writeByte('\n');
        }
        try w.writeAll("      }\n");
        try w.writeAll("    }");
    }
    try w.writeAll("\n  }\n}\n");
    try w.flush();
}

/// Load application state from zurl.json. Returns false if the file doesn't exist.
pub fn loadFromDisk(
    allocator: std.mem.Allocator,
    env_store: *env_mod.EnvStore,
    cache_store: *cache_mod.CacheStore,
) !void {
    const file_path = try getConfigPath(allocator);
    defer allocator.free(file_path);

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidFormat;

    // cache_limit
    if (root.object.get("cache_limit")) |cl| {
        if (cl == .integer and cl.integer > 0) {
            cache_store.cache_limit = @intCast(cl.integer);
        }
    }

    const envs_val = root.object.get("envs") orelse return error.MissingEnvs;
    if (envs_val != .object) return error.InvalidEnvs;

    var envs_it = envs_val.object.iterator();
    while (envs_it.next()) |env_entry| {
        const env_name = env_entry.key_ptr.*;

        // Create the environment in EnvStore
        env_store.create(env_name) catch {};

        if (env_entry.value_ptr.* != .object) continue;
        const env_obj = &env_entry.value_ptr.object;

        // Check format: new (has "vars") or old (flat key-value)
        if (env_obj.get("vars")) |vars_val| {
            // New format
            if (vars_val == .object) {
                var var_it = vars_val.object.iterator();
                while (var_it.next()) |var_entry| {
                    if (var_entry.value_ptr.* == .string) {
                        // Temporarily switch active to set vars
                        const saved = env_store.active_name;
                        env_store.active_name = env_store.envs.getKey(env_name);
                        env_store.setVar(var_entry.key_ptr.*, var_entry.value_ptr.string) catch {};
                        env_store.active_name = saved;
                    }
                }
            }

            // Load cache
            if (env_obj.get("cache")) |cache_val| {
                if (cache_val == .array) {
                    for (cache_val.array.items) |item| {
                        if (parseCacheEntry(allocator, item)) |ce| {
                            cache_store.recordCache(env_name, ce) catch {};
                            ce.deinit(allocator);
                        } else |_| {}
                    }
                }
            }

            // Load groups
            if (env_obj.get("groups")) |groups_val| {
                if (groups_val == .object) {
                    var grp_it = groups_val.object.iterator();
                    while (grp_it.next()) |grp_entry| {
                        if (grp_entry.value_ptr.* == .array) {
                            for (grp_entry.value_ptr.array.items) |item| {
                                if (parseCacheEntry(allocator, item)) |ce| {
                                    cache_store.addToGroup(env_name, grp_entry.key_ptr.*, ce) catch {};
                                    ce.deinit(allocator);
                                } else |_| {}
                            }
                        }
                    }
                }
            }
        } else {
            // Old format: flat key-value vars
            var var_it = env_obj.iterator();
            while (var_it.next()) |var_entry| {
                if (var_entry.value_ptr.* == .string) {
                    const saved = env_store.active_name;
                    env_store.active_name = env_store.envs.getKey(env_name);
                    env_store.setVar(var_entry.key_ptr.*, var_entry.value_ptr.string) catch {};
                    env_store.active_name = saved;
                }
            }
        }
    }

    // Restore active
    if (root.object.get("active")) |active_val| {
        if (active_val == .string) {
            if (env_store.envs.contains(active_val.string)) {
                env_store.use(active_val.string) catch {};
            }
        }
    }
    if (env_store.active_name == null) {
        if (env_store.envs.contains("default")) {
            env_store.use("default") catch {};
        }
    }
}

fn parseCacheEntry(allocator: std.mem.Allocator, value: std.json.Value) !CacheEntry {
    if (value != .object) return error.InvalidCacheEntry;
    const obj = value.object;

    const method_val = obj.get("method") orelse return error.MissingField;
    if (method_val != .string) return error.InvalidField;
    const url_val = obj.get("url") orelse return error.MissingField;
    if (url_val != .string) return error.InvalidField;

    const method = try allocator.dupe(u8, method_val.string);
    const url = try allocator.dupe(u8, url_val.string);

    var body: ?[]const u8 = null;
    if (obj.get("body")) |body_val| {
        if (body_val == .string) body = try allocator.dupe(u8, body_val.string);
    }

    var headers: []CacheEntry.HeaderPair = &.{};
    if (obj.get("headers")) |hdrs_val| {
        if (hdrs_val == .array) {
            var hlist = try allocator.alloc(CacheEntry.HeaderPair, hdrs_val.array.items.len);
            var count: usize = 0;
            for (hdrs_val.array.items) |h| {
                if (h == .object) {
                    var h_it = h.object.iterator();
                    if (h_it.next()) |h_entry| {
                        if (h_entry.value_ptr.* == .string) {
                            hlist[count] = .{
                                .name = try allocator.dupe(u8, h_entry.key_ptr.*),
                                .value = try allocator.dupe(u8, h_entry.value_ptr.string),
                            };
                            count += 1;
                        }
                    }
                }
            }
            if (count < hlist.len) {
                headers = try allocator.realloc(hlist, count);
            } else {
                headers = hlist;
            }
        }
    }

    return .{
        .method = method,
        .url_template = url,
        .headers = headers,
        .body = body,
    };
}

fn writeCacheEntryJson(w: anytype, ce: CacheEntry, indent: usize) !void {
    try json.writeSpaces(w, indent);
    try w.writeAll("{\n");
    try json.writeSpaces(w, indent + 2);
    try w.writeAll("\"method\": \"");
    try json.writeEscaped(w, ce.method);
    try w.writeAll("\",\n");
    try json.writeSpaces(w, indent + 2);
    try w.writeAll("\"url\": \"");
    try json.writeEscaped(w, ce.url_template);
    try w.writeAll("\",\n");
    try json.writeSpaces(w, indent + 2);
    try w.writeAll("\"headers\": [");
    for (ce.headers, 0..) |h, hi| {
        if (hi > 0) try w.writeByte(',');
        try w.writeAll("{\"");
        try json.writeEscaped(w, h.name);
        try w.writeAll("\": \"");
        try json.writeEscaped(w, h.value);
        try w.writeAll("\"}");
    }
    try w.writeAll("],\n");
    try json.writeSpaces(w, indent + 2);
    if (ce.body) |body| {
        try w.writeAll("\"body\": \"");
        try json.writeEscaped(w, body);
        try w.writeAll("\"\n");
    } else {
        try w.writeAll("\"body\": null\n");
    }
    try json.writeSpaces(w, indent);
    try w.writeByte('}');
}
