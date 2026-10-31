//! The HTML tokenizer: UTF-8 bytes in, tokens out, as the WHATWG HTML
//! standard's tokenization section (§13.2.5) defines them.
//!
//! The tokenizer does no I/O. Feed it bytes as they arrive with `feed`, pull
//! tokens with `next` until it returns null, which means "feed more", and call
//! `finish` at the end of the input. A token's slices point into the
//! tokenizer and stay valid until the next call to `next`.
//!
//! Input is decoded as UTF-8 the way the Encoding Standard decodes it: an
//! invalid sequence becomes U+FFFD, and a byte order mark is an ordinary
//! character. CR and CRLF become LF before the state machine sees them.

const std = @import("std");
const ascii = std.ascii;
const assert = std.debug.assert;
const mem = std.mem;
const testing = std.testing;
const unicode = std.unicode;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;

const entities = @import("entities.zig");

const Tokenizer = @This();

/// One token, as the standard defines them. Character tokens arrive in runs,
/// as `text`; two `text` tokens in a row are one run split by the input.
pub const Token = union(enum) {
    doctype: Doctype,
    start_tag: Tag,
    end_tag: Tag,
    comment: []const u8,
    processing_instruction: ProcessingInstruction,
    text: []const u8,
    eof,
};

pub const Doctype = struct {
    /// Null when the DOCTYPE had no name, which is distinct from an empty one.
    name: ?[]const u8,
    public_id: ?[]const u8,
    system_id: ?[]const u8,
    force_quirks: bool,
};

pub const Tag = struct {
    /// Lowercased for ASCII letters, as the standard requires.
    name: []const u8,
    /// In document order. A repeated name is dropped, as the standard requires.
    attributes: []const Attribute,
    self_closing: bool,
};

pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

pub const ProcessingInstruction = struct {
    target: []const u8,
    data: []const u8,
};

/// A parse error, with the line and column, both counted from one, of the
/// character the tokenizer was looking at when it found the error. Columns
/// count UTF-16 code units, as browsers and html5lib-tests do, so a code
/// point above U+FFFF takes two.
pub const ParseError = struct {
    code: ErrorCode,
    line: u32,
    column: u32,
};

/// The parse error codes of §13.2.2 that the tokenizer can report. The names
/// are the standard's, with `_` for `-`.
pub const ErrorCode = enum {
    abrupt_closing_of_empty_comment,
    abrupt_doctype_public_identifier,
    abrupt_doctype_system_identifier,
    absence_of_digits_in_numeric_character_reference,
    cdata_in_html_content,
    character_reference_outside_unicode_range,
    control_character_in_input_stream,
    control_character_reference,
    disallowed_processing_instruction_target,
    duplicate_attribute,
    end_tag_with_attributes,
    end_tag_with_trailing_solidus,
    eof_before_tag_name,
    eof_in_cdata,
    eof_in_comment,
    eof_in_doctype,
    eof_in_processing_instruction,
    eof_in_script_html_comment_like_text,
    eof_in_tag,
    incorrectly_closed_comment,
    incorrectly_opened_comment,
    invalid_character_sequence_after_doctype_name,
    invalid_first_character_of_processing_instruction_target,
    invalid_first_character_of_tag_name,
    invalid_processing_instruction_target,
    missing_attribute_value,
    missing_doctype_name,
    missing_doctype_public_identifier,
    missing_doctype_system_identifier,
    missing_end_tag_name,
    missing_quote_before_doctype_public_identifier,
    missing_quote_before_doctype_system_identifier,
    missing_semicolon_after_character_reference,
    missing_whitespace_after_doctype_public_keyword,
    missing_whitespace_after_doctype_system_keyword,
    missing_whitespace_before_doctype_name,
    missing_whitespace_between_attributes,
    missing_whitespace_between_doctype_public_and_system_identifiers,
    nested_comment,
    noncharacter_character_reference,
    noncharacter_in_input_stream,
    null_character_reference,
    surrogate_character_reference,
    unexpected_character_after_doctype_system_identifier,
    unexpected_character_in_attribute_name,
    unexpected_character_in_unquoted_attribute_value,
    unexpected_equals_sign_before_attribute_name,
    unexpected_null_character,
    unexpected_solidus_in_tag,
    unknown_named_character_reference,
};

// ast-grep-ignore: public-struct-field-default -- options bag: call sites override one knob
pub const Options = struct {
    /// Whether to record parse errors in `errors`. They never stop the
    /// tokenizer; the standard says how to recover from each one.
    errors: ErrorMode = .ignore,
};

pub const ErrorMode = enum { ignore, collect };

/// The states tree construction switches the tokenizer into, for the
/// contents of elements such as `title`, `style`, `script`, and `plaintext`.
pub const TextState = enum { data, rcdata, rawtext, script_data, plaintext, cdata_section };

/// Whether `<![CDATA[` opens a CDATA section. Tree construction sets
/// `.foreign` while the adjusted current node is outside the HTML namespace.
pub const CdataMode = enum { html, foreign };

/// The end of the input: `.open` until `finish` is called.
const InputEnd = enum { open, finished };

/// Characters of text runs where the raw-text states differ.
const Raw = enum {
    rcdata,
    rawtext,
    script_data,
    script_data_escaped,

    fn state(self: Raw) State {
        return switch (self) {
            .rcdata => .rcdata,
            .rawtext => .rawtext,
            .script_data => .script_data,
            .script_data_escaped => .script_data_escaped,
        };
    }
};

const Identifier = enum { public, system };

const QuotedIdentifier = struct { id: Identifier, quote: u8 };

const State = union(enum) {
    data,
    rcdata,
    rawtext,
    script_data,
    plaintext,
    tag_open,
    end_tag_open,
    tag_name,
    text_less_than: Raw,
    text_end_tag_open: Raw,
    text_end_tag_name: Raw,
    script_data_escape_start,
    script_data_escape_start_dash,
    script_data_escaped,
    script_data_escaped_dash,
    script_data_escaped_dash_dash,
    script_data_escaped_less_than,
    script_data_double_escape_start,
    script_data_double_escaped,
    script_data_double_escaped_dash,
    script_data_double_escaped_dash_dash,
    script_data_double_escaped_less_than,
    script_data_double_escape_end,
    before_attribute_name,
    attribute_name,
    after_attribute_name,
    before_attribute_value,
    attribute_value_quoted: u8,
    attribute_value_unquoted,
    after_attribute_value_quoted,
    self_closing_start_tag,
    bogus_comment,
    markup_declaration_open,
    comment_start,
    comment_start_dash,
    comment,
    comment_less_than,
    comment_less_than_bang,
    comment_less_than_bang_dash,
    comment_less_than_bang_dash_dash,
    comment_end_dash,
    comment_end,
    comment_end_bang,
    doctype,
    before_doctype_name,
    doctype_name,
    after_doctype_name,
    after_doctype_keyword: Identifier,
    before_doctype_identifier: Identifier,
    doctype_identifier_quoted: QuotedIdentifier,
    after_doctype_public_identifier,
    between_doctype_identifiers,
    after_doctype_system_identifier,
    bogus_doctype,
    cdata_section,
    cdata_section_bracket,
    cdata_section_end,
    processing_instruction_open,
    processing_instruction_target,
    after_processing_instruction_target,
    processing_instruction_data,
    processing_instruction_questionable,
    character_reference,
    named_character_reference,
    ambiguous_ampersand,
    numeric_character_reference,
    hexadecimal_character_reference_start,
    hexadecimal_character_reference,
    decimal_character_reference,
    numeric_character_reference_end,
    end_of_file,
};

/// The non-text token a step finished, waiting for `next` to return it.
const Ready = enum { doctype, start_tag, end_tag, comment, processing_instruction, eof };

/// What the previous `next` returned, so the next call can release it.
const Returned = enum { nothing, text, token };

const TagKind = enum { start, end };

/// Whether the attribute being read survives. A repeated name is dropped,
/// but it stays the current attribute until the next one starts.
const AttributeFate = enum { kept, dropped };

const DoctypeField = enum { name, public_id, system_id };

/// An attribute's bytes in `attribute_bytes`, as offsets so the list can grow.
const AttributeSpan = struct {
    name_start: u32,
    name_end: u32,
    value_end: u32,
};

/// The next character: a code point and the bytes it took, or the end of
/// input with a length of zero.
const Char = struct {
    cp: u21,
    len: u8,
};

/// Larger than any code point, so it cannot collide with one.
const eof: u21 = 0x1F_FFFF;
const replacement: u21 = 0xFFFD;

/// The result of one state machine step.
const Progress = enum { more, need_input };

/// The most parse errors one step can report: an input stream error, then a
/// missing attribute value and the two end tag errors when it ends a tag.
const max_errors_per_step = 4;

/// Whether a lookahead compares ASCII letters regardless of case.
const Case = enum { sensitive, insensitive };

const Lookahead = enum { yes, no };

