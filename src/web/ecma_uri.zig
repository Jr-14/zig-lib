const std = @import("std");
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
        '-', '_', '.', '!', '~', '*', '\'', '(', ')', => true,
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

    try Encode(&output.writer, string, isEncodeUriUnescaped);

    return try output.toOwnedSlice();
}

fn isEncodeUriUnescaped(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '-', '_', '.', '!', '~', '*', '\'', '(', ')',
        ';', '/', '?', ':', '@', '&', '=', '+', '$', ',', '#',
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

test "encodeURIAlloc" {
    const expected = try encodeURIAlloc(testing.allocator, "https://example.com/?choice=Ben & Jerry's");
    defer testing.allocator.free(expected);

    try testing.expectEqualSlices(u8, expected, "https://example.com/?choice=Ben%20&%20Jerry's");
}

/// https://tc39.es/ecma262/multipage/global-object.html#sec-parsehexoctet
/// The original implemenatation returns either a non-negative interger or a non-empty List of SyntaxError. But for our
/// usecase, it looks like the tha non-empty List of SyntaxError is not used for Decode(). Here we should just return
/// a `null` so that we can handle this case.
fn parseHexOctet(string: []const u8, position: usize) error{InvalidHexOctet}!u8 {
    std.debug.assert(position + 2 <= string.len);

    const high = std.fmt.charToDigit(string[position], 16) catch return error.InvalidHexOctet;
    const low = std.fmt.charToDigit(string[position + 1], 16) catch return error.InvalidHexOctet;
    return (high << 4) | low;
}

fn isDecodeUriPreserved(char: u8) bool {
    return switch (char) {
        ';', '/', '?', ':', '@', '&', '=', '+', '$', ',', '#' => true,
        else => false,
    };
}

pub fn decodeURIAlloc(allocator: std.mem.Allocator, string: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try Decode(&output.writer, string, isDecodeUriPreserved);

    return try output.toOwnedSlice();
}

pub const DecodeError = std.Io.Writer.Error || error{ URIError, InvalidUtf8 };

/// https://tc39.es/ecma262/multipage/global-object.html#sec-decode
fn Decode(writer: *std.Io.Writer, string: []const u8, preserveEscapeSet: fn (u8) bool) DecodeError!void {
    if (!std.unicode.utf8ValidateSlice(string)) return error.InvalidUtf8;

    var k: usize = 0;
    while (k < string.len) {
        const codeUnit = string[k];
        if (codeUnit != '%') {
            try writer.writeByte(codeUnit);
            k += 1;
            continue;
        }

        if ((k + 3) > string.len) return error.URIError;

        const escape = string[k .. k + 3];
        const firstOctet = parseHexOctet(string, k + 1) catch return error.URIError;
        const n: usize = std.unicode.utf8ByteSequenceLength(firstOctet) catch return error.URIError;

        k += 2;

        if (n == 1) {
            if (preserveEscapeSet(firstOctet)) {
                try writer.writeAll(escape);
            } else {
                try writer.writeByte(firstOctet);
            }
        } else {
            var octets: [4]u8 = undefined;
            octets[0] = firstOctet;

            var j: usize = 1;
            while (j < n) : (j += 1) {
                k += 1;
                if (k + 3 > string.len or string[k] != '%') {
                    return error.URIError;
                }

                const continuationByte = parseHexOctet(string, k + 1) catch return error.URIError;
                octets[j] = continuationByte;
                k += 2;
            }
            const encoded = octets[0..n];
            if (!std.unicode.utf8ValidateSlice(encoded)) return error.URIError;

            try writer.writeAll(encoded);
        }

        k += 1;
    }
}

// Adapted from Test262:
// test/built-ins/decodeURI/S15.1.3.1_A1.10_T1.js
// Copyright 2009 the Sputnik authors. All rights reserved.
// Licensed under the Test262 BSD license; see LICENSES/Test262.txt.
test "decodeURIAlloc: invalid hex digits after a two-byte UTF-8 prefix" {
    const intervals = [_][2]u21{
        .{ 0x00, 0x2F },
        .{ 0x3A, 0x40 },
        .{ 0x47, 0x60 },
        .{ 0x67, 0xFFFF },
    };

    for (intervals) |interval| {
        var code_point = interval[0];
        while (code_point <= interval[1]) : (code_point += 1) {
            // Test262 iterates UTF-16 code units, including lone surrogates.
            // They have no valid UTF-8 representation, so they are outside
            // the input domain of this byte-oriented API.
            if (std.unicode.isSurrogateCodepoint(code_point)) continue;

            var encoded_code_point: [4]u8 = undefined;
            const encoded_len: usize = try std.unicode.utf8Encode(code_point, &encoded_code_point);

            var input_buffer: [12]u8 = undefined;
            var input_writer: std.Io.Writer = .fixed(&input_buffer);
            try input_writer.writeAll("%C0%");
            try input_writer.writeAll(encoded_code_point[0..encoded_len]);
            try input_writer.writeAll(encoded_code_point[0..encoded_len]);

            if (decodeURIAlloc(testing.allocator, input_writer.buffered())) |decoded| {
                testing.allocator.free(decoded);
                return error.TestUnexpectedResult;
            } else |err| {
                try testing.expectEqual(error.URIError, err);
            }
        }
    }
}
