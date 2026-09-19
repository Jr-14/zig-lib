const std = @import("std");
const percentEscapeTable = @import("utils.zig").percentEscapeTable;

const Uri = std.Uri;
const testing = std.testing;

/// It escapes all characters except the following
/// A-Z a-z 0-9 - _ . ! ~ * ' ( )
pub fn encodeURIComponentAlloc(allocator: std.mem.Allocator, uriComponent: []u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try Encode(&output.writer, uriComponent, isEncodeUriComponentUnescaped);

    return try output.toOwnedSlice();
}

fn isEncodeUriComponentUnescaped(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '-',
        '_',
        '.',
        '!',
        '~',
        '*',
        '\'',
        '(',
        ')',
        => true,
        else => false,
    };
}

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

    Encode(&output.writer, string, isEncodeUriUnescaped) catch |err| switch (err) {
        error.InvalidUtf8 => return error.URIError,
        else => return err,
    };

    return try output.toOwnedSlice();
}

fn isEncodeUriUnescaped(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '-',
        '_',
        '.',
        '!',
        '~',
        '*',
        '\'',
        '(',
        ')',
        ';',
        '/',
        '?',
        ':',
        '@',
        '&',
        '=',
        '+',
        '$',
        ',',
        '#',
        => true,
        else => false,
    };
}

pub const EncodeError = std.Io.Writer.Error || error{InvalidUtf8};

/// https://tc39.es/ecma262/multipage/global-object.html#sec-decode
fn Encode(writer: *std.Io.Writer, string: []const u8, isValidChar: fn (u8) bool) EncodeError!void {
    if (!std.unicode.utf8ValidateSlice(string)) {
        return error.InvalidUtf8;
    }

    try std.Uri.Component.percentEncode(writer, string, isValidChar);
}

test "encodeURIAlloc: MDN Web example" {
    const expected = try encodeURIAlloc(testing.allocator, "https://example.com/?choice=Ben & Jerry's");
    defer testing.allocator.free(expected);

    try testing.expectEqualSlices(u8, expected, "https://example.com/?choice=Ben%20&%20Jerry's");
}

// https://github.com/tc39/test262/blob/main/test/built-ins/encodeURI/S15.1.3.3_A1.1_T1.js
//
// Adaption of this test as these are valid utf-8 sequences
test "encodeURIAlloc: accept valid two-byte UTF-8 sequences" {
    var input: [2]u8 = undefined;
    var expected: [6]u8 = undefined;
    for (0xC2..0xE0) |i| {
        const firstOctet: u8 = @intCast(i);
        input[0] = firstOctet;
        @memcpy(expected[0..3], percentEscapeTable[firstOctet][0..]);
        for (0x80..0xC0) |j| {
            const secondOctet: u8 = @intCast(j);
            input[1] = secondOctet;
            @memcpy(expected[3..6], percentEscapeTable[secondOctet][0..]);

            const encoded = try encodeURIAlloc(testing.allocator, input[0..]);
            defer testing.allocator.free(encoded);

            try testing.expectEqualSlices(u8, expected[0..], encoded);
        }
    }
}

// Adaptation of this tests for invalid utf-8 sequences
test "encodeURIAlloc: reject malformed UTF-8 bytes" {
    const invalidInputs = [_][]const u8{
        &[_]u8{0x80}, // lone continuation byte
        &[_]u8{0xC2}, // truncated two-byte sequence
        &[_]u8{ 0xC2, 0x20 }, // invalid continuation byte
        &[_]u8{ 0xC0, 0x80 }, // overlong encoding
        &[_]u8{ 0xE2, 0x82 }, // truncated three-byte sequence
        &[_]u8{ 0xE2, 0x20, 0xAC }, // invalid continuation byte
        &[_]u8{ 0xED, 0xA0, 0x80 }, // surrogate-shaped UTF-8 sequence
        &[_]u8{ 0xF0, 0x90, 0x80 }, // truncated four-byte sequence
        &[_]u8{ 0xF4, 0x90, 0x80, 0x80 }, // code point above U+10FFFF
        &[_]u8{ 0xF5, 0x80, 0x80, 0x80 }, // invalid four-byte lead byte
    };

    for (invalidInputs) |input| {
        if (encodeURIAlloc(testing.allocator, input)) |encoded| {
            testing.allocator.free(encoded);
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.URIError, err);
        }
    }
}