gpa: Allocator,
options: Options,
/// Fed bytes not yet consumed start at `pos`.
input: ArrayList(u8),
pos: u32,
/// Bytes before this offset have had their input stream checks.
checked: u32,
input_end: InputEnd,
/// The position of the character at `pos`.
line: u32,
column: u32,
state: State,
return_state: State,
cdata: CdataMode,
text: ArrayList(u8),
temp: ArrayList(u8),
tag_kind: TagKind,
tag_name: ArrayList(u8),
self_closing: bool,
attribute_bytes: ArrayList(u8),
attribute_spans: ArrayList(AttributeSpan),
attribute_fate: AttributeFate,
attributes: ArrayList(Attribute),
last_start_tag: ArrayList(u8),
comment: ArrayList(u8),
doctype_name: ArrayList(u8),
doctype_public_id: ArrayList(u8),
doctype_system_id: ArrayList(u8),
doctype_present: std.EnumSet(DoctypeField),
force_quirks: bool,
pi_target: ArrayList(u8),
pi_data: ArrayList(u8),
/// Where the processing instruction token was created, which is where
/// html5lib-tests places an end of file inside its data.
pi_line: u32,
pi_column: u32,
char_ref_code: u32,
ready: ?Ready,
returned: Returned,
/// Parse errors in the order they were found, when `options.errors` is
/// `.collect`. The caller may read and clear it between calls to `next`.
errors: ArrayList(ParseError),

pub fn init(gpa: Allocator, options: Options) Tokenizer {
    return .{
        .gpa = gpa,
        .options = options,
        .input = .empty,
        .pos = 0,
        .checked = 0,
        .input_end = .open,
        .line = 1,
        .column = 1,
        .state = .data,
        .return_state = .data,
        .cdata = .html,
        .text = .empty,
        .temp = .empty,
        .tag_kind = .start,
        .tag_name = .empty,
        .self_closing = false,
        .attribute_bytes = .empty,
        .attribute_spans = .empty,
        .attribute_fate = .kept,
        .attributes = .empty,
        .last_start_tag = .empty,
        .comment = .empty,
        .doctype_name = .empty,
        .doctype_public_id = .empty,
        .doctype_system_id = .empty,
        .doctype_present = .initEmpty(),
        .force_quirks = false,
        .pi_target = .empty,
        .pi_data = .empty,
        .pi_line = 1,
        .pi_column = 1,
        .char_ref_code = 0,
        .ready = null,
        .returned = .nothing,
        .errors = .empty,
    };
}

pub fn deinit(self: *Tokenizer) void {
    const gpa = self.gpa;
    inline for (.{
        &self.input,        &self.text,              &self.temp,
        &self.tag_name,     &self.attribute_bytes,   &self.attribute_spans,
        &self.attributes,   &self.last_start_tag,    &self.comment,
        &self.doctype_name, &self.doctype_public_id, &self.doctype_system_id,
        &self.pi_target,    &self.pi_data,           &self.errors,
    }) |list| list.deinit(gpa);
    self.* = undefined;
}

/// Append bytes to the input. They are copied, so the caller may reuse them.
pub fn feed(self: *Tokenizer, bytes: []const u8) Allocator.Error!void {
    assert(self.input_end == .open);
    const consumed = self.pos;
    if (consumed != 0) {
        const rest = self.input.items[consumed..];
        @memmove(self.input.items[0..rest.len], rest);
        self.input.shrinkRetainingCapacity(rest.len);
        self.checked -|= consumed;
        self.pos = 0;
    }
    assert(self.input.items.len + bytes.len <= std.math.maxInt(u32));
    try self.input.appendSlice(self.gpa, bytes);
}

/// Mark the end of the input. `next` then runs to the `eof` token.
pub fn finish(self: *Tokenizer) void {
    self.input_end = .finished;
}

/// Switch to one of the text states. Tree construction does this after a
/// start tag such as `<title>` or `<script>`.
pub fn setState(self: *Tokenizer, state: TextState) void {
    self.state = switch (state) {
        .data => .data,
        .rcdata => .rcdata,
        .rawtext => .rawtext,
        .script_data => .script_data,
        .plaintext => .plaintext,
        .cdata_section => .cdata_section,
    };
}

/// Set the tag name an end tag must have to close an RCDATA, RAWTEXT, or
/// script data run, as if a start tag with this name had just been emitted.
pub fn setLastStartTag(self: *Tokenizer, name: []const u8) Allocator.Error!void {
    self.last_start_tag.clearRetainingCapacity();
    try self.last_start_tag.appendSlice(self.gpa, name);
}

/// The next token, or null when the tokenizer needs more input. After `eof`
/// every call returns `eof` again.
pub fn next(self: *Tokenizer) Allocator.Error!?Token {
    switch (self.returned) {
        .nothing => {},
        .text => self.text.clearRetainingCapacity(),
        .token => self.ready = null,
    }
    self.returned = .nothing;
    while (self.ready == null) {
        if (self.options.errors == .collect) {
            try self.errors.ensureUnusedCapacity(self.gpa, max_errors_per_step);
        }
        if (try self.step() == .need_input) break;
    }
    if (self.text.items.len != 0) {
        self.returned = .text;
        return .{ .text = self.text.items };
    }
    const ready = self.ready orelse return null;
    self.returned = .token;
    return self.token(ready);
}

fn token(self: *const Tokenizer, ready: Ready) Token {
    return switch (ready) {
        .doctype => .{ .doctype = .{
            .name = self.doctypeField(.name, &self.doctype_name),
            .public_id = self.doctypeField(.public_id, &self.doctype_public_id),
            .system_id = self.doctypeField(.system_id, &self.doctype_system_id),
            .force_quirks = self.force_quirks,
        } },
        .start_tag => .{ .start_tag = self.tagValue() },
        .end_tag => .{ .end_tag = self.tagValue() },
        .comment => .{ .comment = self.comment.items },
        .processing_instruction => .{ .processing_instruction = .{
            .target = self.pi_target.items,
            .data = self.pi_data.items,
        } },
        .eof => .eof,
    };
}

fn doctypeField(
    self: *const Tokenizer,
    field: DoctypeField,
    list: *const ArrayList(u8),
) ?[]const u8 {
    return if (self.doctype_present.contains(field)) list.items else null;
}

fn tagValue(self: *const Tokenizer) Tag {
    return .{
        .name = self.tag_name.items,
        .attributes = self.attributes.items,
        .self_closing = self.self_closing,
    };
}

// Input

/// The next input character, without consuming it, or null when more input
/// is needed to know it. The first look at a character runs the input stream
/// checks of §13.2.3.5.
fn peek(self: *Tokenizer) ?Char {
    const bytes = self.input.items[self.pos..];
    if (bytes.len == 0) {
        return if (self.input_end == .open) null else .{ .cp = eof, .len = 0 };
    }
    // Most characters a state peeks at are printable ASCII delimiters, which
    // need no decoding and no input stream check. Leaving `checked` behind is
    // safe: it only stops a character from being checked twice.
    const first = bytes[0];
    if ((first >= 0x20 and first < 0x7F) or first == '\t' or first == '\n') {
        return .{ .cp = first, .len = 1 };
    }
    var c = decodeUtf8(bytes, self.input_end) orelse return null;
    if (c.cp == '\r') {
        if (bytes.len == 1 and self.input_end == .open) return null;
        const crlf = bytes.len > 1 and bytes[1] == '\n';
        c = .{ .cp = '\n', .len = if (crlf) 2 else 1 };
    }
    if (self.pos >= self.checked) {
        self.checked = self.pos + c.len;
        self.checkInputCharacter(c.cp);
    }
    return c;
}

fn checkInputCharacter(self: *Tokenizer, cp: u21) void {
    if (isNoncharacter(cp)) return self.fail(.noncharacter_in_input_stream);
    if (isControl(cp) and !isAsciiWhitespace(cp) and cp != 0) {
        self.fail(.control_character_in_input_stream);
    }
}

/// Consume the character `peek` returned.
fn advance(self: *Tokenizer, c: Char) void {
    self.pos += c.len;
    if (c.cp == '\n') {
        self.line +|= 1;
        self.column = 1;
    } else if (c.cp != eof) {
        self.column +|= if (c.cp > 0xFFFF) 2 else 1;
    }
}

/// The ASCII bytes a run may hold: tab, LF, and printable ASCII, but `stops`.
fn runTable(comptime stops: []const u8) [0x80]bool {
    var table: [0x80]bool = @splat(false);
    table['\t'] = true;
    table['\n'] = true;
    for (0x20..0x7F) |b| table[b] = true;
    for (stops) |b| table[b] = false;
    return table;
}

/// Consume the longest run of characters the calling state handles one by
/// one in the same way, except the bytes in `stops`, and return its bytes.
/// A run holds no character that `peek` changes or reports an error for: no
/// CR, NULL, control, noncharacter, or invalid or incomplete UTF-8. So taking
/// a run is the same as stepping through it, only faster.
fn takeRun(self: *Tokenizer, comptime stops: []const u8) []const u8 {
    const table = comptime runTable(stops);
    const bytes = self.input.items[self.pos..];
    var i: usize = 0;
    var line = self.line;
    var column = self.column;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b < 0x80) {
            if (!table[b]) break;
            if (b == '\n') {
                line +|= 1;
                column = 1;
            } else {
                column +|= 1;
            }
            i += 1;
        } else {
            const n = ordinaryUtf8(bytes[i..]) orelse break;
            column +|= if (n == 4) 2 else 1;
            i += n;
        }
    }
    self.pos += @intCast(i);
    self.line = line;
    self.column = column;
    return bytes[0..i];
}

/// The length of the complete, valid UTF-8 sequence starting `bytes`, or
/// null when it is not one or encodes a C1 control or a noncharacter.
fn ordinaryUtf8(bytes: []const u8) ?u8 {
    const len: u8 = switch (bytes[0]) {
        0xC2...0xDF => 2,
        0xE0...0xEF => 3,
        0xF0...0xF4 => 4,
        else => return null,
    };
    const c = decodeUtf8(bytes, .open) orelse return null;
    if (c.len != len or c.cp <= 0x9F or isNoncharacter(c.cp)) return null;
    return len;
}

