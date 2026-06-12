pub fn XY(comptime T: type) type {
    return struct {
        x: T,
        y: T,
    };
}
