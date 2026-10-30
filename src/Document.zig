//! A parsed document, or a fragment: a tree of nodes in one array.
//!
//! Nodes refer to each other by `Node.Index`, so the tree has no pointers to
//! fix up when the array grows. Strings live in an arena the document owns,
//! and `deinit` frees everything at once.

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;

const Document = @This();

/// The DOM's document mode, which the DOCTYPE decides.
pub const Mode = enum { no_quirks, quirks, limited_quirks };

pub const Namespace = enum { html, svg, mathml };

/// The namespaces an attribute can be in. Only the foreign attributes of
/// §13.2.6.1, such as `xlink:href` on an SVG element, are in one.
pub const AttributeNamespace = enum { none, xlink, xml, xmlns };

pub const Attribute = struct {
    namespace: AttributeNamespace = .none,
    /// The local name: `href` for `xlink:href` in the XLink namespace.
    name: []const u8,
    value: []const u8,
};

pub const Node = struct {
    parent: Index = .none,
    first_child: Index = .none,
    last_child: Index = .none,
    prev_sibling: Index = .none,
    next_sibling: Index = .none,
    data: Data,

    pub const Index = enum(u32) {
        /// The document, or the fragment for `Parser.initFragment`.
        root = 0,
        none = std.math.maxInt(u32),
        _,
    };

    pub const Data = union(enum) {
        document,
        /// A `DocumentFragment`: the result of fragment parsing, and the
        /// contents of a `template` element.
        fragment,
        doctype: Doctype,
        element: Element,
        /// Adjacent text is one node, so this grows as the parser appends.
        text: ArrayList(u8),
        comment: []const u8,
        processing_instruction: ProcessingInstruction,
    };
};

pub const Doctype = struct {
    /// Empty when the DOCTYPE token's field was missing, as in the DOM.
    name: []const u8,
    public_id: []const u8,
    system_id: []const u8,
};

pub const Element = struct {
    namespace: Namespace,
    /// The local name, with the case the standard gives foreign elements:
    /// `foreignObject`, not `foreignobject`.
    name: []const u8,
    /// `name` as one of the tags the parser treats specially, or `.other`.
    tag: Tag,
    attributes: []const Attribute,
    /// The fragment holding a `template` element's contents, or `.none`.
    template_contents: Node.Index = .none,

    pub fn attribute(self: *const Element, name: []const u8) ?[]const u8 {
        for (self.attributes) |a| {
            if (a.namespace == .none and mem.eql(u8, a.name, name)) return a.value;
        }
        return null;
    }
};

pub const ProcessingInstruction = struct {
    target: []const u8,
    data: []const u8,
};

/// The element names tree construction handles by name, in any namespace.
/// The field names are the element names, so `@tagName` gives the name back.
pub const Tag = enum {
    a,
    address,
    @"annotation-xml",
    applet,
    area,
    article,
    aside,
    b,
    base,
    basefont,
    bgsound,
    big,
    blockquote,
    body,
    br,
    button,
    caption,
    center,
    code,
    col,
    colgroup,
    dd,
    desc,
    details,
    dialog,
    dir,
    div,
    dl,
    dt,
    em,
    embed,
    fieldset,
    figcaption,
    figure,
    font,
    footer,
    foreignObject,
    form,
    frame,
    frameset,
    h1,
    h2,
    h3,
    h4,
    h5,
    h6,
    head,
    header,
    hgroup,
    hr,
    html,
    i,
    iframe,
    image,
    img,
    input,
    keygen,
    li,
    link,
    listing,
    main,
    malignmark,
    marquee,
    math,
    menu,
    meta,
    mglyph,
    mi,
    mn,
    mo,
    ms,
    mtext,
    nav,
    nobr,
    noembed,
    noframes,
    noscript,
    object,
    ol,
    optgroup,
    option,
    p,
    param,
    plaintext,
    pre,
    rb,
    rp,
    rt,
    rtc,
    ruby,
    s,
    script,
    search,
    section,
    select,
    small,
    source,
    span,
    strike,
    strong,
    style,
    sub,
    summary,
    sup,
    svg,
    table,
    tbody,
    td,
    template,
    textarea,
    tfoot,
    th,
    thead,
    title,
    tr,
    track,
    tt,
    u,
    ul,
    @"var",
    wbr,
    xmp,
    other,

    const map: std.StaticStringMap(Tag) = .initComptime(entries: {
        @setEvalBranchQuota(10_000);
        const fields = @typeInfo(Tag).@"enum".fields;
        var kvs: [fields.len - 1]struct { []const u8, Tag } = undefined;
        for (fields[0 .. fields.len - 1], &kvs) |field, *kv| {
            kv.* = .{ field.name, @enumFromInt(field.value) };
        }
        break :entries kvs;
    });

    pub fn fromName(name: []const u8) Tag {
        return map.get(name) orelse .other;
    }
};

gpa: Allocator,
arena: ArenaAllocator,
nodes: ArrayList(Node),
mode: Mode,