/// Lowercase the ASCII letters in `list` from `start` on, as names need.
fn lowercaseFrom(list: *ArrayList(u8), start: usize) void {
    for (list.items[start..]) |*b| b.* = ascii.toLower(b.*);
}

/// Consume `n` ASCII bytes a lookahead matched. None of them is a newline.
fn advanceAscii(self: *Tokenizer, n: u32) void {
    self.pos += n;
    self.column +|= n;
}

/// Whether the input continues with `pattern`, an ASCII string with no CR or
/// LF, or null when more input is needed to tell.
fn lookahead(self: *const Tokenizer, pattern: []const u8, case: Case) ?Lookahead {
    const bytes = self.input.items[self.pos..];
    const n = @min(bytes.len, pattern.len);
    const same = switch (case) {
        .sensitive => mem.eql(u8, bytes[0..n], pattern[0..n]),
        .insensitive => ascii.eqlIgnoreCase(bytes[0..n], pattern[0..n]),
    };
    if (!same) return .no;
    if (n < pattern.len) return if (self.input_end == .open) null else .no;
    return .yes;
}

fn fail(self: *Tokenizer, code: ErrorCode) void {
    self.failAt(code, self.line, self.column);
}

fn failAt(self: *Tokenizer, code: ErrorCode, line: u32, column: u32) void {
    @branchHint(.cold);
    if (self.options.errors == .ignore) return;
    // `next` reserved room for a step's worth of errors before the step.
    self.errors.appendAssumeCapacity(.{ .code = code, .line = line, .column = column });
}

// Emitting

fn emitChar(self: *Tokenizer, cp: u21) Allocator.Error!void {
    try appendCodepoint(self.gpa, &self.text, cp);
}

fn emitBytes(self: *Tokenizer, bytes: []const u8) Allocator.Error!void {
    try self.text.appendSlice(self.gpa, bytes);
}

fn emit(self: *Tokenizer, ready: Ready) void {
    assert(self.ready == null);
    self.ready = ready;
}

/// Finish the current tag token: resolve its attributes and emit it.
fn emitTag(self: *Tokenizer) Allocator.Error!void {
    self.attributes.clearRetainingCapacity();
    const bytes = self.attribute_bytes.items;
    for (self.attribute_spans.items) |span| {
        try self.attributes.append(self.gpa, .{
            .name = bytes[span.name_start..span.name_end],
            .value = bytes[span.name_end..span.value_end],
        });
    }
    switch (self.tag_kind) {
        .start => {
            try self.setLastStartTag(self.tag_name.items);
            self.emit(.start_tag);
        },
        .end => {
            if (self.attributes.items.len != 0) self.fail(.end_tag_with_attributes);
            if (self.self_closing) self.fail(.end_tag_with_trailing_solidus);
            self.emit(.end_tag);
        },
    }
}

fn emitEof(self: *Tokenizer) void {
    self.state = .end_of_file;
}

fn newTag(self: *Tokenizer, kind: TagKind) void {
    self.tag_kind = kind;
    self.tag_name.clearRetainingCapacity();
    self.self_closing = false;
    self.attribute_bytes.clearRetainingCapacity();
    self.attribute_spans.clearRetainingCapacity();
    self.attribute_fate = .kept;
}

fn newComment(self: *Tokenizer, data: []const u8) Allocator.Error!void {
    self.comment.clearRetainingCapacity();
    try self.comment.appendSlice(self.gpa, data);
}

fn newDoctype(self: *Tokenizer) void {
    self.doctype_name.clearRetainingCapacity();
    self.doctype_public_id.clearRetainingCapacity();
    self.doctype_system_id.clearRetainingCapacity();
    self.doctype_present = .initEmpty();
    self.force_quirks = false;
}

fn isAppropriateEndTag(self: *const Tokenizer) bool {
    return self.last_start_tag.items.len != 0 and
        mem.eql(u8, self.tag_name.items, self.last_start_tag.items);
}

fn startAttribute(self: *Tokenizer) Allocator.Error!void {
    const start: u32 = @intCast(self.attribute_bytes.items.len);
    try self.attribute_spans.append(self.gpa, .{
        .name_start = start,
        .name_end = start,
        .value_end = start,
    });
    self.attribute_fate = .kept;
}

fn appendAttributeName(self: *Tokenizer, cp: u21) Allocator.Error!void {
    try appendCodepoint(self.gpa, &self.attribute_bytes, cp);
}

/// Leave the attribute name state: fix the name's end and drop the attribute
/// when an earlier one has the same name.
fn finishAttributeName(self: *Tokenizer) void {
    const spans = self.attribute_spans.items;
    const current = &spans[spans.len - 1];
    current.name_end = @intCast(self.attribute_bytes.items.len);
    current.value_end = current.name_end;
    const bytes = self.attribute_bytes.items;
    const name = bytes[current.name_start..current.name_end];
    for (spans[0 .. spans.len - 1]) |span| {
        if (!mem.eql(u8, bytes[span.name_start..span.name_end], name)) continue;
        self.fail(.duplicate_attribute);
        self.attribute_bytes.shrinkRetainingCapacity(current.name_start);
        self.attribute_spans.items.len -= 1;
        self.attribute_fate = .dropped;
        return;
    }
}

fn appendAttributeValue(self: *Tokenizer, cp: u21) Allocator.Error!void {
    if (self.attribute_fate == .dropped) return;
    try appendCodepoint(self.gpa, &self.attribute_bytes, cp);
    self.syncAttributeValue();
}

fn appendAttributeValueBytes(self: *Tokenizer, bytes: []const u8) Allocator.Error!void {
    if (self.attribute_fate == .dropped) return;
    try self.attribute_bytes.appendSlice(self.gpa, bytes);
    self.syncAttributeValue();
}

fn syncAttributeValue(self: *Tokenizer) void {
    const spans = self.attribute_spans.items;
    spans[spans.len - 1].value_end = @intCast(self.attribute_bytes.items.len);
}

// The state machine

fn step(self: *Tokenizer) Allocator.Error!Progress {
    return switch (self.state) {
        .data => self.dataState(),
        .rcdata => self.textState(.rcdata),
        .rawtext => self.textState(.rawtext),
        .script_data => self.textState(.script_data),
        .plaintext => self.textState(.plaintext),
        .tag_open => self.tagOpen(),
        .end_tag_open => self.endTagOpen(),
        .tag_name => self.tagNameState(),
        .text_less_than => |raw| self.textLessThan(raw),
        .text_end_tag_open => |raw| self.textEndTagOpen(raw),
        .text_end_tag_name => |raw| self.textEndTagName(raw),
        .script_data_escape_start,
        .script_data_escape_start_dash,
        .script_data_escaped,
        .script_data_escaped_dash,
        .script_data_escaped_dash_dash,
        .script_data_escaped_less_than,
        => self.scriptEscaped(),
        .script_data_double_escape_start,
        .script_data_double_escape_end,
        => self.scriptDoubleEscapeBoundary(),
        .script_data_double_escaped,
        .script_data_double_escaped_dash,
        .script_data_double_escaped_dash_dash,
        .script_data_double_escaped_less_than,
        => self.scriptDoubleEscaped(),
        .before_attribute_name => self.beforeAttributeName(),
        .attribute_name => self.attributeName(),
        .after_attribute_name => self.afterAttributeName(),
        .before_attribute_value => self.beforeAttributeValue(),
        .attribute_value_quoted => |quote| self.attributeValueQuoted(quote),
        .attribute_value_unquoted => self.attributeValueUnquoted(),
        .after_attribute_value_quoted => self.afterAttributeValueQuoted(),
        .self_closing_start_tag => self.selfClosingStartTag(),
        .bogus_comment => self.bogusComment(),
        .markup_declaration_open => self.markupDeclarationOpen(),
        .comment_start,
        .comment_start_dash,
        .comment,
        .comment_end_dash,
        .comment_end,
        .comment_end_bang,
        => self.commentBody(),
        .comment_less_than,
        .comment_less_than_bang,
        .comment_less_than_bang_dash,
        .comment_less_than_bang_dash_dash,
        => self.commentLessThan(),
        .doctype, .before_doctype_name, .doctype_name, .after_doctype_name => self.doctypeName(),
        .after_doctype_keyword => |id| self.afterDoctypeKeyword(id),
        .before_doctype_identifier => |id| self.beforeDoctypeIdentifier(id),
        .doctype_identifier_quoted => |quoted| self.doctypeIdentifierQuoted(quoted),
        .after_doctype_public_identifier,
        .between_doctype_identifiers,
        .after_doctype_system_identifier,
        .bogus_doctype,
        => self.afterDoctypeIdentifier(),
        .cdata_section, .cdata_section_bracket, .cdata_section_end => self.cdataSection(),
        .processing_instruction_open,
        .processing_instruction_target,
        .after_processing_instruction_target,
        .processing_instruction_data,
        .processing_instruction_questionable,
        => self.processingInstruction(),
        .character_reference => self.characterReference(),
        .named_character_reference => self.namedCharacterReference(),
        .ambiguous_ampersand => self.ambiguousAmpersand(),
        .numeric_character_reference,
        .hexadecimal_character_reference_start,
        .hexadecimal_character_reference,
        .decimal_character_reference,
        => self.numericCharacterReference(),
        .numeric_character_reference_end => self.numericCharacterReferenceEnd(),
        .end_of_file => {
            self.emit(.eof);
            return .more;
        },
    };
}

