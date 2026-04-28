const std = @import("std");
const build_options = @import("build_options");

pub const enabled: bool = build_options.function_timing;

const Entry = struct {
    name: []const u8,
    calls: u64 = 0,
    total_ns: u64 = 0,
};

var mutex: std.Thread.Mutex = .{};
var entries: std.ArrayListUnmanaged(Entry) = .empty;

pub fn scope(comptime name: []const u8) ScopeType() {
    if (enabled) {
        return .{
            .name = name,
            .start_ns = std.time.nanoTimestamp(),
        };
    }
    return .{};
}

pub fn maybeWriteReport(writer: anytype) !void {
    if (!enabled) return;
    try writeReport(writer);
}

pub fn writeReport(writer: anytype) !void {
    if (!enabled) return;

    mutex.lock();
    defer mutex.unlock();

    const allocator = std.heap.page_allocator;
    const sorted = try allocator.alloc(Entry, entries.items.len);
    defer allocator.free(sorted);
    @memcpy(sorted, entries.items);

    const SortContext = struct {
        fn lessThan(_: void, lhs: Entry, rhs: Entry) bool {
            if (lhs.total_ns == rhs.total_ns) {
                return std.mem.order(u8, lhs.name, rhs.name) == .lt;
            }
            return lhs.total_ns > rhs.total_ns;
        }
    };
    std.sort.block(Entry, sorted, {}, SortContext.lessThan);

    try writer.writeAll("function timing report:\n");
    for (sorted) |entry| {
        const total_ms = @as(f64, @floatFromInt(entry.total_ns)) / std.time.ns_per_ms;
        const avg_us = if (entry.calls == 0)
            0.0
        else
            @as(f64, @floatFromInt(entry.total_ns)) /
                @as(f64, @floatFromInt(entry.calls)) /
                std.time.ns_per_us;
        try writer.print(
            "  {s}: calls={d} total_ms={d:.3} avg_us={d:.3}\n",
            .{ entry.name, entry.calls, total_ms, avg_us },
        );
    }
}

fn record(name: []const u8, elapsed_ns: u64) void {
    mutex.lock();
    defer mutex.unlock();

    for (entries.items) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            entry.calls += 1;
            entry.total_ns += elapsed_ns;
            return;
        }
    }

    const allocator = std.heap.page_allocator;
    const owned_name = allocator.dupe(u8, name) catch @panic("OOM");
    entries.append(allocator, .{
        .name = owned_name,
        .calls = 1,
        .total_ns = elapsed_ns,
    }) catch @panic("OOM");
}

fn ScopeType() type {
    return if (enabled) EnabledScope else DisabledScope;
}

const DisabledScope = struct {
    pub inline fn end(_: @This()) void {}
};

const EnabledScope = struct {
    name: []const u8,
    start_ns: i128,

    pub fn end(self: @This()) void {
        const elapsed = std.time.nanoTimestamp() - self.start_ns;
        record(self.name, @intCast(@max(elapsed, 0)));
    }
};
