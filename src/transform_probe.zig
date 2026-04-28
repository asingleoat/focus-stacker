const std = @import("std");
const optimize = @import("optimize.zig");

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    if (args.len != 14 and args.len != 15 and args.len != 16 and args.len != 17) {
        std.debug.print("usage: transform_probe width height pano_hfov [image_hfov] yaw_deg pitch_deg roll_deg trx try trz x y tpy_deg tpp_deg [d e]\n", .{});
        std.process.exit(1);
    }

    const width = try std.fmt.parseInt(u32, args[1], 10);
    const height = try std.fmt.parseInt(u32, args[2], 10);
    const base_hfov = try std.fmt.parseFloat(f64, args[3]);
    const has_image_hfov = args.len == 15 or args.len == 17;
    const image_hfov = if (has_image_hfov) try std.fmt.parseFloat(f64, args[4]) else base_hfov;
    const offset: usize = if (has_image_hfov) 1 else 0;
    const yaw_deg = try std.fmt.parseFloat(f64, args[4 + offset]);
    const pitch_deg = try std.fmt.parseFloat(f64, args[5 + offset]);
    const roll_deg = try std.fmt.parseFloat(f64, args[6 + offset]);
    const trx = try std.fmt.parseFloat(f64, args[7 + offset]);
    const try_ = try std.fmt.parseFloat(f64, args[8 + offset]);
    const trz = try std.fmt.parseFloat(f64, args[9 + offset]);
    const x = try std.fmt.parseFloat(f64, args[10 + offset]);
    const y = try std.fmt.parseFloat(f64, args[11 + offset]);
    const tpy_deg = try std.fmt.parseFloat(f64, args[12 + offset]);
    const tpp_deg = try std.fmt.parseFloat(f64, args[13 + offset]);
    const d = if (args.len == 16 or args.len == 17) try std.fmt.parseFloat(f64, args[14 + offset]) else 0.0;
    const e = if (args.len == 16 or args.len == 17) try std.fmt.parseFloat(f64, args[15 + offset]) else 0.0;

    const pose = optimize.ImagePose{
        .yaw = yaw_deg * std.math.pi / 180.0,
        .pitch = pitch_deg * std.math.pi / 180.0,
        .roll = roll_deg * std.math.pi / 180.0,
        .hfov_delta = image_hfov - base_hfov,
        .trans_x = trx,
        .trans_y = try_,
        .trans_z = trz,
        .translation_plane_yaw = tpy_deg * std.math.pi / 180.0,
        .translation_plane_pitch = tpp_deg * std.math.pi / 180.0,
        .center_shift_x = d,
        .center_shift_y = e,
        .base_hfov_degrees = base_hfov,
    };

    const mapped = optimize.transformPoint(pose, x, y, width, height);
    std.debug.print("{d:.6} {d:.6}\n", .{ mapped.x, mapped.y });
}
