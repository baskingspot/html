# Changelog

All notable changes to html are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `parse`, `parseFragment`, and `Parser`: the HTML Living Standard's tree construction, streaming, building a `Document`. Builds the expected tree for 1,963 of the 1,967 web-platform-tests tree construction cases; the other 4 expect `selectedcontent` cloning, which needs the DOM.
- `Document`: the parsed tree, with `node`, `element`, and `children` to walk it and `insertBefore`, `append`, and `remove` to change it.
- `Tokenizer`: the HTML Living Standard's tokenizer, streaming, with every parse error code. Passes all 7,045 html5lib-tests tokenizer cases.

### Changed

- `Document.Attribute`, `Document.Node`, `Document.Element`, and `Parser.Context`: fields no longer have defaults, so callers construct with `Attribute.init`, `Node.init`, `Element.init`, or `Context.init` instead of `.{}` or a partial literal.
