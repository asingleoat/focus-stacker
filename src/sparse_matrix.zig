const std = @import("std");

pub const CrsPattern = struct {
    row_count: usize,
    col_count: usize,
    row_ptr: []usize,
    col_idx: []usize,

    pub fn deinit(self: *CrsPattern, allocator: std.mem.Allocator) void {
        allocator.free(self.row_ptr);
        allocator.free(self.col_idx);
        self.* = undefined;
    }
};

pub const CcsPattern = struct {
    row_count: usize,
    col_count: usize,
    row_idx: []usize,
    col_ptr: []usize,

    pub fn deinit(self: *CcsPattern, allocator: std.mem.Allocator) void {
        allocator.free(self.row_idx);
        allocator.free(self.col_ptr);
        self.* = undefined;
    }

    pub fn colMaxNnz(self: *const CcsPattern) usize {
        var max: usize = 0;
        for (0..self.col_count) |j| {
            max = @max(max, self.col_ptr[j + 1] - self.col_ptr[j]);
        }
        return max;
    }

    pub fn colRowIndices(self: *const CcsPattern, column: usize, out_rows: []usize) usize {
        std.debug.assert(column < self.col_count);
        const start = self.col_ptr[column];
        const end = self.col_ptr[column + 1];
        const count = end - start;
        std.debug.assert(out_rows.len >= count);
        @memcpy(out_rows[0..count], self.row_idx[start..end]);
        return count;
    }
};

pub const CcsMatrix = struct {
    row_count: usize,
    col_count: usize,
    row_idx: []usize,
    col_ptr: []usize,
    values: []f64,

    pub fn deinit(self: *CcsMatrix, allocator: std.mem.Allocator) void {
        allocator.free(self.row_idx);
        allocator.free(self.col_ptr);
        allocator.free(self.values);
        self.* = undefined;
    }
};

pub const ColumnGroups = struct {
    group_offsets: []usize,
    columns: []usize,

    pub fn deinit(self: *ColumnGroups, allocator: std.mem.Allocator) void {
        allocator.free(self.group_offsets);
        allocator.free(self.columns);
        self.* = undefined;
    }

    pub fn groupCount(self: *const ColumnGroups) usize {
        return self.group_offsets.len - 1;
    }

    pub fn groupColumns(self: *const ColumnGroups, group_index: usize) []const usize {
        std.debug.assert(group_index + 1 < self.group_offsets.len);
        return self.columns[self.group_offsets[group_index]..self.group_offsets[group_index + 1]];
    }
};

pub fn crsToCcs(allocator: std.mem.Allocator, crs: *const CrsPattern) !CcsPattern {
    const row_idx = try allocator.alloc(usize, crs.col_idx.len);
    errdefer allocator.free(row_idx);
    const col_ptr = try allocator.alloc(usize, crs.col_count + 1);
    errdefer allocator.free(col_ptr);
    const col_counts = try allocator.alloc(usize, crs.col_count);
    defer allocator.free(col_counts);
    @memset(col_counts, 0);

    for (crs.col_idx) |col| {
        col_counts[col] += 1;
    }

    var running: usize = 0;
    for (0..crs.col_count) |col| {
        col_ptr[col] = running;
        running += col_counts[col];
        col_counts[col] = 0;
    }
    col_ptr[crs.col_count] = crs.col_idx.len;

    for (0..crs.row_count) |row| {
        const start = crs.row_ptr[row];
        const end = crs.row_ptr[row + 1];
        for (start..end) |entry_index| {
            const col = crs.col_idx[entry_index];
            const out_index = col_ptr[col] + col_counts[col];
            col_counts[col] += 1;
            row_idx[out_index] = row;
        }
    }

    return .{
        .row_count = crs.row_count,
        .col_count = crs.col_count,
        .row_idx = row_idx,
        .col_ptr = col_ptr,
    };
}

