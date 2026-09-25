const ecma_uri = @import("ecma_uri.zig");

pub const DecodeError = ecma_uri.DecodeError;
pub const decodeURIAlloc = ecma_uri.decodeURIAlloc;

pub const EncodeError = ecma_uri.EncodeError;
pub const encodeURIAlloc = ecma_uri.encodeURIAlloc;

test {
    _ = ecma_uri;
}
