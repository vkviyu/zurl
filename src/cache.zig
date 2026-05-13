const std = @import("std");

/// A cached request template — stores pre-interpolation URL with {{VAR}} placeholders.
pub const CacheEntry = struct {
    method: []const u8,
    url_template: []const u8,
    headers: []const HeaderPair,
    body: ?[]const u8,

    pub const HeaderPair = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn deinit(self: *const CacheEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        allocator.free(self.url_template);
        if (self.body) |b| allocator.free(b);
        for (self.headers) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        allocator.free(self.headers);
    }

    pub fn dupe(self: *const CacheEntry, allocator: std.mem.Allocator) !CacheEntry {
        const method = try allocator.dupe(u8, self.method);
        const url = try allocator.dupe(u8, self.url_template);
        const body_d = if (self.body) |b| try allocator.dupe(u8, b) else null;
        const hdrs = try allocator.alloc(HeaderPair, self.headers.len);
        for (self.headers, 0..) |h, i| {
            hdrs[i] = .{
                .name = try allocator.dupe(u8, h.name),
                .value = try allocator.dupe(u8, h.value),
            };
        }
        return .{
            .method = method,
            .url_template = url,
            .headers = hdrs,
            .body = body_d,
        };
    }
};

/// Per-environment cache: a rolling ring buffer + named permanent groups.
pub const CacheStore = struct {
    allocator: std.mem.Allocator,
    /// env_name → CacheData
    data: std.StringHashMap(CacheData),
    cache_limit: usize,

    const default_cache_limit = 10;

    const CacheData = struct {
        cache: std.ArrayList(CacheEntry),
        groups: std.StringHashMap(std.ArrayList(CacheEntry)),
    };

    pub fn init(allocator: std.mem.Allocator) CacheStore {
        return .{
            .allocator = allocator,
            .data = std.StringHashMap(CacheData).init(allocator),
            .cache_limit = default_cache_limit,
        };
    }

    pub fn deinit(self: *CacheStore) void {
        var it = self.data.iterator();
        while (it.next()) |entry| {
            freeCacheData(self.allocator, entry.value_ptr);
            self.allocator.free(entry.key_ptr.*);
        }
        self.data.deinit();
    }

    pub fn freeCacheData(allocator: std.mem.Allocator, cd: *CacheData) void {
        for (cd.cache.items) |*ce| ce.deinit(allocator);
        cd.cache.deinit(allocator);
        var grp_it = cd.groups.iterator();
        while (grp_it.next()) |grp| {
            for (grp.value_ptr.items) |*ce| ce.deinit(allocator);
            grp.value_ptr.deinit(allocator);
            allocator.free(grp.key_ptr.*);
        }
        cd.groups.deinit();
    }

    /// Ensure a CacheData exists for the given environment name.
    pub fn ensureEnv(self: *CacheStore, env_name: []const u8) !*CacheData {
        const gop = try self.data.getOrPut(env_name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, env_name);
            gop.value_ptr.* = .{
                .cache = .empty,
                .groups = std.StringHashMap(std.ArrayList(CacheEntry)).init(self.allocator),
            };
        }
        return gop.value_ptr;
    }

    /// Record a request template into the named environment's rolling cache.
    pub fn recordCache(self: *CacheStore, env_name: []const u8, entry: CacheEntry) !void {
        const cd = try self.ensureEnv(env_name);
        const duped = try entry.dupe(self.allocator);
        while (cd.cache.items.len >= self.cache_limit) {
            var oldest = cd.cache.orderedRemove(0);
            oldest.deinit(self.allocator);
        }
        try cd.cache.append(self.allocator, duped);
    }

    /// Add a request template to a named group.
    pub fn addToGroup(self: *CacheStore, env_name: []const u8, group_name: []const u8, entry: CacheEntry) !void {
        const cd = try self.ensureEnv(env_name);
        const duped = try entry.dupe(self.allocator);
        const gop = try cd.groups.getOrPut(group_name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, group_name);
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(self.allocator, duped);
    }

    pub fn getEnvCache(self: *CacheStore, env_name: []const u8) ?[]const CacheEntry {
        const cd = self.data.getPtr(env_name) orelse return null;
        if (cd.cache.items.len == 0) return null;
        return cd.cache.items;
    }

    pub fn getEnvGroups(self: *CacheStore, env_name: []const u8) ?*std.StringHashMap(std.ArrayList(CacheEntry)) {
        const cd = self.data.getPtr(env_name) orelse return null;
        return &cd.groups;
    }
};