fn dataState(self: *Tokenizer) Allocator.Error!Progress {
    const run = self.takeRun("&<");
    if (run.len != 0) {
        try self.emitBytes(run);
        return .more;
    }
    const c = self.peek() orelse return .need_input;
    switch (c.cp) {
        '&' => {
            self.advance(c);
            self.return_state = .data;
            self.state = .character_reference;
        },
        '<' => {
            self.advance(c);
            self.state = .tag_open;
        },
        eof => self.emitEof(),
        else => {
            if (c.cp == 0) self.fail(.unexpected_null_character);
            try self.emitChar(c.cp);
            self.advance(c);
        },
    }
    return .more;
}

/// The RCDATA, RAWTEXT, script data, and PLAINTEXT states.
fn textState(self: *Tokenizer, kind: enum { rcdata, rawtext, script_data, plaintext }) Allocator.Error!Progress {
    const run = switch (kind) {
        .rcdata => self.takeRun("&<"),
        .rawtext, .script_data => self.takeRun("<"),
        .plaintext => self.takeRun(""),
    };
    if (run.len != 0) {
        try self.emitBytes(run);
        return .more;
    }
    const c = self.peek() orelse return .need_input;
    if (c.cp == eof) {
        self.emitEof();
        return .more;
    }
    if (c.cp == '&' and kind == .rcdata) {
        self.return_state = .rcdata;
        self.state = .character_reference;
    } else if (c.cp == '<' and kind != .plaintext) {
        self.state = .{ .text_less_than = switch (kind) {
            .rcdata => .rcdata,
            .rawtext => .rawtext,
            .script_data => .script_data,
            .plaintext => unreachable,
        } };
    } else {
        try self.emitScriptChar(c.cp);
    }
    self.advance(c);
    return .more;
}

fn tagOpen(self: *Tokenizer) Allocator.Error!Progress {
    const c = self.peek() orelse return .need_input;
    switch (c.cp) {
        '!' => {
            self.advance(c);
            self.state = .markup_declaration_open;
        },
        '/' => {
            self.advance(c);
            self.state = .end_tag_open;
        },
        '?' => {
            self.advance(c);
            self.temp.clearRetainingCapacity();
            self.state = .processing_instruction_open;
        },
        eof => {
            self.fail(.eof_before_tag_name);
            try self.emitBytes("<");
            self.emitEof();
        },
        else => if (isAsciiAlpha(c.cp)) {
            self.newTag(.start);
            self.state = .tag_name;
        } else {
            self.fail(.invalid_first_character_of_tag_name);
            try self.emitBytes("<");
            self.state = .data;
        },
    }
    return .more;
}

fn endTagOpen(self: *Tokenizer) Allocator.Error!Progress {
    const c = self.peek() orelse return .need_input;
    if (isAsciiAlpha(c.cp)) {
        self.newTag(.end);
        self.state = .tag_name;
    } else if (c.cp == '>') {
        self.fail(.missing_end_tag_name);
        self.advance(c);
        self.state = .data;
    } else if (c.cp == eof) {
        self.fail(.eof_before_tag_name);
        try self.emitBytes("</");
        self.emitEof();
    } else {
        self.fail(.invalid_first_character_of_tag_name);
        try self.newComment("");
        self.state = .bogus_comment;
    }
    return .more;
}

fn tagNameState(self: *Tokenizer) Allocator.Error!Progress {
    const run = self.takeRun("\t\n />");
    if (run.len != 0) {
        const start = self.tag_name.items.len;
        try self.tag_name.appendSlice(self.gpa, run);
        lowercaseFrom(&self.tag_name, start);
        return .more;
    }
    const c = self.peek() orelse return .need_input;
    switch (c.cp) {
        '\t', '\n', 0x0C, ' ' => {
            self.advance(c);
            self.state = .before_attribute_name;
        },
        '/' => {
            self.advance(c);
            self.state = .self_closing_start_tag;
        },
        '>' => {
            try self.emitTag();
            self.consumeTo(c, .data);
        },
        eof => {
            self.fail(.eof_in_tag);
            self.emitEof();
        },
        else => {
            if (c.cp == 0) self.fail(.unexpected_null_character);
            try appendCodepoint(self.gpa, &self.tag_name, tagNameChar(c.cp));
            self.advance(c);
        },
    }
    return .more;
}

fn textLessThan(self: *Tokenizer, raw: Raw) Allocator.Error!Progress {
    const c = self.peek() orelse return .need_input;
    if (c.cp == '/') {
        self.advance(c);
        self.temp.clearRetainingCapacity();
        self.state = .{ .text_end_tag_open = raw };
    } else if (c.cp == '!' and raw == .script_data) {
        self.advance(c);
        self.state = .script_data_escape_start;
        try self.emitBytes("<!");
    } else {
        try self.emitBytes("<");
        self.state = raw.state();
    }
    return .more;
}

fn textEndTagOpen(self: *Tokenizer, raw: Raw) Allocator.Error!Progress {
    const c = self.peek() orelse return .need_input;
    if (isAsciiAlpha(c.cp)) {
        self.newTag(.end);
        self.state = .{ .text_end_tag_name = raw };
    } else {
        try self.emitBytes("</");
        self.state = raw.state();
    }
    return .more;
}

fn textEndTagName(self: *Tokenizer, raw: Raw) Allocator.Error!Progress {
    const c = self.peek() orelse return .need_input;
    const appropriate = self.isAppropriateEndTag();
    switch (c.cp) {
        '\t', '\n', 0x0C, ' ' => if (appropriate) {
            self.advance(c);
            self.state = .before_attribute_name;
            return .more;
        },
        '/' => if (appropriate) {
            self.advance(c);
            self.state = .self_closing_start_tag;
            return .more;
        },
        '>' => if (appropriate) {
            try self.emitTag();
            self.consumeTo(c, .data);
            return .more;
        },
        else => if (isAsciiAlpha(c.cp)) {
            try self.tag_name.append(self.gpa, ascii.toLower(@intCast(c.cp)));
            try self.temp.append(self.gpa, @intCast(c.cp));
            self.advance(c);
            return .more;
        },
    }
    try self.emitBytes("</");
    try self.emitBytes(self.temp.items);
    self.state = raw.state();
    return .more;
}

/// The script data escape start states and the escaped states, which share
/// the `-`, `<`, NULL, and EOF handling.
fn scriptEscaped(self: *Tokenizer) Allocator.Error!Progress {
    const c = self.peek() orelse return .need_input;
    const state = self.state;
    switch (state) {
        .script_data_escape_start, .script_data_escape_start_dash => {
            if (c.cp != '-') {
                self.state = .script_data;
                return .more;
            }
            self.advance(c);
            try self.emitBytes("-");
            self.state = if (state == .script_data_escape_start)
                .script_data_escape_start_dash
            else
                .script_data_escaped_dash_dash;
            return .more;
        },
        .script_data_escaped_less_than => return self.scriptEscapedLessThan(c),
        else => {},
    }
    switch (c.cp) {
        '-' => {
            self.advance(c);
            try self.emitBytes("-");
            self.state = switch (state) {
                .script_data_escaped => .script_data_escaped_dash,
                else => .script_data_escaped_dash_dash,
            };
        },
        '<' => {
            self.advance(c);
            self.state = .script_data_escaped_less_than;
        },
        '>' => {
            self.advance(c);
            try self.emitBytes(">");
            if (state == .script_data_escaped_dash_dash) self.state = .script_data else {
                self.state = .script_data_escaped;
            }
        },
        eof => {
            self.fail(.eof_in_script_html_comment_like_text);
            self.emitEof();
        },
        else => {
            try self.emitScriptChar(c.cp);
            self.consumeTo(c, .script_data_escaped);
        },
    }
    return .more;
}

fn scriptEscapedLessThan(self: *Tokenizer, c: Char) Allocator.Error!Progress {
    if (c.cp == '/') {
        self.advance(c);
        self.temp.clearRetainingCapacity();
        self.state = .{ .text_end_tag_open = .script_data_escaped };
    } else if (isAsciiAlpha(c.cp)) {
        self.temp.clearRetainingCapacity();
        try self.emitBytes("<");
        self.state = .script_data_double_escape_start;
    } else {
        try self.emitBytes("<");
        self.state = .script_data_escaped;
    }
    return .more;
}

/// Emit a character of a raw text run, replacing NULL with U+FFFD as a parse
/// error.
fn emitScriptChar(self: *Tokenizer, cp: u21) Allocator.Error!void {
    if (cp == 0) {
        self.fail(.unexpected_null_character);
        return self.emitChar(replacement);
    }
    try self.emitChar(cp);
}

/// The script data double escape start and end states: they read a tag
/// name into the temporary buffer and toggle on `script`.
fn scriptDoubleEscapeBoundary(self: *Tokenizer) Allocator.Error!Progress {
    const c = self.peek() orelse return .need_input;
    const entering = self.state == .script_data_double_escape_start;
    switch (c.cp) {
        '\t', '\n', 0x0C, ' ', '/', '>' => {
            const script = mem.eql(u8, self.temp.items, "script");
            self.state = if (script == entering) .script_data_double_escaped else .script_data_escaped;
            try self.emitChar(c.cp);
            self.advance(c);
        },
        else => if (isAsciiAlpha(c.cp)) {
            try self.temp.append(self.gpa, ascii.toLower(@intCast(c.cp)));
            try self.emitChar(c.cp);
            self.advance(c);
        } else {
            self.state = if (entering) .script_data_escaped else .script_data_double_escaped;
        },
    }
    return .more;
}

