const std = @import("std");

pub const VarMap = std.StringHashMap([]const u8);

/// Pure environment variable management.
/// No persistence — that responsibility belongs to store.zig.
pub const EnvStore = struct {
    allocator: std.mem.Allocator,
    envs: std.StringHashMap(VarMap),
    active_name: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator) EnvStore {
        return .{
            .allocator = allocator,
            .envs = std.StringHashMap(VarMap).init(allocator),
            .active_name = null,
        };
    }

    pub fn deinit(self: *EnvStore) void {
        var it = self.envs.iterator();
        while (it.next()) |entry| {
            freeVarMap(self.allocator, entry.value_ptr);
            self.allocator.free(entry.key_ptr.*);
        }
        self.envs.deinit();
        if (self.active_name) |name| self.allocator.free(name);
    }

    pub fn freeVarMap(allocator: std.mem.Allocator, map: *VarMap) void {
        var it = map.iterator();
        while (it.next()) |v| {
            allocator.free(v.key_ptr.*);
            allocator.free(v.value_ptr.*);
        }
        map.deinit();
    }

    pub fn create(self: *EnvStore, name: []const u8) !void {
        if (self.envs.contains(name)) return error.EnvAlreadyExists;
        const duped = try self.allocator.dupe(u8, name);
        try self.envs.put(duped, VarMap.init(self.allocator));
    }

    pub fn use(self: *EnvStore, name: []const u8) !void {
        if (!self.envs.contains(name)) return error.EnvNotFound;
        if (self.active_name) |old| self.allocator.free(old);
        self.active_name = try self.allocator.dupe(u8, name);
    }

    pub fn setVar(self: *EnvStore, key: []const u8, value: []const u8) !void {
        const map = self.getActiveMap() orelse return error.NoActiveEnv;
        if (map.fetchRemove(key)) |removed| {
            self.allocator.free(removed.key);
            self.allocator.free(removed.value);
        }
        const k = try self.allocator.dupe(u8, key);
        const v = try self.allocator.dupe(u8, value);
        try map.put(k, v);
    }

    pub fn getVar(self: *EnvStore, key: []const u8) ?[]const u8 {
        const map = self.getActiveMap() orelse return null;
        return map.get(key);
    }

    pub fn getActiveVars(self: *EnvStore) ?*VarMap {
        return self.getActiveMap();
    }

    pub fn getEnvVars(self: *EnvStore, name: []const u8) ?*VarMap {
        return self.envs.getPtr(name);
    }

    pub fn listEnvs(self: *EnvStore) [][]const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        var it = self.envs.iterator();
        while (it.next()) |entry| {
            names.append(self.allocator, entry.key_ptr.*) catch {};
        }
        return names.toOwnedSlice(self.allocator) catch &.{};
    }

    fn getActiveMap(self: *EnvStore) ?*VarMap {
        const name = self.active_name orelse return null;
        return self.envs.getPtr(name);
    }
};
