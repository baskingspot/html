# Text nodes reserved six to twelve times their text

Change: `insertChars` in `src/Parser.zig` creates a text node's list with
exactly the text's length (`ArrayList.initCapacity`) instead of `appendSlice`
on an empty list. Appends to an existing text node are unchanged.

## Why

A text node is an `ArrayList(u8)` in the document's arena. Zig 0.16's
`growCapacity` (`lib/std/array_list.zig`) reserves `n + n/2 + init_capacity`
for the first `n` bytes, where `init_capacity` is `std.atomic.cache_line /
@sizeOf(T)`: 128 on x86-64. So a three-byte whitespace node took 132 bytes, and
the arena never gives the slack back.

A plain slice that grows with the arena's in-place `resize` was rejected. When
another arena allocation lands between two appends to the same node, as
foster-parented text does in `<table>a<tr x>b<tr x>c...`, every append would
copy the whole node, which is quadratic. The list keeps geometric growth for
those nodes.

## Memory

`parse-zig check` with a temporary column for the arena's `queryCapacity()` and
the sum of every text node's `capacity`. ReleaseFast, x86_64 icelake_server.
`bytes` is everything the parse requested from the gpa, scratch included.

| Document       | Text bytes | Text capacity, before | after     | Arena, before | after      | gpa bytes, before | after       |
| -------------- | ---------- | --------------------- | --------- | ------------- | ---------- | ----------------- | ----------- |
| github-zig     | 22,940     | 230,631               | 23,797    | 774,202       | 497,646    | 1,598,087         | 1,321,507   |
| hackernews     | 3,904      | 64,774                | 31,153    | 187,294       | 113,778    | 444,245           | 370,705     |
| mdn-elements   | 101,341    | 477,579               | 130,573   | 866,974       | 321,724    | 1,783,262         | 1,237,988   |
| nested-divs    | 0          | 0                     | 0         | 0             | 0          | 1,353,748         | 1,353,748   |
| whatwg-spec    | 4,595,975  | 56,115,493            | 5,873,869 | 76,270,204    | 32,997,398 | 164,594,848       | 121,321,994 |
| wikipedia-html | 114,238    | 1,135,181             | 139,082   | 1,890,962     | 1,211,390  | 4,409,218         | 3,729,622   |

The remaining slack is in nodes that grew. hackernews still reserves eight
times its text: its text sits in table cells, where the parser dispatches each
run of words separately and each append grows the node. Growing in place to
the exact length when the node is the arena's newest allocation would close
most of that; it was not tried.

## Time

Interleaved: old binary, new binary, ten rounds, each `--count=1`, pinned with
`taskset -c 3`. benchstat:

```
                     │     old     │                new                 │
                     │   sec/op    │   sec/op     vs base               │
Parse/github-zig       2.509m ± 3%   2.378m ± 3%  -5.21% (p=0.000 n=10)
Parse/hackernews       606.5µ ± 1%   591.5µ ± 7%       ~ (p=0.123 n=10)
Parse/mdn-elements     2.895m ± 4%   2.743m ± 5%  -5.27% (p=0.007 n=10)
Parse/nested-divs      108.9m ± 3%   109.8m ± 9%       ~ (p=0.796 n=10)
Parse/whatwg-spec      268.0m ± 4%   247.0m ± 4%  -7.84% (p=0.000 n=10)
Parse/wikipedia-html   6.663m ± 5%   6.365m ± 5%  -4.47% (p=0.003 n=10)
geomean                9.746m        9.345m       -4.11%
```

`just ci` passed with the change: no tree or token differences in either
corpus.
