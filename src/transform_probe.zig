const std = @import("std");
const optimize = @import("optimize.zig");

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    if (args.len != 14) {
        std.debug.print("usage: transform_probe width height hfov yaw_deg pitch_deg roll_deg trx try trz x y tpy_deg tpp_deg\n", .{});
        std.process.exit(1);
    }

    const width = try std.fmt.parseInt(u32, args[1], 10);
    const height = try std.fmt.parseInt(u32, args[2], 10);
    const base_hfov = try std.fmt.parseFloat(f64, args[3]);
    const yaw_deg = try std.fmt.parseFloat(f64, args[4]);
    const pitch_deg = try std.fmt.parseFloat(f64, args[5]);
    const roll_deg = try std.fmt.parseFloat(f64, args[6]);
    const trx = try std.fmt.parseFloat(f64, args[7]);
    const try_ = try std.fmt.parseFloat(f64, args[8]);
    const trz = try std.fmt.parseFloat(f64, args[9]);
    const x = try std.fmt.parseFloat(f64, args[10]);
    const y = try std.fmt.parseFloat(f64, args[11]);
    const tpy_deg = try std.fmt.parseFloat(f64, args[12]);
    const tpp_deg = try std.fmt.parseFloat(f64, args[13]);

    const pose = optimize.ImagePose{
        .yaw = yaw_deg * std.math.pi / 180.0,
        .pitch = pitch_deg * std.math.pi / 180.0,
        .roll = roll_deg * std.math.pi / 180.0,
        .trans_x = trx,
        .trans_y = try_,
        .trans_z = trz,
        .translation_plane_yaw = tpy_deg * std.math.pi / 180.0,
        .translation_plane_pitch = tpp_deg * std.math.pi / 180.0,
        .base_hfov_degrees = base_hfov,
    };

    const mapped = optimize.transformPoint(pose, x, y, width, height);
    std.debug.print("{d:.6} {d:.6}\n", .{ mapped.x, mapped.y });
}
