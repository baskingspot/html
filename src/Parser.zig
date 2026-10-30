//! The HTML parser: tree construction (§13.2.6 of the WHATWG HTML standard)
//! driving the tokenizer, from bytes to a `Document`.
//!
//! Like the tokenizer it does no I/O. Feed it bytes in any split with `feed`,
//! then call `finish`, which runs the end of the input through the tree and
//! hands back the document. Splitting the input never changes the tree.
//!
//! The parser runs no scripts, so it implements the standard as if every
//! script were inert. It leaves out what only a browser needs: custom
//! elements, declarative shadow roots, the sanitizer, and form association.

const std = @import("std");
const ascii = std.ascii;
const assert = std.debug.assert;
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const EnumSet = std.EnumSet;

const Document = @import("Document.zig");
const Tokenizer = @import("Tokenizer.zig");
const Attribute = Document.Attribute;
const Element = Document.Element;
const Namespace = Document.Namespace;
const Node = Document.Node;
const Tag = Document.Tag;

const Parser = @This();

pub const Options = struct {
    /// Whether to parse as if scripting were enabled, as it is in browsers.
    /// It decides one thing: whether `noscript` holds raw text or markup.
    scripting: Scripting = .enabled,
};

pub const Scripting = enum { enabled, disabled };

/// The element whose contents a fragment is parsed as, as for `innerHTML`.
pub const Context = struct {
    namespace: Namespace = .html,
    name: []const u8,
    attributes: []const Attribute = &.{},
};

const Mode = enum {
    initial,
    before_html,
    before_head,
    in_head,
    in_head_noscript,
    after_head,
    in_body,
    text,
    in_table,
    in_table_text,
    in_caption,
    in_column_group,
    in_table_body,
    in_row,
    in_cell,
    in_template,
    after_body,
    in_frameset,
    after_frameset,
    after_after_body,
    after_after_frameset,
};

/// What a rule asks of the dispatcher once it has handled a token.
const Next = enum { done, reprocess };

const FramesetOk = enum { ok, not_ok };
const Foster = enum { off, on };
/// Whether to drop a newline that starts the next token, after `<pre>`,
/// `<listing>`, and `<textarea>`.
const Skip = enum { none, newline };
const Run = enum { parsing, finished };
const PendingText = enum { whitespace, mixed };
const Scope = enum { default, list_item, button, table };

/// The rules treat character tokens in three classes, so a text run goes
/// through tree construction one run of a single class at a time.
const CharClass = enum { whitespace, null, other };

const TagToken = struct {
    tag: Tag,
    name: []const u8,
    attributes: []Attribute,
    self_closing: bool,
};

/// A token as tree construction sees it.
const Token = union(enum) {
    doctype: Tokenizer.Doctype,
    start_tag: TagToken,
    end_tag: TagToken,
    comment: []const u8,
    processing_instruction: Tokenizer.ProcessingInstruction,
    chars: Chars,
    eof,
};

const Chars = struct { class: CharClass, data: []const u8 };

/// Where to insert a node: in `parent`, before `before`, or at the end.
const Location = struct { parent: Node.Index, before: Node.Index = .none };

/// A marker in the list of active formatting elements.
const marker: Node.Index = .none;

gpa: Allocator,
options: Options,
tokenizer: Tokenizer,
doc: Document,
mode: Mode,
original_mode: Mode,
template_modes: ArrayList(Mode),
/// The stack of open elements; the current node is last.
open: ArrayList(Node.Index),
/// The list of active formatting elements, with `marker` entries.
formatting: ArrayList(Node.Index),
head: Node.Index,
form: Node.Index,
/// The fragment case's context element, which is not in the tree.
context: Node.Index,
/// The fragment case's `html` root, whose children go in the fragment.
fragment_root: Node.Index,
frameset_ok: FramesetOk,
foster: Foster,
skip: Skip,
run: Run,
/// The current tag token's attributes, which the rules adjust in place.
attributes: ArrayList(Attribute),
/// The pending table character tokens.
pending: ArrayList(u8),
pending_text: PendingText,

/// A parser for a whole document.
pub fn init(gpa: Allocator, options: Options) Allocator.Error!Parser {
    return initRoot(gpa, options, .document);
}

/// A parser for a fragment in `context`, as the HTML fragment parsing
/// algorithm defines it. The document's root is a fragment.
pub fn initFragment(gpa: Allocator, context: Context, options: Options) Allocator.Error!Parser {
    var p = try initRoot(gpa, options, .fragment);
    errdefer p.deinit();
    const root = try p.createElement(.html, "html", &.{});
    try p.open.append(gpa, root);
    p.fragment_root = root;
    p.context = try p.createElement(context.namespace, context.name, context.attributes);
    const ctx = p.el(p.context);
    if (ctx.namespace == .html) {
        switch (ctx.tag) {
            .title, .textarea => p.tokenizer.setState(.rcdata),
            .style, .xmp, .iframe, .noembed, .noframes => p.tokenizer.setState(.rawtext),
            .script => p.tokenizer.setState(.script_data),
            .noscript => if (options.scripting == .enabled) p.tokenizer.setState(.rawtext),
            .plaintext => p.tokenizer.setState(.plaintext),
            .template => try p.template_modes.append(gpa, .in_template),
            .form => p.form = p.context,
            else => {},
        }
    }
    p.resetMode();
    p.updateCdata();
    return p;
}

fn initRoot(gpa: Allocator, options: Options, root: enum { document, fragment }) Allocator.Error!Parser {
    return .{
        .gpa = gpa,
        .options = options,
        .tokenizer = .init(gpa, .{}),
        .doc = try .init(gpa, switch (root) {
            .document => .document,
            .fragment => .fragment,
        }),
        .mode = .initial,
        .original_mode = .initial,
        .template_modes = .empty,
        .open = .empty,
        .formatting = .empty,
        .head = .none,
        .form = .none,
        .context = .none,
        .fragment_root = .none,
        .frameset_ok = .ok,
        .foster = .off,
        .skip = .none,
        .run = .parsing,
        .attributes = .empty,
        .pending = .empty,
        .pending_text = .whitespace,
    };
}

pub fn deinit(self: *Parser) void {
    const gpa = self.gpa;
    self.tokenizer.deinit();
    if (self.run == .parsing) self.doc.deinit();
    self.template_modes.deinit(gpa);
    self.open.deinit(gpa);
    self.formatting.deinit(gpa);
    self.attributes.deinit(gpa);
    self.pending.deinit(gpa);
    self.* = undefined;
}

/// Parse more of the input. The bytes are copied, so the caller may reuse them.
pub fn feed(self: *Parser, bytes: []const u8) Allocator.Error!void {
    assert(self.run == .parsing);
    try self.tokenizer.feed(bytes);
    while (try self.tokenizer.next()) |token| try self.process(token);
}

/// End the input and return the document, which the caller then owns and
/// frees with `Document.deinit`. Call `deinit` on the parser as well.
pub fn finish(self: *Parser) Allocator.Error!Document {
    assert(self.run == .parsing);
    self.tokenizer.finish();
    while (true) {
        const token = (try self.tokenizer.next()).?;
        try self.process(token);
        if (token == .eof) break;
    }
    // The end (§13.2.7): pop every open element.
    self.open.clearRetainingCapacity();
    self.run = .finished;
    return self.doc;
}

/// Parse a whole document.
pub fn parse(gpa: Allocator, bytes: []const u8, options: Options) Allocator.Error!Document {
    var p: Parser = try .init(gpa, options);
    defer p.deinit();
    try p.feed(bytes);
    return p.finish();
}

/// Parse a fragment in `context`. The document's root is the fragment.
pub fn parseFragment(
    gpa: Allocator,
    bytes: []const u8,
    context: Context,
    options: Options,
) Allocator.Error!Document {
    var p: Parser = try .initFragment(gpa, context, options);
    defer p.deinit();
    try p.feed(bytes);
    return p.finish();
}

fn process(self: *Parser, token: Tokenizer.Token) Allocator.Error!void {
    const skip = self.skip;
    self.skip = .none;
    switch (token) {
        .text => |text| {
            var rest = text;
            if (skip == .newline and rest[0] == '\n') rest = rest[1..];
            while (rest.len != 0) {
                const class = classOf(rest[0]);
                var n: usize = 1;
                while (n < rest.len and classOf(rest[n]) == class) n += 1;
                try self.dispatch(.{ .chars = .{ .class = class, .data = rest[0..n] } });
                rest = rest[n..];
            }
        },
        .start_tag => |t| try self.dispatch(.{ .start_tag = try self.tagToken(t) }),
        .end_tag => |t| try self.dispatch(.{ .end_tag = try self.tagToken(t) }),
        .doctype => |d| try self.dispatch(.{ .doctype = d }),
        .comment => |c| try self.dispatch(.{ .comment = c }),
        .processing_instruction => |pi| try self.dispatch(.{ .processing_instruction = pi }),
        .eof => try self.dispatch(.eof),
    }
    self.updateCdata();
}

fn classOf(byte: u8) CharClass {
    return switch (byte) {
        '\t', '\n', 0x0C, '\r', ' ' => .whitespace,
        0 => .null,
        else => .other,
    };
}

fn tagToken(self: *Parser, t: Tokenizer.Tag) Allocator.Error!TagToken {
    self.attributes.clearRetainingCapacity();
    try self.attributes.ensureUnusedCapacity(self.gpa, t.attributes.len);
    for (t.attributes) |a| {
        self.attributes.appendAssumeCapacity(.{ .name = a.name, .value = a.value });
    }
    return .{
        .tag = .fromName(t.name),
        .name = t.name,
        .attributes = self.attributes.items,
        .self_closing = t.self_closing,
    };
}

/// A token the rules make up, such as the `tbody` start tag `<tr>` implies.
fn fake(tag: Tag) TagToken {
    return .{ .tag = tag, .name = @tagName(tag), .attributes = &.{}, .self_closing = false };
}

/// `<![CDATA[` opens a CDATA section only in foreign content.
fn updateCdata(self: *Parser) void {
    const foreign = self.open.items.len != 0 and self.el(self.adjustedCurrent()).namespace != .html;
    self.tokenizer.cdata = if (foreign) .foreign else .html;
}

// The tree construction dispatcher.

fn dispatch(self: *Parser, token: Token) Allocator.Error!void {
    var tok = token;
    while (true) {
        const next = if (self.isForeign(&tok))
            try self.foreignContent(&tok)
        else
            try self.step(self.mode, &tok);
        if (next == .done) return;
    }
}

