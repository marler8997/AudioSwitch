pub const IconId = enum {
    none,
    speaker,
    headset,
    other,
};

const Rgb = struct { r: u8, g: u8, b: u8 };

pub fn systrayBitmap(pixels: []u8, size: u16, icon_id: IconId) void {
    std.debug.assert(@as(usize, size) * size * 4 == pixels.len);

    // Each glyph is one flat, anti-aliased color; the shape is what distinguishes
    // the kinds, the color is just a quick at-a-glance hint.
    const color: Rgb = switch (icon_id) {
        .none => .{ .r = 0x9a, .g = 0x9a, .b = 0x9a },
        .speaker => .{ .r = 0x4c, .g = 0xc8, .b = 0x60 },
        .headset => .{ .r = 0x50, .g = 0x9e, .b = 0xf0 },
        .other => .{ .r = 0xc8, .g = 0xc8, .b = 0xc8 },
    };

    // The glyph SDFs live in a [-1,1] square; map each pixel center into it.
    const half = @as(f32, @floatFromInt(size)) / 2.0;
    const pixel = 1.0 / half; // one pixel's width in that space, for ~1px AA

    var y: u16 = 0;
    while (y < size) : (y += 1) {
        var x: u16 = 0;
        while (x < size) : (x += 1) {
            const p: V2 = .{
                .x = (@as(f32, @floatFromInt(x)) + 0.5 - half) / half,
                .y = (@as(f32, @floatFromInt(y)) + 0.5 - half) / half,
            };
            const cov = std.math.clamp(0.5 - iconSdf(icon_id, p) / pixel, 0.0, 1.0);
            if (cov <= 0.0) continue;
            const i = (@as(usize, y) * size + x) * 4;
            pixels[i + 0] = color.b;
            pixels[i + 1] = color.g;
            pixels[i + 2] = color.r;
            pixels[i + 3] = @intFromFloat(@round(cov * 255.0));
        }
    }
}

const V2 = struct {
    x: f32,
    y: f32,
    fn sub(a: V2, b: V2) V2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }
    fn len(a: V2) f32 {
        return @sqrt(a.x * a.x + a.y * a.y);
    }
};

// Signed distance to the glyph for `icon_id` (negative inside). Coordinates are in a
// [-1,1] square centered on the icon_id, +x right / +y down.
fn iconSdf(icon_id: IconId, p: V2) f32 {
    return switch (icon_id) {
        .speaker => sdfSpeaker(p),
        .headset => sdfHeadset(p),
        .other => p.len() - 0.34, // filled dot
        .none => @abs(p.len() - 0.42) - 0.07, // outline ring
    };
}

// A loudspeaker: a back box, a cone widening to the right, and two sound-wave arcs.
fn sdfSpeaker(p: V2) f32 {
    const back = sdRoundBox(p.sub(.{ .x = -0.46, .y = 0.0 }), 0.16, 0.18, 0.03);
    const cone = @max(
        @max(-(p.x + 0.30), p.x - 0.06), // x in [-0.30, 0.06]
        @max(
            halfPlane(p, -0.30, -0.18, -0.5215, -0.8534), // top edge
            halfPlane(p, -0.30, 0.18, -0.5215, 0.8534), // bottom edge
        ),
    );
    const body = @min(back, cone);

    const c: V2 = .{ .x = -0.05, .y = 0.0 };
    const wave1 = @max(@max(@abs(p.sub(c).len() - 0.46) - 0.05, 0.20 - p.x), @abs(p.y) - 0.40);
    const wave2 = @max(@max(@abs(p.sub(c).len() - 0.66) - 0.05, 0.30 - p.x), @abs(p.y) - 0.52);
    return @min(body, @min(wave1, wave2));
}

// Headphones: a top headband arc with an ear cup at each end.
fn sdfHeadset(p: V2) f32 {
    const band = @max(@abs(p.len() - 0.46) - 0.05, p.y); // top half of a ring
    const cup_l = sdRoundBox(p.sub(.{ .x = -0.46, .y = 0.14 }), 0.12, 0.22, 0.06);
    const cup_r = sdRoundBox(p.sub(.{ .x = 0.46, .y = 0.14 }), 0.12, 0.22, 0.06);
    return @min(band, @min(cup_l, cup_r));
}

// Signed distance to the half-plane through (qx,qy) with outward unit normal (nx,ny).
fn halfPlane(p: V2, qx: f32, qy: f32, nx: f32, ny: f32) f32 {
    return (p.x - qx) * nx + (p.y - qy) * ny;
}

fn sdRoundBox(p: V2, hx: f32, hy: f32, r: f32) f32 {
    const qx = @abs(p.x) - hx + r;
    const qy = @abs(p.y) - hy + r;
    const outside = (V2{ .x = @max(qx, 0.0), .y = @max(qy, 0.0) }).len();
    return outside + @min(@max(qx, qy), 0.0) - r;
}

const std = @import("std");