fn scriptDoubleEscaped(self: *Tokenizer) Allocator.Error!Progress {
    const c = self.peek() orelse return .need_input;
    const state = self.state;
    if (state == .script_data_double_escaped_less_than) {
        if (c.cp == '/') {
            self.temp.clearRetainingCapacity();
            self.advance(c);
            try self.emitBytes("/");
            self.state = .script_data_double_escape_end;
        } else {
            self.state = .script_data_double_escaped;
        }
        return .more;
    }
    switch (c.cp) {
        '-' => {
            self.advance(c);
            try self.emitBytes("-");
            self.state = switch (state) {
                .script_data_double_escaped => .script_data_double_escaped_dash,
                else => .script_data_double_escaped_dash_dash,
            };
        },
        '<' => {
            self.advance(c);
            try self.emitBytes("<");
            self.state = .script_data_double_escaped_less_than;
        },
        '>' => {
            self.advance(c);
            try self.emitBytes(">");
            self.state = if (state == .script_data_double_escaped_dash_dash)
                .script_data
            else
                .script_data_double_escaped;
        },
        eof => {
            self.fail(.eof_in_script_html_comment_like_text);
            self.emitEof();
        },
        else => {
            try self.emitScriptChar(c.cp);
            self.consumeTo(c, .script_data_double_escaped);
        },
    }
    return .more;
}

fn beforeAttributeName(self: *Tokenizer) Allocator.Error!Progress {
    const c = self.peek() orelse return .need_input;
    switch (c.cp) {
        '\t', '\n', 0x0C, ' ' => self.advance(c),
        '/', '>', eof => self.state = .after_attribute_name,
        '=' => {
            self.fail(.unexpected_equals_sign_before_attribute_name);
            try self.startAttribute();
            try self.appendAttributeName('=');
            self.advance(c);
            self.state = .attribute_name;
        },
        else => {
            try self.startAttribute();
            self.state = .attribute_name;
        },
    }
    return .more;
}

fn attributeName(self: *Tokenizer) Allocator.Error!Progress {
    const run = self.takeRun("\t\n />=\"'<");
    if (run.len != 0) {
        const start = self.attribute_bytes.items.len;
        try self.attribute_bytes.appendSlice(self.gpa, run);
        lowercaseFrom(&self.attribute_bytes, start);
        return .more;
    }
    const c = self.peek() orelse return .need_input;
    switch (c.cp) {
        '\t', '\n', 0x0C, ' ', '/', '>', eof => {
            self.finishAttributeName();
            self.state = .after_attribute_name;
        },
        '=' => {
            self.finishAttributeName();
            self.advance(c);
            self.state = .before_attribute_value;
        },
        else => {
            if (c.cp == 0) self.fail(.unexpected_null_character);
            if (c.cp == '"' or c.cp == '\'' or c.cp == '<') {
                self.fail(.unexpected_character_in_attribute_name);
            }
            try self.appendAttributeName(tagNameChar(c.cp));
            self.advance(c);
        },
    }
    return .more;
}

fn afterAttributeName(self: *Tokenizer) Allocator.Error!Progress {
    const c = self.peek() orelse return .need_input;
    switch (c.cp) {
        '\t', '\n', 0x0C, ' ' => self.advance(c),
        '/' => {
            self.advance(c);
            self.state = .self_closing_start_tag;
        },
        '=' => {
            self.advance(c);
            self.state = .before_attribute_value;
        },
        '>' => {
            try self.emitTag();
            self.consumeTo(c, .data);
        },
        eof => {
            self.fail(.eof_in_tag);
            self.emitEof();
        },
        else => {
            try self.startAttribute();
            self.state = .attribute_name;
        },
    }
    return .more;
}

fn beforeAttributeValue(self: *Tokenizer) Allocator.Error!Progress {
    const c = self.peek() orelse return .need_input;
    switch (c.cp) {
        '\t', '\n', 0x0C, ' ' => self.advance(c),
        '"', '\'' => {
            self.advance(c);
            self.state = .{ .attribute_value_quoted = @intCast(c.cp) };
        },
        '>' => {
            self.fail(.missing_attribute_value);
            try self.emitTag();
            self.consumeTo(c, .data);
        },
        else => self.state = .attribute_value_unquoted,
    }
    return .more;
}

fn attributeValueQuoted(self: *Tokenizer, quote: u8) Allocator.Error!Progress {
    const run = if (quote == '"') self.takeRun("\"&") else self.takeRun("'&");
    if (run.len != 0) {
        try self.appendAttributeValueBytes(run);
        return .more;
    }
    const c = self.peek() orelse return .need_input;
    if (c.cp == quote) {
        self.advance(c);
        self.state = .after_attribute_value_quoted;
        return .more;
    }
    switch (c.cp) {
        '&' => {
            self.advance(c);
            self.return_state = self.state;
            self.state = .character_reference;
        },
        eof => {
            self.fail(.eof_in_tag);
            self.emitEof();
        },
        else => {
            try self.appendValueChar(c.cp);
            self.advance(c);
        },
    }
    return .more;
}

fn attributeValueUnquoted(self: *Tokenizer) Allocator.Error!Progress {
    const run = self.takeRun("\t\n &>\"'<=`");
    if (run.len != 0) {
        try self.appendAttributeValueBytes(run);
        return .more;
    }
    const c = self.peek() orelse return .need_input;
    switch (c.cp) {
        '\t', '\n', 0x0C, ' ' => {
            self.advance(c);
            self.state = .before_attribute_name;
        },
        '&' => {
            self.advance(c);
            self.return_state = .attribute_value_unquoted;
            self.state = .character_reference;
        },
        '>' => {
            try self.emitTag();
            self.consumeTo(c, .data);
        },
        eof => {
            self.fail(.eof_in_tag);
            self.emitEof();
        },
        else => {
            switch (c.cp) {
                '"', '\'', '<', '=', '`' => self.fail(.unexpected_character_in_unquoted_attribute_value),
                else => {},
            }
            try self.appendValueChar(c.cp);
            self.advance(c);
        },
    }
    return .more;
}

/// Append an attribute value character, replacing NULL as a parse error.
fn appendValueChar(self: *Tokenizer, cp: u21) Allocator.Error!void {
    if (cp == 0) {
        self.fail(.unexpected_null_character);
        return self.appendAttributeValue(replacement);
    }
    try self.appendAttributeValue(cp);
}

fn afterAttributeValueQuoted(self: *Tokenizer) Allocator.Error!Progress {
    const c = self.peek() orelse return .need_input;
    switch (c.cp) {
        '\t', '\n', 0x0C, ' ' => {
            self.advance(c);
            self.state = .before_attribute_name;
        },
        '/' => {
            self.advance(c);
            self.state = .self_closing_start_tag;
        },
        '>' => {
            try self.emitTag();
            self.consumeTo(c, .data);
        },
        eof => {
            self.fail(.eof_in_tag);
            self.emitEof();
        },
        else => {
            self.fail(.missing_whitespace_between_attributes);
            self.state = .before_attribute_name;
        },
    }
    return .more;
}

fn selfClosingStartTag(self: *Tokenizer) Allocator.Error!Progress {
    const c = self.peek() orelse return .need_input;
    switch (c.cp) {
        '>' => {
            self.self_closing = true;
            try self.emitTag();
            self.consumeTo(c, .data);
        },
        eof => {
            self.fail(.eof_in_tag);
            self.emitEof();
        },
        else => {
            self.fail(.unexpected_solidus_in_tag);
            self.state = .before_attribute_name;
        },
    }
    return .more;
}

fn bogusComment(self: *Tokenizer) Allocator.Error!Progress {
    const c = self.peek() orelse return .need_input;
    switch (c.cp) {
        '>' => {
            self.advance(c);
            self.state = .data;
            self.emit(.comment);
        },
        eof => {
            self.emit(.comment);
            self.emitEof();
        },
        else => {
            try self.appendCommentChar(c.cp);
            self.advance(c);
        },
    }
    return .more;
}

/// Append a comment character, replacing NULL as a parse error.
fn appendCommentChar(self: *Tokenizer, cp: u21) Allocator.Error!void {
    if (cp == 0) {
        self.fail(.unexpected_null_character);
        return appendCodepoint(self.gpa, &self.comment, replacement);
    }
    try appendCodepoint(self.gpa, &self.comment, cp);
}

fn markupDeclarationOpen(self: *Tokenizer) Allocator.Error!Progress {
    const dashes = self.lookahead("--", .sensitive) orelse return .need_input;
    if (dashes == .yes) {
        self.advanceAscii(2);
        try self.newComment("");
        self.state = .comment_start;
        return .more;
    }
    const doctype = self.lookahead("DOCTYPE", .insensitive) orelse return .need_input;
    if (doctype == .yes) {
        self.advanceAscii(7);
        self.state = .doctype;
        return .more;
    }
    const cdata = self.lookahead("[CDATA[", .sensitive) orelse return .need_input;
    if (cdata == .yes) {
        if (self.cdata == .foreign) {
            self.advanceAscii(7);
            self.state = .cdata_section;
        } else {
            // The error belongs to the last character consumed, the final `[`.
            self.advanceAscii(6);
            self.fail(.cdata_in_html_content);
            self.advanceAscii(1);
            try self.newComment("[CDATA[");
            self.state = .bogus_comment;
        }
        return .more;
    }
    // Look at the next character first, so its input stream errors come
    // before this one, which is reported at the same position.
    _ = self.peek();
    self.fail(.incorrectly_opened_comment);
    try self.newComment("");
    self.state = .bogus_comment;
    return .more;
}

