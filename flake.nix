{
  description = "OpenSoundcard development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system:
          f {
            pkgs = import nixpkgs { inherit system; };
          });
    in
    {
      devShells = forAllSystems ({ pkgs }: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            cargo
            clippy
            rust-cbindgen
            rustc
            rustfmt
            shellcheck
            shfmt
            tea
          ];
        };
      });
    };
}
