{
  lib,
  rustPlatform,
}:

rustPlatform.buildRustPackage {
  pname = "yuwai-tabs";
  version = "0.1.0";
  src = ../../programs/yuwai-tabs;
  cargoLock.lockFile = ../../programs/yuwai-tabs/Cargo.lock;

  postInstall = ''
    app="$out/share/yuwai-tabs/Yuwai Tabs.app"
    mkdir -p "$app/Contents/MacOS"
    cp ${../../programs/yuwai-tabs/macos/Info.plist} "$app/Contents/Info.plist"
    mv "$out/bin/yuwai-tabs" "$app/Contents/MacOS/yuwai-tabs"
    ln -s "../share/yuwai-tabs/Yuwai Tabs.app/Contents/MacOS/yuwai-tabs" "$out/bin/yuwai-tabs"
  '';

  meta = {
    description = "Same-app tabs for AeroSpace";
    platforms = lib.platforms.darwin;
  };
}
