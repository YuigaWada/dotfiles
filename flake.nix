{
  description = "Yuiga Wada's reproducible macOS and Ubuntu environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    git-number = {
      url = "github:holygeek/git-number";
      flake = false;
    };

    agmsg = {
      url = "github:fujibee/agmsg";
      flake = false;
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      nix-darwin,
      home-manager,
      git-number,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      identity = import ./nix/identity.nix;
      runtimeUsername = builtins.getEnv "DOTFILES_USERNAME";
      runtimeHome = builtins.getEnv "DOTFILES_HOME";
      hasRuntimeIdentity = runtimeUsername != "" && runtimeHome != "";
      currentIdentity = identity // {
        username = runtimeUsername;
        darwin = identity.darwin // {
          homeDirectory = runtimeHome;
        };
        ubuntu = identity.ubuntu // {
          homeDirectory = runtimeHome;
        };
      };
      linuxSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      supportedSystems = [ "aarch64-darwin" ] ++ linuxSystems;

      allowUnfreePredicate =
        pkg:
        builtins.elem (lib.getName pkg) [
          "claude-code"
          "cuda_nvml_dev"
          "antigravity-cli"
        ];

      overlay = final: prev: {
        # Keep the upstream macOS app signature intact. Nix's default fixup
        # rewrites the Mach-O executable in the prebuilt release bundle.
        aerospace = prev.aerospace.overrideAttrs { dontFixup = true; };

        yuwai-tabs = final.callPackage ./nix/packages/yuwai-tabs.nix { };

        aerospace-actions = final.writeShellScriptBin "aerospace-actions" (
          builtins.readFile ./config/aerospace/actions.sh
        );

        git-number = final.callPackage ./nix/packages/git-number.nix {
          src = git-number;
        };

        yuwd-cli = final.writeShellApplication {
          name = "yuwd";
          runtimeInputs = [ final.just ];
          text = builtins.readFile ./scripts/yuwd.sh;
        };

        dotfiles-cli = final.writeShellApplication {
          name = "dotfiles";
          runtimeInputs = [ final.yuwd-cli ];
          text = ''
            exec yuwd "$@"
          '';
        };

        dotcmd = final.writeShellApplication {
          name = "dotcmd";
          runtimeInputs = [ final.yuwd-cli ];
          text = ''
            exec yuwd "$@"
          '';
        };

        dotfiles-doctor = final.writeShellApplication {
          name = "dotfiles-doctor";
          runtimeInputs = with final; [
            bash
            coreutils
            findutils
            git
            gnugrep
            gnused
            jq
            ncurses
            which
            yq-go
          ];
          text = builtins.readFile ./scripts/doctor.sh;
        };

        dotfiles-cleanup-legacy = final.writeShellApplication {
          name = "dotfiles-cleanup-legacy";
          runtimeInputs = with final; [
            bash
            coreutils
            findutils
            gnugrep
            gnused
          ];
          text = builtins.readFile ./scripts/cleanup-legacy.sh;
        };

        agent-tools-updater = final.writeShellApplication {
          name = "update-agent-tools";
          runtimeInputs = with final; [
            coreutils
            nix
          ];
          text = builtins.readFile ./scripts/update-agent-tools.sh;
        };

        mediaanalysisd-cleanup = final.writeShellApplication {
          name = "cleanup-mediaanalysisd";
          text = builtins.readFile ./scripts/cleanup-mediaanalysisd.sh;
        };

      };

      mkPkgs =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ overlay ];
          config = { inherit allowUnfreePredicate; };
        };

      mkUbuntuHome =
        system: profileIdentity:
        home-manager.lib.homeManagerConfiguration {
          pkgs = mkPkgs system;
          extraSpecialArgs = {
            inherit inputs;
            identity = profileIdentity;
          };
          modules = [
            ./nix/home/common.nix
            ./nix/home/ubuntu.nix
          ];
        };

      ubuntuX86 = mkUbuntuHome "x86_64-linux" identity;
      ubuntuArm = mkUbuntuHome "aarch64-linux" identity;
      currentUbuntuX86 = mkUbuntuHome "x86_64-linux" currentIdentity;
      currentUbuntuArm = mkUbuntuHome "aarch64-linux" currentIdentity;

      mkYuwdCliTest =
        system:
        let
          pkgs = mkPkgs system;
        in
        pkgs.runCommand "yuwd-cli-test" { nativeBuildInputs = [ pkgs.bash ]; } ''
          bash ${./tests/test-yuwd-cli.sh} ${./scripts/yuwd.sh}
          touch "$out"
        '';

      mkAgentToolsUpdaterTest =
        system:
        let
          pkgs = mkPkgs system;
        in
        pkgs.runCommand "agent-tools-updater-test"
          {
            nativeBuildInputs = with pkgs; [
              bash
              gnugrep
            ];
          }
          ''
            bash ${./tests/test-update-agent-tools.sh} ${./scripts/update-agent-tools.sh}
            touch "$out"
          '';

      mkMediaanalysisdCleanupTest =
        system:
        let
          pkgs = mkPkgs system;
        in
        pkgs.runCommand "mediaanalysisd-cleanup-test"
          {
            nativeBuildInputs = with pkgs; [
              bash
              gnugrep
            ];
          }
          ''
            bash ${./tests/test-cleanup-mediaanalysisd.sh} ${./scripts/cleanup-mediaanalysisd.sh}
            touch "$out"
          '';

      mkMacos =
        profileIdentity:
        nix-darwin.lib.darwinSystem {
          system = "aarch64-darwin";
          specialArgs = {
            inherit inputs;
            identity = profileIdentity;
            inherit self;
          };
          modules = [
            ./nix/darwin
            home-manager.darwinModules.home-manager
            {
              nixpkgs = {
                overlays = [ overlay ];
                config = { inherit allowUnfreePredicate; };
              };

              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                backupFileExtension = "before-nix";
                extraSpecialArgs = {
                  inherit inputs;
                  identity = profileIdentity;
                };
                users.${profileIdentity.username}.imports = [
                  ./nix/home/common.nix
                  ./nix/home/macos.nix
                ];
              };
            }
          ];
        };
      macos = mkMacos identity;
      currentMacos = mkMacos currentIdentity;
    in
    {
      overlays.default = overlay;

      darwinConfigurations = lib.optionalAttrs hasRuntimeIdentity {
        current = currentMacos;
      };

      homeConfigurations = {
        "${identity.username}@ubuntu-x86_64" = ubuntuX86;
        "${identity.username}@ubuntu-aarch64" = ubuntuArm;
      }
      // lib.optionalAttrs hasRuntimeIdentity {
        "current@ubuntu-x86_64" = currentUbuntuX86;
        "current@ubuntu-aarch64" = currentUbuntuArm;
      };

      checks = {
        aarch64-darwin = {
          agent-tools-updater = mkAgentToolsUpdaterTest "aarch64-darwin";
          darwin = macos.system;
          mediaanalysisd-cleanup = mkMediaanalysisdCleanupTest "aarch64-darwin";
          yuwd-cli = mkYuwdCliTest "aarch64-darwin";
        };
        x86_64-linux = {
          agent-tools-updater = mkAgentToolsUpdaterTest "x86_64-linux";
          home = ubuntuX86.activationPackage;
          yuwd-cli = mkYuwdCliTest "x86_64-linux";
        };
        aarch64-linux = {
          agent-tools-updater = mkAgentToolsUpdaterTest "aarch64-linux";
          home = ubuntuArm.activationPackage;
          yuwd-cli = mkYuwdCliTest "aarch64-linux";
        };
      };

      packages = lib.genAttrs supportedSystems (
        system:
        let
          pkgs = mkPkgs system;
        in
        {
          default = pkgs.dotfiles-doctor;
          doctor = pkgs.dotfiles-doctor;
          cleanup-legacy = pkgs.dotfiles-cleanup-legacy;
        }
        // lib.optionalAttrs (system == "aarch64-darwin") {
          yuwai-tabs = pkgs.yuwai-tabs;
        }
      );

      apps = lib.genAttrs supportedSystems (
        system:
        let
          pkgs = mkPkgs system;
        in
        {
          default = {
            type = "app";
            program = "${pkgs.dotfiles-doctor}/bin/dotfiles-doctor";
            meta.description = "Verify that the active environment comes from Nix";
          };
          doctor = {
            type = "app";
            program = "${pkgs.dotfiles-doctor}/bin/dotfiles-doctor";
            meta.description = "Verify that the active environment comes from Nix";
          };
          cleanup-legacy = {
            type = "app";
            program = "${pkgs.dotfiles-cleanup-legacy}/bin/dotfiles-cleanup-legacy";
            meta.description = "Preview or retire legacy package managers";
          };
          home-manager = {
            type = "app";
            program = "${home-manager.packages.${system}.home-manager}/bin/home-manager";
            meta.description = "Run the pinned Home Manager CLI";
          };
        }
        // lib.optionalAttrs (system == "aarch64-darwin") {
          darwin-rebuild = {
            type = "app";
            program = "${nix-darwin.packages.${system}.darwin-rebuild}/bin/darwin-rebuild";
            meta.description = "Run the pinned nix-darwin rebuild CLI";
          };
        }
      );

      formatter = lib.genAttrs supportedSystems (system: (mkPkgs system).nixfmt-tree);

      devShells = lib.genAttrs supportedSystems (
        system:
        let
          pkgs = mkPkgs system;
        in
        {
          default = pkgs.mkShellNoCC {
            packages = with pkgs; [
              cargo
              go
              nodejs_22
              pnpm
              rustc
              uv
            ];
          };
        }
      );
    };
}
