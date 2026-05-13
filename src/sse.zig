const std = @import("std");

/// SSE event parsed from a text/event-stream response.
pub const SseEvent = struct {
    event_type: ?[]const u8 = null,
    data: []const u8,
    id: ?[]const u8 = null,
    retry: ?u32 = null,
};

/// Streaming SSE parser. Feed it chunks of data, get events out.
pub const SseParser = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    event_type: ?[]const u8 = null,
    data_lines: std.ArrayList([]const u8),
    id: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) SseParser {
        return .{
            .allocator = allocator,
            .buffer = .empty,
            .data_lines = .empty,
        };
    }

    pub fn deinit(self: *SseParser) void {
        self.buffer.deinit(self.allocator);
        for (self.data_lines.items) |line| {
            self.allocator.free(line);
        }
        self.data_lines.deinit(self.allocator);
        if (self.event_type) |et| self.allocator.free(et);
        if (self.id) |i| self.allocator.free(i);
    }

    /// Feed a chunk of data. Returns parsed events (caller owns the returned slice and event data).
    pub fn feed(self: *SseParser, chunk: []const u8) ![]SseEvent {
        try self.buffer.appendSlice(self.allocator, chunk);

        var events: std.ArrayList(SseEvent) = .empty;
        errdefer {
            for (events.items) |*evt| {
                self.allocator.free(evt.data);
                if (evt.event_type) |et| self.allocator.free(et);
                if (evt.id) |i| self.allocator.free(i);
            }
            events.deinit(self.allocator);
        }

        // Process complete lines
        while (true) {
            const buf = self.buffer.items;
            const newline_pos = std.mem.indexOf(u8, buf, "\n") orelse break;

            const line = std.mem.trimRight(u8, buf[0..newline_pos], "\r");

            if (line.len == 0) {
                // Empty line = event boundary
                if (self.data_lines.items.len > 0) {
                    const data = try std.mem.join(self.allocator, "\n", self.data_lines.items);
                    try events.append(self.allocator, .{
                        .event_type = self.event_type,
                        .data = data,
                        .id = self.id,
                    });
                    self.event_type = null;
                    self.id = null;
                    for (self.data_lines.items) |dl| self.allocator.free(dl);
                    self.data_lines.clearRetainingCapacity();
                }
            } else if (std.mem.startsWith(u8, line, "data:")) {
                const value = std.mem.trimLeft(u8, line[5..], " ");
                try self.data_lines.append(self.allocator, try self.allocator.dupe(u8, value));
            } else if (std.mem.startsWith(u8, line, "event:")) {
                const value = std.mem.trimLeft(u8, line[6..], " ");
                if (self.event_type) |old| self.allocator.free(old);
                self.event_type = try self.allocator.dupe(u8, value);
            } else if (std.mem.startsWith(u8, line, "id:")) {
                const value = std.mem.trimLeft(u8, line[3..], " ");
                if (self.id) |old| self.allocator.free(old);
                self.id = try self.allocator.dupe(u8, value);
            }

            // Remove processed line from buffer
            const remaining = buf[newline_pos + 1 ..];
            std.mem.copyForwards(u8, buf[0..remaining.len], remaining);
            self.buffer.shrinkRetainingCapacity(remaining.len);
        }

        return try events.toOwnedSlice(self.allocator);
    }
};
