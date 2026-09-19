/// Precompute and generate the %HH tables at comptime rather than calculating and using the writer at runtime.
pub const percentEscapeTable: [256][3]u8 = blk: {
    const hex = "0123456789ABCDEF";
    var table: [256][3]u8 = undefined;

    for (0..256) |i| {
        const byte: u8 = @intCast(i);
        table[i] = .{
            '%',
            hex[byte >> 4],
            hex[byte & 0x0F],
        };
    }

    break :blk table;
};

