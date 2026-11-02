{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.follows = "baskingspot/flake-parts";
    baskingspot = {
      url = "github:baskingspot/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # imports and inputsFrom below mirror each other, including the
      # toolchain version: pick that once, in the import.
      imports = with inputs.baskingspot.flakeModules; [
        base
        docs
        zig."0.16"
      ];

      perSystem =
        { pkgs, config, ... }:
        {
          devShells.default = pkgs.mkShell {
            inputsFrom = [
              config.devShells.base
              config.devShells.docs
              config.devShells."zig-0-16"
            ];

            packages = with pkgs; [
              # `just bench-compare` (bench/README.md): go and the rust
              # toolchain build the x/net/html and html5ever arms, and
              # nixpkgs' goperf is golang.org/x/perf, which supplies benchstat,
              # and util-linux supplies taskset, which pins every arm to one core.
              go
              cargo
              rustc
              goperf
              util-linux
            ];
          };
        };
    };
}
