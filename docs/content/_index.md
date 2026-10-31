+++
title = "html"
+++

HTML in Zig, the way the WHATWG HTML standard parses it.

This project is incubating. It is unstable, its API will change, and it is not ready to depend on.

std has no HTML parser, and the Zig ones that follow the standard are GPL or stop short of it. This package implements the standard's parsing algorithm itself and checks it against the suites browsers use. The tokenizer passes all 7,045 html5lib-tests tokenizer cases, including the 2026 addition of processing instructions. Tree construction builds the expected tree for 1,963 of the 1,967 cases in the web-platform-tests tree construction corpus, 3,706 runs across both scripting modes; the other 4 need DOM behavior beyond parsing. Neither does I/O, and both take input in any split, so a document can stream through them from a socket.

- [The parser](#the-parser): `parse` and `Parser` run tree construction and return a `Document`, with the elements the markup implies.
- [The document tree](#the-document-tree): `Document` is one array of nodes linked by index, with every string in one arena.
- [The tokenizer](#the-tokenizer): `Tokenizer` is the stage before tree construction, for callers who want tokens and parse errors.
- [Conformance](#conformance): the corpora that `just test` runs, and the cases that diverge from them.
- [Limits](#limits): what a reader might expect and does not get, from encoding sniffing to a depth limit.

The [API reference](api/) documents every public symbol.

# Getting started

## Install

Add the package to `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/baskingspot/html
```

Then wire the module in `build.zig`:

```zig
const html = b.dependency("html", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("html", html.module("html"));
```

html builds with Zig 0.16 only.

## Import it

```zig
const html = @import("html");
```

`std` has no `html` namespace, so the import name does not collide.

## Parse a document

```zig
var doc = try html.parse(gpa, "<p class=intro>Hello, <b>world</b>", .{});
defer doc.deinit();
walk(&doc, .root, 0);
```

```zig
fn walk(doc: *const html.Document, parent: html.Node.Index, depth: u32) void {
    var children = doc.children(parent);
    while (children.next()) |child| {
        switch (doc.node(child).data) {
            .element => |element| std.debug.print("{d} <{s}>\n", .{ depth, element.name }),
            .text => |text| std.debug.print("{d} {s}\n", .{ depth, text.items }),
            else => {},
        }
        walk(doc, child, depth + 1);
    }
}
```

That prints `html`, `head`, `body`, `p`, `Hello, `, `b`, and `world`: the parser adds the elements the markup implies, as browsers do.

`parse` fails only when the allocator fails. Malformed markup is not an error; the standard says how to recover, and the parser recovers the same way.

## Stream the input

A `Parser` takes bytes as they arrive, in any split, and returns the document at the end:

```zig
var parser: html.Parser = try .init(gpa, .{});
defer parser.deinit();
try parser.feed("<ul><li>one<li>t");
try parser.feed("wo</ul>");
var doc = try parser.finish();
defer doc.deinit();
```

Splitting the input never changes a token or a tree. The corpus tests check that by feeding every case one byte at a time.

## Parse a fragment

`parseFragment` parses markup as the contents of an element, the way `innerHTML` does:

```zig
var fragment = try html.parseFragment(gpa, "<td>cell", .init(.html, "tr"), .{});
defer fragment.deinit();
```

The context element sets the insertion mode and the namespace. The fragment's nodes are the children of `.root`.

## Take tokens

The tokenizer runs on its own when the tree is not wanted:

```zig
var tokenizer: html.Tokenizer = .init(gpa, .{ .errors = .collect });
defer tokenizer.deinit();
try tokenizer.feed("<p class=intro>Hello");
tokenizer.finish();
while (try tokenizer.next()) |token| {
    switch (token) {
        .start_tag => |tag| std.debug.print("<{s}>\n", .{tag.name}),
        .text => |text| std.debug.print("{s}\n", .{text}),
        .eof => break,
        else => {},
    }
}
```

`next` returns null when the tokenizer needs more input and `eof` after the end of the input. A token's slices stay valid until the next call to `next`.

# The parser

Tree construction applies the standard's rules to the tokenizer's tokens and builds the tree:

- The elements the markup implies. `html`, `head`, and `body` appear even when the markup omits them.
- Misnested formatting. The adoption agency repairs `<b>one<i>two</b>three</i>` the way browsers do.
- Tables and foster parenting. Content between `<table>` and its cells moves in front of the table, as the standard requires.
- `template` elements. The element's contents are a separate fragment, reachable through `Element.template_contents`.
- Foreign content. SVG and MathML elements keep their namespace and the case of their names, such as `foreignObject`.
- Quirks mode. The DOCTYPE decides `Document.mode`, and the mode decides a few layout-adjacent rules in the tree.

`Parser.Options.scripting` decides one thing: whether `noscript` holds raw text, as in a browser with scripting enabled, or markup. It defaults to `.enabled`.

A parse owns its allocator from `init` to `deinit`. The `Document` you get back owns an arena, so `doc.deinit()` frees the tree and every string in it at once. Nodes and text slices must not outlive it.

# The document tree

A `Document` is one array of nodes. A node refers to its parent, children, and siblings by `Node.Index`, and every string the parser kept lives in the document's arena. There are no pointers to fix up when the array grows.

- `.root` is the document, or the fragment for `parseFragment`.
- `.none` is the null index.
- `doc.node(index)` returns a node; `doc.children(parent)` returns an iterator with `next()`.
- `doc.element(index)` returns an `Element` when the node is one.

An `Element` carries its namespace, its local name, its `Tag` (the parser's enum of the tags it treats specially, or `.other`), and its attributes. An attribute carries its namespace, its local name, and its value, so `xlink:href` is name `href` in the XLink namespace. `element.attribute("class")` looks up an HTML attribute by name.

A text node holds an `ArrayList(u8)`, and adjacent text is one node. `insertBefore` and `append` are the building blocks tree construction uses; a document is built by the parser, not edited by hand.

# The tokenizer

`Tokenizer` is the tokenizer of §13.2.5, with the public API the parser uses:

- `feed` appends bytes. They are copied, so the caller may reuse the buffer.
- `finish` marks the end of the input.
- `next` returns the next token, or null when it needs more input.

`Token` is the standard's union: `doctype`, `start_tag`, `end_tag`, `comment`, `processing_instruction`, `text`, and `eof`. Character tokens arrive in runs as `text`.

Set `.errors = .collect` to record parse errors in `tokenizer.errors`. A `ParseError` carries the standard's code, the line, and the column, both counted from one. Columns count UTF-16 code units, as browsers and html5lib-tests do, so a code point above U+FFFF takes two. The caller reads and clears the list between calls to `next`.

Callers that build a tree need to put the tokenizer into the text states by hand. `setState` switches it to `.rcdata`, `.rawtext`, `.script_data`, or `.plaintext`, and `setLastStartTag` sets the name the matching end tag must have. The parser does both after a start tag such as `<title>` or `<script>`.

# Conformance

`just test` runs the parser against the corpora browsers use.

- The tokenizer corpus is `test/html5lib-tests/tokenizer/`, vendored at a pinned commit. Every case runs in every initial state, twice: fed whole and fed one byte at a time. Both runs must produce the expected tokens and parse errors.
- The tree construction corpus is `test/wpt-tree-construction/`, vendored from web-platform-tests. Every case runs with scripting enabled and disabled.
- `xmlViolation.test` is excluded. Its expectations assume the "coercing an HTML DOM into an infoset" tweaks, which are not tokenizing.

A case whose expectations contradict the standard or the rest of the corpus goes in `known_divergences` in `test/tokenizer.zig` or `test/tree.zig`, with the reason. The test fails when a listed case starts passing, so the list cannot outlive the problem.

# Limits

What a reader might expect and does not get:

- Encoding sniffing. Input is UTF-8. A byte order mark is an ordinary character.
- Serializing a tree back to HTML.
- Tree construction parse errors. The tokenizer reports its own; the parser reports none.
- A depth limit. Scope checks walk the open elements, as the standard defines them, so pathologically deep input such as 40,000 nested `<div>`s takes seconds.
- What only a browser needs: scripts, custom elements, declarative shadow roots, the sanitizer, form association, and the `selectedcontent` cloning that §4.10 asks of the parser.
