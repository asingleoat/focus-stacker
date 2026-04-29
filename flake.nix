{
  description = "Focus Rail - Headless camera macro focus rail controller";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    vkfft-src = {
      url = "github:DTolm/VkFFT";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, vkfft-src }:
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
          pkgs.pffft
          pkgs.libjpeg_turbo
          pkgs.libpng
          pkgs.libtiff
          pkgs.vulkan-headers
          pkgs.vulkan-loader
          pkgs.glslang
          # Focus stack processing (desktop only)
          pkgs.hugin        # provides align_image_stack
          pkgs.enblend-enfuse  # provides enfuse
          pkgs.jq           # manifest parsing in scripts
        ];
        shellHook = ''
          export VKFFT_INCLUDE_DIR="${vkfft-src}"
          export PFFFT_INCLUDE_DIR="${pkgs.pffft}/include"
          export PFFFT_LIB_DIR="${pkgs.pffft}/lib"
        '';
      };
    };
}
