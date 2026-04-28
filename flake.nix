{
  description = "Focus Rail - Headless camera macro focus rail controller";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        nativeBuildInputs = [
          pkgs.zig
          pkgs.zls
          pkgs.pkg-config
        ];
        buildInputs = [
          pkgs.libgphoto2
          pkgs.libgpiod
          pkgs.panotools
          pkgs.libexif
          pkgs.libjpeg_turbo
          pkgs.libpng
          pkgs.libtiff
          # Focus stack processing (desktop only)
          pkgs.hugin        # provides align_image_stack
          pkgs.enblend-enfuse  # provides enfuse
          pkgs.jq           # manifest parsing in scripts
        ];
      };
    };
}