/// The comment start, comment, and comment end states.
fn commentBody(self: *Tokenizer) Allocator.Error!Progress {
    const c = self.peek() orelse return .need_input;
    const state = self.state;
    if (c.cp == eof and state != .comment_start) {
        self.fail(.eof_in_comment);
        self.emit(.comment);
        self.emitEof();
        return .more;
    }
    switch (state) {
        .comment_start, .comment_start_dash => switch (c.cp) {
            '-' => self.consumeTo(c, if (state == .comment_start) .comment_start_dash else .comment_end),
            '>' => {
                self.fail(.abrupt_closing_of_empty_comment);
                self.advance(c);
                self.state = .data;
                self.emit(.comment);
            },
            else => {
                if (state == .comment_start_dash) try self.comment.append(self.gpa, '-');
                self.state = .comment;
            },
        },
        .comment => switch (c.cp) {
            '<' => {
                try self.comment.append(self.gpa, '<');
                self.consumeTo(c, .comment_less_than);
            },
            '-' => self.consumeTo(c, .comment_end_dash),
            else => {
                try self.appendCommentChar(c.cp);
                self.advance(c);
            },
        },
        .comment_end_dash => if (c.cp == '-') self.consumeTo(c, .comment_end) else {
            try self.comment.append(self.gpa, '-');
            self.state = .comment;
        },
        .comment_end, .comment_end_bang => try self.commentEnd(c),
        else => unreachable,
    }
    return .more;
}

fn commentEnd(self: *Tokenizer, c: Char) Allocator.Error!void {
    const bang = self.state == .comment_end_bang;
    switch (c.cp) {
        '>' => {
            if (bang) self.fail(.incorrectly_closed_comment);
            self.advance(c);
            self.state = .data;
            self.emit(.comment);
        },
        '!' => if (bang) {
            try self.comment.appendSlice(self.gpa, "--!");
            self.state = .comment;
        } else self.consumeTo(c, .comment_end_bang),
        '-' => if (bang) {
            try self.comment.appendSlice(self.gpa, "--!");
            self.consumeTo(c, .comment_end_dash);
        } else {
            try self.comment.append(self.gpa, '-');
            self.advance(c);
        },
        else => {
            try self.comment.appendSlice(self.gpa, if (bang) "--!" else "--");
            self.state = .comment;
        },
    }
}

/// Consume the character and switch to `state`.
fn consumeTo(self: *Tokenizer, c: Char, state: State) void {
    self.advance(c);
    self.state = state;
}

/// The comment less-than sign states, which watch for a nested `<!--`.
fn commentLessThan(self: *Tokenizer) Allocator.Error!Progress {
    const c = self.peek() orelse return .need_input;
    switch (self.state) {
        .comment_less_than => switch (c.cp) {
            '!' => {
                try self.comment.append(self.gpa, '!');
                self.consumeTo(c, .comment_less_than_bang);
            },
            '<' => {
                try self.comment.append(self.gpa, '<');
                self.advance(c);
            },
            else => self.state = .comment,
        },
        .comment_less_than_bang => if (c.cp == '-') {
            self.consumeTo(c, .comment_less_than_bang_dash);
        } else {
            self.state = .comment;
        },
        .comment_less_than_bang_dash => if (c.cp == '-') {
            self.consumeTo(c, .comment_less_than_bang_dash_dash);
        } else {
            self.state = .comment_end_dash;
        },
        .comment_less_than_bang_dash_dash => {
            if (c.cp != '>' and c.cp != eof) self.fail(.nested_comment);
            self.state = .comment_end;
        },
        else => unreachable,
    }
    return .more;
}

/// The DOCTYPE state through the after DOCTYPE name state.
fn doctypeName(self: *Tokenizer) Allocator.Error!Progress {
    const c = self.peek() orelse return .need_input;
    const state = self.state;
    if (c.cp == eof) {
        self.fail(.eof_in_doctype);
        if (state == .doctype or state == .before_doctype_name) self.newDoctype();
        return self.emitQuirkyDoctypeAtEof();
    }
    const whitespace = isAsciiWhitespace(c.cp) and c.cp != '\r';
    switch (state) {
        .doctype => {
            if (whitespace) return self.consumeStep(c, .before_doctype_name);
            if (c.cp != '>') self.fail(.missing_whitespace_before_doctype_name);
            self.state = .before_doctype_name;
        },
        .before_doctype_name => {
            if (whitespace) return self.consumeStep(c, .before_doctype_name);
            self.newDoctype();
            if (c.cp == '>') {
                self.fail(.missing_doctype_name);
                self.force_quirks = true;
                self.advance(c);
                self.state = .data;
                self.emit(.doctype);
                return .more;
            }
            self.doctype_present.insert(.name);
            try self.appendDoctypeNameChar(c.cp);
            self.consumeTo(c, .doctype_name);
        },
        .doctype_name => {
            if (whitespace) return self.consumeStep(c, .after_doctype_name);
            if (c.cp == '>') return self.emitDoctype(c);
            try self.appendDoctypeNameChar(c.cp);
            self.advance(c);
        },
        .after_doctype_name => return self.afterDoctypeName(c, whitespace),
        else => unreachable,
    }
    return .more;
}

fn afterDoctypeName(self: *Tokenizer, c: Char, whitespace: bool) Allocator.Error!Progress {
    if (whitespace) return self.consumeStep(c, .after_doctype_name);
    if (c.cp == '>') return self.emitDoctype(c);
    const public = self.lookahead("PUBLIC", .insensitive) orelse return .need_input;
    if (public == .yes) {
        self.advanceAscii(6);
        self.state = .{ .after_doctype_keyword = .public };
        return .more;
    }
    const system = self.lookahead("SYSTEM", .insensitive) orelse return .need_input;
    if (system == .yes) {
        self.advanceAscii(6);
        self.state = .{ .after_doctype_keyword = .system };
        return .more;
    }
    self.fail(.invalid_character_sequence_after_doctype_name);
    self.force_quirks = true;
    self.state = .bogus_doctype;
    return .more;
}

fn appendDoctypeNameChar(self: *Tokenizer, cp: u21) Allocator.Error!void {
    if (cp == 0) self.fail(.unexpected_null_character);
    try appendCodepoint(self.gpa, &self.doctype_name, tagNameChar(cp));
}

fn consumeStep(self: *Tokenizer, c: Char, state: State) Progress {
    self.consumeTo(c, state);
    return .more;
}

fn emitDoctype(self: *Tokenizer, c: Char) Progress {
    self.advance(c);
    self.state = .data;
    self.emit(.doctype);
    return .more;
}

fn emitQuirkyDoctypeAtEof(self: *Tokenizer) Progress {
    self.force_quirks = true;
    self.emit(.doctype);
    self.emitEof();
    return .more;
}

fn quirkyDoctype(self: *Tokenizer, code: ErrorCode, c: Char) Progress {
    self.fail(code);
    self.force_quirks = true;
    if (c.cp == '>') return self.emitDoctype(c);
    self.state = .bogus_doctype;
    return .more;
}

/// Start an identifier: present and empty, read until `quote`.
fn openIdentifier(self: *Tokenizer, id: Identifier, c: Char) Progress {
    self.doctype_present.insert(switch (id) {
        .public => .public_id,
        .system => .system_id,
    });
    self.advance(c);
    self.state = .{ .doctype_identifier_quoted = .{ .id = id, .quote = @intCast(c.cp) } };
    return .more;
}

fn afterDoctypeKeyword(self: *Tokenizer, id: Identifier) Allocator.Error!Progress {
    const c = self.peek() orelse return .need_input;
    switch (c.cp) {
        '\t', '\n', 0x0C, ' ' => return self.consumeStep(c, .{ .before_doctype_identifier = id }),
        '"', '\'' => {
            self.fail(switch (id) {
                .public => .missing_whitespace_after_doctype_public_keyword,
                .system => .missing_whitespace_after_doctype_system_keyword,
            });
            return self.openIdentifier(id, c);
        },
        eof => {
            self.fail(.eof_in_doctype);
            return self.emitQuirkyDoctypeAtEof();
        },
        else => return self.missingIdentifier(id, c),
    }
}

fn beforeDoctypeIdentifier(self: *Tokenizer, id: Identifier) Allocator.Error!Progress {
    const c = self.peek() orelse return .need_input;
    switch (c.cp) {
        '\t', '\n', 0x0C, ' ' => return self.consumeStep(c, self.state),
        '"', '\'' => return self.openIdentifier(id, c),
        eof => {
            self.fail(.eof_in_doctype);
            return self.emitQuirkyDoctypeAtEof();
        },
        else => return self.missingIdentifier(id, c),
    }
}

/// A `>` where an identifier should start, or a character that is not a quote.
fn missingIdentifier(self: *Tokenizer, id: Identifier, c: Char) Progress {
    const code: ErrorCode = if (c.cp == '>') switch (id) {
        .public => .missing_doctype_public_identifier,
        .system => .missing_doctype_system_identifier,
    } else switch (id) {
        .public => .missing_quote_before_doctype_public_identifier,
        .system => .missing_quote_before_doctype_system_identifier,
    };
    return self.quirkyDoctype(code, c);
}

