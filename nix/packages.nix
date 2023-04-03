# ------------------------------------------------------------------------------------------------
# declare packages
# ------------------------------------------------------------------------------------------------
{
  buildDeps,
  isStatic,
  mkBuilder,
  nimBuild,
  pkgs,
}: rec {
  # ------------------------------------------------------------------------------------------------
  kpkg = nimBuild {
    name = "kpkg";
    nativeBuildInputs = with buildDeps; [cligen libsha];
    propagatedBuildInputs = let
      git = pkgs.git.override {doInstallCheck = false;};
    in
      (with pkgs; [git libarchive shadow gnutar gzip openssl])
      ++ (
        if isStatic
        then [git]
        else [pkgs.git]
      );
  };

  # ------------------------------------------------------------------------------------------------

  chkupd = nimBuild {
    name = "chkupd";
    nativeBuildInputs = with buildDeps; [cligen libsha];
  };

  # ------------------------------------------------------------------------------------------------

  mari = nimBuild {
    name = "mari";
    nativeBuildInputs = with buildDeps; [httpbeast libsha];
  };

  # ------------------------------------------------------------------------------------------------

  purr = nimBuild {
    name = "purr";
    nativeBuildInputs = with buildDeps; [cligen libsha];
    propagatedBuildInputs = [kpkg];
  };

  # ------------------------------------------------------------------------------------------------

  kreastrap = nimBuild rec {
    name = "kreastrap";
    nativeBuildInputs = with buildDeps; [cligen libsha];
    propagatedBuildInputs = [purr pkgs.su];
    extraInstallPhase = ''
      cp -r ${../src/kreastrap/arch} $out/bin/arch
      cp -r ${../src/kreastrap/overlay} $out/bin/overlay
    '';
  };

  # ------------------------------------------------------------------------------------------------

  rootfs-nocc = mkBuilder "nocc" kreastrap;
  rootfs-builder = mkBuilder "builder" kreastrap;
  rootfs-server = mkBuilder "server" kreastrap;

  # ------------------------------------------------------------------------------------------------

  # dummy package to build everything at once
  all =
    pkgs.runCommand "build-all" {
      buildInputs = [kpkg chkupd mari purr kreastrap];
    } ''
      mkdir $out
    '';
}
