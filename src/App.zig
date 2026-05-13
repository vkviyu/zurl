const std = @import("std");
const config = @import("config.zig");
const client = @import("client.zig");
const env_mod = @import("env.zig");
const cache_mod = @import("cache.zig");
const store = @import("store.zig");
const har = @import("har.zig");
const interpolate = @import("interpolate.zig");
const args_util = @import("args.zig");
const Executor = @import("executor.zig").Executor;
const extractJsonPath = @import("executor.zig").extractJsonPath;
const curl_parser = @import("curl_parser.zig");
const curl_import = @import("curl_import.zig");

const c_stdio = @cImport({
    @cInclude("stdio.h");
});

/// Application context — holds all mutable state and dispatches commands.
pub const App = struct {
    allocator: std.mem.Allocator,
    env_store: env_mod.EnvStore,
    cache_store: cache_mod.CacheStore,
    http_client: client.HttpClient,
    collection: ?config.Collection,
    history: std.ArrayList(har.HarEntry),
    /// Pointer to the cancellation flag managed by the signal handler.
    cancelled: *bool,
    /// Last response body for standalone `capture` command.
    last_response_body: ?[]const u8 = null,
    /// Capture variables — separate namespace from env vars, referenced via $var.
    capture_vars: interpolate.CaptureMap,

    pub fn init(allocator: std.mem.Allocator, cancelled: *bool) !App {
        var env_s = env_mod.EnvStore.init(allocator);
        var cache_s = cache_mod.CacheStore.init(allocator);

        // Load persisted state (ignore errors — file may not exist)
        store.loadFromDisk(allocator, &env_s, &cache_s) catch {};

        return .{
            .allocator = allocator,
            .env_store = env_s,
            .cache_store = cache_s,
            .http_client = try client.HttpClient.init(allocator, cancelled),
            .collection = null,
            .history = .empty,
            .cancelled = cancelled,
            .capture_vars = interpolate.CaptureMap.init(allocator),
        };
    }

    pub fn deinit(self: *App) void {
        if (self.last_response_body) |b| self.allocator.free(b);
        var cap_it = self.capture_vars.iterator();
        while (cap_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.capture_vars.deinit();
        if (self.collection) |*c| c.deinit();
        for (self.history.items) |*entry| entry.deinit(self.allocator);
        self.history.deinit(self.allocator);
        self.http_client.deinit();
        self.cache_store.deinit();
        self.env_store.deinit();
    }

    /// Dispatch a single user command line.
    pub fn dispatch(self: *App, input: []const u8, writer: anytype) !void {
        var iter = std.mem.tokenizeScalar(u8, input, ' ');
        const cmd = iter.next() orelse return;
        const rest = iter.rest();

        // Check if cmd is an HTTP method -> inline request
        if (config.Method.fromString(cmd)) |method| {
            try self.cmdInlineRequest(method, rest, writer);
        } else |_| {
            if (std.mem.eql(u8, cmd, "help")) {
                try printHelp(writer);
            } else if (std.mem.eql(u8, cmd, "clear") or std.mem.eql(u8, cmd, "cls")) {
                try writer.print("\x1b[H\x1b[2J\x1b[3J", .{});
            } else if (std.mem.eql(u8, cmd, "quit") or std.mem.eql(u8, cmd, "exit")) {
                std.process.exit(0);
            } else if (std.mem.eql(u8, cmd, "load")) {
                try self.cmdLoad(rest, writer);
            } else if (std.mem.eql(u8, cmd, "list")) {
                try self.cmdList(writer);
            } else if (std.mem.eql(u8, cmd, "run")) {
                try self.cmdRun(rest, writer);
            } else if (std.mem.eql(u8, cmd, "env")) {
                try self.cmdEnv(rest, writer);
            } else if (std.mem.eql(u8, cmd, "set")) {
                if (rest.len == 0) {
                    try writer.print("Usage: set <k1> <v1> [<k2> <v2> ...]\n", .{});
                } else {
                    var buf: [4096]u8 = undefined;
                    const full = std.fmt.bufPrint(&buf, "set {s}", .{rest}) catch {
                        try writer.print("Arguments too long.\n", .{});
                        return;
                    };
                    try self.cmdEnv(full, writer);
                }
            } else if (std.mem.eql(u8, cmd, "vars")) {
                try self.cmdVars(rest, writer);
            } else if (std.mem.eql(u8, cmd, "export")) {
                try self.cmdExport(rest, writer);
            } else if (std.mem.eql(u8, cmd, "history")) {
                try self.cmdHistory(writer);
            } else if (std.mem.eql(u8, cmd, "curl")) {
                try self.cmdCurl(rest, writer);
            } else if (std.mem.eql(u8, cmd, "cache")) {
                try self.cmdCache(rest, writer);
            } else if (std.mem.eql(u8, cmd, "replay")) {
                try self.cmdReplay(rest, writer);
            } else if (std.mem.eql(u8, cmd, "groups")) {
                try self.cmdGroups(rest, writer);
            } else if (std.mem.eql(u8, cmd, "capture")) {
                try self.cmdCapture(rest, writer);
            } else if (std.mem.eql(u8, cmd, "captures")) {
                try self.cmdCaptures(writer);
            } else if (std.mem.eql(u8, cmd, "import")) {
                try self.cmdImport(rest, writer);
            } else {
                try writer.print("Unknown command: {s}. Type 'help' for usage.\n", .{cmd});
            }
        }
    }

    // ── Command Handlers ────────────────────────────────────

    fn cmdLoad(self: *App, path: []const u8, writer: anytype) !void {
        if (path.len == 0) {
            try writer.print("Usage: load <file.json>\n", .{});
            return;
        }
        if (self.collection) |*c| c.deinit();
        self.collection = try config.Collection.loadFromFile(self.allocator, path);
        const c = self.collection.?;
        try writer.print("Loaded collection: {s} ({d} requests)\n", .{ c.name, c.requests.len });
    }

    fn cmdList(self: *App, writer: anytype) !void {
        const c = self.collection orelse {
            try writer.print("No collection loaded. Use 'load <file>' first.\n", .{});
            return;
        };
        try writer.print("Collection: {s}\n", .{c.name});
        for (c.requests, 0..) |req, i| {
            try writer.print("  [{d}] {s}  {s} {s}\n", .{
                i,
                req.name,
                @tagName(req.request.method),
                req.request.url,
            });
        }
    }

    fn cmdRun(self: *App, arg: []const u8, writer: anytype) !void {
        const col = self.collection orelse {
            try writer.print("No collection loaded. Use 'load <file>' first.\n", .{});
            return;
        };
        if (arg.len == 0) {
            try writer.print("Usage: run <name|index|all>\n", .{});
            return;
        }

        var exec = Executor.init(self.allocator, &self.http_client, &self.history, &self.capture_vars);

        if (std.mem.eql(u8, arg, "all")) {
            for (col.requests, 0..) |req, i| {
                try writer.print("\n--- [{d}] {s} ---\n", .{ i, req.name });
                var hdr_buf: [32]Executor.Request.Header = undefined;
                const r = Executor.fromRequestItem(req, &hdr_buf);
                const result = try exec.execute(r, &self.env_store, writer, false);
                if (result.body) |b| self.allocator.free(b);
                if (result.headers_raw) |h| self.allocator.free(h);
            }
            return;
        }

        if (std.fmt.parseInt(usize, arg, 10)) |idx| {
            if (idx < col.requests.len) {
                var hdr_buf: [32]Executor.Request.Header = undefined;
                const r = Executor.fromRequestItem(col.requests[idx], &hdr_buf);
                const result = try exec.execute(r, &self.env_store, writer, false);
                if (result.body) |b| self.allocator.free(b);
                if (result.headers_raw) |h| self.allocator.free(h);
                return;
            }
            try writer.print("Index out of range (0..{d})\n", .{col.requests.len - 1});
            return;
        } else |_| {}

        for (col.requests) |req| {
            if (std.mem.eql(u8, req.name, arg)) {
                var hdr_buf: [32]Executor.Request.Header = undefined;
                const r = Executor.fromRequestItem(req, &hdr_buf);
                const result = try exec.execute(r, &self.env_store, writer, false);
                if (result.body) |b| self.allocator.free(b);
                if (result.headers_raw) |h| self.allocator.free(h);
                return;
            }
        }
        try writer.print("Request not found: {s}\n", .{arg});
    }

    fn cmdInlineRequest(
        self: *App,
        method: config.Method,
        input_args: []const u8,
        writer: anytype,
    ) !void {
        // Parse inline request arguments
        var req_headers: [32]Executor.Request.Header = undefined;
        var header_count: usize = 0;

        var raw_url: ?[]const u8 = null;
        var body_template: ?[]const u8 = null;
        var follow_redirects: bool = false;
        var use_env: ?[]const u8 = null;
        var pretty: bool = false;
        var group_name: ?[]const u8 = null;
        var captures: [16]config.CaptureEntry = undefined;
        var capture_count: usize = 0;

        var i: usize = 0;
        const input = input_args;
        while (i < input.len) {
            args_util.skipWhitespace(input, &i);
            if (i >= input.len) break;

            if (args_util.matchFlag(input, i, 'H')) {
                i += 2;
                args_util.skipWhitespace(input, &i);
                const val = try args_util.parseValue(input, &i);
                if (std.mem.indexOfScalar(u8, val, ':')) |colon| {
                    const hname = std.mem.trim(u8, val[0..colon], " ");
                    const hval = std.mem.trim(u8, val[colon + 1 ..], " ");
                    if (header_count < req_headers.len) {
                        req_headers[header_count] = .{ .name = hname, .value_template = hval };
                        header_count += 1;
                    }
                }
            } else if (args_util.matchFlag(input, i, 'L')) {
                i += 2;
                follow_redirects = true;
            } else if (args_util.matchFlag(input, i, 'p')) {
                i += 2;
                pretty = true;
            } else if (args_util.matchFlag(input, i, 'e')) {
                i += 2;
                args_util.skipWhitespace(input, &i);
                use_env = try args_util.parseValue(input, &i);
            } else if (args_util.matchFlag(input, i, 'g')) {
                i += 2;
                args_util.skipWhitespace(input, &i);
                group_name = try args_util.parseValue(input, &i);
            } else if (args_util.matchFlag(input, i, 'd')) {
                i += 2;
                args_util.skipWhitespace(input, &i);
                body_template = try args_util.parseValue(input, &i);
            } else if (args_util.matchFlag(input, i, 'c')) {
                i += 2;
                args_util.skipWhitespace(input, &i);
                const val = try args_util.parseValue(input, &i);
                // Parse "key=$.path"
                if (std.mem.indexOfScalar(u8, val, '=')) |eq| {
                    if (capture_count < captures.len) {
                        captures[capture_count] = .{
                            .name = val[0..eq],
                            .path = val[eq + 1 ..],
                        };
                        capture_count += 1;
                    }
                }
            } else if (args_util.isFlag(input, i)) {
                const flag_start = i;
                i += 1;
                while (i < input.len and input[i] != ' ' and input[i] != '\t') : (i += 1) {}
                const flag = input[flag_start..i];
                try writer.print("Unknown option: {s}  (available: -H, -d, -L, -e, -p, -g, -c)\n", .{flag});
                return;
            } else {
                const val = try args_util.parseValue(input, &i);
                if (raw_url == null) raw_url = val;
            }
        }

        const url_raw = raw_url orelse {
            try writer.print("Usage: {s} <url> [-H \"Header: Value\"] [-d body] [-L] [-e env] [-p] [-g group]\n", .{@tagName(method)});
            return;
        };

        // Temporarily switch environment if -e specified
        const saved_env = self.env_store.active_name;
        if (use_env) |target_env| {
            if (self.env_store.getEnvVars(target_env) == null) {
                try writer.print("Environment not found: {s}\n", .{target_env});
                return;
            }
            self.env_store.active_name = try self.allocator.dupe(u8, target_env);
        }
        defer {
            if (use_env != null) {
                if (self.env_store.active_name) |tmp| {
                    if (saved_env == null or !std.mem.eql(u8, tmp, saved_env.?)) {
                        self.allocator.free(tmp);
                    }
                }
                self.env_store.active_name = saved_env;
            }
        }

        // Execute via unified executor
        var exec = Executor.init(self.allocator, &self.http_client, &self.history, &self.capture_vars);
        const result = try exec.execute(.{
            .method = method,
            .method_str = @tagName(method),
            .url_template = url_raw,
            .headers = req_headers[0..header_count],
            .body_template = body_template,
            .follow_redirects = follow_redirects,
            .captures = if (capture_count > 0) captures[0..capture_count] else null,
        }, &self.env_store, writer, pretty);
        defer {
            if (result.headers_raw) |h| self.allocator.free(h);
        }

        // Store last response body for standalone `capture` command
        if (self.last_response_body) |old| self.allocator.free(old);
        self.last_response_body = result.body; // take ownership, don't free

        // Build cache entry from template (pre-interpolation values)
        const cache_entry = buildCacheEntry(
            self.allocator,
            @tagName(method),
            url_raw,
            req_headers[0..header_count],
            body_template,
        ) catch null;
        if (cache_entry) |ce| {
            const env_name = self.env_store.active_name orelse "default";
            if (group_name) |gname| {
                self.cache_store.addToGroup(env_name, gname, ce) catch {};
                try writer.print("  [saved to group '{s}']\n", .{gname});
            } else {
                self.cache_store.recordCache(env_name, ce) catch {};
            }
            ce.deinit(self.allocator);
            self.save();
        }
    }

    fn cmdEnv(self: *App, args_str: []const u8, writer: anytype) !void {
        var iter = std.mem.tokenizeScalar(u8, args_str, ' ');
        const sub = iter.next() orelse {
            try writer.print("Usage: env <create|use|set|list> ...\n", .{});
            return;
        };

        if (std.mem.eql(u8, sub, "create")) {
            const name = iter.next() orelse {
                try writer.print("Usage: env create <name>\n", .{});
                return;
            };
            try self.env_store.create(name);
            try writer.print("Created environment: {s}\n", .{name});
            self.save();
        } else if (std.mem.eql(u8, sub, "use")) {
            const name = iter.next() orelse {
                try writer.print("Usage: env use <name>\n", .{});
                return;
            };
            try self.env_store.use(name);
            try writer.print("Switched to: {s}\n", .{name});
            self.save();
        } else if (std.mem.eql(u8, sub, "set")) {
            const rest = iter.rest();
            var pos: usize = 0;
            var count: usize = 0;
            while (pos < rest.len) {
                args_util.skipWhitespace(rest, &pos);
                if (pos >= rest.len) break;
                const key = args_util.parseValue(rest, &pos) catch break;
                args_util.skipWhitespace(rest, &pos);
                if (pos >= rest.len) {
                    try writer.print("Missing value for key: {s}\n", .{key});
                    try writer.print("Usage: env set <k1> <v1> [<k2> <v2> ...]\n", .{});
                    return;
                }
                const value = args_util.parseValue(rest, &pos) catch {
                    try writer.print("Missing value for key: {s}\n", .{key});
                    try writer.print("Usage: env set <k1> <v1> [<k2> <v2> ...]\n", .{});
                    return;
                };
                try self.env_store.setVar(key, value);
                try writer.print("Set {s} = {s}\n", .{ key, value });
                count += 1;
            }
            if (count == 0) {
                try writer.print("Usage: env set <k1> <v1> [<k2> <v2> ...]\n", .{});
                return;
            }
            self.save();
        } else if (std.mem.eql(u8, sub, "list")) {
            const names = self.env_store.listEnvs();
            for (names) |name| {
                const marker: []const u8 = if (self.env_store.active_name != null and std.mem.eql(u8, name, self.env_store.active_name.?)) " *" else "";
                try writer.print("  {s}{s}\n", .{ name, marker });
            }
            if (names.len == 0) try writer.print("  (none)\n", .{});
            self.allocator.free(names);
        } else {
            try writer.print("Unknown env subcommand: {s}\n", .{sub});
        }
    }

    fn cmdVars(self: *App, args_str: []const u8, writer: anytype) !void {
        const trimmed = std.mem.trim(u8, args_str, " \t");
        if (trimmed.len > 0) {
            const vars = self.env_store.getEnvVars(trimmed);
            if (vars) |v| {
                try writer.print("Environment: {s}\n", .{trimmed});
                var it = v.iterator();
                var count: usize = 0;
                while (it.next()) |entry| {
                    try writer.print("  {s} = {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                    count += 1;
                }
                if (count == 0) try writer.print("  (empty)\n", .{});
            } else {
                try writer.print("Environment not found: {s}\n", .{trimmed});
            }
        } else {
            const name = self.env_store.active_name orelse {
                try writer.print("No active environment. Use 'env create <name>' first.\n", .{});
                return;
            };
            const vars = self.env_store.getActiveVars();
            if (vars) |v| {
                try writer.print("Environment: {s} *\n", .{name});
                var it = v.iterator();
                var count: usize = 0;
                while (it.next()) |entry| {
                    try writer.print("  {s} = {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
                    count += 1;
                }
                if (count == 0) try writer.print("  (empty)\n", .{});
            }
        }
    }

    fn cmdExport(self: *App, args_str: []const u8, writer: anytype) !void {
        if (self.history.items.len == 0) {
            try writer.print("No requests recorded. Make some requests first.\n", .{});
            return;
        }
        const path = if (args_str.len > 0) args_str else "zurl_export.har";
        try har.exportHar(self.allocator, self.history.items, path);
        try writer.print("Exported {d} entries to {s}\n", .{ self.history.items.len, path });
    }

    fn cmdHistory(self: *App, writer: anytype) !void {
        if (self.history.items.len == 0) {
            try writer.print("No requests recorded.\n", .{});
            return;
        }
        for (self.history.items, 0..) |entry, i| {
            try writer.print("  [{d}] {s} {s}  -> {d} ({d}ms)\n", .{
                i,
                entry.method,
                entry.url,
                entry.response.status,
                entry.response.duration_ms,
            });
        }
    }

    fn cmdCurl(self: *App, args_str: []const u8, writer: anytype) !void {
        if (args_str.len == 0) {
            try writer.print("Usage: curl [options] <url>\n", .{});
            return;
        }

        const resolved = try interpolate.resolve(self.allocator, args_str, &self.env_store, null, &self.capture_vars);
        defer self.allocator.free(resolved);

        const cmd = try std.fmt.allocPrintSentinel(self.allocator, "curl {s}", .{resolved}, 0);
        defer self.allocator.free(cmd);

        const fp = c_stdio.popen(cmd.ptr, "r") orelse {
            try writer.print("Failed to execute curl. Is curl installed?\n", .{});
            return;
        };
        defer _ = c_stdio.pclose(fp);

        var buf: [4096]u8 = undefined;
        while (true) {
            if (self.cancelled.*) {
                try writer.print("\nCurl interrupted.\n", .{});
                break;
            }
            const n = c_stdio.fread(&buf, 1, buf.len, fp);
            if (n > 0) {
                try writer.print("{s}", .{buf[0..n]});
            }
            if (c_stdio.feof(fp) != 0) break;
            if (n == 0) break;
        }
        try writer.print("\n", .{});
    }

    fn cmdCache(self: *App, args_str: []const u8, writer: anytype) !void {
        const trimmed = std.mem.trim(u8, args_str, " \t");
        const env_name = if (trimmed.len > 0)
            trimmed
        else
            (self.env_store.active_name orelse "default");

        const cache = self.cache_store.getEnvCache(env_name);

        if (cache) |entries| {
            try writer.print("Cache ({s}) - {d}/{d} entries:\n", .{ env_name, entries.len, self.cache_store.cache_limit });
            for (entries, 0..) |ce, ci| {
                try writer.print("  [{d}] {s} {s}", .{ ci, ce.method, ce.url_template });
                if (ce.body != null) try writer.print("  [body]", .{});
                try writer.print("\n", .{});
            }
        } else {
            try writer.print("No cached requests for {s}.\n", .{env_name});
        }
    }

    fn cmdReplay(self: *App, args_str: []const u8, writer: anytype) !void {
        if (args_str.len == 0) {
            try writer.print("Usage: replay <index> [-s source_env]  or  replay -g <group> [index|all] [-s source_env]\n", .{});
            return;
        }

        var source_env: ?[]const u8 = null;
        var group_flag: ?[]const u8 = null;
        var target_idx: ?[]const u8 = null;

        var pos: usize = 0;
        const input = args_str;
        while (pos < input.len) {
            args_util.skipWhitespace(input, &pos);
            if (pos >= input.len) break;

            if (args_util.matchFlag(input, pos, 's')) {
                pos += 2;
                args_util.skipWhitespace(input, &pos);
                source_env = args_util.parseValue(input, &pos) catch null;
            } else if (args_util.matchFlag(input, pos, 'g')) {
                pos += 2;
                args_util.skipWhitespace(input, &pos);
                group_flag = args_util.parseValue(input, &pos) catch null;
            } else {
                target_idx = args_util.parseValue(input, &pos) catch null;
            }
        }

        const src_name = source_env orelse (self.env_store.active_name orelse "default");
        var exec = Executor.init(self.allocator, &self.http_client, &self.history, &self.capture_vars);

        if (group_flag) |gname| {
            const groups = self.cache_store.getEnvGroups(src_name) orelse {
                try writer.print("No groups in {s}.\n", .{src_name});
                return;
            };
            const glist = groups.getPtr(gname) orelse {
                try writer.print("Group not found: {s}\n", .{gname});
                return;
            };
            if (glist.items.len == 0) {
                try writer.print("Group '{s}' is empty.\n", .{gname});
                return;
            }

            const idx_str = target_idx orelse "all";
            if (std.mem.eql(u8, idx_str, "all")) {
                for (glist.items, 0..) |ce, ci| {
                    try writer.print("\n--- [{d}] {s} {s} ---\n", .{ ci, ce.method, ce.url_template });
                    try self.replayEntry(ce, &exec, writer);
                }
            } else {
                const idx = std.fmt.parseInt(usize, idx_str, 10) catch {
                    try writer.print("Invalid index: {s}\n", .{idx_str});
                    return;
                };
                if (idx >= glist.items.len) {
                    try writer.print("Index out of range (0..{d})\n", .{glist.items.len - 1});
                    return;
                }
                try self.replayEntry(glist.items[idx], &exec, writer);
            }
        } else {
            const cache = self.cache_store.getEnvCache(src_name) orelse {
                try writer.print("No cached requests in {s}.\n", .{src_name});
                return;
            };
            const idx_str = target_idx orelse {
                try writer.print("Usage: replay <index> [-s source_env]\n", .{});
                return;
            };
            const idx = std.fmt.parseInt(usize, idx_str, 10) catch {
                try writer.print("Invalid index: {s}\n", .{idx_str});
                return;
            };
            if (idx >= cache.len) {
                try writer.print("Index out of range (0..{d})\n", .{cache.len - 1});
                return;
            }
            try self.replayEntry(cache[idx], &exec, writer);
        }
    }

    fn replayEntry(self: *App, ce: cache_mod.CacheEntry, exec: *Executor, writer: anytype) !void {
        var hdr_buf: [32]Executor.Request.Header = undefined;
        const req = Executor.fromCacheEntry(ce, &hdr_buf) catch {
            try writer.print("Invalid method in cache: {s}\n", .{ce.method});
            return;
        };
        const result = try exec.execute(req, &self.env_store, writer, false);
        if (result.body) |b| self.allocator.free(b);
        if (result.headers_raw) |h| self.allocator.free(h);
    }

    fn cmdGroups(self: *App, args_str: []const u8, writer: anytype) !void {
        const trimmed = std.mem.trim(u8, args_str, " \t");
        var iter = std.mem.tokenizeScalar(u8, trimmed, ' ');
        const first_arg = iter.next();

        const env_name = self.env_store.active_name orelse "default";

        const groups = self.cache_store.getEnvGroups(env_name) orelse {
            try writer.print("No groups in {s}.\n", .{env_name});
            return;
        };

        if (first_arg) |gname| {
            if (groups.getPtr(gname)) |glist| {
                try writer.print("Group '{s}' ({d} entries):\n", .{ gname, glist.items.len });
                for (glist.items, 0..) |ce, ci| {
                    try writer.print("  [{d}] {s} {s}", .{ ci, ce.method, ce.url_template });
                    if (ce.body != null) try writer.print("  [body]", .{});
                    try writer.print("\n", .{});
                }
                return;
            }
        }

        var grp_it = groups.iterator();
        var count: usize = 0;
        while (grp_it.next()) |entry| {
            try writer.print("  {s} ({d} entries)\n", .{ entry.key_ptr.*, entry.value_ptr.items.len });
            count += 1;
        }
        if (count == 0) {
            try writer.print("No groups in {s}.\n", .{env_name});
        }
    }

    fn cmdCapture(self: *App, args_str: []const u8, writer: anytype) !void {
        const body = self.last_response_body orelse {
            try writer.print("No response body available. Make a request first.\n", .{});
            return;
        };

        var iter = std.mem.tokenizeScalar(u8, args_str, ' ');
        const name = iter.next() orelse {
            try writer.print("Usage: capture <var_name> <$.json.path>\n", .{});
            try writer.print("Captured variables are referenced with $var in templates.\n", .{});
            return;
        };
        const path = iter.next() orelse {
            try writer.print("Usage: capture <var_name> <$.json.path>\n", .{});
            return;
        };

        const value = extractJsonPath(self.allocator, body, path) catch |err| {
            try writer.print("Capture failed: {s} ({any})\n", .{ path, err });
            return;
        };

        // Store in capture namespace
        if (self.capture_vars.fetchRemove(name)) |removed| {
            self.allocator.free(removed.key);
            self.allocator.free(removed.value);
        }
        const k = try self.allocator.dupe(u8, name);
        const v = try self.allocator.dupe(u8, value);
        try self.capture_vars.put(k, v);
        try writer.print("  captured ${s} = {s}\n", .{ name, value });
        self.allocator.free(value);
    }

    fn cmdCaptures(self: *App, writer: anytype) !void {
        if (self.capture_vars.count() == 0) {
            try writer.print("No captured variables. Use -c or capture command after a request.\n", .{});
            return;
        }
        try writer.print("Captured variables (use $var to reference):\n", .{});
        var it = self.capture_vars.iterator();
        while (it.next()) |entry| {
            try writer.print("  ${s} = {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    fn cmdImport(self: *App, args_str: []const u8, writer: anytype) !void {
        if (args_str.len == 0) {
            try writer.print("Usage: import <group_name> curl ...\n", .{});
            try writer.print("       import file <input.txt> [output.json]\n", .{});
            try writer.print("Example: import login curl -X POST 'https://api.example.com/login' -H 'Content-Type: application/json' -d '{{\"user\":\"admin\"}}'\n", .{});
            try writer.print("         import file curls.txt my_api.json\n", .{});
            return;
        }

        // Check for "file" subcommand
        var iter = std.mem.tokenizeScalar(u8, args_str, ' ');
        const first_token = iter.next() orelse return;

        if (std.mem.eql(u8, first_token, "file")) {
            const input_path = iter.next() orelse {
                try writer.print("Usage: import file <input.txt> [output.json]\n", .{});
                return;
            };
            const output_path = iter.next() orelse "collection.json";
            try curl_import.importFile(self.allocator, input_path, output_path, writer);
            return;
        }

        // Original behavior: import <group_name> curl ...
        const group_name = first_token;
        const curl_str = iter.rest();

        if (curl_str.len == 0) {
            try writer.print("Usage: import <group_name> curl ...\n", .{});
            return;
        }

        const parsed = curl_parser.parse(self.allocator, curl_str) catch |err| {
            try writer.print("Failed to parse curl command: {any}\n", .{err});
            return;
        };

        // Build cache entry from parsed curl
        var hdrs = self.allocator.alloc(cache_mod.CacheEntry.HeaderPair, parsed.headers.len) catch {
            try writer.print("Out of memory.\n", .{});
            return;
        };
        for (parsed.headers, 0..) |h, i| {
            hdrs[i] = .{
                .name = self.allocator.dupe(u8, h.name) catch return,
                .value = self.allocator.dupe(u8, h.value) catch return,
            };
        }

        const ce = cache_mod.CacheEntry{
            .method = self.allocator.dupe(u8, parsed.method) catch return,
            .url_template = self.allocator.dupe(u8, parsed.url) catch return,
            .headers = hdrs,
            .body = if (parsed.body) |b| (self.allocator.dupe(u8, b) catch null) else null,
        };

        const env_name = self.env_store.active_name orelse "default";
        self.cache_store.addToGroup(env_name, group_name, ce) catch {
            try writer.print("Failed to save to group.\n", .{});
            return;
        };
        ce.deinit(self.allocator);
        self.save();

        try writer.print("  imported to group '{s}': {s} {s}\n", .{ group_name, parsed.method, parsed.url });
        if (parsed.headers.len > 0) {
            try writer.print("  {d} header(s)", .{parsed.headers.len});
            if (parsed.body != null) try writer.print(", with body", .{});
            try writer.print("\n", .{});
        } else if (parsed.body != null) {
            try writer.print("  with body\n", .{});
        }
    }

    // ── Internal Helpers ────────────────────────────────────

    fn save(self: *App) void {
        store.saveToDisk(self.allocator, &self.env_store, &self.cache_store) catch {};
    }
};

fn buildCacheEntry(
    allocator: std.mem.Allocator,
    method: []const u8,
    url_template: []const u8,
    req_headers: []const Executor.Request.Header,
    body_template: ?[]const u8,
) !cache_mod.CacheEntry {
    const dup_method = try allocator.dupe(u8, method);
    const dup_url = try allocator.dupe(u8, url_template);
    const dup_body = if (body_template) |b| try allocator.dupe(u8, b) else null;
    const hdrs = try allocator.alloc(cache_mod.CacheEntry.HeaderPair, req_headers.len);
    for (req_headers, 0..) |h, i| {
        hdrs[i] = .{
            .name = try allocator.dupe(u8, h.name),
            .value = try allocator.dupe(u8, h.value_template),
        };
    }
    return .{
        .method = dup_method,
        .url_template = dup_url,
        .headers = hdrs,
        .body = dup_body,
    };
}

fn printHelp(writer: anytype) !void {
    try writer.print(
        \\
        \\  HTTP Requests:
        \\    GET    <url> [options]        Send GET request
        \\    POST   <url> [options]        Send POST request
        \\    PUT    <url> [options]        Send PUT request
        \\    DELETE <url> [options]        Send DELETE request
        \\    PATCH  <url> [options]        Send PATCH request
        \\    HEAD   <url> [options]        Send HEAD request
        \\    OPTIONS <url> [options]       Send OPTIONS request
        \\
        \\    Options:
        \\      -H "Name: Value"           Add request header
        \\      -d <body>                  Set request body
        \\      -c <var>=<$.path>          Capture response field to variable
        \\      -L                         Follow redirects
        \\      -e <env>                   Use specified environment
        \\      -p                         Pretty print response
        \\      -g <group>                 Save to named group
        \\
        \\  Curl:
        \\    curl [opts] <url>            Pass-through to system curl
        \\    import <group> curl ...      Parse curl command → save to group
        \\    import file <in> [out.json]  Import curl file → collection JSON
        \\
        \\  Collections:
        \\    load <file>                  Load a JSON collection file
        \\    list                         List requests in collection
        \\    run <name|index|all>         Execute request(s)
        \\
        \\  Environments:
        \\    env create <name>            Create a new environment
        \\    env use <name>               Switch active environment
        \\    env set <k> <v> ...          Set variable(s)
        \\    env list                     List all environments
        \\    set <k> <v> ...              Shortcut for 'env set'
        \\    vars [env_name]              Show variables
        \\
        \\  Cache & Replay:
        \\    cache [env_name]             Show cached requests
        \\    groups [group_name]          List groups or contents
        \\    replay <index> [-s env]      Replay cached request
        \\    replay -g <grp> [idx|all]    Replay from a group
        \\
        \\  Capture (extract response → $var, separate from {{env}}):
        \\    capture <var> <$.path>       Extract from last response
        \\    captures                     List all captured variables
        \\    Inline: -c var=$.path        Extract during request
        \\    Paths:  $.field  $.a.b  $.arr[0]  $.arr[0].name
        \\
        \\  Export & History:
        \\    export [file.har]            Export history as HAR 1.2
        \\    history                      Show request history
        \\
        \\  Other:
        \\    help                         Show this help
        \\    clear                        Clear screen
        \\    quit / exit                  Exit zurl
        \\
    , .{});
}
