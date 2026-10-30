# html: HTML in Zig, the way the WHATWG HTML standard parses it. `just --list`
# shows the recipes. AGENTS.md holds the working conventions.

markdown := "README.md AGENTS.md CHANGELOG.md THIRD_PARTY.md bench/README.md docs/content docs/config.toml docs/slop .github"

[private]
default:
    @just --list

[doc("Unit tests and the html5lib-tests corpus, in Debug and ReleaseSafe")]
[group("test")]
test:
    zig build test --summary all
    zig build test -Doptimize=ReleaseSafe --summary all

[doc("Lint Zig, Nix, Markdown, the workflows, and this justfile: ziglint, ast-grep (baskingspot-lint), zig fmt, nix fmt, oxfmt, actionlint, zizmor, and just --fmt")]
[group("lint")]
lint:
    ziglint
    baskingspot-lint src
    zig fmt --check src docs/examples test bench build.zig build.zig.zon
    nix fmt -- --ci
    oxfmt --check {{ markdown }}
    actionlint
    zizmor .
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src docs/examples test bench build.zig build.zig.zon
    nix fmt
    oxfmt {{ markdown }}
    just --fmt

[doc("Regenerate src/entities.zig from the standard's named character reference table")]
[group("build")]
entities:
    curl -sSfL https://html.spec.whatwg.org/entities.json -o .zig-cache/entities.json
    python3 tools/entities.py .zig-cache/entities.json > src/entities.zig

[doc("Everything CI runs: the tests, lint, and the site build")]
[group("ci")]
ci: test lint doc

[doc("Build the site into zig-out/site/html/: the guide (Zola, from docs/) and the API reference (docgen JSON, rendered by the theme's api.html) under api/. The router in baskingspot/site serves /html/... from it")]
[group("docs")]
doc: api
    baskingspot-docs build html

[doc("Edit the guide with live reload (http://127.0.0.1:1111), API reference included")]
[group("docs")]
guide: api
    baskingspot-docs serve html

# The API reference data. docgen comes from the baskingspot flake's docs shell,
# so this is not a Zig build dependency.
[private]
api:
    docgen --root src/root.zig --title html --repo-url https://github.com/baskingspot/html --rev main --format json --out docs/data

[doc("Deploy the rendered docs to Cloudflare as an assets-only Worker (config in wrangler.jsonc). Needs CLOUDFLARE_API_TOKEN in the environment, plus CLOUDFLARE_ACCOUNT_ID if the token can see more than one account")]
[group("docs")]
doc-deploy: doc
    wrangler deploy

[doc("Fetch and generate the parse benchmark corpus in bench/corpus-gen/, and verify it against bench/corpus/SHA256SUMS")]
[group("bench")]
bench-corpus:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p bench/corpus-gen
    grep -v '^#' bench/corpus/sources.tsv | while IFS=$'\t' read -r name url; do
        [ -f "bench/corpus-gen/$name" ] || curl -sSfL --compressed -o "bench/corpus-gen/$name" "$url"
    done
    # Ten thousand nested elements: every start tag's scope checks walk them.
    printf '<div>%.0s' $(seq 10000) > bench/corpus-gen/nested-divs.html
    cd bench/corpus-gen && sha256sum --quiet --check ../corpus/SHA256SUMS

[doc("Local parse benchmarks of this package alone. The numbers are not claims")]
[group("bench")]
bench *ARGS: bench-corpus
    zig build bench -- {{ ARGS }}

[doc("Compare with Go's x/net/html and Rust's scraper (html5ever) on this machine: interleaved rounds on one core, then benchstat. The numbers are not claims")]
[group("bench")]
bench-compare ROUNDS="10": bench-corpus
    #!/usr/bin/env bash
    set -euo pipefail
    out=zig-out/bench-compare
    rm -rf "$out" && mkdir -p "$out"
    zig build bench-install
    go build -C bench/go -o ../../zig-out/bin/parse-go .
    cargo build --quiet --release --locked --manifest-path bench/rust/Cargo.toml
    cp bench/rust/target/release/parse-rust zig-out/bin/
    arms=(zig go rust)
    # The trees must match before their timings mean anything.
    for arm in "${arms[@]}"; do zig-out/bin/parse-$arm check > "$out/check-$arm.txt"; done
    for arm in go rust; do
        if ! diff <(cut -f1 "$out/check-zig.txt") <(cut -f1 "$out/check-$arm.txt") > "$out/check-diff-$arm.txt"; then
            echo "node counts differ between zig and $arm:"; cat "$out/check-diff-$arm.txt"
        fi
    done
    paste "$out"/check-{zig,go,rust}.txt | awk -F'\t' '{ print $1 "\n  zig  " $2 "\n  go   " $4 "\n  rust " $6 }'
    # The last core, and one round of each arm at a time in a rotating order,
    # so drift on the machine lands on every arm alike.
    core=$(( $(nproc) - 1 ))
    for round in $(seq 0 $(( {{ ROUNDS }} - 1 ))); do
        for i in 0 1 2; do
            arm=${arms[$(( (round + i) % 3 ))]}
            taskset -c "$core" zig-out/bin/parse-$arm >> "$out/raw-$arm.txt"
        done
    done
    # Only the result lines: testingx's config header, which the other arms
    # lack, would put each arm in a table of its own.
    for arm in "${arms[@]}"; do grep '^Benchmark' "$out/raw-$arm.txt" > "$out/$arm.txt"; done
    benchstat zig="$out/zig.txt" go="$out/go.txt" rust="$out/rust.txt" | tee "$out/benchstat.txt"
