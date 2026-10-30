# Allocation

## What a `Document` owns

- `nodes`: one `ArrayList(Node)` on the gpa. Nodes link by `Node.Index`
  (`u32`), so the array grows and moves without pointers to fix up.
- `arena`: an `ArenaAllocator` on the gpa holding every string the tree keeps:
  `.other` element names, attribute arrays and their strings (one allocation
  per element), comments, doctype fields, processing instructions, and text.
  Names of known tags point at the static `@tagName(tag)` and take nothing.

`Document.deinit` frees both. `parse` returns the document by value, so the
caller owns them.

The node array is deliberately not in the arena. An arena grows only its newest
allocation in place, and strings land between node appends, so every resize
of an arena-backed array would leave a dead copy behind; on whatwg-spec,
333,000 elements, that is megabytes.

## What parsing owns

Scratch on the gpa, freed by `Parser.deinit`, so the document holds only the
tree:

- Parser: the open elements, active formatting elements, template modes,
  attribute scratch, and pending table text.
- Tokenizer: the input buffer and one `ArrayList` per kind of token data. Each
  is cleared with `clearRetainingCapacity` per token, so allocation stops once
  they are warm. A token's slices borrow them until the next `next`.
  `feed` copies the caller's bytes and slides the unconsumed tail to the front.

## Text

A text node is an `ArrayList(u8)` in the arena, because adjacent text appends
to it. A new node gets exactly its length; appends grow geometrically, and
`ArrayList` tries the arena's in-place remap first. A plain slice regrown on
each append would be quadratic when other arena allocations interleave, as
foster-parented text does. Measurements: `results/text-capacity-20261030.md`.

## Known costs

- `Document.remove` unlinks a node; its slot and strings stay until `deinit`.
  Fine for parse-then-read; a long-lived, mutation-heavy DOM would grow.
- There is no leaky variant like toml's `parseFromSliceLeaky`. A caller's arena
  would still need a separate allocator for the node array, for the reason
  above.
- Text nodes that grow keep their growth slack; see the results file.
