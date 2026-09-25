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

// This is the UTF-8 equivalent of the Test262 tests for lone UTF-16
// surrogates, which cannot be represented by this byte-oriented API.
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

// Portions of the tests below are adapted from TC39 Test262.
//
// Copyright (C) Ecma International and other Test262 contributors.
// Test262 is licensed under the BSD license.
// See LICENSES/Test262.txt.
//
// https://github.com/tc39/test262/blob/main/test/built-ins/encodeURI/S15.1.3.3_A2.1_T1.js
//
// Percent-encode ASCII bytes outside uriReserved, uriUnescaped, and '#'.
test "encodeURIAlloc: percent-encode escaped ASCII bytes" {
    const unescaped = ";/?:@&=+$,#-_.!~*'()ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

    for (0x00..0x80) |value| {
        const byte: u8 = @intCast(value);
        if (std.mem.indexOfScalar(u8, unescaped, byte) != null) continue;

        const input = [_]u8{byte};
        const encoded = try encodeURIAlloc(testing.allocator, &input);
        defer testing.allocator.free(encoded);

        try testing.expectEqualSlices(u8, percentEscapeTable[byte][0..], encoded);
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/encodeURI/S15.1.3.3_A2.2_T1.js
//
// Percent-encode every valid two-byte UTF-8 sequence (U+0080..U+07FF).
test "encodeURIAlloc: percent-encode valid two-byte UTF-8 sequences" {
    var input: [2]u8 = undefined;
    var expected: [6]u8 = undefined;
    for (0xC2..0xE0) |i| {
        input[0] = @intCast(i);
        @memcpy(expected[0..3], percentEscapeTable[input[0]][0..]);

        for (0x80..0xC0) |j| {
            input[1] = @intCast(j);
            @memcpy(expected[3..6], percentEscapeTable[input[1]][0..]);

            const encoded = try encodeURIAlloc(testing.allocator, &input);
            defer testing.allocator.free(encoded);

            try testing.expectEqualSlices(u8, &expected, encoded);
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/encodeURI/S15.1.3.3_A2.3_T1.js
//
// Percent-encode valid three-byte UTF-8 sequences for U+0800..U+D7FF.
test "encodeURIAlloc: percent-encode three-byte UTF-8 sequences below the surrogate range" {
    var input: [4]u8 = undefined;
    var expected: [9]u8 = undefined;
    for (0x0800..0xD800) |value| {
        const codePoint: u21 = @intCast(value);
        const length = try std.unicode.utf8Encode(codePoint, &input);
        try testing.expectEqual(@as(u3, 3), length);

        for (input[0..length], 0..) |byte, index| {
            const start = index * 3;
            @memcpy(expected[start .. start + 3], percentEscapeTable[byte][0..]);
        }

        const encoded = try encodeURIAlloc(testing.allocator, input[0..length]);
        defer testing.allocator.free(encoded);

        try testing.expectEqualSlices(u8, &expected, encoded);
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/encodeURI/S15.1.3.3_A2.4_T1.js
//
// Test four-byte UTF-8 sequences across every supplementary-plane block,
// using the three within-block offsets selected by Test262.
test "encodeURIAlloc: percent-encode four-byte UTF-8 sequences by block" {
    const withinBlockOffsets = [_]u21{ 0x000, 0x1FF, 0x3FF };
    var input: [4]u8 = undefined;
    var expected: [12]u8 = undefined;

    for (0..0x400) |block| {
        for (withinBlockOffsets) |offset| {
            const codePoint: u21 = @intCast(0x10000 + block * 0x400 + offset);
            const length = try std.unicode.utf8Encode(codePoint, &input);
            try testing.expectEqual(@as(u3, 4), length);

            for (input[0..length], 0..) |byte, index| {
                const start = index * 3;
                @memcpy(expected[start .. start + 3], percentEscapeTable[byte][0..]);
            }

            const encoded = try encodeURIAlloc(testing.allocator, input[0..length]);
            defer testing.allocator.free(encoded);

            try testing.expectEqualSlices(u8, &expected, encoded);
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/encodeURI/S15.1.3.3_A2.4_T2.js
//
// Test four-byte UTF-8 sequences at every offset within three
// supplementary-plane blocks selected by Test262.
test "encodeURIAlloc: percent-encode four-byte UTF-8 sequences by offset" {
    const blockOffsets = [_]u21{ 0x000, 0x3FF, 0x1FF };
    var input: [4]u8 = undefined;
    var expected: [12]u8 = undefined;

    for (0..0x400) |offset| {
        for (blockOffsets) |block| {
            const codePoint: u21 = @intCast(0x10000 + block * 0x400 + offset);
            const length = try std.unicode.utf8Encode(codePoint, &input);
            try testing.expectEqual(@as(u3, 4), length);

            for (input[0..length], 0..) |byte, index| {
                const start = index * 3;
                @memcpy(expected[start .. start + 3], percentEscapeTable[byte][0..]);
            }

            const encoded = try encodeURIAlloc(testing.allocator, input[0..length]);
            defer testing.allocator.free(encoded);

            try testing.expectEqualSlices(u8, &expected, encoded);
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/encodeURI/S15.1.3.3_A2.5_T1.js
//
// Percent-encode valid three-byte UTF-8 sequences for U+E000..U+FFFF.
test "encodeURIAlloc: percent-encode three-byte UTF-8 sequences above the surrogate range" {
    var input: [4]u8 = undefined;
    var expected: [9]u8 = undefined;
    for (0xE000..0x10000) |value| {
        const codePoint: u21 = @intCast(value);
        const length = try std.unicode.utf8Encode(codePoint, &input);
        try testing.expectEqual(@as(u3, 3), length);

        for (input[0..length], 0..) |byte, index| {
            const start = index * 3;
            @memcpy(expected[start .. start + 3], percentEscapeTable[byte][0..]);
        }

        const encoded = try encodeURIAlloc(testing.allocator, input[0..length]);
        defer testing.allocator.free(encoded);

        try testing.expectEqualSlices(u8, &expected, encoded);
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/encodeURI/S15.1.3.3_A3.1_T1.js
//
// Leave every uriReserved character unescaped.
test "encodeURIAlloc: leave uriReserved characters unescaped" {
    const uriReserved = ";/?:@&=+$,";
    for (uriReserved) |character| {
        const input = [_]u8{character};
        const encoded = try encodeURIAlloc(testing.allocator, &input);
        defer testing.allocator.free(encoded);

        try testing.expectEqualSlices(u8, &input, encoded);
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/encodeURI/S15.1.3.3_A3.2_T1.js
//
// Leave ASCII alphabetic characters unescaped.
test "encodeURIAlloc: leave ASCII alphabetic characters unescaped" {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    for (alphabet) |character| {
        const input = [_]u8{character};
        const encoded = try encodeURIAlloc(testing.allocator, &input);
        defer testing.allocator.free(encoded);

        try testing.expectEqualSlices(u8, &input, encoded);
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/encodeURI/S15.1.3.3_A3.2_T2.js
//
// Leave ASCII decimal digits unescaped.
test "encodeURIAlloc: leave ASCII decimal digits unescaped" {
    const decimalDigits = "0123456789";
    for (decimalDigits) |character| {
        const input = [_]u8{character};
        const encoded = try encodeURIAlloc(testing.allocator, &input);
        defer testing.allocator.free(encoded);

        try testing.expectEqualSlices(u8, &input, encoded);
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/encodeURI/S15.1.3.3_A3.2_T3.js
//
// Leave uriMark characters unescaped.
test "encodeURIAlloc: leave uriMark characters unescaped" {
    const uriMark = "-_.!~*'()";
    for (uriMark) |character| {
        const input = [_]u8{character};
        const encoded = try encodeURIAlloc(testing.allocator, &input);
        defer testing.allocator.free(encoded);

        try testing.expectEqualSlices(u8, &input, encoded);
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/encodeURI/S15.1.3.3_A3.3_T1.js
//
// Leave '#' unescaped.
test "encodeURIAlloc: leave fragment delimiter unescaped" {
    const input = "#";
    const encoded = try encodeURIAlloc(testing.allocator, input);
    defer testing.allocator.free(encoded);

    try testing.expectEqualSlices(u8, input, encoded);
}

// https://github.com/tc39/test262/blob/main/test/built-ins/encodeURI/S15.1.3.3_A4_T1.js
//
// Encode URIs containing the English alphabet and unescaped URI characters.
test "encodeURIAlloc: encode the English alphabet" {
    // Check #1
    {
        const input = "http://unipro.ru/0123456789";
        const encoded = try encodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(encoded);

        try testing.expectEqualSlices(u8, input, encoded);
    }

    // Check #2
    {
        const input = "aAbBcCdDeEfFgGhHiIjJkKlLmMnNoOpPqQrRsStTuUvVwWxXyYzZ";
        const encoded = try encodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(encoded);

        try testing.expectEqualSlices(u8, input, encoded);
    }

    // Check #3
    {
        const input = "aA_bB-cC.dD!eE~fF*gG'hH(iI)jJ;kK/lL?mM:nN@oO&pP=qQ+rR$sS,tT9uU8vV7wW6xX5yY4zZ";
        const encoded = try encodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(encoded);

        try testing.expectEqualSlices(u8, input, encoded);
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/encodeURI/S15.1.3.3_A4_T2.js
//
// Encode URIs containing the Russian alphabet.
test "encodeURIAlloc: encode the Russian alphabet" {
    // Check #1
    {
        const input = "http://ru.wikipedia.org/wiki/Юникод";
        const expected = "http://ru.wikipedia.org/wiki/%D0%AE%D0%BD%D0%B8%D0%BA%D0%BE%D0%B4";
        const encoded = try encodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(encoded);

        try testing.expectEqualSlices(u8, expected, encoded);
    }

    // Check #2
    {
        const input = "http://ru.wikipedia.org/wiki/Юникод#Ссылки";
        const expected = "http://ru.wikipedia.org/wiki/%D0%AE%D0%BD%D0%B8%D0%BA%D0%BE%D0%B4#%D0%A1%D1%81%D1%8B%D0%BB%D0%BA%D0%B8";
        const encoded = try encodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(encoded);

        try testing.expectEqualSlices(u8, expected, encoded);
    }

    // Check #3
    {
        const input = "http://ru.wikipedia.org/wiki/Юникод#Версии Юникода";
        const expected = "http://ru.wikipedia.org/wiki/%D0%AE%D0%BD%D0%B8%D0%BA%D0%BE%D0%B4#%D0%92%D0%B5%D1%80%D1%81%D0%B8%D0%B8%20%D0%AE%D0%BD%D0%B8%D0%BA%D0%BE%D0%B4%D0%B0";
        const encoded = try encodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(encoded);

        try testing.expectEqualSlices(u8, expected, encoded);
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/encodeURI/S15.1.3.3_A4_T3.js
//
// Percent-encode ASCII line and spacing control bytes.
test "encodeURIAlloc: encode URLs containing control bytes" {
    // Check #1
    {
        const input = "http://unipro.ru/\nabout";
        const expected = "http://unipro.ru/%0Aabout";
        const encoded = try encodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(encoded);

        try testing.expectEqualSlices(u8, expected, encoded);
    }

    // Check #2
    {
        const input = "http://unipro.ru/\x0Babout";
        const expected = "http://unipro.ru/%0Babout";
        const encoded = try encodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(encoded);

        try testing.expectEqualSlices(u8, expected, encoded);
    }

    // Check #3
    {
        const input = "http://unipro.ru/\x0Cabout";
        const expected = "http://unipro.ru/%0Cabout";
        const encoded = try encodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(encoded);

        try testing.expectEqualSlices(u8, expected, encoded);
    }

    // Check #4
    {
        const input = "http://unipro.ru/\rabout";
        const expected = "http://unipro.ru/%0Dabout";
        const encoded = try encodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(encoded);

        try testing.expectEqualSlices(u8, expected, encoded);
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/encodeURI/S15.1.3.3_A4_T4.js
//
// Leave complete URIs containing only unescaped characters unchanged.
test "encodeURIAlloc: encode complete URLs" {
    // Check #1
    {
        const input = "";
        const encoded = try encodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(encoded);

        try testing.expectEqualSlices(u8, input, encoded);
    }

    // Check #2
    {
        const input = "http://unipro.ru";
        const encoded = try encodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(encoded);

        try testing.expectEqualSlices(u8, input, encoded);
    }

    // Check #3
    {
        const input = "http://www.google.ru/support/jobs/bin/static.py?page=why-ru.html&sid=liveandwork";
        const encoded = try encodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(encoded);

        try testing.expectEqualSlices(u8, input, encoded);
    }

    // Check #4
    {
        const input = "http://en.wikipedia.org/wiki/UTF-8#Description";
        const encoded = try encodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(encoded);

        try testing.expectEqualSlices(u8, input, encoded);
    }
}
