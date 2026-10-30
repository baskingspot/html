# html

HTML in Zig, the way the WHATWG HTML standard parses it.

std has no HTML parser, and the Zig ones that follow the standard are GPL or stop short of it. This package implements the standard's parsing algorithm itself and checks it against the suites browsers use. The tokenizer passes all 7,045 html5lib-tests tokenizer cases, including the 2026 addition of processing instructions. Tree construction builds the expected tree for 1,963 of the 1,967 cases in the web-platform-tests tree construction corpus, 3,706 runs across both scripting modes; the other 4 need DOM behavior beyond parsing (see Not implemented). Neither does I/O, and both take input in any split, so a document can stream through them from a socket.

## What is in it

- `parse` and `Parser`: UTF-8 bytes in, a `Document` out, built by the standard's tree construction: implied tags, misnested formatting (the adoption agency), tables and foster parenting, templates, framesets, SVG and MathML, and quirks mode from the DOCTYPE.
- `parseFragment`: markup parsed in the context of an element, as `innerHTML` parses it.
- `Document`: the tree, one array of nodes linked by index, with its strings in one arena.
- `Tokenizer`: the stage before tree construction, for callers who want tokens: DOCTYPE, start and end tags, comments, processing instructions, and text, with every parse error code and its position.

Not implemented yet:

- Encoding sniffing. Input is UTF-8; a byte order mark is an ordinary character.
- Serializing a tree back to HTML.
- Tree construction parse errors. The tokenizer reports its own.
- A depth limit. Scope checks walk the open elements, as the standard defines them, so pathologically deep input such as 40,000 nested `<div>`s takes seconds.
- What only a browser needs: scripts, custom elements, declarative shadow roots, the sanitizer, form association, and the `selectedcontent` cloning that §4.10 asks of the parser.

## Use

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

To stream, feed a `Parser` as bytes arrive and call `finish` at the end, which returns the document:

```zig
var parser: html.Parser = try .init(gpa, .{});
defer parser.deinit();
try parser.feed("<ul><li>one<li>t");
try parser.feed("wo</ul>");
var doc = try parser.finish();
defer doc.deinit();
```

`parseFragment(gpa, "<td>cell", .{ .name = "tr" }, .{})` parses markup as the contents of a `tr`. The fragment's nodes are the children of `.root`.

`Options.scripting` defaults to `.enabled`, as in browsers, so `noscript` holds raw text. Set it to `.disabled` to parse `noscript` contents as markup.

The `Tokenizer` alone works the same way: `feed`, `finish`, and `next` until it returns null, which means it wants more input. A token's slices stay valid until the next call to `next`.

## Install

```sh
zig fetch --save git+https://github.com/baskingspot/html
```

Add the module to your build:

```zig
const html = b.dependency("html", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("html", html.module("html"));
```

html builds with Zig 0.16 only.

## Work on it

```sh
just ci
```

`nix develop` provides the toolchain. `just` lists the recipes, and `just ci` runs what CI runs. `just bench-compare` times this parser against Go's x/net/html and Rust's html5ever on a pinned corpus of real pages; `bench/README.md` has the method.

## License

MIT. See `LICENSE`. The vendored test corpora and the generated entity table come from elsewhere; see `THIRD_PARTY.md`.

## How it's made

Built with LLM assistance. [How, in detail](https://github.com/baskingspot/.github/blob/main/docs/AI.md).
