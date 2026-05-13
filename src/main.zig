const std = @import("std");
const posix = std.posix;
const Linenoise = @import("linenoise").Linenoise;
const App = @import("App.zig").App;

/// Global flag set by SIGINT handler.
pub var interrupted: bool = false;

fn sigintHandler(_: c_int) callconv(.c) void {
    interrupted = true;
}

fn installSigintHandler() void {
    const act = posix.Sigaction{
        .handler = .{ .handler = sigintHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &act, null);
}

/// All commands available for tab completion.
const commands = [_][]const u8{
    "GET",    "POST",    "PUT",    "DELETE",  "PATCH",
    "HEAD",   "OPTIONS", "help",   "clear",   "quit",
    "exit",   "load",    "list",   "run",     "env",
    "set",    "vars",    "export", "history", "curl",
    "cache",  "replay",  "groups", "capture", "captures",
    "import",
};

/// Env sub-commands for "env " prefix completion.
const env_subcommands = [_][]const u8{ "create", "use", "set", "list" };

fn completion(allocator: std.mem.Allocator, buf: []const u8) std.mem.Allocator.Error![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;

    // Complete "env <sub>" when user typed "env "
    if (std.mem.startsWith(u8, buf, "env ")) {
        const rest = buf["env ".len..];
        for (env_subcommands) |sub| {
            if (std.mem.startsWith(u8, sub, rest)) {
                const entry = try std.fmt.allocPrint(allocator, "env {s}", .{sub});
                try result.append(allocator, entry);
            }
        }
        return result.toOwnedSlice(allocator);
    }

    // Complete top-level commands
    for (&commands) |cmd| {
        if (std.mem.startsWith(u8, cmd, buf)) {
            try result.append(allocator, try allocator.dupe(u8, cmd));
        }
    }
    return result.toOwnedSlice(allocator);
}

pub fn main() !void {
    installSigintHandler();

    // Debug 模式使用 GPA 检测内存泄漏；Release 模式使用 c_allocator (malloc/free) 追求性能
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer if (@import("builtin").mode == .Debug) {
        _ = gpa.deinit();
    };
    const allocator = if (@import("builtin").mode == .Debug)
        gpa.allocator()
    else
        std.heap.c_allocator;

    var app = try App.init(allocator, &interrupted);
    defer app.deinit();

    var stdout_file = std.fs.File.stdout();
    var writer = stdout_file.writer(&.{});

    try writer.interface.print("zurl v0.1.0 - Interactive API Testing Tool\n", .{});
    try writer.interface.print("Type 'help' for available commands. Tab to complete.\n\n", .{});

    // Initialize linenoize for interactive editing
    var ln = Linenoise.init(allocator);
    defer ln.deinit();

    ln.completions_callback = completion;

    // Load history from ~/.zurl_history
    ln.history.load(getHistoryPath()) catch {};
    defer ln.history.save(getHistoryPath()) catch {};

    // REPL loop
    while (true) {
        // Build dynamic prompt
        const prompt_env = app.env_store.active_name orelse "default";
        var prompt_buf: [256]u8 = undefined;
        const prompt = std.fmt.bufPrint(&prompt_buf, "zurl({s})> ", .{prompt_env}) catch "zurl> ";

        const input = (try ln.linenoise(prompt)) orelse break; // null = EOF (Ctrl+D)
        defer allocator.free(input);

        if (interrupted) {
            interrupted = false;
            continue;
        }

        const trimmed = std.mem.trim(u8, input, " \t\r");
        if (trimmed.len == 0) continue;

        // Add to history
        ln.history.add(trimmed) catch {};

        app.dispatch(trimmed, &writer.interface) catch |err| {
            if (err == error.CurlAbortedByCallback) {
                try writer.interface.print("\nRequest cancelled.\n", .{});
            } else {
                var stderr_file = std.fs.File.stderr();
                var err_writer = stderr_file.writer(&.{});
                err_writer.interface.print("Error: {}\n", .{err}) catch {};
            }
        };
        interrupted = false;
    }

    try writer.interface.print("\nBye!\n", .{});
}

fn getHistoryPath() []const u8 {
    return ".zurl_history";
}