fn doctypeIdentifierQuoted(self: *Tokenizer, quoted: QuotedIdentifier) Allocator.Error!Progress {
    const c = self.peek() orelse return .need_input;
    if (c.cp == quoted.quote) {
        return self.consumeStep(c, switch (quoted.id) {
            .public => .after_doctype_public_identifier,
            .system => .after_doctype_system_identifier,
        });
    }
    switch (c.cp) {
        '>' => return self.quirkyDoctype(switch (quoted.id) {
            .public => .abrupt_doctype_public_identifier,
            .system => .abrupt_doctype_system_identifier,
        }, c),
        eof => {
            self.fail(.eof_in_doctype);
            return self.emitQuirkyDoctypeAtEof();
        },
        else => {
            if (c.cp == 0) self.fail(.unexpected_null_character);
            const list = switch (quoted.id) {
                .public => &self.doctype_public_id,
                .system => &self.doctype_system_id,
            };
            try appendCodepoint(self.gpa, list, if (c.cp == 0) replacement else c.cp);
            self.advance(c);
            return .more;
        },
    }
}

/// The states after the public identifier, between the identifiers, after
/// the system identifier, and the bogus DOCTYPE state.
fn afterDoctypeIdentifier(self: *Tokenizer) Allocator.Error!Progress {
    const c = self.peek() orelse return .need_input;
    const state = self.state;
    if (state == .bogus_doctype) {
        if (c.cp == '>') return self.emitDoctype(c);
        if (c.cp == eof) {
            self.emit(.doctype);
            self.emitEof();
            return .more;
        }
        if (c.cp == 0) self.fail(.unexpected_null_character);
        return self.consumeStep(c, state);
    }
    switch (c.cp) {
        '\t', '\n', 0x0C, ' ' => return self.consumeStep(c, switch (state) {
            .after_doctype_public_identifier => .between_doctype_identifiers,
            else => state,
        }),
        '>' => return self.emitDoctype(c),
        eof => {
            self.fail(.eof_in_doctype);
            return self.emitQuirkyDoctypeAtEof();
        },
        '"', '\'' => if (state != .after_doctype_system_identifier) {
            if (state == .after_doctype_public_identifier) {
                self.fail(.missing_whitespace_between_doctype_public_and_system_identifiers);
            }
            return self.openIdentifier(.system, c);
        },
        else => {},
    }
    if (state == .after_doctype_system_identifier) {
        self.fail(.unexpected_character_after_doctype_system_identifier);
        self.state = .bogus_doctype;
        return .more;
    }
    return self.quirkyDoctype(.missing_quote_before_doctype_system_identifier, c);
}

fn cdataSection(self: *Tokenizer) Allocator.Error!Progress {
    const c = self.peek() orelse return .need_input;
    switch (self.state) {
        .cdata_section => switch (c.cp) {
            ']' => self.consumeTo(c, .cdata_section_bracket),
            eof => {
                self.fail(.eof_in_cdata);
                self.emitEof();
            },
            else => {
                try self.emitChar(c.cp);
                self.advance(c);
            },
        },
        .cdata_section_bracket => if (c.cp == ']') self.consumeTo(c, .cdata_section_end) else {
            try self.emitBytes("]");
            self.state = .cdata_section;
        },
        .cdata_section_end => switch (c.cp) {
            ']' => {
                try self.emitBytes("]");
                self.advance(c);
            },
            '>' => self.consumeTo(c, .data),
            else => {
                try self.emitBytes("]]");
                self.state = .cdata_section;
            },
        },
        else => unreachable,
    }
    return .more;
}

fn processingInstruction(self: *Tokenizer) Allocator.Error!Progress {
    const c = self.peek() orelse return .need_input;
    const state = self.state;
    if (c.cp == eof and state != .after_processing_instruction_target) {
        switch (state) {
            .processing_instruction_data, .processing_instruction_questionable => {
                self.failAt(.eof_in_processing_instruction, self.pi_line, self.pi_column);
            },
            else => self.fail(.eof_in_processing_instruction),
        }
        self.emitEof();
        return .more;
    }
    switch (state) {
        .processing_instruction_open => if (isAsciiAlpha(c.cp) or c.cp == '_') {
            self.state = .processing_instruction_target;
        } else {
            try self.processingInstructionToComment(.invalid_first_character_of_processing_instruction_target);
        },
        .processing_instruction_target => try self.processingInstructionTarget(c),
        .after_processing_instruction_target => if (isAsciiWhitespace(c.cp)) self.advance(c) else {
            self.state = .processing_instruction_data;
        },
        .processing_instruction_data => switch (c.cp) {
            '?' => self.consumeTo(c, .processing_instruction_questionable),
            '>' => {
                self.consumeTo(c, .data);
                self.emit(.processing_instruction);
            },
            else => {
                try appendCodepoint(self.gpa, &self.pi_data, c.cp);
                self.advance(c);
            },
        },
        .processing_instruction_questionable => if (c.cp == '>') {
            self.consumeTo(c, .data);
            self.emit(.processing_instruction);
        } else {
            try self.pi_data.append(self.gpa, '?');
            self.state = .processing_instruction_data;
        },
        else => unreachable,
    }
    return .more;
}

fn processingInstructionTarget(self: *Tokenizer, c: Char) Allocator.Error!void {
    switch (c.cp) {
        '\t', '\n', 0x0C, ' ', '?', '>' => {
            const target = self.temp.items;
            if (ascii.eqlIgnoreCase(target, "xml") or ascii.eqlIgnoreCase(target, "xml-stylesheet")) {
                return self.processingInstructionToComment(.disallowed_processing_instruction_target);
            }
            self.pi_target.clearRetainingCapacity();
            try self.pi_target.appendSlice(self.gpa, target);
            self.pi_data.clearRetainingCapacity();
            self.pi_line = self.line;
            self.pi_column = self.column;
            self.state = .after_processing_instruction_target;
        },
        else => if (c.cp < 0x80 and (ascii.isAlphanumeric(@intCast(c.cp)) or c.cp == '-' or c.cp == '_')) {
            try self.temp.append(self.gpa, @intCast(c.cp));
            self.advance(c);
        } else {
            try self.processingInstructionToComment(.invalid_processing_instruction_target);
        },
    }
}

/// Report `code`, convert the temporary buffer to a comment, and reconsume
/// in the bogus comment state.
fn processingInstructionToComment(self: *Tokenizer, code: ErrorCode) Allocator.Error!void {
    self.fail(code);
    try self.newComment("?");
    try self.comment.appendSlice(self.gpa, self.temp.items);
    self.state = .bogus_comment;
}

// Character references

fn inAttribute(self: *const Tokenizer) bool {
    return switch (self.return_state) {
        .attribute_value_quoted, .attribute_value_unquoted => true,
        else => false,
    };
}

/// Flush code points consumed as a character reference.
fn flushCharacterReference(self: *Tokenizer) Allocator.Error!void {
    if (self.inAttribute()) {
        try self.appendAttributeValueBytes(self.temp.items);
    } else {
        try self.emitBytes(self.temp.items);
    }
}

fn characterReference(self: *Tokenizer) Allocator.Error!Progress {
    const c = self.peek() orelse return .need_input;
    self.temp.clearRetainingCapacity();
    try self.temp.append(self.gpa, '&');
    if (c.cp < 0x80 and ascii.isAlphanumeric(@intCast(c.cp))) {
        self.state = .named_character_reference;
    } else if (c.cp == '#') {
        try self.temp.append(self.gpa, '#');
        self.consumeTo(c, .numeric_character_reference);
    } else {
        try self.flushCharacterReference();
        self.state = self.return_state;
    }
    return .more;
}

fn namedCharacterReference(self: *Tokenizer) Allocator.Error!Progress {
    const bytes = self.input.items[self.pos..];
    const match = matchEntity(bytes, self.input_end) orelse return .need_input;
    const entity = match.entity orelse {
        try self.flushCharacterReference();
        self.state = .ambiguous_ampersand;
        return .more;
    };
    const name = entity.name;
    const semicolon = name[name.len - 1] == ';';
    if (self.inAttribute() and !semicolon) {
        if (name.len == bytes.len and self.input_end == .open) return .need_input;
        const following: u8 = if (name.len < bytes.len) bytes[name.len] else 0;
        if (following == '=' or ascii.isAlphanumeric(following)) {
            try self.temp.appendSlice(self.gpa, name);
            self.advanceAscii(@intCast(name.len));
            try self.flushCharacterReference();
            self.state = self.return_state;
            return .more;
        }
    }
    self.advanceAscii(@intCast(name.len));
    if (!semicolon) self.fail(.missing_semicolon_after_character_reference);
    self.temp.clearRetainingCapacity();
    for (entity.codepoints) |cp| {
        if (cp != 0) try appendCodepoint(self.gpa, &self.temp, cp);
    }
    try self.flushCharacterReference();
    self.state = self.return_state;
    return .more;
}

fn ambiguousAmpersand(self: *Tokenizer) Allocator.Error!Progress {
    const c = self.peek() orelse return .need_input;
    if (c.cp < 0x80 and ascii.isAlphanumeric(@intCast(c.cp))) {
        if (self.inAttribute()) try self.appendAttributeValue(c.cp) else try self.emitChar(c.cp);
        self.advance(c);
        return .more;
    }
    if (c.cp == ';') self.fail(.unknown_named_character_reference);
    self.state = self.return_state;
    return .more;
}

