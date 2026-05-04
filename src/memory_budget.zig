const std = @import("std");

pub const default_memory_fraction: f32 = 0.5;

pub fn availableMemoryBytes() ?u64 {
    var file = std.fs.openFileAbsolute("/proc/meminfo", .{}) catch return null;
    defer file.close();

    var buffer: [32 * 1024]u8 = undefined;
    const len = file.readAll(&buffer) catch return null;
    const contents = buffer[0..len];

    var lines = std.mem.tokenizeScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "MemAvailable:")) continue;
        var fields = std.mem.tokenizeAny(u8, line["MemAvailable:".len..], " \t");
        const value_text = fields.next() orelse return null;
        const unit = fields.next() orelse return null;
        if (!std.mem.eql(u8, unit, "kB")) return null;
        const kib = std.fmt.parseInt(u64, value_text, 10) catch return null;
        return kib * 1024;
    }
    return null;
}

pub fn allowedBytes(fraction: f32) ?u64 {
    if (!(fraction > 0)) return null;
    const available = availableMemoryBytes() orelse return null;
    const scaled = @as(f64, @floatFromInt(available)) * @as(f64, fraction);
    if (!std.math.isFinite(scaled) or scaled <= 0) return null;
    return @as(u64, @intFromFloat(@floor(scaled)));
}

pub fn capConcurrentUnits(
    requested: usize,
    shared_bytes: u64,
    per_unit_bytes: u64,
    fraction: f32,
) usize {
    if (requested <= 1) return requested;
    if (per_unit_bytes == 0) return requested;
    const budget = allowedBytes(fraction) orelse return requested;
    if (budget <= shared_bytes) return 1;
    const usable = budget - shared_bytes;
    const max_units = usable / per_unit_bytes;
    if (max_units == 0) return 1;
    return @max(@as(usize, 1), @min(requested, @as(usize, @intCast(max_units))));
}

pub fn cacheAllowanceBytes(fraction: f32, hard_cap_bytes: u64) u64 {
    const budget = allowedBytes(fraction) orelse return hard_cap_bytes;
    return @min(budget, hard_cap_bytes);
}

test "capConcurrentUnits returns requested when budget unknown" {
    try std.testing.expectEqual(@as(usize, 8), capConcurrentUnits(8, 0, 1024, 0));
}