/// A document with only its root: a `document` node, or a `fragment`.
pub fn init(gpa: Allocator, root: enum { document, fragment }) Allocator.Error!Document {
    var doc: Document = .{
        .gpa = gpa,
        .arena = .init(gpa),
        .nodes = .empty,
        .mode = .no_quirks,
    };
    errdefer doc.deinit();
    _ = try doc.create(switch (root) {
        .document => .document,
        .fragment => .fragment,
    });
    return doc;
}

pub fn deinit(doc: *Document) void {
    doc.nodes.deinit(doc.gpa);
    doc.arena.deinit();
    doc.* = undefined;
}

pub fn node(doc: *const Document, index: Node.Index) *const Node {
    return &doc.nodes.items[@intFromEnum(index)];
}

pub fn nodeMut(doc: *Document, index: Node.Index) *Node {
    return &doc.nodes.items[@intFromEnum(index)];
}

/// The element at `index`, or null for any other kind of node.
pub fn element(doc: *const Document, index: Node.Index) ?*const Element {
    return switch (doc.node(index).data) {
        .element => |*e| e,
        else => null,
    };
}

pub fn children(doc: *const Document, parent: Node.Index) Children {
    return .{ .doc = doc, .next_child = doc.node(parent).first_child };
}

pub const Children = struct {
    doc: *const Document,
    next_child: Node.Index,

    pub fn next(it: *Children) ?Node.Index {
        const child = it.next_child;
        if (child == .none) return null;
        it.next_child = it.doc.node(child).next_sibling;
        return child;
    }
};

/// A new node with no parent. Its strings must already belong to the
/// document; `dupe` copies one in.
pub fn create(doc: *Document, data: Node.Data) Allocator.Error!Node.Index {
    assert(doc.nodes.items.len < @intFromEnum(Node.Index.none));
    const index: Node.Index = @enumFromInt(doc.nodes.items.len);
    try doc.nodes.append(doc.gpa, .{ .data = data });
    return index;
}

/// Copy `bytes` into the document's arena.
pub fn dupe(doc: *Document, bytes: []const u8) Allocator.Error![]const u8 {
    return doc.arena.allocator().dupe(u8, bytes);
}

/// Insert `child`, which has no parent, into `parent` before `before`, or at
/// the end when `before` is `.none`.
pub fn insertBefore(doc: *Document, parent: Node.Index, child: Node.Index, before: Node.Index) void {
    assert(doc.node(child).parent == .none);
    const prev = if (before == .none) doc.node(parent).last_child else doc.node(before).prev_sibling;
    const c = doc.nodeMut(child);
    c.parent = parent;
    c.prev_sibling = prev;
    c.next_sibling = before;
    if (prev == .none) doc.nodeMut(parent).first_child = child else doc.nodeMut(prev).next_sibling = child;
    if (before == .none) doc.nodeMut(parent).last_child = child else doc.nodeMut(before).prev_sibling = child;
}

pub fn append(doc: *Document, parent: Node.Index, child: Node.Index) void {
    doc.insertBefore(parent, child, .none);
}

/// Take `child` out of its parent, if it has one.
pub fn remove(doc: *Document, child: Node.Index) void {
    const c = doc.node(child).*;
    if (c.parent == .none) return;
    if (c.prev_sibling == .none) {
        doc.nodeMut(c.parent).first_child = c.next_sibling;
    } else {
        doc.nodeMut(c.prev_sibling).next_sibling = c.next_sibling;
    }
    if (c.next_sibling == .none) {
        doc.nodeMut(c.parent).last_child = c.prev_sibling;
    } else {
        doc.nodeMut(c.next_sibling).prev_sibling = c.prev_sibling;
    }
    const m = doc.nodeMut(child);
    m.parent = .none;
    m.prev_sibling = .none;
    m.next_sibling = .none;
}

/// Whether `ancestor` is `descendant` or one of its ancestors.
pub fn isInclusiveAncestor(doc: *const Document, ancestor: Node.Index, descendant: Node.Index) bool {
    var n = descendant;
    while (n != .none) : (n = doc.node(n).parent) {
        if (n == ancestor) return true;
    }
    return false;
}

test "insertBefore and remove keep the sibling links consistent" {
    var doc: Document = try .init(std.testing.allocator, .document);
    defer doc.deinit();
    const a = try doc.create(.{ .comment = "a" });
    const b = try doc.create(.{ .comment = "b" });
    const c = try doc.create(.{ .comment = "c" });
    doc.append(.root, c);
    doc.insertBefore(.root, a, c);
    doc.insertBefore(.root, b, c);
    doc.remove(a);
    doc.append(.root, a);

    var order: [3]Node.Index = undefined;
    var it = doc.children(.root);
    var n: u32 = 0;
    while (it.next()) |child| : (n += 1) order[n] = child;
    try std.testing.expectEqual(3, n);
    try std.testing.expectEqualSlices(Node.Index, &.{ b, c, a }, &order);
    try std.testing.expectEqual(c, doc.node(a).prev_sibling);
    try std.testing.expectEqual(b, doc.node(.root).first_child);
}
