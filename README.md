<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/static/logo-dark.svg">
    <img src="docs/static/logo.svg" alt="html" height="48">
  </picture>
</h1>

HTML in Zig, the way the WHATWG HTML standard parses it.

This project is incubating. It is unstable, its API will change, and it is not ready to depend on.

std has no HTML parser, and the Zig ones that follow the standard are GPL or stop short of it. This package implements the standard's parsing algorithm itself and checks it against the suites browsers use. The tokenizer passes all 7,045 html5lib-tests tokenizer cases, including the 2026 addition of processing instructions. Tree construction builds the expected tree for 1,963 of the 1,967 cases in the web-platform-tests tree construction corpus, 3,706 runs across both scripting modes; the other 4 need DOM behavior beyond parsing (see Not implemented). Neither does I/O, and both take input in any split, so a document can stream through them from a socket.

```zig
var doc = try html.parse(gpa, "<p class=intro>Hello, <b>world</b>", .{});
defer doc.deinit();
```

## What is in it

- [The parser](https://baskingspot.dev/html/#the-parser): `parse` and `Parser` run tree construction and return a `Document`, with the elements the markup implies.
- [The document tree](https://baskingspot.dev/html/#the-document-tree): `Document` is one array of nodes linked by index, with every string in one arena.
- [The tokenizer](https://baskingspot.dev/html/#the-tokenizer): `Tokenizer` is the stage before tree construction, for callers who want tokens and parse errors.
- [Conformance](https://baskingspot.dev/html/#conformance): the corpora that `just test` runs, and the cases that diverge from them.

Not implemented:

- Encoding sniffing. Input is UTF-8; a byte order mark is an ordinary character.
- Serializing a tree back to HTML.
- Tree construction parse errors. The tokenizer reports its own.
- A depth limit. Scope checks walk the open elements, as the standard defines them, so pathologically deep input such as 40,000 nested `<div>`s takes seconds.
- What only a browser needs: scripts, custom elements, declarative shadow roots, the sanitizer, form association, and the `selectedcontent` cloning that §4.10 asks of the parser.

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

## Documentation

- The [guide](https://baskingspot.dev/html/) covers the parser, the document tree, the tokenizer, and the corpora behind them.
- The [API reference](https://baskingspot.dev/html/api/) documents every public symbol.
- [`docs/examples/`](docs/examples/) is the test-verified code shown in the guide: `just test` compiles and runs it with the module's own tests.

## Work on it

```sh
just ci
```

`nix develop` provides the toolchain and the site tools. `just` lists the recipes, and `just ci` runs what CI runs: the tests, lint, and the site build. `just guide` serves the guide with live reload, and `just doc` builds the whole site into `zig-out/site/html/`.

`just bench-compare` times this parser against Go's x/net/html and Rust's html5ever on a pinned corpus of real pages; `bench/README.md` has the method.

## License

MIT. See [`LICENSE`](LICENSE). The vendored test corpora and the generated entity table come from elsewhere; [`THIRD_PARTY.md`](THIRD_PARTY.md) lists their terms. The logo files in `docs/static/` are baskingspot marks and are not covered by it. See [`docs/static/LICENSE`](docs/static/LICENSE).

## How it's made

Built with LLM assistance. [How, in detail](https://github.com/baskingspot/.github/blob/main/docs/AI.md).

<a href="https://github.com/baskingspot"><img src="https://raw.githubusercontent.com/baskingspot/.github/main/brand/assets/badge.svg" alt="baskingspot" height="24"></a>
