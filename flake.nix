{
  inputs = {
    nixpkgs.url      = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url  = "github:numtide/flake-utils";
    nixgl.url        = "github:guibou/nixGL";
    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, nixgl, rust-overlay, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ nixgl.overlay (import rust-overlay) ];
        pkgs = import nixpkgs {
          inherit system overlays;
        };
        local-rust = pkgs.rust-bin.stable.latest.default.override {
          extensions = [ "rust-analysis" ];
        };
      in
      {
        checks = {
          tests = pkgs.stdenv.mkDerivation {
            name = "emu-tests";
            src = ./.;

            nativeBuildInputs = with pkgs; [
              odin
            ];

            buildPhase = ''
              mkdir -p bin/
              make test
            '';
            installPhase = ''
              touch $out
            '';
          };
        };

        devShell = pkgs.mkShell {
          buildInputs = with pkgs; (if pkgs.system == "aarch64-darwin" || pkgs.system == "x86_64-darwin" then [
            git
            local-rust
            pkgsCross.riscv64-embedded.buildPackages.gcc
            odin
            ols
            binutils
            clang
          ] else if pkgs.system == "x86_64-linux" then [
            pkg-config
            binutils
            odin
            ols
            local-rust
            libGL
            xorg.libX11
            xorg.libXi
            xorg.xinput
            xorg.libXcursor
            xorg.libXrandr
            xorg.libXinerama
            pkgs.nixgl.nixGLIntel
          ] else throw "unsupported system" );
        };

        # packages = {
        #   emu-elf = pkgs.stdenv.mkDerivation rec {
        #     pname = "emu";
        #     version = "0.1";
        #     src = ./.;

        #     buildInputs = with pkgs; [
        #       odin
        #     ];
        #     installPhase = ''
        #       mkdir -p $out/bin
        #       cp bin/ $out/bin/editor
        #     '';
        #   };
        # };
      }
    );
}
