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

// Precompute and generate the %HH tables at comptime rather than calculating and using the writer at runtime.
const percentEscapeTable: [256][3]u8 = blk: {
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
    var buffer: [6]u8 = undefined;
    for (0xC0..0xE0) |i| {
        const firstOctect: u8 = @intCast(i);
        @memcpy(buffer[0..3], percentEscapeTable[firstOctect][0..]);
        for (0x00..0x80) |j| {
            const secondOctect: u8 = @intCast(j);
            @memcpy(buffer[3..6], percentEscapeTable[secondOctect][0..]);
            if (decodeURIAlloc(testing.allocator, buffer[0..])) |decoded| {
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
test "decodeURIAlloc: invalid continuation byte in a two-byte UTF-8 sequence (secondOctet = 0xC0..0x100)" {
    var buffer: [6]u8 = undefined;
    for (0xC0..0xE0) |i| {
        const firstOctet: u8 = @intCast(i);
        @memcpy(buffer[0..3], percentEscapeTable[firstOctet][0..]);
        for (0xC0..0x100) |j| {
            const secondOctet: u8 = @intCast(j);
            @memcpy(buffer[3..6], percentEscapeTable[secondOctet][0..]);

            if (decodeURIAlloc(testing.allocator, buffer[0..])) |decoded| {
                testing.allocator.free(decoded);
                return error.TestUnexpectedResult;
            } else |err| {
                try testing.expectEqual(error.URIError, err);
            }
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.14_T1.js
//
// A `firstOctet` with the bit pattern `1110xxxx` indicates a three-byte UTF-8
// sequence. The following `continuationByte` must have the pattern `10xxxxxx`;
// otherwise the octets are not valid UTF-8 and `decodeURIAlloc` must return
// `error.URIError`.
test "decodeURIAlloc: invalid continuation byte in a three-byte UTF-8 sequence (secondOctet = 0x00..0x80, thirdOctet = A0)" {
    var buffer: [9]u8 = undefined;
    @memcpy(buffer[6..9], "%A0");
    for (0xE0..0xF0) |i| {
        const firstOctet: u8 = @intCast(i);
        @memcpy(buffer[0..3], percentEscapeTable[firstOctet][0..]);
        for (0x00..0x80) |j| {
            const secondOctet: u8 = @intCast(j);
            @memcpy(buffer[3..6], percentEscapeTable[secondOctet][0..]);

            if (decodeURIAlloc(testing.allocator, buffer[0..])) |decoded| {
                testing.allocator.free(decoded);
                return error.TestUnexpectedResult;
            } else |err| {
                try testing.expectEqual(error.URIError, err);
            }
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.14_T2.js
//
// A `firstOctet` with the bit pattern `1110xxxx` indicates a three-byte UTF-8
// sequence. The following `continuationByte` must have the pattern `10xxxxxx`;
// otherwise the octets are not valid UTF-8 and `decodeURIAlloc` must return
// `error.URIError`.
test "decodeURIAlloc: invalid continuation byte in a three-byte UTF-8 sequence (secondOctet = A0, thirdOctet = 0x00..0x80)" {
    var buffer: [9]u8 = undefined;
    @memcpy(buffer[3..6], "%A0");
    for (0xE0..0xF0) |i| {
        const firstOctet: u8 = @intCast(i);
        @memcpy(buffer[0..3], percentEscapeTable[firstOctet][0..]);
        for (0x00..0x80) |j| {
            const thirdOctet: u8 = @intCast(j);
            @memcpy(buffer[6..9], percentEscapeTable[thirdOctet][0..]);

            if (decodeURIAlloc(testing.allocator, buffer[0..])) |decoded| {
                testing.allocator.free(decoded);
                return error.TestUnexpectedResult;
            } else |err| {
                try testing.expectEqual(error.URIError, err);
            }
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.14_T3.js
//
// A `firstOctet` with the bit pattern `1110xxxx` indicates a three-byte UTF-8
// sequence. The following `continuationByte` must have the pattern `10xxxxxx`;
// otherwise the octets are not valid UTF-8 and `decodeURIAlloc` must return
// `error.URIError`.
test "decodeURIAlloc: invalid continuation byte in a three-byte UTF-8 sequence (secondOctet = 0xC0..0x100, thirdOctet = A0)" {
    var buffer: [9]u8 = undefined;
    @memcpy(buffer[6..9], "%A0");
    for (0xE0..0xF0) |i| {
        const firstOctet: u8 = @intCast(i);
        @memcpy(buffer[0..3], percentEscapeTable[firstOctet][0..]);
        for (0xC0..0x100) |j| {
            const secondOctet: u8 = @intCast(j);
            @memcpy(buffer[3..6], percentEscapeTable[secondOctet][0..]);

            if (decodeURIAlloc(testing.allocator, buffer[0..])) |decoded| {
                testing.allocator.free(decoded);
                return error.TestUnexpectedResult;
            } else |err| {
                try testing.expectEqual(error.URIError, err);
            }
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.14_T4.js
//
// A `firstOctet` with the bit pattern `1110xxxx` indicates a three-byte UTF-8
// sequence. The following `continuationByte` must have the pattern `10xxxxxx`;
// otherwise the octets are not valid UTF-8 and `decodeURIAlloc` must return
// `error.URIError`.
test "decodeURIAlloc: invalid continuation byte in a three-byte UTF-8 sequence (secondOctet = A0, thirdOctet = 0xC0..0x100)" {
    var buffer: [9]u8 = undefined;
    @memcpy(buffer[3..6], "%A0");
    for (0xE0..0xF0) |i| {
        const firstOctet: u8 = @intCast(i);
        @memcpy(buffer[0..3], percentEscapeTable[firstOctet][0..]);
        for (0xC0..0x100) |j| {
            const thirdOctet: u8 = @intCast(j);
            @memcpy(buffer[6..9], percentEscapeTable[thirdOctet][0..]);

            if (decodeURIAlloc(testing.allocator, buffer[0..])) |decoded| {
                testing.allocator.free(decoded);
                return error.TestUnexpectedResult;
            } else |err| {
                try testing.expectEqual(error.URIError, err);
            }
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.15_T1.js
//
// A `firstOctet` with the bit pattern `11110xxx` indicates a four-byte UTF-8
// sequence. The following continuationByte` must have the pattern `10xxxxxx`;
// otherwise the octets are not valid UTF-8 and `dedodeURIAlloc` must return
// `error.URIError`.
test "decodeURIAlloc: invalid continuation byte in a four-byte UTF-8 sequence (secondOctet = 0x00..0x80, thirdOctet = fourthOctet = A0)" {
    var buffer: [12]u8 = undefined;
    @memcpy(buffer[6..12], "%A0%A0");
    for (0xF0..0xF8) |i| {
        const firstOctet: u8 = @intCast(i);
        @memcpy(buffer[0..3], percentEscapeTable[firstOctet][0..]);
        for (0x00..0x80) |j| {
            const secondOctet: u8 = @intCast(j);
            @memcpy(buffer[3..6], percentEscapeTable[secondOctet][0..]);

            if (decodeURIAlloc(testing.allocator, buffer[0..])) |decoded| {
                testing.allocator.free(decoded);
                return error.TestUnexpectedResult;
            } else |err| {
                try testing.expectEqual(error.URIError, err);
            }
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.15_T2.js
//
// A `firstOctet` with the bit pattern `11110xxx` indicates a four-byte UTF-8
// sequence. The following continuationByte` must have the pattern `10xxxxxx`;
// otherwise the octets are not valid UTF-8 and `dedodeURIAlloc` must return
// `error.URIError`.
test "decodeURIAlloc: invalid continuation byte in a four-byte UTF-8 sequence (thirdOctet = 0x00..0x80, secondOctet = fourthOctet = A0)" {
    var buffer: [12]u8 = undefined;
    @memcpy(buffer[3..6], "%A0");
    @memcpy(buffer[9..12], "%A0");
    for (0xF0..0xF8) |i| {
        const firstOctet: u8 = @intCast(i);
        @memcpy(buffer[0..3], percentEscapeTable[firstOctet][0..]);
        for (0x00..0x80) |j| {
            const thirdOctet: u8 = @intCast(j);
            @memcpy(buffer[6..9], percentEscapeTable[thirdOctet][0..]);

            if (decodeURIAlloc(testing.allocator, buffer[0..])) |decoded| {
                testing.allocator.free(decoded);
                return error.TestUnexpectedResult;
            } else |err| {
                try testing.expectEqual(error.URIError, err);
            }
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.15_T3.js
//
// A `firstOctet` with the bit pattern `11110xxx` indicates a four-byte UTF-8
// sequence. The following continuationByte` must have the pattern `10xxxxxx`;
// otherwise the octets are not valid UTF-8 and `dedodeURIAlloc` must return
// `error.URIError`.
test "decodeURIAlloc: invalid continuation byte in a four-byte UTF-8 sequence (secondOctet = thirdOctet = A0, fourthOctet = 0x00..0x80)" {
    var buffer: [12]u8 = undefined;
    @memcpy(buffer[3..9], "%A0%A0");
    for (0xF0..0xF8) |i| {
        const firstOctet: u8 = @intCast(i);
        @memcpy(buffer[0..3], percentEscapeTable[firstOctet][0..]);
        for (0x00..0x80) |j| {
            const fourthOctet: u8 = @intCast(j);
            @memcpy(buffer[9..12], percentEscapeTable[fourthOctet][0..]);

            if (decodeURIAlloc(testing.allocator, buffer[0..])) |decoded| {
                testing.allocator.free(decoded);
                return error.TestUnexpectedResult;
            } else |err| {
                try testing.expectEqual(error.URIError, err);
            }
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.15_T4.js
//
// A `firstOctet` with the bit pattern `11110xxx` indicates a four-byte UTF-8
// sequence. The following continuationByte` must have the pattern `10xxxxxx`;
// otherwise the octets are not valid UTF-8 and `dedodeURIAlloc` must return
// `error.URIError`.
test "decodeURIAlloc: invalid continuation byte in a four-byte UTF-8 sequence (secondOctet = 0xC0..0x100, thirdOctet = fourthOctet = A0)" {
    var buffer: [12]u8 = undefined;
    @memcpy(buffer[6..12], "%A0%A0");
    for (0xF0..0xF8) |i| {
        const firstOctet: u8 = @intCast(i);
        @memcpy(buffer[0..3], percentEscapeTable[firstOctet][0..]);
        for (0xC0..0x100) |j| {
            const secondOctet: u8 = @intCast(j);
            @memcpy(buffer[3..6], percentEscapeTable[secondOctet][0..]);

            if (decodeURIAlloc(testing.allocator, buffer[0..])) |decoded| {
                testing.allocator.free(decoded);
                return error.TestUnexpectedResult;
            } else |err| {
                try testing.expectEqual(error.URIError, err);
            }
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.15_T5.js
//
// A `firstOctet` with the bit pattern `11110xxx` indicates a four-byte UTF-8
// sequence. The following continuationByte` must have the pattern `10xxxxxx`;
// otherwise the octets are not valid UTF-8 and `dedodeURIAlloc` must return
// `error.URIError`.
test "decodeURIAlloc: invalid continuation byte in a four-byte UTF-8 sequence (secondOctet = fourthOctet = A0, thirdOctet = 0xC0..0x100)" {
    var buffer: [12]u8 = undefined;
    @memcpy(buffer[3..6], "%A0");
    @memcpy(buffer[9..12], "%A0");
    for (0xF0..0xF8) |i| {
        const firstOctet: u8 = @intCast(i);
        @memcpy(buffer[0..3], percentEscapeTable[firstOctet][0..]);
        for (0xC0..0x100) |j| {
            const thirdOctet: u8 = @intCast(j);
            @memcpy(buffer[6..9], percentEscapeTable[thirdOctet][0..]);

            if (decodeURIAlloc(testing.allocator, buffer[0..])) |decoded| {
                testing.allocator.free(decoded);
                return error.TestUnexpectedResult;
            } else |err| {
                try testing.expectEqual(error.URIError, err);
            }
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.15_T6.js
//
// A `firstOctet` with the bit pattern `11110xxx` indicates a four-byte UTF-8
// sequence. The following continuationByte` must have the pattern `10xxxxxx`;
// otherwise the octets are not valid UTF-8 and `dedodeURIAlloc` must return
// `error.URIError`.
test "decodeURIAlloc: invalid continuation byte in a four-byte UTF-8 sequence (secondOctet = thirdOctet = A0, fourthOctet = 0xC0..0x100)" {
    var buffer: [12]u8 = undefined;
    for (0xF0..0xF8) |i| {
        const firstOctet: u8 = @intCast(i);
        @memcpy(buffer[0..3], percentEscapeTable[firstOctet][0..]);
        @memcpy(buffer[3..9], "%A0%A0");
        for (0xC0..0x100) |j| {
            const fourthOctet: u8 = @intCast(j);
            @memcpy(buffer[9..12], percentEscapeTable[fourthOctet][0..]);

            if (decodeURIAlloc(testing.allocator, buffer[0..])) |decoded| {
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
        const input = "%";

        if (decodeURIAlloc(testing.allocator, input[0..])) |decoded| {
            testing.allocator.free(decoded);
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.URIError, err);
        }
    }

    // Check 2
    {
        const input = "%A";

        if (decodeURIAlloc(testing.allocator, input[0..])) |decoded| {
            testing.allocator.free(decoded);
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.URIError, err);
        }
    }

    // Check 3
    {
        const input = "%1";

        if (decodeURIAlloc(testing.allocator, input[0..])) |decoded| {
            testing.allocator.free(decoded);
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.URIError, err);
        }
    }

    // Check 4
    {
        const input = "% ";

        if (decodeURIAlloc(testing.allocator, input[0..])) |decoded| {
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

    var buffer: [8]u8 = undefined;
    for (intervals) |interval| {
        var code_point = interval[0];
        while (code_point <= interval[1]) : (code_point += 1) {
            // Test262 iterates UTF-16 code units, including lone surrogates.
            // They have no valid UTF-8 representation, so they are outside
            // the input domain of this byte-oriented API.
            if (std.unicode.isSurrogateCodepoint(code_point)) continue;

            var encoded_code_point: [4]u8 = undefined;
            const encoded_len: usize = try std.unicode.utf8Encode(code_point, &encoded_code_point);

            const length: usize = 1 + encoded_len;
            @memcpy(buffer[0..1], "%");
            @memcpy(buffer[1..length], encoded_code_point[0..encoded_len]);
            @memcpy(buffer[length .. length + 1], "1");

            if (decodeURIAlloc(testing.allocator, buffer[0..length])) |decoded| {
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

    var buffer: [8]u8 = undefined;
    for (intervals) |interval| {
        var code_point = interval[0];
        while (code_point <= interval[1]) : (code_point += 1) {
            // Test262 iterates UTF-16 code units, including lone surrogates.
            // They have no valid UTF-8 representation, so they are outside
            // the input domain of this byte-oriented API.
            if (std.unicode.isSurrogateCodepoint(code_point)) continue;

            var encoded_code_point: [4]u8 = undefined;
            const encoded_len: usize = try std.unicode.utf8Encode(code_point, &encoded_code_point);

            const length: usize = 2 + encoded_len;
            @memcpy(buffer[0..2], "%1");
            @memcpy(buffer[2..length], encoded_code_point[0..encoded_len]);

            if (decodeURIAlloc(testing.allocator, buffer[0..length])) |decoded| {
                testing.allocator.free(decoded);
                return error.TestUnexpectedResult;
            } else |err| {
                try testing.expectEqual(error.URIError, err);
            }
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.3_T1.js
//
// The `firstOctet` cannot have these leadings bits `10xxxxxx` or `11111xxx` as the leadings bits for
// continuation bytes can only have 0, 2, 3, or 4 leading bits for valid UTF-8.
test "decodeURIAlloc: invalid leading bits (n = 1)" {
    var buffer: [3]u8 = undefined;
    for (0x80..0xC0) |i| {
        const firstOctet: u8 = @intCast(i);
        @memcpy(buffer[0..3], percentEscapeTable[firstOctet][0..]);

        if (decodeURIAlloc(testing.allocator, buffer[0..])) |decoded| {
            testing.allocator.free(decoded);
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.URIError, err);
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.3_T2.js
//
// The `firstOctet` cannot have these leadings bits `10xxxxxx` or `11111xxx` as the leadings bits for
// continuation bytes can only have 0, 2, 3, or 4 leading bits for valid UTF-8.
test "decodeURIAlloc: invalid leading bits (n = 5)" {
    var buffer: [3]u8 = undefined;
    for (0xF8..0x100) |i| {
        const firstOctet: u8 = @intCast(i);
        @memcpy(buffer[0..3], percentEscapeTable[firstOctet][0..]);

        if (decodeURIAlloc(testing.allocator, buffer[0..])) |decoded| {
            testing.allocator.free(decoded);
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.URIError, err);
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.4_T1.js
//
// A continuation byte (`10xxxxxx`) cannot start a UTF-8 sequence, and `11111xxx` is not a valid
// UTF-8 starting pattern for B = 110xxxxx (n = 2) and (k + 2) + 3 >= length
test "decodeURIAlloc: missing or incomplete continuation escape (n = 2)" {
    var buffer: [6]u8 = undefined;
    for (0xC0..0xE0) |i| {
        const firstOctet: u8 = @intCast(i);
        @memcpy(buffer[0..3], percentEscapeTable[firstOctet][0..]);
        const suffix = "111";
        for (0..suffix.len) |suffixLen| {
            const length: usize = 3 + suffixLen;
            @memcpy(buffer[3..length], suffix[0..suffixLen]);

            if (decodeURIAlloc(testing.allocator, buffer[0..length])) |decoded| {
                testing.allocator.free(decoded);
                return error.TestUnexpectedResult;
            } else |err| {
                try testing.expectEqual(error.URIError, err);
            }
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.5_T1.js
//
// A continuation byte (`10xxxxxx`) cannot start a UTF-8 sequence, and `11111xxx` is not a valid
// UTF-8 starting pattern for B = 1110xxxx (n = 3) and (k + 2) + 6 >= length
test "decodeURIAlloc: missing or incomplete continuation escape (n = 3)" {
    var buffer: [9]u8 = undefined;
    for (0xE0..0xF0) |i| {
        const firstOctet: u8 = @intCast(i);
        @memcpy(buffer[0..3], percentEscapeTable[firstOctet][0..]);
        const suffix = "111111";
        for (0..suffix.len) |suffixLen| {
            const length: usize = 3 + suffixLen;
            @memcpy(buffer[3..length], suffix[0..suffixLen]);

            if (decodeURIAlloc(testing.allocator, buffer[0..length])) |decoded| {
                testing.allocator.free(decoded);
                return error.TestUnexpectedResult;
            } else |err| {
                try testing.expectEqual(error.URIError, err);
            }
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.6_T1.js
//
// A continuation byte (`10xxxxxx`) cannot start a UTF-8 sequence, and `11111xxx` is not a valid
// UTF-8 starting pattern for B = 11110xxx (n = 4) and (k + 2) + 9 >= length
test "decodeURIAlloc: missing or incomplete continuation escape (n = 4)" {
    var buffer: [12]u8 = undefined;
    for (0xF0..0xF8) |i| {
        const firstOctet: u8 = @intCast(i);
        @memcpy(buffer[0..3], percentEscapeTable[firstOctet][0..]);
        const suffix = "111111111";
        for (0..suffix.len) |suffixLen| {
            const length: usize = 3 + suffixLen;
            @memcpy(buffer[3..length], suffix[0..suffixLen]);

            if (decodeURIAlloc(testing.allocator, buffer[0..length])) |decoded| {
                testing.allocator.free(decoded);
                return error.TestUnexpectedResult;
            } else |err| {
                try testing.expectEqual(error.URIError, err);
            }
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.7_T1.js
//
// An escape sequence (`110xxxxx`) must have the next continuation bytes be prefixed with '%'
test "decodeURIAlloc: continuation byte must be prefixed with '%' (n = 2)" {
    var buffer: [6]u8 = undefined;
    for (0xC0..0xE0) |i| {
        const firstOctet: u8 = @intCast(i);
        @memcpy(buffer[0..3], percentEscapeTable[firstOctet][0..]);
        @memcpy(buffer[3..6], "111");

        if (decodeURIAlloc(testing.allocator, buffer[0..])) |decoded| {
            testing.allocator.free(decoded);
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.URIError, err);
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.8_T1.js
//
// An escape sequence (`1110xxxx) must have the next continuation bytes be prefixed with '%'
test "decodeURIAlloc: continuation byte must be prefixed with '%' (n = 3) - invalid 2nd octet" {
    var buffer: [9]u8 = undefined;
    for (0xE0..0xF0) |i| {
        const firstOctet: u8 = @intCast(i);
        @memcpy(buffer[0..3], percentEscapeTable[firstOctet][0..]);
        @memcpy(buffer[3..9], "111%A0");

        if (decodeURIAlloc(testing.allocator, buffer[0..])) |decoded| {
            testing.allocator.free(decoded);
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.URIError, err);
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.8_T2.js
//
// An escape sequence (`1110xxxx`) must have the next continuation bytes be prefixed with '%'
test "decodeURIAlloc: continuation byte must be prefixed with '%' (n=3) - invalid third octet" {
    var buffer: [9]u8 = undefined;
    for (0xE0..0xF0) |i| {
        const firstOctet: u8 = @intCast(i);
        @memcpy(buffer[0..3], percentEscapeTable[firstOctet][0..]);
        @memcpy(buffer[3..9], "%A0111");

        if (decodeURIAlloc(testing.allocator, buffer[0..])) |decoded| {
            testing.allocator.free(decoded);
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.URIError, err);
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.9_T1.js
//
// An escape sequence (`11110xxx`) must have the next continuation bytes be prefixed with '%'
test "decodeURIAlloc: continuation byte must be prefixed with '%' (n = 4) - invalid first continuation byte" {
    var buffer: [12]u8 = undefined;
    for (0xF0..0xF8) |i| {
        const firstOctet: u8 = @intCast(i);
        @memcpy(buffer[0..3], percentEscapeTable[firstOctet][0..]);
        @memcpy(buffer[3..12], "111%A0%A0");

        if (decodeURIAlloc(testing.allocator, buffer[0..])) |decoded| {
            testing.allocator.free(decoded);
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.URIError, err);
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.9_T2.js
//
// An escape sequence (`11110xxx`) must have the next continuation bytes be prefixed with '%'
test "decodeURIAlloc: continuation byte mustb e prefixed with '%' (n = 4) - invalid second continuation byte" {
    var buffer: [12]u8 = undefined;
    for (0xF0..0xF8) |i| {
        const firstOctet: u8 = @intCast(i);
        @memcpy(buffer[0..3], percentEscapeTable[firstOctet][0..]);
        @memcpy(buffer[3..12], "%A0111%A0");

        if (decodeURIAlloc(testing.allocator, buffer[0..])) |decoded| {
            testing.allocator.free(decoded);
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.URIError, err);
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.9_T3.js
//
// An escape sequence (`11110xxx`) must have the next continuation bytes be prefixed with '%'
test "decodeURIAlloc: continuation byte mustb e prefixed with '%' (n = 4) - invalid third continuation byte" {
    var buffer: [12]u8 = undefined;
    for (0xF0..0xF8) |i| {
        const firstOctet: u8 = @intCast(i);
        @memcpy(buffer[0..3], percentEscapeTable[firstOctet][0..]);
        @memcpy(buffer[3..12], "%A0%A0111");

        if (decodeURIAlloc(testing.allocator, buffer[0..])) |decoded| {
            testing.allocator.free(decoded);
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.URIError, err);
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A2.1_T1.js
//
// It should not change the input byte as long as it is not '%'
test "decodeURIAlloc: it should keep the same byte as long as the character is not '%'" {
    for (0..65536) |value| {
        const codePoint: u21 = @intCast(value);

        if (std.unicode.isSurrogateCodepoint(codePoint) or codePoint == '%') continue;

        var encoded: [4]u8 = undefined;
        const encodedLen = try std.unicode.utf8Encode(codePoint, &encoded);
        const input = encoded[0..encodedLen];

        if (decodeURIAlloc(testing.allocator, input)) |decoded| {
            defer testing.allocator.free(decoded);
            try testing.expectEqualSlices(u8, input, decoded);
        } else |err| {
            return err;
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A2.2_T1.js
//
// If there is no continuation byte and it's not a reserved character, it should return the character
test "decodeURIAlloc: it should return the byte as long as it's not a reserved character (no continuation byte)" {
    var buffer: [3]u8 = undefined;
    const uriReserved = ";/?:@&=+$,";
    skip: for (0x00..0x80) |i| {
        const octet: u8 = @intCast(i);
        for (uriReserved) |char| {
            if (char == octet) continue :skip;
        }
        if (octet == '#') continue :skip;
        @memcpy(buffer[0..3], percentEscapeTable[octet][0..]);

        if (decodeURIAlloc(testing.allocator, buffer[0..])) |decoded| {
            defer testing.allocator.free(decoded);
            const expected = [_]u8{octet};
            try testing.expectEqualSlices(u8, expected[0..], decoded);
        } else |err| {
            return err;
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A2.3_T1.js
//
// It should return the decoded character
test "decodeURIAlloc: it should return the bytes correctly decoded (n=2)" {
    var buffer: [6]u8 = undefined;
    for (0xC2..0xE0) |i| {
        const firstOctet: u8 = @intCast(i);
        @memcpy(buffer[0..3], percentEscapeTable[firstOctet][0..]);

        for (0x80..0xC0) |j| {
            const secondOctet: u8 = @intCast(j);
            @memcpy(buffer[3..6], percentEscapeTable[secondOctet][0..]);

            if (decodeURIAlloc(testing.allocator, buffer[0..])) |decoded| {
                defer testing.allocator.free(decoded);
                const expected = [_]u8{ firstOctet, secondOctet };
                try testing.expectEqualSlices(u8, expected[0..2], decoded);
            } else |err| {
                return err;
            }
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A2.4_T1.js
//
// It should return the decoded character
test "decodeURIAlloc: it should return the bytes correctly decoded (n=3)" {
    var buffer: [9]u8 = undefined;
    for (0xE0..0xF0) |i| {
        const firstOctet: u8 = @intCast(i);
        @memcpy(buffer[0..3], percentEscapeTable[firstOctet][0..]);
        for (0x80..0xC0) |j| {
            const secondOctet: u8 = @intCast(j);
            if (firstOctet == 0xE0 and secondOctet <= 0x9F) continue;
            if (firstOctet == 0xED and 0xA0 <= secondOctet) continue;
            @memcpy(buffer[3..6], percentEscapeTable[secondOctet][0..]);

            for (0x80..0xC0) |k| {
                const thirdOctet: u8 = @intCast(k);
                @memcpy(buffer[6..9], percentEscapeTable[thirdOctet][0..]);

                if (decodeURIAlloc(testing.allocator, buffer[0..])) |decoded| {
                    defer testing.allocator.free(decoded);
                    const expected = [_]u8{ firstOctet, secondOctet, thirdOctet };
                    try testing.expectEqualSlices(u8, expected[0..], decoded);
                } else |err| {
                    return err;
                }
            }
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A2.5_T1.js
//
// It should return the decoded character
test "decodeURIAlloc: it should return the bytes correctly decoded (n=4)" {
    var buffer: [12]u8 = undefined;
    for (0xF0..0xF5) |i| {
        const firstOctect: u8 = @intCast(i);
        @memcpy(buffer[0..3], percentEscapeTable[firstOctect][0..]);

        for (0x80..0xC0) |j| {
            const secondOctet: u8 = @intCast(j);
            if (firstOctect == 0xF0 and secondOctet <= 0x9F) continue;
            if (firstOctect == 0xF4 and secondOctet >= 0x90) continue;
            @memcpy(buffer[3..6], percentEscapeTable[secondOctet][0..]);

            for (0x80..0xC0) |k| {
                const thirdOctet: u8 = @intCast(k);
                @memcpy(buffer[6..9], percentEscapeTable[thirdOctet][0..]);
                for (0x80..0xC0) |l| {
                    const fourthOctet: u8 = @intCast(l);
                    @memcpy(buffer[9..12], percentEscapeTable[fourthOctet][0..]);

                    if (decodeURIAlloc(testing.allocator, buffer[0..])) |decoded| {
                        defer testing.allocator.free(decoded);
                        const expected = [_]u8{ firstOctect, secondOctet, thirdOctet, fourthOctet };
                        try testing.expectEqualSlices(u8, expected[0..], decoded);
                    } else |err| {
                        return err;
                    }
                }
            }
        }
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A3_T1.js
//
// Preserves the string containing one instance of each character valid in the uri reserved plus '#'
test "decodeURIAlloc: preserves the string if it's in the uriReserved plus '#' (uppercase)" {
    // Check #1
    {
        const input = "%3B";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, input, decoded);
    }

    // Check #2
    {
        const input = "%2F";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, input, decoded);
    }

    // Check #3
    {
        const input = "%3F";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, input, decoded);
    }

    // Check #4
    {
        const input = "%3A";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, input, decoded);
    }

    // Check #5
    {
        const input = "%40";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, input, decoded);
    }

    // Check #6
    {
        const input = "%26";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, input, decoded);
    }

    // Check #7
    {
        const input = "%3D";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, input, decoded);
    }

    // Check #8
    {
        const input = "%2B";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, input, decoded);
    }

    // Check #9
    {
        const input = "%24";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, input, decoded);
    }

    // Check #10
    {
        const input = "%2C";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, input, decoded);
    }

    // Check #11
    {
        const input = "%23";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, input, decoded);
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A3_T2.js
//
// Preserves the string containing one instance of each character valid in the uri reserved plus '#'
test "decodeURIAlloc: preserves the string if it's in the uriReserved plus '#' (lowercase)" {
    // Check #1
    {
        const input = "%3b";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, input, decoded);
    }

    // Check #2
    {
        const input = "%2f";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, input, decoded);
    }

    // Check #3
    {
        const input = "%3f";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, input, decoded);
    }

    // Check #4
    {
        const input = "%3a";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, input, decoded);
    }

    // Check #5
    {
        const input = "%40";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, input, decoded);
    }

    // Check #6
    {
        const input = "%26";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, input, decoded);
    }

    // Check #7
    {
        const input = "%3d";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, input, decoded);
    }

    // Check #8
    {
        const input = "%2b";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, input, decoded);
    }

    // Check #9
    {
        const input = "%24";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, input, decoded);
    }

    // Check #10
    {
        const input = "%2c";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, input, decoded);
    }

    // Check #11
    {
        const input = "%23";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, input, decoded);
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A3_T3.js
//
// Preserves the string containing one instance of each character valid in the uri reserved plus '#'
test "decodeURIAlloc: preserves the string if it's in the uriReserved plus '#' (string)" {
    // Check #1
    {
        const input = "%3B%2F%3F%3A%40%26%3D%2B%24%2C%23";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, input, decoded);
    }

    // Check #2
    {
        const input = "%3b%2f%3f%3a%40%26%3d%2b%24%2c%23";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, input, decoded);
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A4_T1.js
//
// Correctly decode the english alphabet
test "decodeURIAlloc: decode the english alphabet" {
    // Check #1
    {
        const input = "http://unipro.ru/0123456789";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, decoded, input);
    }

    // Check #1
    {
        const input = "%41%42%43%44%45%46%47%48%49%4A%4B%4C%4D%4E%4F%50%51%52%53%54%55%56%57%58%59%5A";
        const expected = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, expected, decoded);
    }

    // Check #2
    {
        const input = "%61%62%63%64%65%66%67%68%69%6A%6B%6C%6D%6E%6F%70%71%72%73%74%75%76%77%78%79%7A";
        const expected = "abcdefghijklmnopqrstuvwxyz";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, expected, decoded);
    }
}

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A4_T2.js
//
// Correctly decode the russian alphabet
test "decodeURIAlloc: decode the russian alphabet" {
    // Check #1
    {
        const input = "http://ru.wikipedia.org/wiki/%d0%ae%D0%bd%D0%B8%D0%BA%D0%BE%D0%B4";
        const expected = "http://ru.wikipedia.org/wiki/Юникод";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, expected, decoded);
    }

    // Check #2
    {
        const input = "http://ru.wikipedia.org/wiki/%D0%AE%D0%BD%D0%B8%D0%BA%D0%BE%D0%B4#%D0%A1%D1%81%D1%8B%D0%BB%D0%BA%D0%B8";
        const expected = "http://ru.wikipedia.org/wiki/Юникод#Ссылки";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, expected, decoded);
    }

    // Check #3
    {
        const input = "http://ru.wikipedia.org/wiki/%D0%AE%D0%BD%D0%B8%D0%BA%D0%BE%D0%B4%23%D0%92%D0%B5%D1%80%D1%81%D0%B8%D0%B8%20%D0%AE%D0%BD%D0%B8%D0%BA%D0%BE%D0%B4%D0%B0";
        const expected = "http://ru.wikipedia.org/wiki/Юникод%23Версии Юникода";
        const decoded = try decodeURIAlloc(testing.allocator, input);
        defer testing.allocator.free(decoded);
        try testing.expectEqualSlices(u8, expected, decoded);
    }
}
