let
  sources = import ./nix/sources.nix;
  pkgs = import sources.nixpkgs { };

  ###
  ### Coreboot Toolchain Sources
  ###

  gmpTarName = "gmp-6.2.0.tar.xz";
  gmpTar = pkgs.fetchurl {
    url = "https://ftpmirror.gnu.org/gmp/${gmpTarName}";
    sha256 = "09hmg8k63mbfrx1x3yy6y1yzbbq85kw5avbibhcgrg9z3ganr3i5";
  };

  mpfrTarName = "mpfr-4.1.0.tar.xz";
  mpfrTar = pkgs.fetchurl {
    url = "https://ftpmirror.gnu.org/mpfr/${mpfrTarName}";
    sha256 = "0zwaanakrqjf84lfr5hfsdr7hncwv9wj0mchlr7cmxigfgqs760c";
  };

  mpcTarName = "mpc-1.2.0.tar.gz";
  mpcTar = pkgs.fetchurl {
    url = "https://ftpmirror.gnu.org/mpc/${mpcTarName}";
    sha256 = "19pxx3gwhwl588v496g3aylhcw91z1dk1d5x3a8ik71sancjs3z9";
  };

  binutilsTarName = "binutils-2.35.tar.xz";
  binutilsTar = pkgs.fetchurl {
    url = "https://ftpmirror.gnu.org/binutils/${binutilsTarName}";
    sha256 = "119g6340ksv1jkg6bwaxdp2whhlly22l9m30nj6y284ynjgna48v";
  };

  gccVersion = "8.3.0";
  gccTarName = "gcc-${gccVersion}.tar.xz";
  gccTar = pkgs.fetchurl {
    url = "https://ftpmirror.gnu.org/gcc/gcc-${gccVersion}/${gccTarName}";
    sha256 = "0b3xv411xhlnjmin2979nxcbnidgvzqdf4nbhix99x60dkzavfk4";
  };

  nasmVersion = "2.15.03";
  nasmTarName = "nasm-${nasmVersion}.tar.bz2";
  nasmTar = pkgs.fetchurl {
    url = "https://www.nasm.us/pub/nasm/releasebuilds/${nasmVersion}/${nasmTarName}";
    sha256 = "0y6p3d5lhmwzvgi85f00sz6c485ir33zd1nskzxby4pikcyk9rq4";
  };

  acpicaTarName = "acpica-unix2-20200717.tar.gz";
  acpicaTar = pkgs.fetchurl {
    url = "https://acpica.org/sites/acpica/files/${acpicaTarName}";
    sha256 = "0jyy71szjr40c8v40qqw6yh3gfk8d6sl3nay69zrn5d88i3r0jca";
  };

  ###
  ### Coreboot Sources
  ###

  corebootVersion = "4.13";
  corebootSource = pkgs.fetchurl {
    url = "https://coreboot.org/releases/coreboot-${corebootVersion}.tar.xz";
    sha256 = "0sl50aajnah4a138sr3jjm3ydc8gfh5vvlhviz3ypp95b9jdlya7";
  };

in
rec {

  # We first prepare a FHS-compatible chroot environment with all
  # dependencies that the coreboot toolchain requires to build.
  corebootEnv = pkgs.buildFHSUserEnv {
    name = "coreboot-env";
    targetPkgs = pkgs: with pkgs; [ gcc binutils gnumake coreutils patch zlib zlib.dev curl git m4 bison flex ];
  };

  # Then we build the coreboot toolchain in this chroot. We manually
  # link all the sources into the right place, because the build is
  # sandboxed and is not allowed to fech from the network on its own.
  corebootToolchain = pkgs.stdenv.mkDerivation {
    pname = "coreboot-toolchain";
    version = "4.13";

    src = corebootSource;

    # Because the binaries that are build in the chroot reference
    # shared libraries in a way that will not work outside of it, we
    # need to patch the resulting ELFs.
    #
    # This is conceptually similar to how externally-built binary
    # packages, such as Steam or MS Teams, are built. autoPatchelfHook
    # is taking care of the heavy lifting here.
    #
    # There is small wrinkle here: autoPatchelfHook assumes it has a
    # working compilation environment with binutils. That's why we use
    # `mkDerivation` instead of `mkDerivationNoCC` for the toolchain
    # derivation.
    nativeBuildInputs = [ corebootEnv pkgs.autoPatchelfHook ];
    buildInputs = [ pkgs.zlib pkgs.flex pkgs.gcc.cc.lib ];

    postPatch = ''
      mkdir -p util/crossgcc/tarballs
      ln -s ${gmpTar} util/crossgcc/tarballs/${gmpTarName}
      ln -s ${mpfrTar} util/crossgcc/tarballs/${mpfrTarName}
      ln -s ${mpcTar} util/crossgcc/tarballs/${mpcTarName}
      ln -s ${binutilsTar} util/crossgcc/tarballs/${binutilsTarName}
      ln -s ${gccTar} util/crossgcc/tarballs/${gccTarName}
      ln -s ${nasmTar} util/crossgcc/tarballs/${nasmTarName}
      ln -s ${acpicaTar} util/crossgcc/tarballs/${acpicaTarName}
    '';

    buildPhase = let
      buildScript = pkgs.writeText "coreboot-toolchain-build" ''
        export PATH=/bin:/sbin:/usr/bin:/usr/sbin

        mkdir -p $out
        make crossgcc-i386 CPUS=$(nproc) DEST=$out
      '';
    in ''
      coreboot-env ${buildScript}
    '';

    installPhase = ''
      echo Already installed.
    '';

  };

  # Finally, we can build coreboot itself. It's cross compilation
  # scripting (xcompile) will find its toolchain in PATH and use it to
  # build the target binaries. The normal Nix toolchain is used for
  # host binaries.
  #
  # The coreboot build is well-behaved, so there is no need to do it
  # in a chroot.
  coreboot = pkgs.stdenv.mkDerivation {
    pname = "coreboot";
    version = corebootVersion;

    src = corebootSource;

    nativeBuildInputs = [ corebootToolchain ];

    postPatch = ''
      patchShebangs util/xcompile/xcompile
    '';

    buildPhase = ''
      cp ${./config} .config

      make olddefconfig
      make
    '';

    installPhase = ''
      prefix=$out/share/coreboot

      mkdir -p $prefix
      install -m 0444 build/coreboot.rom $prefix
    '';
  };
}
