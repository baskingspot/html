//! HTML in Zig, the way the WHATWG HTML standard parses it.
//!
//! `parse` turns UTF-8 bytes into a `Document`, and `parseFragment` parses
//! markup in the context of an element, as `innerHTML` does. `Parser` does
//! the same in chunks, so a document can stream through it. `Tokenizer` is
//! the stage before tree construction, for callers who only want tokens.
//! None of them do I/O.

const std = @import("std");
const testing = std.testing;

/// The HTML parser: tree construction, §13.2.6 of the standard.
pub const Parser = @import("Parser.zig");
pub const parse = Parser.parse;
pub const parseFragment = Parser.parseFragment;

/// A parsed document or fragment.
pub const Document = @import("Document.zig");
pub const Node = Document.Node;

/// The HTML tokenizer, §13.2.5 of the standard.
pub const Tokenizer = @import("Tokenizer.zig");
pub const Token = Tokenizer.Token;
pub const ParseError = Tokenizer.ParseError;
pub const ErrorCode = Tokenizer.ErrorCode;

test {
    testing.refAllDecls(@This());
}
