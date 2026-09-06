const decodeURI = @import("decodeURI.zig");
const encodeURI = @import("encodeURI.zig");

pub const DecodeError = decodeURI.DecodeError;
pub const decodeURIAlloc = decodeURI.decodeURIAlloc;

pub const EncodeError = encodeURI.EncodeError;
pub const encodeURIAlloc = encodeURI.encodeURIAlloc;

test "decodeURI" {
    _ = @import("decodeURI.zig");
}

test "encodeURI" {
    _ = @import("encodeURI.zig");
}
