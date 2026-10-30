# Parse speed against Go and Rust, before and after the first optimizations

Method: `just bench-compare 10`, as `bench/README.md` describes: interleaved
rounds on one core (`taskset -c 3`), then benchstat with the Zig arm as the
base. x86_64 icelake_server, in an orb, so neighbors share the host. Go is
`golang.org/x/net/html` v0.62.0 and Rust is `scraper` 0.29.0 (html5ever
0.40.1). All three arms built the same trees on every page. Go has no
nested-divs row: x/net/html refuses input nested deeper than 512 elements.

## Before: `28755bd`, the first parser

```
                     │     zig      │                   go                   │                 rust                 │
                     │     B/s      │     B/s       vs base                  │     B/s       vs base                │
Parse/github-zig       38.18Mi ± 3%   62.22Mi ± 4%  +62.96% (p=0.000 n=10)     51.98Mi ± 2%  +36.16% (p=0.000 n=10)
Parse/hackernews       30.20Mi ± 4%   40.30Mi ± 3%  +33.44% (p=0.000 n=10)     36.03Mi ± 3%  +19.33% (p=0.000 n=10)
Parse/mdn-elements     34.79Mi ± 2%   66.47Mi ± 5%  +91.05% (p=0.000 n=10)     55.88Mi ± 3%  +60.62% (p=0.000 n=10)
Parse/nested-divs      449.2Ki ± 7%                                            244.1Ki ± 4%  -45.65% (p=0.000 n=10)
Parse/whatwg-spec      28.71Mi ± 6%   33.06Mi ± 7%  +15.18% (p=0.000 n=10)     39.63Mi ± 8%  +38.04% (p=0.000 n=10)
Parse/wikipedia-html   32.25Mi ± 5%   45.65Mi ± 8%  +41.53% (p=0.000 n=10)     48.03Mi ± 4%  +48.92% (p=0.000 n=10)
```

## After: `5264aa1`, tokenizer runs and text dispatch

```
                     │      zig       │                   go                    │                 rust                 │
                     │      B/s       │      B/s       vs base                  │     B/s       vs base                │
Parse/github-zig       100.25Mi ±  8%   60.93Mi ±  5%  -39.22% (p=0.000 n=10)     50.98Mi ± 4%  -49.15% (p=0.000 n=10)
Parse/hackernews        49.08Mi ±  5%   39.53Mi ± 11%  -19.46% (p=0.000 n=10)     35.39Mi ± 5%  -27.89% (p=0.000 n=10)
Parse/mdn-elements      70.92Mi ± 11%   64.32Mi ±  6%   -9.31% (p=0.023 n=10)     55.60Mi ± 8%  -21.61% (p=0.000 n=10)
Parse/nested-divs       449.2Ki ±  7%                                             253.9Ki ± 4%  -43.48% (p=0.000 n=10)
Parse/whatwg-spec       52.42Mi ±  5%   32.10Mi ±  4%  -38.77% (p=0.000 n=10)     40.14Mi ± 4%  -23.43% (p=0.000 n=10)
Parse/wikipedia-html    66.46Mi ± 17%   44.09Mi ±  4%  -33.66% (p=0.000 n=10)     47.49Mi ± 5%  -28.54% (p=0.000 n=10)
```

## The changes, and what each was worth

Each measured as an interleaved A/B of the Zig arm alone, pinned to one core.
Only the headline numbers were kept for these, not the benchstat output.

- `c71085f` tokenizer: take runs of ordinary characters in one step. About 2x
  on every real page: the data, RCDATA, RAWTEXT, script data, PLAINTEXT, tag
  name, attribute name, and attribute value states copy a run up to the next
  byte that matters to them instead of one code point per state step.
- `5264aa1` parser: dispatch a run of body text once, not once per word. About
  10% on text-heavy pages.
- `8fc003d` parser: copy an element's attribute strings in one allocation, and
  pass the tag the tokenizer already looked up. With `68bd28a`, 4 to 7% faster
  on all five real pages (p <= 0.029).
- `68bd28a` tokenizer: decode ASCII in `peek` without the UTF-8 decoder.
- Text node capacity: `text-capacity-20261030.md`.

Tried and dropped:

- A vectorized `takeRun`. No gain, and 7.8% slower on hackernews, whose runs
  are short. Reverted.
- Not copying the caller's input in `parse`: about 1%, and `feed` must copy for
  streaming anyway.
- Shrinking `Node`: dropped.
- Constant-time scope checks: not chosen.