/// The numeric character reference states up to the end state.
fn numericCharacterReference(self: *Tokenizer) Allocator.Error!Progress {
    const c = self.peek() orelse return .need_input;
    const digit: ?u8 = if (c.cp < 0x80) std.fmt.charToDigit(@intCast(c.cp), 16) catch null else null;
    switch (self.state) {
        .numeric_character_reference => {
            self.char_ref_code = 0;
            if (c.cp == 'x' or c.cp == 'X') {
                try self.temp.append(self.gpa, @intCast(c.cp));
                self.consumeTo(c, .hexadecimal_character_reference_start);
            } else if (digit != null and digit.? < 10) {
                self.state = .decimal_character_reference;
            } else {
                return self.absentDigits();
            }
        },
        .hexadecimal_character_reference_start => if (digit != null) {
            self.state = .hexadecimal_character_reference;
        } else {
            return self.absentDigits();
        },
        .hexadecimal_character_reference, .decimal_character_reference => {
            const base: u32 = if (self.state == .decimal_character_reference) 10 else 16;
            if (digit != null and digit.? < base) {
                self.char_ref_code = @min(self.char_ref_code * base + digit.?, 0x110000);
                self.advance(c);
            } else if (c.cp == ';') {
                self.consumeTo(c, .numeric_character_reference_end);
            } else {
                self.fail(.missing_semicolon_after_character_reference);
                self.state = .numeric_character_reference_end;
            }
        },
        else => unreachable,
    }
    return .more;
}

fn absentDigits(self: *Tokenizer) Allocator.Error!Progress {
    self.fail(.absence_of_digits_in_numeric_character_reference);
    try self.flushCharacterReference();
    self.state = self.return_state;
    return .more;
}

fn numericCharacterReferenceEnd(self: *Tokenizer) Allocator.Error!Progress {
    var code = self.char_ref_code;
    if (code == 0) {
        self.fail(.null_character_reference);
        code = replacement;
    } else if (code > 0x10FFFF) {
        self.fail(.character_reference_outside_unicode_range);
        code = replacement;
    } else if (code >= 0xD800 and code <= 0xDFFF) {
        self.fail(.surrogate_character_reference);
        code = replacement;
    } else if (isNoncharacter(@intCast(code))) {
        self.fail(.noncharacter_character_reference);
    } else if (code == 0x0D or (isControl(@intCast(code)) and !isAsciiWhitespace(@intCast(code)))) {
        self.fail(.control_character_reference);
        code = windows1252(code);
    }
    self.temp.clearRetainingCapacity();
    try appendCodepoint(self.gpa, &self.temp, @intCast(code));
    try self.flushCharacterReference();
    self.state = self.return_state;
    return .more;
}

/// The longest named character reference at the start of `bytes`, or null
/// when more input could make a longer one match.
const EntityMatch = struct { entity: ?*const entities.Entity };

fn matchEntity(bytes: []const u8, input_end: InputEnd) ?EntityMatch {
    const table = &entities.table;
    var lo: u32 = 0;
    var hi: u32 = table.len;
    var best: ?*const entities.Entity = null;
    var depth: u32 = 0;
    while (depth < bytes.len and depth < entities.max_name_len) {
        const byte = bytes[depth];
        lo = narrow(lo, hi, depth, byte, .first);
        hi = narrow(lo, hi, depth, byte, .past);
        if (lo == hi) return .{ .entity = best };
        depth += 1;
        if (table[lo].name.len == depth) best = &table[lo];
    }
    if (depth == bytes.len and input_end == .open and depth < entities.max_name_len) return null;
    return .{ .entity = best };
}

/// Within entries `[lo, hi)` sharing a prefix of length `depth`, the first
/// whose byte at `depth` is at least (`.first`) or past (`.past`) `byte`.
/// The entry equal to the prefix itself sorts first and is passed over.
fn narrow(lo: u32, hi: u32, depth: u32, byte: u8, bound: enum { first, past }) u32 {
    var low = lo;
    var high = hi;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const name = entities.table[mid].name;
        const before = name.len <= depth or switch (bound) {
            .first => name[depth] < byte,
            .past => name[depth] <= byte,
        };
        if (before) low = mid + 1 else high = mid;
    }
    return low;
}

// Helpers

/// Decode the next code point the way the Encoding Standard's UTF-8 decoder
/// does, or null when the sequence continues past the input fed so far.
fn decodeUtf8(bytes: []const u8, input_end: InputEnd) ?Char {
    const first = bytes[0];
    if (first < 0x80) return .{ .cp = first, .len = 1 };
    var needed: u8 = 0;
    var cp: u21 = 0;
    var lower: u8 = 0x80;
    var upper: u8 = 0xBF;
    switch (first) {
        0xC2...0xDF => {
            needed = 1;
            cp = first & 0x1F;
        },
        0xE0...0xEF => {
            if (first == 0xE0) lower = 0xA0;
            if (first == 0xED) upper = 0x9F;
            needed = 2;
            cp = first & 0x0F;
        },
        0xF0...0xF4 => {
            if (first == 0xF0) lower = 0x90;
            if (first == 0xF4) upper = 0x8F;
            needed = 3;
            cp = first & 0x07;
        },
        else => return .{ .cp = replacement, .len = 1 },
    }
    var i: u8 = 1;
    while (i <= needed) : (i += 1) {
        if (i >= bytes.len) {
            return if (input_end == .open) null else .{ .cp = replacement, .len = i };
        }
        const byte = bytes[i];
        if (byte < lower or byte > upper) return .{ .cp = replacement, .len = i };
        lower = 0x80;
        upper = 0xBF;
        cp = (cp << 6) | (byte & 0x3F);
    }
    return .{ .cp = cp, .len = needed + 1 };
}

fn appendCodepoint(gpa: Allocator, list: *ArrayList(u8), cp: u21) Allocator.Error!void {
    var buf: [4]u8 = undefined;
    // Every code point here is a scalar value: the decoder and the character
    // reference states replace surrogates with U+FFFD.
    const n = unicode.utf8Encode(cp, &buf) catch unreachable;
    try list.appendSlice(gpa, buf[0..n]);
}

/// A tag name, attribute name, or DOCTYPE name character: ASCII upper alpha
/// lowercased, NULL replaced with U+FFFD. The caller reports the NULL.
fn tagNameChar(cp: u21) u21 {
    if (cp == 0) return replacement;
    if (cp >= 'A' and cp <= 'Z') return cp + 0x20;
    return cp;
}

fn isAsciiAlpha(cp: u21) bool {
    return cp < 0x80 and ascii.isAlphabetic(@intCast(cp));
}

fn isAsciiWhitespace(cp: u21) bool {
    return switch (cp) {
        '\t', '\n', 0x0C, '\r', ' ' => true,
        else => false,
    };
}

fn isControl(cp: u21) bool {
    return cp <= 0x1F or (cp >= 0x7F and cp <= 0x9F);
}

fn isNoncharacter(cp: u21) bool {
    return (cp >= 0xFDD0 and cp <= 0xFDEF) or (cp & 0xFFFE) == 0xFFFE;
}

/// The code points §13.2.5.84 substitutes for C1 controls, which legacy
/// content wrote meaning the windows-1252 characters at those bytes.
fn windows1252(code: u32) u32 {
    return switch (code) {
        0x80 => 0x20AC,
        0x82 => 0x201A,
        0x83 => 0x0192,
        0x84 => 0x201E,
        0x85 => 0x2026,
        0x86 => 0x2020,
        0x87 => 0x2021,
        0x88 => 0x02C6,
        0x89 => 0x2030,
        0x8A => 0x0160,
        0x8B => 0x2039,
        0x8C => 0x0152,
        0x8E => 0x017D,
        0x91 => 0x2018,
        0x92 => 0x2019,
        0x93 => 0x201C,
        0x94 => 0x201D,
        0x95 => 0x2022,
        0x96 => 0x2013,
        0x97 => 0x2014,
        0x98 => 0x02DC,
        0x99 => 0x2122,
        0x9A => 0x0161,
        0x9B => 0x203A,
        0x9C => 0x0153,
        0x9E => 0x017E,
        0x9F => 0x0178,
        else => code,
    };
}

test "a token split across feeds waits for the rest" {
    var tokenizer: Tokenizer = .init(testing.allocator, .{});
    defer tokenizer.deinit();

    try tokenizer.feed("Hi <di");
    // Text flows out as it arrives; the half-read tag waits.
    try testing.expectEqualStrings("Hi ", (try tokenizer.next()).?.text);
    try testing.expectEqual(null, try tokenizer.next());

    // The reference could still grow into a longer name until `;` arrives.
    try tokenizer.feed("v class=a&am");
    try testing.expectEqual(null, try tokenizer.next());
    try tokenizer.feed("p;b>");
    const tag = (try tokenizer.next()).?.start_tag;
    try testing.expectEqualStrings("div", tag.name);
    try testing.expectEqual(1, tag.attributes.len);
    try testing.expectEqualStrings("a&b", tag.attributes[0].value);

    try testing.expectEqual(null, try tokenizer.next());
    tokenizer.finish();
    try testing.expectEqual(.eof, try tokenizer.next());
    try testing.expectEqual(.eof, try tokenizer.next());
}
