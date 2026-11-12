{
  lib,
  buildGoModule,
  src,
}:

buildGoModule {
  pname = "git-number";
  version = "unstable";
  inherit src;

  vendorHash = null;

  meta = {
    description = "Use numbers to address files in Git commands";
    homepage = "https://github.com/holygeek/git-number";
    license = lib.licenses.mit;
    mainProgram = "git-number";
    platforms = lib.platforms.unix;
  };
}
