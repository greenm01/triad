{
  description = "Triad dynamic window-management client for River";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    dank-material-shell = {
      url = "github:AvengeMedia/DankMaterialShell";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          lib = pkgs.lib;

          triad = pkgs.buildNimPackage {
            pname = "triad";
            version = "0.1.0";

            src = lib.cleanSource ./.;
            lockFile = ./nix/triad-nim-lock.json;
            requiredNimVersion = 2;

            nativeBuildInputs = [ pkgs.pkg-config ];
            buildInputs = [
              pkgs.wayland
              pkgs.libxkbcommon
              pkgs.pixman
            ];

            doCheck = false;

            nimFlags = [
              "--path:src"
              "-d:release"
              "--opt:speed"
            ];

            postInstall = ''
              install -Dm644 config.default.kdl $out/share/triad/config.default.kdl
              install -Dm755 tools/river-triad-session.sh $out/libexec/triad/river-triad-session
              install -Dm755 tools/triad-manager-loop.sh $out/libexec/triad/triad-manager-loop
            '';

            meta = {
              description = "Dynamic window-management client for River";
              homepage = "https://github.com/greenm01/triad";
              license = lib.licenses.mit;
              platforms = lib.platforms.linux;
              mainProgram = "triad";
            };
          };

          dankShell = inputs.dank-material-shell.packages.${system}.dms-shell;

          sessionRuntimePackages = [
            triad
            pkgs.river
            pkgs.dbus
            pkgs.pipewire
            pkgs.wireplumber
            pkgs.xdg-desktop-portal
            pkgs.xdg-desktop-portal-wlr
            pkgs.xdg-desktop-portal-gtk
            pkgs.grim
            pkgs.slurp
            pkgs.wl-clipboard
            pkgs.kitty
            pkgs.fuzzel
            pkgs.wtype
            pkgs.waybar
            pkgs.swaylock
            pkgs.gtklock
            pkgs.sunsetr
            pkgs.quickshell
            pkgs.noctalia-shell
            dankShell
            pkgs.janet
            pkgs.jq
            pkgs.procps
          ];

          managerLoop = pkgs.writeShellApplication {
            name = "triad-manager-loop";
            runtimeInputs = [
              pkgs.coreutils
              pkgs.gnused
            ];
            text = ''
              state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/triad"
              mkdir -p "$state_dir"
              triad_bin="''${TRIAD_BIN:-${triad}/bin/triad}"
              triad_args=""

              case "''${TRIAD_DEV_MODE:-}" in
                1|true|TRUE|yes|YES|on|ON)
                  triad_args="--dev-mode"
                  export TRIAD_DEV_MODE=1
                  export TRIAD_BEHAVIOR_LOG="''${TRIAD_BEHAVIOR_LOG:-1}"
                  ;;
              esac

              rapid_restarts=0

              while :; do
                start_sec="$(date +%s)"
                stamp="$(date +%Y%m%d-%H%M%S)"
                log="$state_dir/triad-$stamp.log"
                latest="$state_dir/triad-latest.log"

                ln -sfn "$log" "$latest" 2>/dev/null || true
                printf '%s\n' "triad-manager-loop: starting triad, log=$log" >&2

                "$triad_bin" $triad_args >>"$log" 2>&1
                status="$?"
                end_sec="$(date +%s)"
                runtime_sec=$((end_sec - start_sec))

                if [ "$runtime_sec" -lt 5 ]; then
                  rapid_restarts=$((rapid_restarts + 1))
                else
                  rapid_restarts=0
                fi

                if [ "$status" -eq 0 ]; then
                  if [ "$rapid_restarts" -ge 3 ]; then
                    printf '%s\n' "triad-manager-loop: triad exited cleanly after ''${runtime_sec}s; rapid restart count ''${rapid_restarts}, backing off" >&2
                    sleep 5
                  else
                    printf '%s\n' "triad-manager-loop: triad exited cleanly after ''${runtime_sec}s; restarting" >&2
                    sleep 0.2
                  fi
                else
                  printf '%s\n' "triad-manager-loop: triad exited with status $status; leaving River session" >&2
                  exit "$status"
                fi
              done
            '';
          };

          riverTriadSession = pkgs.writeShellApplication {
            name = "river-triad-session";
            runtimeInputs = sessionRuntimePackages;
            text = ''
              export XDG_CURRENT_DESKTOP=river
              export XDG_SESSION_DESKTOP=river-triad
              export XDG_SESSION_TYPE=wayland
              export PATH="${lib.makeBinPath sessionRuntimePackages}:$PATH"
              export TRIAD_BIN="''${TRIAD_BIN:-${triad}/bin/triad}"
              export TRIAD_MANAGER_LOOP="''${TRIAD_MANAGER_LOOP:-${managerLoop}/bin/triad-manager-loop}"
              export TRIAD_RIVER_BIN="''${TRIAD_RIVER_BIN:-${pkgs.river}/bin/river}"

              exec "$TRIAD_RIVER_BIN" -c "$TRIAD_MANAGER_LOOP"
            '';
          };

          desktopFile = pkgs.writeText "river-triad.desktop" ''
            [Desktop Entry]
            Name=River (Triad)
            Comment=River Wayland compositor with the Triad window manager
            Exec=${riverTriadSession}/bin/river-triad-session
            Type=Application
            DesktopNames=river
          '';

          triadSession = pkgs.runCommand "triad-session-${triad.version}" { } ''
            install -Dm755 ${riverTriadSession}/bin/river-triad-session \
              $out/bin/river-triad-session
            install -Dm755 ${managerLoop}/bin/triad-manager-loop \
              $out/bin/triad-manager-loop
            install -Dm644 ${desktopFile} \
              $out/share/wayland-sessions/river-triad.desktop
            install -Dm644 ${./config.default.kdl} \
              $out/share/triad/config.default.kdl
          '';

          installSession = pkgs.writeShellApplication {
            name = "triad-install-session";
            runtimeInputs = [ pkgs.coreutils ];
            text = ''
              config_dir="''${XDG_CONFIG_HOME:-$HOME/.config}/triad"
              config_path="$config_dir/config.kdl"
              desktop_dir="''${TRIAD_WAYLAND_SESSION_DIR:-''${XDG_DATA_HOME:-$HOME/.local/share}/wayland-sessions}"
              desktop_path="$desktop_dir/river-triad.desktop"

              mkdir -p "$config_dir" "$desktop_dir"

              if [ ! -e "$config_path" ] && [ ! -L "$config_path" ]; then
                install -Dm644 ${./config.default.kdl} "$config_path"
                printf '%s\n' "triad-install-session: installed default config at $config_path"
              else
                printf '%s\n' "triad-install-session: leaving existing config at $config_path"
              fi

              install -Dm644 ${desktopFile} "$desktop_path"
              printf '%s\n' "triad-install-session: installed $desktop_path"
              printf '%s\n' "triad-install-session: select 'River (Triad)' at login"
            '';
          };
        in
        {
          inherit
            triad
            triadSession
            riverTriadSession
            managerLoop
            installSession
            ;

          default = triad;
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          installSession = self.packages.${system}.installSession;
          riverTriadSession = self.packages.${system}.riverTriadSession;
        in
        {
          default = {
            type = "app";
            program = "${pkgs.lib.getExe self.packages.${system}.triad}";
          };

          install-session = {
            type = "app";
            program = "${pkgs.lib.getExe installSession}";
          };

          river-triad-session = {
            type = "app";
            program = "${pkgs.lib.getExe riverTriadSession}";
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          sessionRuntimePackages =
            let
              dankShell = inputs.dank-material-shell.packages.${system}.dms-shell;
            in
            [
              pkgs.river
              pkgs.dbus
              pkgs.pipewire
              pkgs.wireplumber
              pkgs.xdg-desktop-portal
              pkgs.xdg-desktop-portal-wlr
              pkgs.xdg-desktop-portal-gtk
              pkgs.grim
              pkgs.slurp
              pkgs.wl-clipboard
              pkgs.kitty
              pkgs.fuzzel
              pkgs.wtype
              pkgs.waybar
              pkgs.swaylock
              pkgs.gtklock
              pkgs.sunsetr
              pkgs.quickshell
              pkgs.noctalia-shell
              dankShell
              pkgs.janet
              pkgs.jq
              pkgs.procps
            ];
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.nim
              pkgs.nimble
              pkgs.nph
              pkgs.nimlangserver
              pkgs.pkg-config
              pkgs.git
              pkgs.wayland
              pkgs.wayland-protocols
              pkgs.libxkbcommon
              pkgs.pixman
            ]
            ++ sessionRuntimePackages;

            TRIAD_NIX_RUNTIME_PATH = pkgs.lib.makeBinPath sessionRuntimePackages;

            shellHook = ''
              echo "Triad dev shell"
              echo "  build:         nimble build"
              echo "  nix build:     nix build .#triad"
              echo "  install seat:  nix run .#install-session"
            '';
          };
        }
      );

      checks = forAllSystems (system: {
        triad = self.packages.${system}.triad;
        triadSession = self.packages.${system}.triadSession;
      });

      formatter = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        pkgs.writeShellApplication {
          name = "triad-format";
          runtimeInputs = [ pkgs.nixfmt ];
          text = ''
            nixfmt flake.nix
          '';
        }
      );
    };
}
