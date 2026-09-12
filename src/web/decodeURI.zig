const std = @import("std");

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

// Portions of the tests in this file are adapted from TC39 Test262.
//
// Copyright (C) Ecma International and other Test262 contributors.
// Test262 is licensed under the BSD license.
// See LICENSES/test262.txt.
//
// Upstream: https://github.com/tc39/test262

const testing = std.testing;

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.10_T1.js
//
// A `firstOctet` with the bit pattern `110xxxxx` makes `Decode` collect one
// more percent-encoded octet. Both digits in that `%HH` escape must be ASCII
// hexadecimal; otherwise `decodeURIAlloc` must return `error.URIError`.
test "decodeURIAlloc: invalid hexadecimal digits in a two-byte UTF-8 sequence" {
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

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.11_T1.js
//
// A `firstOctet` with the bit pattern `1110xxxx` makes `Decode` collect two
// more percent-encoded octets. Both digits in the second octet's `%HH` escape
// must be ASCII hexadecimal; otherwise `decodeURIAlloc` must return
// `error.URIError`.
test "decodeURIAlloc: invalid hexadecimal digits in the second octet of a three-byte UTF-8 sequence" {
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

            var input_buffer: [16]u8 = undefined;
            var input_writer: std.Io.Writer = .fixed(&input_buffer);
            try input_writer.writeAll("%E0%");
            try input_writer.writeAll(encoded_code_point[0..encoded_len]);
            try input_writer.writeAll(encoded_code_point[0..encoded_len]);
            try input_writer.writeAll("%A0");

            if (decodeURIAlloc(testing.allocator, input_writer.buffered())) |decoded| {
                testing.allocator.free(decoded);
                return error.TestUnexpectedResult;
            } else |err| {
                try testing.expectEqual(error.URIError, err);
            }
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.11_T2.js
//
// A `firstOctet` with the bit pattern `1110xxxx` makes `Decode` collect two
// more percent-encoded octets. Both digits in the third octet's `%HH` escape
// must be ASCII hexadecimal; otherwise `decodeURIAlloc` must return
// `error.URIError`.
test "decodeURIAlloc: invalid hexadecimal digits in the third octet of a three-byte UTF-8 sequence" {
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

            var input_buffer: [16]u8 = undefined;
            var input_writer: std.Io.Writer = .fixed(&input_buffer);
            try input_writer.writeAll("%E0%");
            try input_writer.writeAll("%A0");
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

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.12_T1.js
//
// A `firstOctet` with the bit pattern `11110xxx` makes `Decode` collect three
// more percent-encoded octets. Both digits in the second octet's `%HH` escape
// must be ASCII hexadecimal; otherwise `decodeURIAlloc` must return
// `error.URIError`.
test "decodeURIAlloc: invalid hexadecimal digits in the second octet of a four-byte UTF-8 sequence" {
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

            var input_buffer: [20]u8 = undefined;
            var input_writer: std.Io.Writer = .fixed(&input_buffer);
            try input_writer.writeAll("%F0%");
            try input_writer.writeAll(encoded_code_point[0..encoded_len]);
            try input_writer.writeAll(encoded_code_point[0..encoded_len]);
            try input_writer.writeAll("%A0");
            try input_writer.writeAll("%A0");

            if (decodeURIAlloc(testing.allocator, input_writer.buffered())) |decoded| {
                testing.allocator.free(decoded);
                return error.TestUnexpectedResult;
            } else |err| {
                try testing.expectEqual(error.URIError, err);
            }
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.12_T2.js
//
// A `firstOctet` with the bit pattern `11110xxx` makes `Decode` collect three
// more percent-encoded octets. Both digits in the third octet's `%HH` escape
// must be ASCII hexadecimal; otherwise `decodeURIAlloc` must return
// `error.URIError`.
test "decodeURIAlloc: invalid hexadecimal digits in the third octet of a four-byte UTF-8 sequence" {
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

            var input_buffer: [20]u8 = undefined;
            var input_writer: std.Io.Writer = .fixed(&input_buffer);
            try input_writer.writeAll("%F0%");
            try input_writer.writeAll("%A0");
            try input_writer.writeAll(encoded_code_point[0..encoded_len]);
            try input_writer.writeAll(encoded_code_point[0..encoded_len]);
            try input_writer.writeAll("%A0");

            if (decodeURIAlloc(testing.allocator, input_writer.buffered())) |decoded| {
                testing.allocator.free(decoded);
                return error.TestUnexpectedResult;
            } else |err| {
                try testing.expectEqual(error.URIError, err);
            }
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.12_T3.js
//
// A `firstOctet` with the bit pattern `11110xxx` makes `Decode` collect three
// more percent-encoded octets. Both digits in the fourth octet's `%HH` escape
// must be ASCII hexadecimal; otherwise `decodeURIAlloc` must return
// `error.URIError`.
test "decodeURIAlloc: invalid hexadecimal digits in the fourth octet of a four-byte UTF-8 sequence" {
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

            var input_buffer: [20]u8 = undefined;
            var input_writer: std.Io.Writer = .fixed(&input_buffer);
            try input_writer.writeAll("%F0%");
            try input_writer.writeAll("%A0");
            try input_writer.writeAll("%A0");
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

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.13_T1.js
//
// A `firstOctet` with the bit pattern `110xxxxx` indicates a two-byte UTF-8
// sequence. The following `continuationByte` must have the pattern `10xxxxxx`;
// otherwise the octets are not valid UTF-8 and `decodeURIAlloc` must return
// `error.URIError`.
test "decodeURIAlloc: invalid continuation byte in a two-byte UTF-8 sequence (secondOctet = 0x00..0x80)" {
    for (0xC0..0xE0) |i| {
        const firstOctect: u8 = @intCast(i);
        for (0x00..0x80) |j| {
            const secondOctect: u8 = @intCast(j);
            var buffer: [6]u8 = undefined;
            const input = try std.fmt.bufPrint(
                &buffer,
                "%{X:0>2}%{X:0>2}",
                .{ firstOctect, secondOctect },
            );

            if (decodeURIAlloc(testing.allocator, input)) |decoded| {
                testing.allocator.free(decoded);
                return error.TestUnexpectedResult;
            } else |err| {
                try testing.expectEqual(error.URIError, err);
            }
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.13_T2.js
//
// A `firstOctet` with the bit pattern `110xxxxx` indicates a two-byte UTF-8
// sequence. The following `continuationByte` must have the pattern `10xxxxxx`;
// otherwise the octets are not valid UTF-8 and `decodeURIAlloc` must return
// `error.URIError`.
test "decodeURIAlloc: invalid continuation byte in a two-byte UTF-8 sequence (secondOctect = 0xC0..0x100)" {
    for (0xC0..0xE0) |i| {
        const firstOctet: u8 = @intCast(i);
        for (0xC0..0x100) |j| {
            const secondOctect: u8 = @intCast(j);
            var buffer: [6]u8 = undefined;
            const input = try std.fmt.bufPrint(&buffer, "%{X:0>2}%{X:0>2}", .{ firstOctet, secondOctect });

            if (decodeURIAlloc(testing.allocator, input)) |decoded| {
                testing.allocator.free(decoded);
                return error.TestUnexpectedResult;
            } else |err| {
                try testing.expectEqual(error.URIError, err);
            }
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.1_T1.js
//
// A percent escape requires exactly two ASCII hexadecimal digits after `%`.
// If the input ends before both digits are available, `decodeURIAlloc` must
// return `error.URIError`.
test "decodeURIAlloc: incomplete percent escape" {
    // Check 1
    {
        var input_buffer: [4]u8 = undefined;
        var input_writer: std.Io.Writer = .fixed(&input_buffer);
        try input_writer.writeAll("%");

        if (decodeURIAlloc(testing.allocator, input_writer.buffered())) |decoded| {
            testing.allocator.free(decoded);
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.URIError, err);
        }
    }

    // Check 2
    {
        var input_buffer: [8]u8 = undefined;
        var input_writer: std.Io.Writer = .fixed(&input_buffer);
        try input_writer.writeAll("%A");

        if (decodeURIAlloc(testing.allocator, input_writer.buffered())) |decoded| {
            testing.allocator.free(decoded);
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.URIError, err);
        }
    }

    // Check 3
    {
        var input_buffer: [8]u8 = undefined;
        var input_writer: std.Io.Writer = .fixed(&input_buffer);
        try input_writer.writeAll("%1");

        if (decodeURIAlloc(testing.allocator, input_writer.buffered())) |decoded| {
            testing.allocator.free(decoded);
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.URIError, err);
        }
    }

    // Check 4
    {
        var input_buffer: [8]u8 = undefined;
        var input_writer: std.Io.Writer = .fixed(&input_buffer);
        try input_writer.writeAll("% ");

        if (decodeURIAlloc(testing.allocator, input_writer.buffered())) |decoded| {
            testing.allocator.free(decoded);
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.URIError, err);
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.2_T1.js
//
// Both digits after `%` must be ASCII hexadecimal for `parseHexOctet` to
// produce `firstOctet`. An invalid first digit must make `decodeURIAlloc`
// return `error.URIError`.
test "decodeURIAlloc: invalid first hexadecimal digit after %" {
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

            var input_buffer: [8]u8 = undefined;
            var input_writer: std.Io.Writer = .fixed(&input_buffer);
            try input_writer.writeAll("%");
            try input_writer.writeAll(encoded_code_point[0..encoded_len]);
            try input_writer.writeAll("1");

            if (decodeURIAlloc(testing.allocator, input_writer.buffered())) |decoded| {
                testing.allocator.free(decoded);
                return error.TestUnexpectedResult;
            } else |err| {
                try testing.expectEqual(error.URIError, err);
            }
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.2_T2.js
//
// Both digits after `%` must be ASCII hexadecimal for `parseHexOctet` to
// produce `firstOctet`. An invalid second digit must make `decodeURIAlloc`
// return `error.URIError`.
test "decodeURIAlloc: invalid second hexadecimal digit after %" {
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

            var input_buffer: [8]u8 = undefined;
            var input_writer: std.Io.Writer = .fixed(&input_buffer);
            try input_writer.writeAll("%");
            try input_writer.writeAll("1");
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