pub fn partitionIndependentColumns(allocator: std.mem.Allocator, pattern: *const CcsPattern) !ColumnGroups {
    const row_owner = try allocator.alloc(i32, pattern.row_count);
    defer allocator.free(row_owner);
    @memset(row_owner, -1);

    const max_col_nnz = pattern.colMaxNnz();
    const row_buffer = try allocator.alloc(usize, max_col_nnz);
    defer allocator.free(row_buffer);
    const varlist = try allocator.alloc(usize, pattern.col_count);
    defer allocator.free(varlist);
    const coldone = try allocator.alloc(bool, pattern.col_count);
    defer allocator.free(coldone);
    @memset(coldone, false);

    var group_offsets: std.ArrayList(usize) = .empty;
    defer group_offsets.deinit(allocator);
    var columns: std.ArrayList(usize) = .empty;
    defer columns.deinit(allocator);

    try group_offsets.append(allocator, 0);

    for (0..pattern.col_count) |j| {
        if (coldone[j]) continue;

        var group_len: usize = 0;
        var row_count = pattern.colRowIndices(j, row_buffer);
        for (row_buffer[0..row_count]) |row| row_owner[row] = @as(i32, @intCast(j));
        varlist[group_len] = j;
        group_len += 1;
        coldone[j] = true;

        for (j + 1..pattern.col_count) |jj| {
            if (coldone[jj]) continue;

            row_count = pattern.colRowIndices(jj, row_buffer);
            var clashes = false;
            for (row_buffer[0..row_count]) |row| {
                if (row_owner[row] != -1) {
                    clashes = true;
                    break;
                }
            }
            if (clashes) continue;
            if (row_count == 0) {
                coldone[jj] = true;
                continue;
            }

            for (row_buffer[0..row_count]) |row| row_owner[row] = @as(i32, @intCast(jj));
            varlist[group_len] = jj;
            group_len += 1;
            coldone[jj] = true;
        }

        for (varlist[0..group_len]) |col| {
            try columns.append(allocator, col);
        }
        try group_offsets.append(allocator, columns.items.len);

        for (varlist[0..group_len]) |col| {
            row_count = pattern.colRowIndices(col, row_buffer);
            for (row_buffer[0..row_count]) |row| row_owner[row] = -1;
        }
    }

    return .{
        .group_offsets = try group_offsets.toOwnedSlice(allocator),
        .columns = try columns.toOwnedSlice(allocator),
    };
}

pub fn clonePatternToMatrix(allocator: std.mem.Allocator, pattern: *const CcsPattern) !CcsMatrix {
    return .{
        .row_count = pattern.row_count,
        .col_count = pattern.col_count,
        .row_idx = try allocator.dupe(usize, pattern.row_idx),
        .col_ptr = try allocator.dupe(usize, pattern.col_ptr),
        .values = try allocator.alloc(f64, pattern.row_idx.len),
    };
}

test "crsToCcs converts a simple pattern" {
    const allocator = std.testing.allocator;
    var crs = CrsPattern{
        .row_count = 3,
        .col_count = 4,
        .row_ptr = try allocator.dupe(usize, &.{ 0, 2, 3, 5 }),
        .col_idx = try allocator.dupe(usize, &.{ 0, 2, 1, 0, 3 }),
    };
    defer crs.deinit(allocator);

    var ccs = try crsToCcs(allocator, &crs);
    defer ccs.deinit(allocator);

    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 3, 4, 5 }, ccs.col_ptr);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 1, 0, 2 }, ccs.row_idx);
}

test "partitionIndependentColumns groups non-overlapping columns" {
    const allocator = std.testing.allocator;
    var ccs = CcsPattern{
        .row_count = 4,
        .col_count = 4,
        .col_ptr = try allocator.dupe(usize, &.{ 0, 2, 3, 4, 6 }),
        .row_idx = try allocator.dupe(usize, &.{ 0, 2, 1, 3, 0, 2 }),
    };
    defer ccs.deinit(allocator);

    var groups = try partitionIndependentColumns(allocator, &ccs);
    defer groups.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), groups.groupCount());
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, groups.groupColumns(0));
    try std.testing.expectEqualSlices(usize, &.{ 3 }, groups.groupColumns(1));
}