fn isForeign(self: *Parser, tok: *const Token) bool {
    if (self.open.items.len == 0 or tok.* == .eof) return false;
    const node = self.adjustedCurrent();
    const e = self.el(node);
    if (e.namespace == .html) return false;
    switch (tok.*) {
        .start_tag => |t| {
            if (isMathmlTextIntegrationPoint(e) and t.tag != .mglyph and t.tag != .malignmark) return false;
            if (e.namespace == .mathml and e.tag == .@"annotation-xml" and t.tag == .svg) return false;
            return !isHtmlIntegrationPoint(e);
        },
        .chars => return !isMathmlTextIntegrationPoint(e) and !isHtmlIntegrationPoint(e),
        else => return true,
    }
}

fn isMathmlTextIntegrationPoint(e: *const Element) bool {
    return e.namespace == .mathml and switch (e.tag) {
        .mi, .mo, .mn, .ms, .mtext => true,
        else => false,
    };
}

fn isHtmlIntegrationPoint(e: *const Element) bool {
    return switch (e.namespace) {
        .html => false,
        .svg => e.tag == .foreignObject or e.tag == .desc or e.tag == .title,
        .mathml => {
            if (e.tag != .@"annotation-xml") return false;
            const encoding = e.attribute("encoding") orelse return false;
            return ascii.eqlIgnoreCase(encoding, "text/html") or
                ascii.eqlIgnoreCase(encoding, "application/xhtml+xml");
        },
    };
}

fn step(self: *Parser, mode: Mode, tok: *Token) Allocator.Error!Next {
    return switch (mode) {
        .initial => self.initial(tok),
        .before_html => self.beforeHtml(tok),
        .before_head => self.beforeHead(tok),
        .in_head => self.inHead(tok),
        .in_head_noscript => self.inHeadNoscript(tok),
        .after_head => self.afterHead(tok),
        .in_body => self.inBody(tok),
        .text => self.inText(tok),
        .in_table => self.inTable(tok),
        .in_table_text => self.inTableText(tok),
        .in_caption => self.inCaption(tok),
        .in_column_group => self.inColumnGroup(tok),
        .in_table_body => self.inTableBody(tok),
        .in_row => self.inRow(tok),
        .in_cell => self.inCell(tok),
        .in_template => self.inTemplate(tok),
        .after_body => self.afterBody(tok),
        .in_frameset => self.inFrameset(tok),
        .after_frameset => self.afterFrameset(tok),
        .after_after_body => self.afterAfterBody(tok),
        .after_after_frameset => self.afterAfterFrameset(tok),
    };
}

fn isWhitespace(tok: *const Token) bool {
    return tok.* == .chars and tok.chars.class == .whitespace;
}

fn isStart(tok: *const Token, tags: []const Tag) bool {
    return tok.* == .start_tag and mem.findScalar(Tag, tags, tok.start_tag.tag) != null;
}

fn isEnd(tok: *const Token, tags: []const Tag) bool {
    return tok.* == .end_tag and mem.findScalar(Tag, tags, tok.end_tag.tag) != null;
}

/// Comments and processing instructions go in the current place, and every
/// mode but the initial ones ignores a DOCTYPE. True when `tok` was one.
fn commonToken(self: *Parser, tok: *const Token) Allocator.Error!bool {
    switch (tok.*) {
        .comment => |data| try self.insertComment(data, null),
        .processing_instruction => |pi| try self.insertPi(pi, null),
        .doctype => {},
        else => return false,
    }
    return true;
}

// The insertion modes, §13.2.6.4.

fn initial(self: *Parser, tok: *Token) Allocator.Error!Next {
    const root: Location = .{ .parent = .root };
    switch (tok.*) {
        .chars => |c| if (c.class == .whitespace) return .done,
        .comment => |data| {
            try self.insertComment(data, root);
            return .done;
        },
        .processing_instruction => |pi| {
            try self.insertPi(pi, root);
            return .done;
        },
        .doctype => |d| {
            try self.insertDoctype(d);
            self.mode = .before_html;
            return .done;
        },
        else => {},
    }
    self.doc.mode = .quirks;
    self.mode = .before_html;
    return .reprocess;
}

fn insertDoctype(self: *Parser, d: Tokenizer.Doctype) Allocator.Error!void {
    const node = try self.doc.create(.{ .doctype = .{
        .name = try self.doc.dupe(d.name orelse ""),
        .public_id = try self.doc.dupe(d.public_id orelse ""),
        .system_id = try self.doc.dupe(d.system_id orelse ""),
    } });
    var it = self.doc.children(.root);
    const has_child = while (it.next()) |child| {
        switch (self.doc.node(child).data) {
            .doctype, .element => break true,
            else => {},
        }
    } else false;
    if (!has_child) self.doc.append(.root, node);
    self.doc.mode = doctypeMode(d);
}

