const std = @import("std");
const build_options = @import("build_options");

pub const enabled: bool = build_options.allocation_profiling;

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const AllocationMeta = struct {
    size: usize,
    ret_addr: usize,
};

const Entry = struct {
    ret_addr: usize,
    alloc_calls: u64 = 0,
    free_calls: u64 = 0,
    remap_calls: u64 = 0,
    alloc_bytes: u64 = 0,
    freed_bytes: u64 = 0,
    current_live_bytes: u64 = 0,
    peak_live_bytes: u64 = 0,
};

const State = struct {
    child: Allocator,
};

var mutex: std.Thread.Mutex = .{};
var entries: std.ArrayListUnmanaged(Entry) = .empty;
var allocations: std.AutoHashMapUnmanaged(usize, AllocationMeta) = .empty;

pub fn wrap(child: Allocator) Allocator {
    if (!enabled) return child;
    const state = std.heap.page_allocator.create(State) catch @panic("OOM");
    state.* = .{ .child = child };
    return .{
        .ptr = state,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
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
            if (lhs.peak_live_bytes == rhs.peak_live_bytes) {
                return lhs.alloc_bytes > rhs.alloc_bytes;
            }
            return lhs.peak_live_bytes > rhs.peak_live_bytes;
        }
    };
    std.sort.block(Entry, sorted, {}, SortContext.lessThan);

    var total_current_live: u64 = 0;
    var total_peak_live: u64 = 0;
    for (sorted) |entry| {
        total_current_live += entry.current_live_bytes;
        total_peak_live += entry.peak_live_bytes;
    }

    try writer.print(
        "allocation profiling report:\n  sites={d} outstanding_allocations={d} current_live_bytes={d} sum_peak_live_bytes={d}\n",
        .{ sorted.len, allocations.count(), total_current_live, total_peak_live },
    );
    for (sorted) |entry| {
        try writer.print(
            "  0x{x}: alloc_calls={d} free_calls={d} remap_calls={d} alloc_bytes={d} freed_bytes={d} current_live={d} peak_live={d}\n",
            .{
                entry.ret_addr,
                entry.alloc_calls,
                entry.free_calls,
                entry.remap_calls,
                entry.alloc_bytes,
                entry.freed_bytes,
                entry.current_live_bytes,
                entry.peak_live_bytes,
            },
        );
    }
}

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    const state: *State = @ptrCast(@alignCast(ctx));
    const ptr = state.child.rawAlloc(len, alignment, ret_addr) orelse return null;
    recordAlloc(@intFromPtr(ptr), len, ret_addr);
    return ptr;
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    const state: *State = @ptrCast(@alignCast(ctx));
    const ok = state.child.rawResize(memory, alignment, new_len, ret_addr);
    if (ok) {
        recordResize(@intFromPtr(memory.ptr), memory.len, new_len, ret_addr);
    }
    return ok;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const state: *State = @ptrCast(@alignCast(ctx));
    const new_ptr = state.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
    recordRemap(@intFromPtr(memory.ptr), @intFromPtr(new_ptr), memory.len, new_len, ret_addr);
    return new_ptr;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    const state: *State = @ptrCast(@alignCast(ctx));
    recordFree(@intFromPtr(memory.ptr), memory.len, ret_addr);
    state.child.rawFree(memory, alignment, ret_addr);
}

fn recordAlloc(ptr: usize, len: usize, ret_addr: usize) void {
    mutex.lock();
    defer mutex.unlock();

    const entry = getOrCreateEntryLocked(ret_addr);
    entry.alloc_calls += 1;
    entry.alloc_bytes += len;
    entry.current_live_bytes += len;
    entry.peak_live_bytes = @max(entry.peak_live_bytes, entry.current_live_bytes);

    allocations.put(std.heap.page_allocator, ptr, .{
        .size = len,
        .ret_addr = ret_addr,
    }) catch @panic("OOM");
}

fn recordFree(ptr: usize, len: usize, ret_addr: usize) void {
    mutex.lock();
    defer mutex.unlock();

    const free_entry = getOrCreateEntryLocked(ret_addr);
    free_entry.free_calls += 1;

    if (allocations.fetchRemove(ptr)) |removed| {
        const meta = removed.value;
        const owner_entry = getOrCreateEntryLocked(meta.ret_addr);
        owner_entry.freed_bytes += meta.size;
        owner_entry.current_live_bytes -|= meta.size;
        return;
    }

    free_entry.freed_bytes += len;
    free_entry.current_live_bytes -|= len;
}

fn recordResize(ptr: usize, old_len: usize, new_len: usize, ret_addr: usize) void {
    mutex.lock();
    defer mutex.unlock();

    const entry = getOrCreateEntryLocked(ret_addr);
    entry.remap_calls += 1;

    if (allocations.getPtr(ptr)) |meta| {
        const owner_entry = getOrCreateEntryLocked(meta.ret_addr);
        if (new_len > meta.size) {
            const delta = new_len - meta.size;
            entry.alloc_bytes += delta;
            owner_entry.current_live_bytes += delta;
            owner_entry.peak_live_bytes = @max(owner_entry.peak_live_bytes, owner_entry.current_live_bytes);
        } else if (meta.size > new_len) {
            const delta = meta.size - new_len;
            owner_entry.freed_bytes += delta;
            owner_entry.current_live_bytes -|= delta;
        }
        meta.size = new_len;
        meta.ret_addr = ret_addr;
        _ = old_len;
        return;
    }

    allocations.put(std.heap.page_allocator, ptr, .{
        .size = new_len,
        .ret_addr = ret_addr,
    }) catch @panic("OOM");
    entry.alloc_bytes += new_len;
    entry.current_live_bytes += new_len;
    entry.peak_live_bytes = @max(entry.peak_live_bytes, entry.current_live_bytes);
}

fn recordRemap(old_ptr: usize, new_ptr: usize, old_len: usize, new_len: usize, ret_addr: usize) void {
    mutex.lock();
    defer mutex.unlock();

    const entry = getOrCreateEntryLocked(ret_addr);
    entry.remap_calls += 1;

    if (allocations.fetchRemove(old_ptr)) |removed| {
        const meta = removed.value;
        const owner_entry = getOrCreateEntryLocked(meta.ret_addr);
        owner_entry.freed_bytes += meta.size;
        owner_entry.current_live_bytes -|= meta.size;
        _ = old_len;
    }

    entry.alloc_bytes += new_len;
    entry.current_live_bytes += new_len;
    entry.peak_live_bytes = @max(entry.peak_live_bytes, entry.current_live_bytes);
    allocations.put(std.heap.page_allocator, new_ptr, .{
        .size = new_len,
        .ret_addr = ret_addr,
    }) catch @panic("OOM");

}

fn getOrCreateEntryLocked(ret_addr: usize) *Entry {
    for (entries.items) |*entry| {
        if (entry.ret_addr == ret_addr) return entry;
    }
    entries.append(std.heap.page_allocator, .{ .ret_addr = ret_addr }) catch @panic("OOM");
    return &entries.items[entries.items.len - 1];
}
