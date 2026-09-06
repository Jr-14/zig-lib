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

const testing = std.testing;

// Adapted from Test262:
// test/built-ins/decodeURI/S15.1.3.1_A1.10_T1.js
// Copyright 2009 the Sputnik authors. All rights reserved.
// Licensed under the Test262 BSD license; see LICENSES/Test262.txt.
//
// info: |
//  If B = 110xxxxx (n = 2) and string.charAt(k + 4) and
//  string.charAt(k + 5) do not represent hexadecimal digits, throw URIError
test "decodeURIAlloc: (n = 2) invalid hex digits after a two-byte UTF-8 prefix" {
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
// info: |
//  If B = 1110xxxx (n = 3) and (string.charAt(k + 4) and
//  string.charAt(k + 5)) or (string.charAt(k + 7) and
//  string.charAt(k + 8)) do not represent hexadecimal digits, throw URIError
test "decodeURIAlloc: (n = 3) invalid hex digits on the second byte" {
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
// info: |
//  If B = 1110xxxx (n = 3) and (string.charAt(k + 4) and
//  string.charAt(k + 5)) or (string.charAt(k + 7) and
//  string.charAt(k + 8)) do not represent hexadecimal digits, throw URIError
test "decodeURIAlloc: (n = 3) invalid hex digits on the third byte" {
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
// info: |
//  If B = 11110xxx (n = 4) and (string.charAt(k + 4) and
//  string.charAt(k + 5)) or (string.charAt(k + 7) and
//  string.charAt(k + 8)) or (string.charAt(k + 10) and
//  string.charAt(k + 11)) do not represent hexadecimal digits, throw URIError
test "decodeURIAlloc: (n = 4) invalid hex digits on the 2nd byte" {
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
// info: |
//  If B = 11110xxx (n = 4) and (string.charAt(k + 4) and
//  string.charAt(k + 5)) or (string.charAt(k + 7) and
//  string.charAt(k + 8)) or (string.charAt(k + 10) and
//  string.charAt(k + 11)) do not represent hexadecimal digits, throw URIError
test "decodeURIAlloc: (n = 4) invalid hex digits on the 3rd byte" {
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
// info: |
//  If B = 11110xxx (n = 4) and (string.charAt(k + 4) and
//  string.charAt(k + 5)) or (string.charAt(k + 7) and
//  string.charAt(k + 8)) or (string.charAt(k + 10) and
//  string.charAt(k + 11)) do not represent hexadecimal digits, throw URIError
test "decodeURIAlloc: (n = 4) invalid hex digits on the 4th byte" {
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

// https://github.com/tc39/test262/blob/main/test/built-ins/decodeURI/S15.1.3.1_A1.1_T1.js
//
// info: If string.charAt(k) equal "%" and k + 2 >= string.length, throw URIError
test "decodeURIAlloc: % at the very end of the string" {
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
// info: |
//  If B = string.charAt(k+1) + string.charAt(k+2) do not represent
//  hexadecimal digits, throw URIError
test "decodeURIAlloc: invalid hexadecimal digit on the 2nd character after %" {
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
// info: |
//  If B = string.charAt(k+1) + string.charAt(k+2) do not represent
//  hexadecimal digits, throw URIError
test "decodeURIAlloc: invalid hexadecimal digit on the 1st character after %" {
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
