const std = @import("std");
const Uri = std.Uri;

fn isEncodeUriComponentUnescaped(byte: u8) bool {
}

fn shouldPreserverEscape(byte: u8, preservationBytes: []const u8) bool {
    return std.mem.findScalar(u8, byte, preservationBytes) != null;
}

/// It escapes all characters except the following
/// A-Z a-z 0-9 - _ . ! ~ * ' ( )
// pub fn encodeURIComponentAlloc(allocator: std.mem.Allocator, uriComponent: []u8) void {}

/// This is used to encode a URL as a whole, assuming it is already well-formed
///
/// It escapes all characters except the following
///   A-Z a-z 0-9 - _ . ! ~ * ' ( )
///   ; / ? : @ & = + $ , #
///
/// Example:
/// encodeURIAlloc("https://example.com/?choice=Ben & Jerry's");
/// $ "https://example.com/?choice=Ben%20&%20Jerry's"
///
/// See: https://tc39.es/ecma262/2023/multipage/global-object.html#sec-encodeuri-uri
pub fn encodeURIAlloc(allocator: std.mem.Allocator, string: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try encodeUri(&output.writer, string);

    return try output.toOwnedSlice();
}

pub const EncodeUriError = std.Io.Writer.Error || error{InvalidUtf8};

fn isEncodeUriUnescaped(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '-', '_', '.', '!', '~', '*', '\'', '(', ')',
        ';', '/', '?', ':', '@', '&', '=', '+', '$', ',', '#',
        => true,
        else => false,
    };
}


fn encodeUri(writer: *std.Io.Writer, string: []const u8) EncodeUriError!void {
    if (!std.unicode.utf8ValidateSlice(string)) {
        return error.InvalidUtf8;
    }

    try std.Uri.Component.percentEncode(writer, string, isEncodeUriUnescaped);
}

const testing = std.testing;

test "encodeURIAlloc" {
    const expected = try encodeURIAlloc(testing.allocator, "https://example.com/?choice=Ben & Jerry's");
    defer testing.allocator.free(expected);

    try testing.expectEqualSlices(u8, expected, "https://example.com/?choice=Ben%20&%20Jerry's");
}
