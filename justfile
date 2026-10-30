# html: HTML in Zig, the way the WHATWG HTML standard parses it. `just --list`
# shows the recipes. AGENTS.md holds the working conventions.

[private]
default:
    @just --list

[doc("Unit tests and the html5lib-tests corpus, in Debug and ReleaseSafe")]
[group("test")]
test:
    zig build test --summary all
    zig build test -Doptimize=ReleaseSafe --summary all

[doc("Lint Zig and this justfile: ziglint, zig fmt, and just --fmt")]
[group("lint")]
lint:
    ziglint
    zig fmt --check src test build.zig build.zig.zon
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src test build.zig build.zig.zon
    just --fmt

[doc("Regenerate src/entities.zig from the standard's named character reference table")]
[group("build")]
entities:
    curl -sSfL https://html.spec.whatwg.org/entities.json -o .zig-cache/entities.json
    python3 tools/entities.py .zig-cache/entities.json > src/entities.zig

[doc("Everything CI runs: the tests and lint")]
[group("ci")]
ci: test lint