fn doctypeMode(d: Tokenizer.Doctype) Document.Mode {
    if (d.force_quirks or d.name == null or !mem.eql(u8, d.name.?, "html")) return .quirks;
    const system = d.system_id orelse "";
    if (ascii.eqlIgnoreCase(system, "http://www.ibm.com/data/dtd/v11/ibmxhtml1-transitional.dtd")) return .quirks;
    const public = d.public_id orelse return .no_quirks;
    for (quirks_public_ids) |id| {
        if (ascii.eqlIgnoreCase(public, id)) return .quirks;
    }
    for (quirks_public_prefixes) |prefix| {
        if (startsWithIgnoreCase(public, prefix)) return .quirks;
    }
    for (html401_public_prefixes) |prefix| {
        if (startsWithIgnoreCase(public, prefix)) return if (system.len == 0) .quirks else .limited_quirks;
    }
    for (limited_quirks_public_prefixes) |prefix| {
        if (startsWithIgnoreCase(public, prefix)) return .limited_quirks;
    }
    return .no_quirks;
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    return haystack.len >= prefix.len and ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

fn beforeHtml(self: *Parser, tok: *Token) Allocator.Error!Next {
    const root: Location = .{ .parent = .root };
    switch (tok.*) {
        .doctype => return .done,
        .comment => |data| {
            try self.insertComment(data, root);
            return .done;
        },
        .processing_instruction => |pi| {
            try self.insertPi(pi, root);
            return .done;
        },
        .chars => |c| if (c.class == .whitespace) return .done,
        .start_tag => |*t| if (t.tag == .html) {
            const html = try self.createElement(.html, t.name, t.attributes);
            try self.insertElement(html, root);
            try self.open.append(self.gpa, html);
            self.mode = .before_head;
            return .done;
        },
        .end_tag => |t| switch (t.tag) {
            .head, .body, .html, .br => {},
            else => return .done,
        },
        .eof => {},
    }
    const html = try self.createElement(.html, "html", &.{});
    try self.insertElement(html, root);
    try self.open.append(self.gpa, html);
    self.mode = .before_head;
    return .reprocess;
}

fn beforeHead(self: *Parser, tok: *Token) Allocator.Error!Next {
    if (isWhitespace(tok)) return .done;
    if (try self.commonToken(tok)) return .done;
    if (isStart(tok, &.{.html})) return self.step(.in_body, tok);
    if (isStart(tok, &.{.head})) {
        self.head = try self.insertHtml(&tok.start_tag);
        self.mode = .in_head;
        return .done;
    }
    if (tok.* == .end_tag and !isEnd(tok, &.{ .head, .body, .html, .br })) return .done;
    var head = fake(.head);
    self.head = try self.insertHtml(&head);
    self.mode = .in_head;
    return .reprocess;
}

fn inHead(self: *Parser, tok: *Token) Allocator.Error!Next {
    if (isWhitespace(tok)) {
        try self.insertChars(tok.chars.data);
        return .done;
    }
    if (try self.commonToken(tok)) return .done;
    switch (tok.*) {
        .start_tag => |*t| switch (t.tag) {
            .html => return self.step(.in_body, tok),
            .base, .basefont, .bgsound, .link, .meta => {
                _ = try self.insertHtml(t);
                _ = self.open.pop();
                return .done;
            },
            .title => return self.rawText(t, .rcdata),
            .noscript => if (self.options.scripting == .enabled) return self.rawText(t, .rawtext) else {
                _ = try self.insertHtml(t);
                self.mode = .in_head_noscript;
                return .done;
            },
            .noframes, .style => return self.rawText(t, .rawtext),
            .script => return self.rawText(t, .script_data),
            .template => {
                try self.formatting.append(self.gpa, marker);
                self.frameset_ok = .not_ok;
                self.mode = .in_template;
                try self.template_modes.append(self.gpa, .in_template);
                _ = try self.insertHtml(t);
                return .done;
            },
            .head => return .done,
            else => {},
        },
        .end_tag => |t| switch (t.tag) {
            .head => {
                _ = self.open.pop();
                self.mode = .after_head;
                return .done;
            },
            .body, .html, .br => {},
            .template => {
                self.endTemplate();
                return .done;
            },
            else => return .done,
        },
        else => {},
    }
    _ = self.open.pop();
    self.mode = .after_head;
    return .reprocess;
}

fn endTemplate(self: *Parser) void {
    if (!self.templateOnStack()) return;
    while (self.isHtmlIn(self.current(), thoroughly_implied)) _ = self.open.pop();
    self.popUntil(.template);
    self.clearToMarker();
    _ = self.template_modes.pop();
    self.resetMode();
}

fn inHeadNoscript(self: *Parser, tok: *Token) Allocator.Error!Next {
    switch (tok.*) {
        .doctype => return .done,
        .start_tag => |t| switch (t.tag) {
            .html => return self.step(.in_body, tok),
            .basefont, .bgsound, .link, .meta, .noframes, .style => return self.step(.in_head, tok),
            .head, .noscript => return .done,
            else => {},
        },
        .end_tag => |t| switch (t.tag) {
            .noscript => {
                _ = self.open.pop();
                self.mode = .in_head;
                return .done;
            },
            .br => {},
            else => return .done,
        },
        .chars => |c| if (c.class == .whitespace) return self.step(.in_head, tok),
        .comment, .processing_instruction => return self.step(.in_head, tok),
        .eof => {},
    }
    _ = self.open.pop();
    self.mode = .in_head;
    return .reprocess;
}

fn afterHead(self: *Parser, tok: *Token) Allocator.Error!Next {
    if (isWhitespace(tok)) {
        try self.insertChars(tok.chars.data);
        return .done;
    }
    if (try self.commonToken(tok)) return .done;
    switch (tok.*) {
        .start_tag => |*t| switch (t.tag) {
            .html => return self.step(.in_body, tok),
            .body => {
                _ = try self.insertHtml(t);
                self.frameset_ok = .not_ok;
                self.mode = .in_body;
                return .done;
            },
            .frameset => {
                _ = try self.insertHtml(t);
                self.mode = .in_frameset;
                return .done;
            },
            .base, .basefont, .bgsound, .link, .meta, .noframes, .script, .style, .template, .title => {
                try self.open.append(self.gpa, self.head);
                const next = try self.step(.in_head, tok);
                self.removeOpen(self.head);
                return next;
            },
            .head => return .done,
            else => {},
        },
        .end_tag => |t| switch (t.tag) {
            .template => return self.step(.in_head, tok),
            .body, .html, .br => {},
            else => return .done,
        },
        else => {},
    }
    var body = fake(.body);
    _ = try self.insertHtml(&body);
    self.frameset_ok = .ok;
    self.mode = .in_body;
    return .reprocess;
}

fn inBody(self: *Parser, tok: *Token) Allocator.Error!Next {
    switch (tok.*) {
        .chars => |c| switch (c.class) {
            .null => {},
            .whitespace => {
                try self.reconstruct();
                try self.insertChars(c.data);
            },
            .other => {
                try self.reconstruct();
                try self.insertChars(c.data);
                self.frameset_ok = .not_ok;
            },
        },
        .comment, .processing_instruction, .doctype => _ = try self.commonToken(tok),
        .eof => if (self.template_modes.items.len != 0) return self.step(.in_template, tok),
        .start_tag => return self.inBodyStartTag(tok),
        .end_tag => return self.inBodyEndTag(tok),
    }
    return .done;
}

fn inBodyStartTag(self: *Parser, tok: *Token) Allocator.Error!Next {
    const t = &tok.start_tag;
    switch (t.tag) {
        .html => if (!self.templateOnStack()) try self.mergeAttributes(self.open.items[0], t.attributes),
        .base, .basefont, .bgsound, .link, .meta, .noframes, .script, .style, .template, .title => {
            return self.step(.in_head, tok);
        },
        .body => try self.bodyStartTag(t),
        .frameset => try self.framesetStartTag(t),
        .address, .article, .aside, .blockquote, .center, .details, .dialog, .dir, .div, .dl => {
            try self.closePInButtonScope();
            _ = try self.insertHtml(t);
        },
        .fieldset, .figcaption, .figure, .footer, .header, .hgroup, .main, .menu, .nav, .ol, .p => {
            try self.closePInButtonScope();
            _ = try self.insertHtml(t);
        },
        .search, .section, .summary, .ul => {
            try self.closePInButtonScope();
            _ = try self.insertHtml(t);
        },
        .h1, .h2, .h3, .h4, .h5, .h6 => {
            try self.closePInButtonScope();
            if (self.isHtmlIn(self.current(), headings)) _ = self.open.pop();
            _ = try self.insertHtml(t);
        },
        .pre, .listing => {
            try self.closePInButtonScope();
            _ = try self.insertHtml(t);
            self.skip = .newline;
            self.frameset_ok = .not_ok;
        },
        .form => try self.formStartTag(t),
        .li, .dd, .dt => try self.listItemStartTag(t),
        .plaintext => {
            try self.closePInButtonScope();
            _ = try self.insertHtml(t);
            self.tokenizer.setState(.plaintext);
        },
        .button => {
            if (self.hasInScope(.button, .default)) {
                self.generateImpliedEndTags(null);
                self.popUntil(.button);
            }
            try self.reconstruct();
            _ = try self.insertHtml(t);
            self.frameset_ok = .not_ok;
        },
        .a, .nobr => try self.formattingStartTag(t),
        .b, .big, .code, .em, .font, .i, .s, .small, .strike, .strong, .tt, .u => {
            try self.formattingStartTag(t);
        },
        .applet, .marquee, .object => {
            try self.reconstruct();
            _ = try self.insertHtml(t);
            try self.formatting.append(self.gpa, marker);
            self.frameset_ok = .not_ok;
        },
        else => return self.inBodyLaterStartTag(tok),
    }
    return .done;
}

/// The "in body" start tag entries from `table` on, in the standard's order.
fn inBodyLaterStartTag(self: *Parser, tok: *Token) Allocator.Error!Next {
    const t = &tok.start_tag;
    switch (t.tag) {
        .table => {
            if (self.doc.mode != .quirks) try self.closePInButtonScope();
            _ = try self.insertHtml(t);
            self.frameset_ok = .not_ok;
            self.mode = .in_table;
        },
        .area, .br, .embed, .img, .keygen, .wbr, .image => try self.voidStartTag(t),
        .input => try self.inputStartTag(t),
        .param, .source, .track => {
            _ = try self.insertHtml(t);
            _ = self.open.pop();
        },
        .hr => {
            try self.closePInButtonScope();
            if (self.hasInScope(.select, .default)) self.generateImpliedEndTags(null);
            _ = try self.insertHtml(t);
            _ = self.open.pop();
            self.frameset_ok = .not_ok;
        },
        .textarea => {
            _ = try self.insertHtml(t);
            self.skip = .newline;
            self.tokenizer.setState(.rcdata);
            self.original_mode = self.mode;
            self.frameset_ok = .not_ok;
            self.mode = .text;
        },
        .xmp => {
            try self.closePInButtonScope();
            try self.reconstruct();
            self.frameset_ok = .not_ok;
            return self.rawText(t, .rawtext);
        },
        .iframe => {
            self.frameset_ok = .not_ok;
            return self.rawText(t, .rawtext);
        },
        .noembed => return self.rawText(t, .rawtext),
        .noscript => if (self.options.scripting == .enabled) return self.rawText(t, .rawtext) else {
            try self.reconstruct();
            _ = try self.insertHtml(t);
        },
        .select, .option, .optgroup => try self.selectStartTag(t),
        .rb, .rtc, .rp, .rt => {
            if (self.hasInScope(.ruby, .default)) {
                self.generateImpliedEndTags(if (t.tag == .rp or t.tag == .rt) .rtc else null);
            }
            _ = try self.insertHtml(t);
        },
        .math, .svg => {
            try self.reconstruct();
            const namespace: Namespace = if (t.tag == .math) .mathml else .svg;
            adjustAttributes(namespace, t.attributes);
            _ = try self.insertForeign(t, namespace);
            if (t.self_closing) _ = self.open.pop();
        },
        .caption, .col, .colgroup, .frame, .head, .tbody, .td, .tfoot, .th, .thead, .tr => {},
        else => {
            try self.reconstruct();
            _ = try self.insertHtml(t);
        },
    }
    return .done;
}

fn bodyStartTag(self: *Parser, t: *const TagToken) Allocator.Error!void {
    const items = self.open.items;
    if (items.len == 1 or !self.isHtml(items[1], .body) or self.templateOnStack()) return;
    self.frameset_ok = .not_ok;
    try self.mergeAttributes(items[1], t.attributes);
}

fn framesetStartTag(self: *Parser, t: *const TagToken) Allocator.Error!void {
    const items = self.open.items;
    if (items.len == 1 or !self.isHtml(items[1], .body)) return;
    if (self.frameset_ok == .not_ok) return;
    self.doc.remove(items[1]);
    self.open.shrinkRetainingCapacity(1);
    _ = try self.insertHtml(t);
    self.mode = .in_frameset;
}

/// Add the attributes `element` lacks, for a stray `<html>` or `<body>`.
fn mergeAttributes(self: *Parser, node: Node.Index, attributes: []const Attribute) Allocator.Error!void {
    const e = &self.doc.nodeMut(node).data.element;
    var merged: ArrayList(Attribute) = .empty;
    const arena = self.doc.arena.allocator();
    try merged.appendSlice(arena, e.attributes);
    for (attributes) |a| {
        if (e.attribute(a.name) != null) continue;
        try merged.append(arena, .{ .name = try self.doc.dupe(a.name), .value = try self.doc.dupe(a.value) });
    }
    e.attributes = merged.items;
}

fn formStartTag(self: *Parser, t: *const TagToken) Allocator.Error!void {
    const in_template = self.parsingTemplateContents();
    if (self.form != .none and !in_template) return;
    try self.closePInButtonScope();
    const form = try self.insertHtml(t);
    if (!in_template) self.form = form;
}

fn listItemStartTag(self: *Parser, t: *const TagToken) Allocator.Error!void {
    self.frameset_ok = .not_ok;
    var i = self.open.items.len;
    while (i > 0) {
        i -= 1;
        const node = self.open.items[i];
        const closes = switch (t.tag) {
            .li => self.isHtml(node, .li),
            else => self.isHtml(node, .dd) or self.isHtml(node, .dt),
        };
        if (closes) {
            const tag = self.el(node).tag;
            self.generateImpliedEndTags(tag);
            self.popUntil(tag);
            break;
        }
        if (self.isSpecial(node) and !self.isHtml(node, .address) and
            !self.isHtml(node, .div) and !self.isHtml(node, .p)) break;
    }
    try self.closePInButtonScope();
    _ = try self.insertHtml(t);
}

fn formattingStartTag(self: *Parser, t: *const TagToken) Allocator.Error!void {
    switch (t.tag) {
        .a => if (self.formattingAfterMarker("a")) |a| {
            if (try self.adoptionAgency("a") == .any_other_end_tag) self.anyOtherEndTag(t);
            if (self.formattingIndex(a)) |i| _ = self.formatting.orderedRemove(i);
            self.removeOpen(a);
        },
        .nobr => {
            try self.reconstruct();
            if (self.hasInScope(.nobr, .default)) {
                // A marker can hide the open `nobr` from the algorithm, which
                // then closes it as an end tag would.
                if (try self.adoptionAgency("nobr") == .any_other_end_tag) self.anyOtherEndTag(t);
            }
        },
        else => {},
    }
    try self.reconstruct();
    const node = try self.insertHtml(t);
    try self.pushFormatting(node);
}

fn voidStartTag(self: *Parser, t: *TagToken) Allocator.Error!void {
    if (t.tag == .image) {
        t.tag = .img;
        t.name = "img";
    }
    try self.reconstruct();
    _ = try self.insertHtml(t);
    _ = self.open.pop();
    self.frameset_ok = .not_ok;
}

fn inputStartTag(self: *Parser, t: *const TagToken) Allocator.Error!void {
    if (self.contextIs(.select)) return;
    if (self.hasInScope(.select, .default)) self.popUntil(.select);
    try self.reconstruct();
    _ = try self.insertHtml(t);
    _ = self.open.pop();
    if (!isHiddenInput(t)) self.frameset_ok = .not_ok;
}

fn isHiddenInput(t: *const TagToken) bool {
    for (t.attributes) |a| {
        if (mem.eql(u8, a.name, "type")) return ascii.eqlIgnoreCase(a.value, "hidden");
    }
    return false;
}

fn selectStartTag(self: *Parser, t: *const TagToken) Allocator.Error!void {
    const in_select = self.hasInScope(.select, .default);
    switch (t.tag) {
        .select => {
            if (self.contextIs(.select)) return;
            if (in_select) return self.popUntil(.select);
            try self.reconstruct();
            _ = try self.insertHtml(t);
            self.frameset_ok = .not_ok;
            return;
        },
        .option => if (in_select) {
            self.generateImpliedEndTags(.optgroup);
        } else if (self.isHtml(self.current(), .option)) {
            _ = self.open.pop();
        },
        else => if (in_select) {
            self.generateImpliedEndTags(null);
        } else if (self.isHtml(self.current(), .option)) {
            _ = self.open.pop();
        },
    }
    try self.reconstruct();
    _ = try self.insertHtml(t);
}

fn inBodyEndTag(self: *Parser, tok: *Token) Allocator.Error!Next {
    const t = &tok.end_tag;
    switch (t.tag) {
        .template => return self.step(.in_head, tok),
        .body, .html => {
            if (!self.hasInScope(.body, .default)) return .done;
            self.mode = .after_body;
            if (t.tag == .html) return .reprocess;
        },
        .address, .article, .aside, .blockquote, .button, .center, .details, .dialog, .dir, .div => {
            self.closeBlock(t.tag);
        },
        .dl, .fieldset, .figcaption, .figure, .footer, .header, .hgroup, .listing, .main, .menu => {
            self.closeBlock(t.tag);
        },
        .nav, .ol, .pre, .search, .section, .select, .summary, .ul => self.closeBlock(t.tag),
        .form => self.formEndTag(),
        .p => {
            if (!self.hasInScope(.p, .button)) {
                var p = fake(.p);
                _ = try self.insertHtml(&p);
            }
            self.closeP();
        },
        .li, .dd, .dt => {
            if (!self.hasInScope(t.tag, if (t.tag == .li) .list_item else .default)) return .done;
            self.generateImpliedEndTags(t.tag);
            self.popUntil(t.tag);
        },
        .h1, .h2, .h3, .h4, .h5, .h6 => {
            if (!self.hasAnyInScope(headings)) return .done;
            self.generateImpliedEndTags(null);
            while (!self.isHtmlIn(self.open.pop().?, headings)) {}
        },
        .a, .b, .big, .code, .em, .font, .i, .nobr, .s, .small, .strike, .strong, .tt, .u => {
            if (try self.adoptionAgency(t.name) == .any_other_end_tag) self.anyOtherEndTag(t);
        },
        .applet, .marquee, .object => {
            if (!self.hasInScope(t.tag, .default)) return .done;
            self.generateImpliedEndTags(null);
            self.popUntil(t.tag);
            self.clearToMarker();
        },
        .br => {
            var br = fake(.br);
            try self.voidStartTag(&br);
        },
        else => self.anyOtherEndTag(t),
    }
    return .done;
}

fn closeBlock(self: *Parser, tag: Tag) void {
    if (!self.hasInScope(tag, .default)) return;
    self.generateImpliedEndTags(null);
    self.popUntil(tag);
}

fn formEndTag(self: *Parser) void {
    if (!self.parsingTemplateContents()) {
        const node = self.form;
        self.form = .none;
        if (node == .none or !self.hasNodeInScope(node)) return;
        self.generateImpliedEndTags(null);
        self.removeOpen(node);
    } else {
        if (!self.hasInScope(.form, .default)) return;
        self.generateImpliedEndTags(null);
        self.popUntil(.form);
    }
}

fn anyOtherEndTag(self: *Parser, t: *const TagToken) void {
    var i = self.open.items.len;
    while (i > 0) {
        i -= 1;
        const node = self.open.items[i];
        const e = self.el(node);
        if (e.namespace == .html and mem.eql(u8, e.name, t.name)) {
            self.generateImpliedEndTags(t.tag);
            self.open.shrinkRetainingCapacity(i);
            return;
        }
        if (self.isSpecial(node)) return;
    }
}

const Adoption = enum { done, any_other_end_tag };

/// The adoption agency algorithm, for an end tag named `subject`.
fn adoptionAgency(self: *Parser, subject: []const u8) Allocator.Error!Adoption {
    const current_node = self.current();
    if (self.isHtmlNamed(current_node, subject) and self.formattingIndex(current_node) == null) {
        _ = self.open.pop();
        return .done;
    }
    for (0..8) |_| {
        const formatting_element = self.formattingAfterMarker(subject) orelse return .any_other_end_tag;
        const fe_open = self.openIndex(formatting_element) orelse {
            _ = self.formatting.orderedRemove(self.formattingIndex(formatting_element).?);
            return .done;
        };
        if (!self.hasNodeInScope(formatting_element)) return .done;
        const furthest_open = for (self.open.items[fe_open + 1 ..], fe_open + 1..) |node, i| {
            if (self.isSpecial(node)) break i;
        } else {
            self.open.shrinkRetainingCapacity(fe_open);
            _ = self.formatting.orderedRemove(self.formattingIndex(formatting_element).?);
            return .done;
        };
        try self.adoptOnce(formatting_element, fe_open, furthest_open);
    }
    return .done;
}

/// One pass of the adoption agency's outer loop, from the furthest block on.
fn adoptOnce(self: *Parser, formatting_element: Node.Index, fe_open: usize, furthest_open: usize) Allocator.Error!void {
    const furthest_block = self.open.items[furthest_open];
    const common_ancestor = self.open.items[fe_open - 1];
    var bookmark = self.formattingIndex(formatting_element).?;
    var bookmark_moved = false;
    var last_node = furthest_block;
    var node_open = furthest_open;
    var inner: u32 = 0;
    while (true) {
        inner += 1;
        node_open -= 1;
        var node = self.open.items[node_open];
        if (node == formatting_element) break;
        var fi = self.formattingIndex(node);
        if (inner > 3 and fi != null) {
            _ = self.formatting.orderedRemove(fi.?);
            if (fi.? < bookmark) bookmark -= 1;
            fi = null;
        }
        const i = fi orelse {
            _ = self.open.orderedRemove(node_open);
            continue;
        };
        node = try self.cloneElement(node);
        self.formatting.items[i] = node;
        self.open.items[node_open] = node;
        if (!bookmark_moved) {
            bookmark = i + 1;
            bookmark_moved = true;
        }
        self.doc.remove(last_node);
        self.doc.append(node, last_node);
        last_node = node;
    }
    const place = self.appropriatePlace(common_ancestor);
    self.doc.remove(last_node);
    if (!self.doc.isInclusiveAncestor(last_node, place.parent)) {
        self.doc.insertBefore(place.parent, last_node, place.before);
    }
    const new_element = try self.cloneElement(formatting_element);
    while (self.doc.node(furthest_block).first_child != .none) {
        const child = self.doc.node(furthest_block).first_child;
        self.doc.remove(child);
        self.doc.append(new_element, child);
    }
    self.doc.append(furthest_block, new_element);
    try self.formatting.insert(self.gpa, bookmark, new_element);
    _ = self.formatting.orderedRemove(self.formattingIndex(formatting_element).?);
    self.removeOpen(formatting_element);
    try self.open.insert(self.gpa, self.openIndex(furthest_block).? + 1, new_element);
}

fn inText(self: *Parser, tok: *Token) Allocator.Error!Next {
    switch (tok.*) {
        .chars => |c| try self.insertChars(c.data),
        .eof => {
            _ = self.open.pop();
            self.mode = self.original_mode;
            return .reprocess;
        },
        .end_tag => {
            _ = self.open.pop();
            self.mode = self.original_mode;
        },
        else => {},
    }
    return .done;
}

fn inTable(self: *Parser, tok: *Token) Allocator.Error!Next {
    switch (tok.*) {
        .chars => if (self.isHtmlIn(self.current(), table_text_targets)) {
            self.pending.clearRetainingCapacity();
            self.pending_text = .whitespace;
            self.original_mode = self.mode;
            self.mode = .in_table_text;
            return .reprocess;
        },
        .comment, .processing_instruction, .doctype => {
            _ = try self.commonToken(tok);
            return .done;
        },
        .start_tag => |*t| if (try self.inTableStartTag(tok, t)) |next| return next,
        .end_tag => |t| switch (t.tag) {
            .table => {
                if (self.hasInScope(.table, .table)) {
                    self.popUntil(.table);
                    self.resetMode();
                }
                return .done;
            },
            .body, .caption, .col, .colgroup, .html, .tbody, .td, .tfoot, .th, .thead, .tr => return .done,
            .template => return self.step(.in_head, tok),
            else => {},
        },
        .eof => return self.step(.in_body, tok),
    }
    self.foster = .on;
    defer self.foster = .off;
    return self.step(.in_body, tok);
}

/// The start tags "in table" handles itself, or null for "anything else".
fn inTableStartTag(self: *Parser, tok: *Token, t: *TagToken) Allocator.Error!?Next {
    switch (t.tag) {
        .caption, .colgroup, .tbody, .tfoot, .thead => {
            self.clearStackBackTo(table_context);
            if (t.tag == .caption) try self.formatting.append(self.gpa, marker);
            _ = try self.insertHtml(t);
            self.mode = switch (t.tag) {
                .caption => .in_caption,
                .colgroup => .in_column_group,
                else => .in_table_body,
            };
            return .done;
        },
        .col, .td, .th, .tr => {
            self.clearStackBackTo(table_context);
            var implied = fake(if (t.tag == .col) .colgroup else .tbody);
            _ = try self.insertHtml(&implied);
            self.mode = if (t.tag == .col) .in_column_group else .in_table_body;
            return .reprocess;
        },
        .table => {
            if (!self.hasInScope(.table, .table)) return .done;
            self.popUntil(.table);
            self.resetMode();
            return .reprocess;
        },
        .style, .script, .template => return try self.step(.in_head, tok),
        .input => {
            if (!isHiddenInput(t)) return null;
            _ = try self.insertHtml(t);
            _ = self.open.pop();
            return .done;
        },
        .form => {
            if (self.form != .none and !self.parsingTemplateContents()) return .done;
            const form = try self.insertHtml(t);
            if (!self.parsingTemplateContents()) self.form = form;
            _ = self.open.pop();
            return .done;
        },
        else => return null,
    }
}

fn inTableText(self: *Parser, tok: *Token) Allocator.Error!Next {
    if (tok.* == .chars) {
        const c = tok.chars;
        if (c.class == .null) return .done;
        if (c.class == .other) self.pending_text = .mixed;
        try self.pending.appendSlice(self.gpa, c.data);
        return .done;
    }
    switch (self.pending_text) {
        .whitespace => try self.insertChars(self.pending.items),
        .mixed => {
            // The "anything else" rules of "in table", one class at a time.
            self.foster = .on;
            defer self.foster = .off;
            var rest = self.pending.items;
            while (rest.len != 0) {
                const class = classOf(rest[0]);
                var n: usize = 1;
                while (n < rest.len and classOf(rest[n]) == class) n += 1;
                var chars: Token = .{ .chars = .{ .class = class, .data = rest[0..n] } };
                _ = try self.inBody(&chars);
                rest = rest[n..];
            }
        },
    }
    self.mode = self.original_mode;
    return .reprocess;
}

fn inCaption(self: *Parser, tok: *Token) Allocator.Error!Next {
    const closes = isEnd(tok, &.{ .caption, .table }) or
        isStart(tok, &.{ .caption, .col, .colgroup, .tbody, .td, .tfoot, .th, .thead, .tr });
    if (closes) {
        if (!self.hasInScope(.caption, .table)) return .done;
        self.generateImpliedEndTags(null);
        self.popUntil(.caption);
        self.clearToMarker();
        self.mode = .in_table;
        return if (isEnd(tok, &.{.caption})) .done else .reprocess;
    }
    if (isEnd(tok, &.{ .body, .col, .colgroup, .html, .tbody, .td, .tfoot, .th, .thead, .tr })) return .done;
    return self.step(.in_body, tok);
}

fn inColumnGroup(self: *Parser, tok: *Token) Allocator.Error!Next {
    if (isWhitespace(tok)) {
        try self.insertChars(tok.chars.data);
        return .done;
    }
    if (try self.commonToken(tok)) return .done;
    switch (tok.*) {
        .start_tag => |*t| switch (t.tag) {
            .html => return self.step(.in_body, tok),
            .col => {
                _ = try self.insertHtml(t);
                _ = self.open.pop();
                return .done;
            },
            .template => return self.step(.in_head, tok),
            else => {},
        },
        .end_tag => |t| switch (t.tag) {
            .colgroup => {
                if (!self.isHtml(self.current(), .colgroup)) return .done;
                _ = self.open.pop();
                self.mode = .in_table;
                return .done;
            },
            .col => return .done,
            .template => return self.step(.in_head, tok),
            else => {},
        },
        .eof => return self.step(.in_body, tok),
        else => {},
    }
    if (!self.isHtml(self.current(), .colgroup)) return .done;
    _ = self.open.pop();
    self.mode = .in_table;
    return .reprocess;
}

fn inTableBody(self: *Parser, tok: *Token) Allocator.Error!Next {
    switch (tok.*) {
        .start_tag => |*t| switch (t.tag) {
            .tr, .th, .td => {
                self.clearStackBackTo(table_body_context);
                if (t.tag == .tr) {
                    _ = try self.insertHtml(t);
                } else {
                    var tr = fake(.tr);
                    _ = try self.insertHtml(&tr);
                }
                self.mode = .in_row;
                return if (t.tag == .tr) .done else .reprocess;
            },
            .caption, .col, .colgroup, .tbody, .tfoot, .thead => return self.leaveTableBody(),
            else => {},
        },
        .end_tag => |t| switch (t.tag) {
            .tbody, .tfoot, .thead => {
                if (!self.hasInScope(t.tag, .table)) return .done;
                self.clearStackBackTo(table_body_context);
                _ = self.open.pop();
                self.mode = .in_table;
                return .done;
            },
            .table => return self.leaveTableBody(),
            .body, .caption, .col, .colgroup, .html, .td, .th, .tr => return .done,
            else => {},
        },
        else => {},
    }
    return self.step(.in_table, tok);
}

fn leaveTableBody(self: *Parser) Next {
    if (!self.hasInScope(.tbody, .table) and !self.hasInScope(.thead, .table) and
        !self.hasInScope(.tfoot, .table)) return .done;
    self.clearStackBackTo(table_body_context);
    _ = self.open.pop();
    self.mode = .in_table;
    return .reprocess;
}

fn inRow(self: *Parser, tok: *Token) Allocator.Error!Next {
    switch (tok.*) {
        .start_tag => |*t| switch (t.tag) {
            .th, .td => {
                self.clearStackBackTo(table_row_context);
                _ = try self.insertHtml(t);
                self.mode = .in_cell;
                try self.formatting.append(self.gpa, marker);
                return .done;
            },
            .caption, .col, .colgroup, .tbody, .tfoot, .thead, .tr => return self.leaveRow(.reprocess),
            else => {},
        },
        .end_tag => |t| switch (t.tag) {
            .tr => return self.leaveRow(.done),
            .table => return self.leaveRow(.reprocess),
            .tbody, .tfoot, .thead => {
                if (!self.hasInScope(t.tag, .table)) return .done;
                return self.leaveRow(.reprocess);
            },
            .body, .caption, .col, .colgroup, .html, .td, .th => return .done,
            else => {},
        },
        else => {},
    }
    return self.step(.in_table, tok);
}

fn leaveRow(self: *Parser, next: Next) Next {
    if (!self.hasInScope(.tr, .table)) return .done;
    self.clearStackBackTo(table_row_context);
    _ = self.open.pop();
    self.mode = .in_table_body;
    return next;
}

fn inCell(self: *Parser, tok: *Token) Allocator.Error!Next {
    switch (tok.*) {
        .end_tag => |t| switch (t.tag) {
            .td, .th => {
                if (!self.hasInScope(t.tag, .table)) return .done;
                self.generateImpliedEndTags(null);
                self.popUntil(t.tag);
                self.clearToMarker();
                self.mode = .in_row;
                return .done;
            },
            .body, .caption, .col, .colgroup, .html => return .done,
            .table, .tbody, .tfoot, .thead, .tr => {
                if (!self.hasInScope(t.tag, .table)) return .done;
                self.closeCell();
                return .reprocess;
            },
            else => {},
        },
        .start_tag => |t| switch (t.tag) {
            .caption, .col, .colgroup, .tbody, .td, .tfoot, .th, .thead, .tr => {
                assert(self.hasInScope(.td, .table) or self.hasInScope(.th, .table));
                self.closeCell();
                return .reprocess;
            },
            else => {},
        },
        else => {},
    }
    return self.step(.in_body, tok);
}

fn closeCell(self: *Parser) void {
    self.generateImpliedEndTags(null);
    while (true) {
        const node = self.open.pop().?;
        if (self.isHtml(node, .td) or self.isHtml(node, .th)) break;
    }
    self.clearToMarker();
    self.mode = .in_row;
}

fn inTemplate(self: *Parser, tok: *Token) Allocator.Error!Next {
    const mode: Mode = switch (tok.*) {
        .chars, .comment, .processing_instruction, .doctype => return self.step(.in_body, tok),
        .start_tag => |t| switch (t.tag) {
            .base, .basefont, .bgsound, .link, .meta, .noframes, .script, .style, .template, .title => {
                return self.step(.in_head, tok);
            },
            .caption, .colgroup, .tbody, .tfoot, .thead => .in_table,
            .col => .in_column_group,
            .tr => .in_table_body,
            .td, .th => .in_row,
            else => .in_body,
        },
        .end_tag => |t| return if (t.tag == .template) self.step(.in_head, tok) else .done,
        .eof => {
            if (!self.templateOnStack()) return .done;
            self.popUntil(.template);
            self.clearToMarker();
            _ = self.template_modes.pop();
            self.resetMode();
            return .reprocess;
        },
    };
    self.template_modes.items[self.template_modes.items.len - 1] = mode;
    self.mode = mode;
    return .reprocess;
}

fn afterBody(self: *Parser, tok: *Token) Allocator.Error!Next {
    const html: Location = .{ .parent = self.open.items[0] };
    switch (tok.*) {
        .chars => |c| if (c.class == .whitespace) return self.step(.in_body, tok),
        .comment => |data| {
            try self.insertComment(data, html);
            return .done;
        },
        .processing_instruction => |pi| {
            try self.insertPi(pi, html);
            return .done;
        },
        .doctype, .eof => return .done,
        .start_tag => |t| if (t.tag == .html) return self.step(.in_body, tok),
        .end_tag => |t| if (t.tag == .html) {
            if (self.context == .none) self.mode = .after_after_body;
            return .done;
        },
    }
    self.mode = .in_body;
    return .reprocess;
}

fn inFrameset(self: *Parser, tok: *Token) Allocator.Error!Next {
    if (isWhitespace(tok)) {
        try self.insertChars(tok.chars.data);
        return .done;
    }
    if (try self.commonToken(tok)) return .done;
    switch (tok.*) {
        .start_tag => |*t| switch (t.tag) {
            .html => return self.step(.in_body, tok),
            .frameset => _ = try self.insertHtml(t),
            .frame => {
                _ = try self.insertHtml(t);
                _ = self.open.pop();
            },
            .noframes => return self.step(.in_head, tok),
            else => {},
        },
        .end_tag => |t| if (t.tag == .frameset and self.open.items.len > 1) {
            _ = self.open.pop();
            if (self.context == .none and !self.isHtml(self.current(), .frameset)) {
                self.mode = .after_frameset;
            }
        },
        else => {},
    }
    return .done;
}

fn afterFrameset(self: *Parser, tok: *Token) Allocator.Error!Next {
    if (isWhitespace(tok)) {
        try self.insertChars(tok.chars.data);
        return .done;
    }
    if (try self.commonToken(tok)) return .done;
    if (isStart(tok, &.{.html})) return self.step(.in_body, tok);
    if (isStart(tok, &.{.noframes})) return self.step(.in_head, tok);
    if (isEnd(tok, &.{.html})) self.mode = .after_after_frameset;
    return .done;
}

fn afterAfterBody(self: *Parser, tok: *Token) Allocator.Error!Next {
    switch (tok.*) {
        .comment => |data| try self.insertComment(data, .{ .parent = .root }),
        .processing_instruction => |pi| try self.insertPi(pi, .{ .parent = .root }),
        .eof => {},
        else => {
            if (tok.* == .doctype or isWhitespace(tok) or isStart(tok, &.{.html})) {
                return self.step(.in_body, tok);
            }
            self.mode = .in_body;
            return .reprocess;
        },
    }
    return .done;
}

fn afterAfterFrameset(self: *Parser, tok: *Token) Allocator.Error!Next {
    switch (tok.*) {
        .comment => |data| try self.insertComment(data, .{ .parent = .root }),
        .processing_instruction => |pi| try self.insertPi(pi, .{ .parent = .root }),
        else => {
            if (tok.* == .doctype or isWhitespace(tok) or isStart(tok, &.{.html})) {
                return self.step(.in_body, tok);
            }
            if (isStart(tok, &.{.noframes})) return self.step(.in_head, tok);
        },
    }
    return .done;
}

// The rules for parsing tokens in foreign content, §13.2.6.5.

fn foreignContent(self: *Parser, tok: *Token) Allocator.Error!Next {
    switch (tok.*) {
        .chars => |c| switch (c.class) {
            .null => for (c.data) |_| try self.insertChars("\u{FFFD}"),
            .whitespace => try self.insertChars(c.data),
            .other => {
                try self.insertChars(c.data);
                self.frameset_ok = .not_ok;
            },
        },
        .comment, .processing_instruction, .doctype => _ = try self.commonToken(tok),
        .start_tag => |*t| {
            if (breaksOut(t)) return self.breakOut(tok);
            try self.foreignStartTag(t);
        },
        .end_tag => |*t| {
            if (t.tag == .br or t.tag == .p) return self.breakOut(tok);
            const node = self.current();
            const e = self.el(node);
            if (t.tag == .script and e.namespace == .svg and e.tag == .script) {
                _ = self.open.pop();
                return .done;
            }
            return self.foreignEndTag(tok);
        },
        .eof => unreachable,
    }
    return .done;
}

fn breaksOut(t: *const TagToken) bool {
    if (t.tag == .font) {
        for (t.attributes) |a| {
            if (mem.eql(u8, a.name, "color") or mem.eql(u8, a.name, "face") or
                mem.eql(u8, a.name, "size")) return true;
        }
        return false;
    }
    return breakout_tags.contains(t.tag);
}

/// An HTML tag in foreign content: close the foreign elements, then
/// process the token as HTML.
fn breakOut(self: *Parser, tok: *Token) Allocator.Error!Next {
    while (true) {
        const e = self.el(self.current());
        if (e.namespace == .html or isMathmlTextIntegrationPoint(e) or isHtmlIntegrationPoint(e)) break;
        _ = self.open.pop();
    }
    return self.step(self.mode, tok);
}

fn foreignStartTag(self: *Parser, t: *TagToken) Allocator.Error!void {
    const namespace = self.el(self.adjustedCurrent()).namespace;
    if (namespace == .svg) {
        if (svg_tag_names.get(t.name)) |name| t.name = name;
    }
    adjustAttributes(namespace, t.attributes);
    _ = try self.insertForeign(t, namespace);
    if (t.self_closing) _ = self.open.pop();
}

fn foreignEndTag(self: *Parser, tok: *Token) Allocator.Error!Next {
    const name = tok.end_tag.name;
    var i = self.open.items.len - 1;
    while (i != 0) {
        const e = self.el(self.open.items[i]);
        if (e.name.len == name.len and ascii.eqlIgnoreCase(e.name, name)) {
            self.open.shrinkRetainingCapacity(i);
            return .done;
        }
        i -= 1;
        if (self.el(self.open.items[i]).namespace == .html) return self.step(self.mode, tok);
    }
    return .done;
}

/// Adjust MathML or SVG attributes, then foreign attributes, for a token.
fn adjustAttributes(namespace: Namespace, attributes: []Attribute) void {
    for (attributes) |*a| {
        switch (namespace) {
            .mathml => if (mem.eql(u8, a.name, "definitionurl")) {
                a.name = "definitionURL";
            },
            .svg => if (svg_attribute_names.get(a.name)) |name| {
                a.name = name;
            },
            .html => unreachable,
        }
        if (foreign_attributes.get(a.name)) |foreign| {
            a.namespace = foreign.namespace;
            a.name = foreign.name;
        }
    }
}

// Creating and inserting nodes, §13.2.6.1.

fn current(self: *const Parser) Node.Index {
    return self.open.items[self.open.items.len - 1];
}

fn adjustedCurrent(self: *const Parser) Node.Index {
    if (self.context != .none and self.open.items.len == 1) return self.context;
    return self.current();
}

fn el(self: *const Parser, node: Node.Index) *const Element {
    return self.doc.element(node).?;
}

fn isHtml(self: *const Parser, node: Node.Index, tag: Tag) bool {
    const e = self.el(node);
    return e.namespace == .html and e.tag == tag;
}

fn isHtmlIn(self: *const Parser, node: Node.Index, tags: EnumSet(Tag)) bool {
    const e = self.el(node);
    return e.namespace == .html and tags.contains(e.tag);
}

fn isHtmlNamed(self: *const Parser, node: Node.Index, name: []const u8) bool {
    const e = self.el(node);
    return e.namespace == .html and mem.eql(u8, e.name, name);
}

fn contextIs(self: *const Parser, tag: Tag) bool {
    return self.context != .none and self.isHtml(self.context, tag);
}

fn isSpecial(self: *const Parser, node: Node.Index) bool {
    const e = self.el(node);
    return switch (e.namespace) {
        .html => special_html.contains(e.tag),
        .mathml => isMathmlTextIntegrationPoint(e) or e.tag == .@"annotation-xml",
        .svg => e.tag == .foreignObject or e.tag == .desc or e.tag == .title,
    };
}

fn templateOnStack(self: *const Parser) bool {
    for (self.open.items) |node| {
        if (self.isHtml(node, .template)) return true;
    }
    return false;
}

/// Which also holds in a fragment whose context is a `template`.
fn parsingTemplateContents(self: *const Parser) bool {
    return self.templateOnStack() or self.contextIs(.template);
}

/// The appropriate place for inserting a node, adjusted for the fragment
/// case's root. `target` overrides the current node unless it is `.none`.
fn appropriatePlace(self: *const Parser, target: Node.Index) Location {
    var place: Location = .{ .parent = if (target != .none) target else self.current() };
    if (self.foster == .on and self.isHtmlIn(place.parent, foster_targets)) {
        var i = self.open.items.len;
        const last = while (i > 0) {
            i -= 1;
            const node = self.open.items[i];
            if (self.isHtml(node, .template) or self.isHtml(node, .table)) break node;
        } else return self.adjust(.{ .parent = self.open.items[0] });
        if (self.isHtml(last, .template)) {
            place.parent = last;
        } else if (self.doc.node(last).parent != .none) {
            place = .{ .parent = self.doc.node(last).parent, .before = last };
        } else {
            place.parent = self.open.items[i - 1];
        }
    }
    if (self.isElement(place.parent) and self.isHtml(place.parent, .template)) {
        return .{ .parent = self.el(place.parent).template_contents };
    }
    return self.adjust(place);
}

fn isElement(self: *const Parser, node: Node.Index) bool {
    return self.doc.node(node).data == .element;
}

/// The fragment case's root `html` element stands in for the fragment.
fn adjust(self: *const Parser, place: Location) Location {
    if (place.parent == self.fragment_root and place.parent != .none) {
        return .{ .parent = .root, .before = place.before };
    }
    return place;
}

fn createElement(
    self: *Parser,
    namespace: Namespace,
    name: []const u8,
    attributes: []const Attribute,
) Allocator.Error!Node.Index {
    const tag: Tag = .fromName(name);
    const copies = try self.doc.arena.allocator().alloc(Attribute, attributes.len);
    for (attributes, copies) |a, *copy| copy.* = .{
        .namespace = a.namespace,
        .name = try self.doc.dupe(a.name),
        .value = try self.doc.dupe(a.value),
    };
    const contents = if (namespace == .html and tag == .template) try self.doc.create(.fragment) else .none;
    return self.doc.create(.{ .element = .{
        .namespace = namespace,
        .name = if (tag == .other) try self.doc.dupe(name) else @tagName(tag),
        .tag = tag,
        .attributes = copies,
        .template_contents = contents,
    } });
}

/// A new element for the token `node` was created for. The token's
/// attributes are the element's, since only `html` and `body` gain more.
fn cloneElement(self: *Parser, node: Node.Index) Allocator.Error!Node.Index {
    var e = self.el(node).*;
    if (e.template_contents != .none) e.template_contents = try self.doc.create(.fragment);
    return self.doc.create(.{ .element = e });
}

fn insertElement(self: *Parser, element: Node.Index, place: Location) Allocator.Error!void {
    if (self.doc.node(place.parent).data == .document) {
        var it = self.doc.children(.root);
        while (it.next()) |child| if (self.isElement(child)) return;
    }
    self.doc.insertBefore(place.parent, element, place.before);
}

fn insertForeign(self: *Parser, t: *const TagToken, namespace: Namespace) Allocator.Error!Node.Index {
    const element = try self.createElement(namespace, t.name, t.attributes);
    try self.insertElement(element, self.appropriatePlace(.none));
    try self.open.append(self.gpa, element);
    return element;
}

fn insertHtml(self: *Parser, t: *const TagToken) Allocator.Error!Node.Index {
    return self.insertForeign(t, .html);
}

/// Insert a clone of `node` where an element goes, as reconstructing the
/// active formatting elements does.
fn insertClone(self: *Parser, node: Node.Index) Allocator.Error!Node.Index {
    const element = try self.cloneElement(node);
    try self.insertElement(element, self.appropriatePlace(.none));
    try self.open.append(self.gpa, element);
    return element;
}

fn insertChars(self: *Parser, data: []const u8) Allocator.Error!void {
    const place = self.appropriatePlace(.none);
    if (self.doc.node(place.parent).data == .document) return;
    const prev = if (place.before == .none)
        self.doc.node(place.parent).last_child
    else
        self.doc.node(place.before).prev_sibling;
    const arena = self.doc.arena.allocator();
    if (prev != .none) {
        switch (self.doc.nodeMut(prev).data) {
            .text => |*t| return t.appendSlice(arena, data),
            else => {},
        }
    }
    var t: ArrayList(u8) = .empty;
    try t.appendSlice(arena, data);
    const node = try self.doc.create(.{ .text = t });
    self.doc.insertBefore(place.parent, node, place.before);
}

fn insertComment(self: *Parser, data: []const u8, place: ?Location) Allocator.Error!void {
    const where = if (place) |p| self.adjust(p) else self.appropriatePlace(.none);
    const node = try self.doc.create(.{ .comment = try self.doc.dupe(data) });
    self.doc.insertBefore(where.parent, node, where.before);
}

fn insertPi(self: *Parser, pi: Tokenizer.ProcessingInstruction, place: ?Location) Allocator.Error!void {
    const where = if (place) |p| self.adjust(p) else self.appropriatePlace(.none);
    const node = try self.doc.create(.{ .processing_instruction = .{
        .target = try self.doc.dupe(pi.target),
        .data = try self.doc.dupe(pi.data),
    } });
    self.doc.insertBefore(where.parent, node, where.before);
}

/// The generic raw text and RCDATA element parsing algorithms, and the
/// same steps for `script`.
fn rawText(self: *Parser, t: *const TagToken, state: Tokenizer.TextState) Allocator.Error!Next {
    _ = try self.insertHtml(t);
    self.tokenizer.setState(state);
    self.original_mode = self.mode;
    self.mode = .text;
    return .done;
}

// The stack of open elements, §13.2.4.2.

fn openIndex(self: *const Parser, node: Node.Index) ?usize {
    return mem.findScalarLast(Node.Index, self.open.items, node);
}

fn removeOpen(self: *Parser, node: Node.Index) void {
    if (self.openIndex(node)) |i| _ = self.open.orderedRemove(i);
}

/// Pop elements until an HTML element with this tag has been popped.
fn popUntil(self: *Parser, tag: Tag) void {
    while (!self.isHtml(self.open.pop().?, tag)) {}
}

fn clearStackBackTo(self: *Parser, tags: EnumSet(Tag)) void {
    while (!self.isHtmlIn(self.current(), tags)) _ = self.open.pop();
}

/// Generate implied end tags, except for elements with tag `except`.
fn generateImpliedEndTags(self: *Parser, except: ?Tag) void {
    while (true) {
        const e = self.el(self.current());
        if (e.namespace != .html or !implied_end_tags.contains(e.tag)) return;
        if (except) |tag| if (e.tag == tag) return;
        _ = self.open.pop();
    }
}

fn closeP(self: *Parser) void {
    self.generateImpliedEndTags(.p);
    self.popUntil(.p);
}

fn closePInButtonScope(self: *Parser) Allocator.Error!void {
    if (self.hasInScope(.p, .button)) self.closeP();
}

fn isScopeBoundary(self: *const Parser, node: Node.Index, scope: Scope) bool {
    const e = self.el(node);
    if (scope == .table) return e.namespace == .html and (e.tag == .html or e.tag == .table or e.tag == .template);
    return switch (e.namespace) {
        .html => default_scope.contains(e.tag) or
            (scope == .list_item and (e.tag == .ol or e.tag == .ul)) or
            (scope == .button and e.tag == .button),
        .mathml, .svg => self.isSpecial(node),
    };
}

/// Whether the stack has an HTML element with this tag in the scope.
fn hasInScope(self: *const Parser, tag: Tag, scope: Scope) bool {
    var i = self.open.items.len;
    while (i > 0) {
        i -= 1;
        const node = self.open.items[i];
        if (self.isHtml(node, tag)) return true;
        if (self.isScopeBoundary(node, scope)) return false;
    }
    return false;
}

fn hasAnyInScope(self: *const Parser, tags: EnumSet(Tag)) bool {
    var i = self.open.items.len;
    while (i > 0) {
        i -= 1;
        const node = self.open.items[i];
        if (self.isHtmlIn(node, tags)) return true;
        if (self.isScopeBoundary(node, .default)) return false;
    }
    return false;
}

fn hasNodeInScope(self: *const Parser, target: Node.Index) bool {
    var i = self.open.items.len;
    while (i > 0) {
        i -= 1;
        const node = self.open.items[i];
        if (node == target) return true;
        if (self.isScopeBoundary(node, .default)) return false;
    }
    return false;
}

fn resetMode(self: *Parser) void {
    var i = self.open.items.len;
    while (i > 0) {
        i -= 1;
        const last = i == 0;
        const node = if (last and self.context != .none) self.context else self.open.items[i];
        const e = self.el(node);
        const mode: ?Mode = if (e.namespace != .html) null else switch (e.tag) {
            .td, .th => if (last) null else .in_cell,
            .tr => .in_row,
            .tbody, .thead, .tfoot => .in_table_body,
            .caption => .in_caption,
            .colgroup => .in_column_group,
            .table => .in_table,
            .template => self.template_modes.items[self.template_modes.items.len - 1],
            .head => if (last) null else .in_head,
            .body => .in_body,
            .frameset => .in_frameset,
            .html => if (self.head == .none) .before_head else .after_head,
            else => null,
        };
        if (mode) |m| {
            self.mode = m;
            return;
        }
    }
    self.mode = .in_body;
}

// The list of active formatting elements, §13.2.4.3.

fn formattingIndex(self: *const Parser, node: Node.Index) ?usize {
    return mem.findScalarLast(Node.Index, self.formatting.items, node);
}

/// The last element named `name` after the last marker, if any.
fn formattingAfterMarker(self: *const Parser, name: []const u8) ?Node.Index {
    var i = self.formatting.items.len;
    while (i > 0) {
        i -= 1;
        const entry = self.formatting.items[i];
        if (entry == marker) return null;
        if (mem.eql(u8, self.el(entry).name, name)) return entry;
    }
    return null;
}

fn pushFormatting(self: *Parser, node: Node.Index) Allocator.Error!void {
    var count: u32 = 0;
    var earliest: usize = 0;
    var i = self.formatting.items.len;
    while (i > 0) {
        i -= 1;
        const entry = self.formatting.items[i];
        if (entry == marker) break;
        if (self.sameFormatting(entry, node)) {
            count += 1;
            earliest = i;
        }
    }
    // The Noah's Ark clause: at most three of a kind after the last marker.
    if (count >= 3) _ = self.formatting.orderedRemove(earliest);
    try self.formatting.append(self.gpa, node);
}

fn sameFormatting(self: *const Parser, a: Node.Index, b: Node.Index) bool {
    const x = self.el(a);
    const y = self.el(b);
    if (x.namespace != y.namespace or !mem.eql(u8, x.name, y.name)) return false;
    if (x.attributes.len != y.attributes.len) return false;
    for (x.attributes) |attr| {
        const found = for (y.attributes) |other| {
            if (attr.namespace == other.namespace and mem.eql(u8, attr.name, other.name)) break other;
        } else return false;
        if (!mem.eql(u8, attr.value, found.value)) return false;
    }
    return true;
}

fn reconstruct(self: *Parser) Allocator.Error!void {
    const len = self.formatting.items.len;
    if (len == 0) return;
    const last = self.formatting.items[len - 1];
    if (last == marker or self.openIndex(last) != null) return;
    var i = len - 1;
    while (i > 0) : (i -= 1) {
        const entry = self.formatting.items[i - 1];
        if (entry == marker or self.openIndex(entry) != null) break;
    }
    while (i < len) : (i += 1) {
        self.formatting.items[i] = try self.insertClone(self.formatting.items[i]);
    }
}

fn clearToMarker(self: *Parser) void {
    while (self.formatting.pop()) |entry| if (entry == marker) return;
}

// Element sets.

fn tagSet(comptime tags: []const Tag) EnumSet(Tag) {
    return .initMany(tags);
}

const special_html = tagSet(&.{
    .address, .applet,     .area,     .article,    .aside,     .base,     .basefont,
    .bgsound, .blockquote, .body,     .br,         .button,    .caption,  .center,
    .col,     .colgroup,   .dd,       .details,    .dir,       .div,      .dl,
    .dt,      .embed,      .fieldset, .figcaption, .figure,    .footer,   .form,
    .frame,   .frameset,   .h1,       .h2,         .h3,        .h4,       .h5,
    .h6,      .head,       .header,   .hgroup,     .hr,        .html,     .iframe,
    .img,     .input,      .keygen,   .li,         .link,      .listing,  .main,
    .marquee, .menu,       .meta,     .nav,        .noembed,   .noframes, .noscript,
    .object,  .ol,         .p,        .param,      .plaintext, .pre,      .script,
    .search,  .section,    .select,   .source,     .style,     .summary,  .table,
    .tbody,   .td,         .template, .textarea,   .tfoot,     .th,       .thead,
    .title,   .tr,         .track,    .ul,         .wbr,       .xmp,
});

const default_scope = tagSet(&.{
    .applet, .caption, .html, .table, .td, .th, .marquee, .object, .select, .template,
});

const implied_end_tags = tagSet(&.{ .dd, .dt, .li, .optgroup, .option, .p, .rb, .rp, .rt, .rtc });

const thoroughly_implied = tagSet(&.{
    .caption, .colgroup, .dd,  .dt,    .li, .optgroup, .option, .p,     .rb,
    .rp,      .rt,       .rtc, .tbody, .td, .tfoot,    .th,     .thead, .tr,
});

const headings = tagSet(&.{ .h1, .h2, .h3, .h4, .h5, .h6 });
const foster_targets = tagSet(&.{ .table, .tbody, .tfoot, .thead, .tr });
const table_text_targets = tagSet(&.{ .table, .tbody, .template, .tfoot, .thead, .tr });
const table_context = tagSet(&.{ .table, .template, .html });
const table_body_context = tagSet(&.{ .tbody, .tfoot, .thead, .template, .html });
const table_row_context = tagSet(&.{ .tr, .template, .html });

const breakout_tags = tagSet(&.{
    .b,      .big,  .blockquote, .body,  .br,   .center, .code,    .dd,     .div,
    .dl,     .dt,   .em,         .embed, .h1,   .h2,     .h3,      .h4,     .h5,
    .h6,     .head, .hr,         .i,     .img,  .li,     .listing, .menu,   .meta,
    .nobr,   .ol,   .p,          .pre,   .ruby, .s,      .small,   .span,   .strong,
    .strike, .sub,  .sup,        .table, .tt,   .u,      .ul,      .@"var",
});

// Tables from the standard.

const svg_tag_names: std.StaticStringMap([]const u8) = .initComptime(.{
    .{ "altglyph", "altGlyph" },
    .{ "altglyphdef", "altGlyphDef" },
    .{ "altglyphitem", "altGlyphItem" },
    .{ "animatecolor", "animateColor" },
    .{ "animatemotion", "animateMotion" },
    .{ "animatetransform", "animateTransform" },
    .{ "clippath", "clipPath" },
    .{ "feblend", "feBlend" },
    .{ "fecolormatrix", "feColorMatrix" },
    .{ "fecomponenttransfer", "feComponentTransfer" },
    .{ "fecomposite", "feComposite" },
    .{ "feconvolvematrix", "feConvolveMatrix" },
    .{ "fediffuselighting", "feDiffuseLighting" },
    .{ "fedisplacementmap", "feDisplacementMap" },
    .{ "fedistantlight", "feDistantLight" },
    .{ "fedropshadow", "feDropShadow" },
    .{ "feflood", "feFlood" },
    .{ "fefunca", "feFuncA" },
    .{ "fefuncb", "feFuncB" },
    .{ "fefuncg", "feFuncG" },
    .{ "fefuncr", "feFuncR" },
    .{ "fegaussianblur", "feGaussianBlur" },
    .{ "feimage", "feImage" },
    .{ "femerge", "feMerge" },
    .{ "femergenode", "feMergeNode" },
    .{ "femorphology", "feMorphology" },
    .{ "feoffset", "feOffset" },
    .{ "fepointlight", "fePointLight" },
    .{ "fespecularlighting", "feSpecularLighting" },
    .{ "fespotlight", "feSpotLight" },
    .{ "fetile", "feTile" },
    .{ "feturbulence", "feTurbulence" },
    .{ "foreignobject", "foreignObject" },
    .{ "glyphref", "glyphRef" },
    .{ "lineargradient", "linearGradient" },
    .{ "radialgradient", "radialGradient" },
    .{ "textpath", "textPath" },
});

const svg_attribute_names: std.StaticStringMap([]const u8) = .initComptime(.{
    .{ "attributename", "attributeName" },
    .{ "attributetype", "attributeType" },
    .{ "basefrequency", "baseFrequency" },
    .{ "baseprofile", "baseProfile" },
    .{ "calcmode", "calcMode" },
    .{ "clippathunits", "clipPathUnits" },
    .{ "diffuseconstant", "diffuseConstant" },
    .{ "edgemode", "edgeMode" },
    .{ "filterunits", "filterUnits" },
    .{ "glyphref", "glyphRef" },
    .{ "gradienttransform", "gradientTransform" },
    .{ "gradientunits", "gradientUnits" },
    .{ "kernelmatrix", "kernelMatrix" },
    .{ "kernelunitlength", "kernelUnitLength" },
    .{ "keypoints", "keyPoints" },
    .{ "keysplines", "keySplines" },
    .{ "keytimes", "keyTimes" },
    .{ "lengthadjust", "lengthAdjust" },
    .{ "limitingconeangle", "limitingConeAngle" },
    .{ "markerheight", "markerHeight" },
    .{ "markerunits", "markerUnits" },
    .{ "markerwidth", "markerWidth" },
    .{ "maskcontentunits", "maskContentUnits" },
    .{ "maskunits", "maskUnits" },
    .{ "numoctaves", "numOctaves" },
    .{ "pathlength", "pathLength" },
    .{ "patterncontentunits", "patternContentUnits" },
    .{ "patterntransform", "patternTransform" },
    .{ "patternunits", "patternUnits" },
    .{ "pointsatx", "pointsAtX" },
    .{ "pointsaty", "pointsAtY" },
    .{ "pointsatz", "pointsAtZ" },
    .{ "preservealpha", "preserveAlpha" },
    .{ "preserveaspectratio", "preserveAspectRatio" },
    .{ "primitiveunits", "primitiveUnits" },
    .{ "refx", "refX" },
    .{ "refy", "refY" },
    .{ "repeatcount", "repeatCount" },
    .{ "repeatdur", "repeatDur" },
    .{ "requiredextensions", "requiredExtensions" },
    .{ "requiredfeatures", "requiredFeatures" },
    .{ "specularconstant", "specularConstant" },
    .{ "specularexponent", "specularExponent" },
    .{ "spreadmethod", "spreadMethod" },
    .{ "startoffset", "startOffset" },
    .{ "stddeviation", "stdDeviation" },
    .{ "stitchtiles", "stitchTiles" },
    .{ "surfacescale", "surfaceScale" },
    .{ "systemlanguage", "systemLanguage" },
    .{ "tablevalues", "tableValues" },
    .{ "targetx", "targetX" },
    .{ "targety", "targetY" },
    .{ "textlength", "textLength" },
    .{ "viewbox", "viewBox" },
    .{ "viewtarget", "viewTarget" },
    .{ "xchannelselector", "xChannelSelector" },
    .{ "ychannelselector", "yChannelSelector" },
    .{ "zoomandpan", "zoomAndPan" },
});

const ForeignAttribute = struct { namespace: Document.AttributeNamespace, name: []const u8 };

const foreign_attributes: std.StaticStringMap(ForeignAttribute) = .initComptime(.{
    .{ "xlink:actuate", ForeignAttribute{ .namespace = .xlink, .name = "actuate" } },
    .{ "xlink:arcrole", ForeignAttribute{ .namespace = .xlink, .name = "arcrole" } },
    .{ "xlink:href", ForeignAttribute{ .namespace = .xlink, .name = "href" } },
    .{ "xlink:role", ForeignAttribute{ .namespace = .xlink, .name = "role" } },
    .{ "xlink:show", ForeignAttribute{ .namespace = .xlink, .name = "show" } },
    .{ "xlink:title", ForeignAttribute{ .namespace = .xlink, .name = "title" } },
    .{ "xlink:type", ForeignAttribute{ .namespace = .xlink, .name = "type" } },
    .{ "xml:lang", ForeignAttribute{ .namespace = .xml, .name = "lang" } },
    .{ "xml:space", ForeignAttribute{ .namespace = .xml, .name = "space" } },
    .{ "xmlns", ForeignAttribute{ .namespace = .xmlns, .name = "xmlns" } },
    .{ "xmlns:xlink", ForeignAttribute{ .namespace = .xmlns, .name = "xlink" } },
});

/// The public identifiers that put a document in quirks mode, compared
/// ASCII case-insensitively.
const quirks_public_ids = [_][]const u8{
    "-//w3o//dtd w3 html strict 3.0//en//",
    "-/w3c/dtd html 4.0 transitional/en",
    "html",
};

/// The public identifier prefixes that put a document in quirks mode.
const quirks_public_prefixes = [_][]const u8{
    "+//silmaril//dtd html pro v0r11 19970101//",
    "-//as//dtd html 3.0 aswedit + extensions//",
    "-//advasoft ltd//dtd html 3.0 aswedit + extensions//",
    "-//ietf//dtd html 2.0 level 1//",
    "-//ietf//dtd html 2.0 level 2//",
    "-//ietf//dtd html 2.0 strict level 1//",
    "-//ietf//dtd html 2.0 strict level 2//",
    "-//ietf//dtd html 2.0 strict//",
    "-//ietf//dtd html 2.0//",
    "-//ietf//dtd html 2.1e//",
    "-//ietf//dtd html 3.0//",
    "-//ietf//dtd html 3.2 final//",
    "-//ietf//dtd html 3.2//",
    "-//ietf//dtd html 3//",
    "-//ietf//dtd html level 0//",
    "-//ietf//dtd html level 1//",
    "-//ietf//dtd html level 2//",
    "-//ietf//dtd html level 3//",
    "-//ietf//dtd html strict level 0//",
    "-//ietf//dtd html strict level 1//",
    "-//ietf//dtd html strict level 2//",
    "-//ietf//dtd html strict level 3//",
    "-//ietf//dtd html strict//",
    "-//ietf//dtd html//",
    "-//metrius//dtd metrius presentational//",
    "-//microsoft//dtd internet explorer 2.0 html strict//",
    "-//microsoft//dtd internet explorer 2.0 html//",
    "-//microsoft//dtd internet explorer 2.0 tables//",
    "-//microsoft//dtd internet explorer 3.0 html strict//",
    "-//microsoft//dtd internet explorer 3.0 html//",
    "-//microsoft//dtd internet explorer 3.0 tables//",
    "-//netscape comm. corp.//dtd html//",
    "-//netscape comm. corp.//dtd strict html//",
    "-//o'reilly and associates//dtd html 2.0//",
    "-//o'reilly and associates//dtd html extended 1.0//",
    "-//o'reilly and associates//dtd html extended relaxed 1.0//",
    "-//sq//dtd html 2.0 hotmetal + extensions//",
    "-//softquad software//dtd hotmetal pro 6.0::19990601::extensions to html 4.0//",
    "-//softquad//dtd hotmetal pro 4.0::19971010::extensions to html 4.0//",
    "-//spyglass//dtd html 2.0 extended//",
    "-//sun microsystems corp.//dtd hotjava html//",
    "-//sun microsystems corp.//dtd hotjava strict html//",
    "-//w3c//dtd html 3 1995-03-24//",
    "-//w3c//dtd html 3.2 draft//",
    "-//w3c//dtd html 3.2 final//",
    "-//w3c//dtd html 3.2//",
    "-//w3c//dtd html 3.2s draft//",
    "-//w3c//dtd html 4.0 frameset//",
    "-//w3c//dtd html 4.0 transitional//",
    "-//w3c//dtd html experimental 19960712//",
    "-//w3c//dtd html experimental 970421//",
    "-//w3c//dtd w3 html//",
    "-//w3o//dtd w3 html 3.0//",
    "-//webtechs//dtd mozilla html 2.0//",
    "-//webtechs//dtd mozilla html//",
};

/// The public identifier prefixes that put a document in limited-quirks mode.
const limited_quirks_public_prefixes = [_][]const u8{
    "-//w3c//dtd xhtml 1.0 frameset//",
    "-//w3c//dtd xhtml 1.0 transitional//",
};

/// HTML 4.01 is quirks mode without a system identifier and limited-quirks
/// mode with one.
const html401_public_prefixes = [_][]const u8{
    "-//w3c//dtd html 4.01 frameset//",
    "-//w3c//dtd html 4.01 transitional//",
};

test "the input may be split anywhere" {
    const input = "<!DOCTYPE html><p>One<table><tr><td>Two</table><svg><circle/></svg>";
    var whole = try parse(testing.allocator, input, .{});
    defer whole.deinit();

    var p: Parser = try .init(testing.allocator, .{});
    defer p.deinit();
    for (0..input.len) |i| try p.feed(input[i .. i + 1]);
    var split = try p.finish();
    defer split.deinit();

    try testing.expectEqual(whole.nodes.items.len, split.nodes.items.len);
    for (whole.nodes.items, split.nodes.items) |a, b| {
        try testing.expectEqual(a.parent, b.parent);
        try testing.expectEqual(a.next_sibling, b.next_sibling);
        try testing.expectEqual(std.meta.activeTag(a.data), std.meta.activeTag(b.data));
    }
}
