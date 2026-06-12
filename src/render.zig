// The tint says which config slot picked the device, independent of its shape,
// so two devices with the same form factor stay distinguishable by color.
pub const Tint = enum { neutral, slot1, slot2 };

pub const Rgb = struct { r: u8, g: u8, b: u8 };

// Tray slot colors. The menu passes its own color (the menu text color) instead.
pub fn tintColor(tint: Tint) Rgb {
    return switch (tint) {
        .slot1 => .{ .r = 0x4c, .g = 0xc8, .b = 0x60 }, // green
        .slot2 => .{ .r = 0x50, .g = 0x9e, .b = 0xf0 }, // blue
        .neutral => .{ .r = 0xc8, .g = 0xc8, .b = 0xc8 }, // gray
    };
}

// Each glyph is one flat, anti-aliased `color`; the shape carries the meaning.
pub fn systrayBitmap(pixels: []u8, size: u16, form_factor: ?audio.FormFactor, color: Rgb) void {
    std.debug.assert(@as(usize, size) * size * 4 == pixels.len);

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
            const cov = std.math.clamp(0.5 - iconSdf(form_factor, p) / pixel, 0.0, 1.0);
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

// Signed distance to the glyph for `form_factor` (negative inside). Coordinates
// are in a [-1,1] square centered on the glyph, +x right / +y down.
fn iconSdf(form_factor: ?audio.FormFactor, p: V2) f32 {
    const ff = form_factor orelse return @abs(p.len() - 0.42) - 0.07; // ring: none / unknown
    return switch (ff) {
        .remote_network => sdfNetwork(p),
        .speakers => sdfSpeaker(p),
        .line_level => sdfLine(p),
        .headphones => sdfHeadphones(p),
        .microphone => sdfMic(p),
        .headset => sdfHeadset(p),
        .handset => sdfHandset(p),
        .unknown_digital_passthrough => sdfDigital(p),
        .spdif => sdfSpdif(p),
        .digital_audio_display => sdfDisplay(p),
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
fn sdfHeadphones(p: V2) f32 {
    const band = @max(@abs(p.len() - 0.46) - 0.05, p.y); // top half of a ring
    const cup_l = sdRoundBox(p.sub(.{ .x = -0.46, .y = 0.14 }), 0.12, 0.22, 0.06);
    const cup_r = sdRoundBox(p.sub(.{ .x = 0.46, .y = 0.14 }), 0.12, 0.22, 0.06);
    return @min(band, @min(cup_l, cup_r));
}

// Headset: headphones with a boom mic swinging down from the left cup.
fn sdfHeadset(p: V2) f32 {
    const boom = sdSegment(p, .{ .x = -0.44, .y = 0.28 }, .{ .x = -0.06, .y = 0.44 }, 0.045);
    const mic = sdRoundBox(p.sub(.{ .x = 0.02, .y = 0.44 }), 0.11, 0.06, 0.06);
    return @min(sdfHeadphones(p), @min(boom, mic));
}

// A microphone: a capsule on a stem with a base.
fn sdfMic(p: V2) f32 {
    const body = sdRoundBox(p.sub(.{ .x = 0.0, .y = -0.18 }), 0.16, 0.28, 0.16);
    const stem = sdRoundBox(p.sub(.{ .x = 0.0, .y = 0.30 }), 0.03, 0.16, 0.02);
    const base = sdRoundBox(p.sub(.{ .x = 0.0, .y = 0.46 }), 0.17, 0.035, 0.03);
    return @min(body, @min(stem, base));
}

// A telephone handset: a diagonal handle with an earpiece and a mouthpiece.
fn sdfHandset(p: V2) f32 {
    const handle = sdSegment(p, .{ .x = -0.30, .y = 0.30 }, .{ .x = 0.30, .y = -0.30 }, 0.07);
    const ear = p.sub(.{ .x = -0.38, .y = 0.38 }).len() - 0.14;
    const mouth = p.sub(.{ .x = 0.38, .y = -0.38 }).len() - 0.14;
    return @min(handle, @min(ear, mouth));
}

// A network device: three nodes linked into a triangle.
fn sdfNetwork(p: V2) f32 {
    const a: V2 = .{ .x = 0.0, .y = -0.36 };
    const b: V2 = .{ .x = -0.36, .y = 0.30 };
    const c: V2 = .{ .x = 0.36, .y = 0.30 };
    const nodes = @min(p.sub(a).len() - 0.13, @min(p.sub(b).len() - 0.13, p.sub(c).len() - 0.13));
    const links = @min(sdSegment(p, a, b, 0.035), @min(sdSegment(p, a, c, 0.035), sdSegment(p, b, c, 0.035)));
    return @min(nodes, links);
}

// An unknown digital passthrough: a coax-style jack — an outer ring with a center pin.
fn sdfDigital(p: V2) f32 {
    const ring = @abs(p.len() - 0.36) - 0.07;
    const pin = p.len() - 0.11;
    return @min(ring, pin);
}

// A phone/aux plug pointing right: a cable, a sleeve, and a narrower tip, with a
// ring groove notched out of the sleeve.
fn sdfLine(p: V2) f32 {
    const cable = sdRoundBox(p.sub(.{ .x = -0.60, .y = 0.0 }), 0.14, 0.05, 0.04);
    const sleeve = sdRoundBox(p.sub(.{ .x = -0.06, .y = 0.0 }), 0.34, 0.12, 0.06);
    const groove = sdRoundBox(p.sub(.{ .x = 0.06, .y = 0.0 }), 0.03, 0.14, 0.0);
    const tip = sdRoundBox(p.sub(.{ .x = 0.44, .y = 0.0 }), 0.10, 0.07, 0.05);
    return @min(@min(cable, tip), @max(sleeve, -groove));
}

// A monitor: a screen with a short neck and a base.
fn sdfDisplay(p: V2) f32 {
    const screen = sdRoundBox(p.sub(.{ .x = 0.0, .y = -0.12 }), 0.46, 0.30, 0.06);
    const neck = sdRoundBox(p.sub(.{ .x = 0.0, .y = 0.28 }), 0.06, 0.08, 0.02);
    const base = sdRoundBox(p.sub(.{ .x = 0.0, .y = 0.42 }), 0.24, 0.04, 0.03);
    return @min(screen, @min(neck, base));
}

// An optical/S/PDIF port: a square housing outline with a lit square at its center.
fn sdfSpdif(p: V2) f32 {
    const outer = sdRoundBox(p, 0.44, 0.44, 0.10);
    const cut = sdRoundBox(p, 0.28, 0.28, 0.06);
    const ring = @max(outer, -cut); // square frame
    const light = sdRoundBox(p, 0.14, 0.14, 0.05); // central emitter
    return @min(ring, light);
}

// Signed distance to the half-plane through (qx,qy) with outward unit normal (nx,ny).
fn halfPlane(p: V2, qx: f32, qy: f32, nx: f32, ny: f32) f32 {
    return (p.x - qx) * nx + (p.y - qy) * ny;
}

// Signed distance to the capsule of radius r around segment a-b.
fn sdSegment(p: V2, a: V2, b: V2, r: f32) f32 {
    const pa = p.sub(a);
    const ba = b.sub(a);
    const h = std.math.clamp((pa.x * ba.x + pa.y * ba.y) / (ba.x * ba.x + ba.y * ba.y), 0.0, 1.0);
    return (V2{ .x = pa.x - ba.x * h, .y = pa.y - ba.y * h }).len() - r;
}

fn sdRoundBox(p: V2, hx: f32, hy: f32, r: f32) f32 {
    const qx = @abs(p.x) - hx + r;
    const qy = @abs(p.y) - hy + r;
    const outside = (V2{ .x = @max(qx, 0.0), .y = @max(qy, 0.0) }).len();
    return outside + @min(@max(qx, qy), 0.0) - r;
}

const std = @import("std");
const audio = @import("audio.zig");
