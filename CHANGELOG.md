# Changelog

All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `parse`, `parseFragment`, and `Parser`: the HTML Living Standard's tree construction, streaming, building a `Document`. Builds the expected tree for 1,963 of the 1,967 web-platform-tests tree construction cases; the other 4 expect `selectedcontent` cloning, which needs the DOM.
- `Document`: the parsed tree, with `node`, `element`, and `children` to walk it and `insertBefore`, `append`, and `remove` to change it.
- `Tokenizer`: the HTML Living Standard's tokenizer, streaming, with every parse error code. Passes all 7,045 html5lib-tests tokenizer cases.
