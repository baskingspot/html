# html bench

Parse benchmarks: this package against the HTML parsers Go and Rust programs use, over one pinned corpus of real pages.

These are local numbers, for iterating. They are not claims: a number that gets quoted in the README needs a run on dedicated hardware, as `baskingspot/compress/bench` does on the EC2 fleet.

## Arms

Each arm is one program with the same contract. Run from the repository root, it reads every `.html` file in `bench/corpus-gen/`. With no arguments it prints one row per document in the Go benchmark format: `BenchmarkParse/<document>`, the iterations, ns/op, and MB/s. With `check` it prints each document's node counts and one parse's allocations.

| Arm    | Program                                  | Library                                                                                      | What a row times                                                                                                                    |
| ------ | ---------------------------------------- | -------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `zig`  | `bench/zig/parse.zig`, `zig build bench` | this package                                                                                 | `html.parse` from the bytes into a `Document`, then `deinit`, with `std.heap.smp_allocator`. testingx sizes the loop.               |
| `go`   | `bench/go`                               | `golang.org/x/net/html` v0.62.0, pinned in `go.sum`                                          | `html.Parse` from a `bytes.Reader`, garbage collection included. Go's `testing.Benchmark` sizes the loop.                           |
| `rust` | `bench/rust`                             | `scraper` 0.29.0, which is html5ever 0.40.1 building an ego-tree DOM, pinned in `Cargo.lock` | `String::from_utf8_lossy` (scraper takes `&str`), `Html::parse_document`, and dropping the tree. The loop is sized the way Go's is. |

scraper stands for Rust because html5ever is the only Rust parser that implements the standard's tree construction, and scraper is how Rust programs use it; `markup5ever_rcdom` calls itself a test-only DOM. All three arms parse with scripting enabled, their default.

The Rust arm's global allocator counts allocations for `check`. Outside `check`, each allocation pays one relaxed atomic load for that.

## Equivalence

`just bench-compare` runs every arm's `check` first and diffs the node counts: elements, attributes, text nodes, text bytes, and comments. On every page of the corpus the three trees agree, so the rows time the same work. The allocation columns are not compared; each language counts differently.

x/net/html refuses documents nested deeper than 512 elements, so the Go arm has no `nested-divs` row. It prints a `# SKIP` comment instead.

## Corpus

`bench/corpus/sources.tsv` lists the pages and `bench/corpus/SHA256SUMS` pins their bytes; neither the pages nor their copyright are ours, so only the hashes are committed. `just bench-corpus` fetches each page into the gitignored `bench/corpus-gen/` and fails on any difference. Each URL is a Wayback Machine `id_` capture, which serves the original bytes and does not change.

| Document         | Size     | Shape                                                                  |
| ---------------- | -------- | ---------------------------------------------------------------------- |
| `github-zig`     | 273 KiB  | a GitHub repository page: attribute-heavy markup, inline SVG           |
| `hackernews`     | 34 KiB   | Hacker News: table layout, short text                                  |
| `mdn-elements`   | 224 KiB  | an MDN reference page: prose, lists, many comments                     |
| `wikipedia-html` | 497 KiB  | a Wikipedia article: prose, tables, references                         |
| `whatwg-spec`    | 14.8 MiB | the HTML standard on one page: long prose, about 333,000 elements      |
| `nested-divs`    | 49 KiB   | generated: 10,000 nested `div` elements, which every scope check walks |

## Method

`just bench-compare [ROUNDS]` (default 10) builds the three arms, checks equivalence, then runs ROUNDS rounds. A round runs each arm once, in an order that rotates each round, so drift on the machine lands on every arm alike. Every run is pinned with `taskset` to the last core, which also makes Go's runtime use one processor. `benchstat` then compares the arms' rows with the Zig arm as the base. Everything lands in `zig-out/bench-compare/`: the raw output, the check tables, and `benchstat.txt`.

`just bench` runs the Zig arm alone, with testingx's flags: `just bench --count=10 --filter=wikipedia`.
