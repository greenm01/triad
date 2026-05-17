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

                set +e
                "$triad_bin" $triad_args >>"$log" 2>&1
                status="$?"
                set -e
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
                  if [ "$rapid_restarts" -ge 3 ]; then
                    printf '%s\n' "triad-manager-loop: triad exited with status $status after ''${runtime_sec}s; rapid restart count ''${rapid_restarts}, backing off" >&2
                    sleep 5
                  else
                    printf '%s\n' "triad-manager-loop: triad exited with status $status after ''${runtime_sec}s; restarting" >&2
                    sleep 1
                  fi
                fi
              done
            '';
          };

          riverTriadSession = pkgs.writeShellApplication {
            name = "river-triad-session";
            runtimeInputs = sessionRuntimePackages;
            text = ''
              state_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/triad"
              mkdir -p "$state_dir"
              stamp="$(date +%Y%m%d-%H%M%S)"
              session_log="$state_dir/river-triad-session-$stamp.log"
              latest_log="$state_dir/river-triad-session-latest.log"
              ln -sfn "$session_log" "$latest_log" 2>/dev/null || true
              exec >>"$session_log" 2>&1

              export XDG_CURRENT_DESKTOP=river
              export XDG_SESSION_DESKTOP=river-triad
              export XDG_SESSION_TYPE=wayland
              export PATH="${lib.makeBinPath sessionRuntimePackages}:$PATH"
              export TRIAD_BIN="''${TRIAD_BIN:-${triad}/bin/triad}"
              export TRIAD_MANAGER_LOOP="''${TRIAD_MANAGER_LOOP:-${managerLoop}/bin/triad-manager-loop}"
              export TRIAD_RIVER_BIN="''${TRIAD_RIVER_BIN:-${pkgs.river}/bin/river}"

              find_dbus_run_session() {
                for candidate in \
                  /usr/bin/dbus-run-session \
                  /bin/dbus-run-session \
                  /usr/sbin/dbus-run-session \
                  /sbin/dbus-run-session; do
                  if [ -x "$candidate" ]; then
                    printf '%s\n' "$candidate"
                    return 0
                  fi
                done

                command -v dbus-run-session 2>/dev/null || true
              }

              find_dbus_session_config() {
                for candidate in \
                  /usr/share/dbus-1/session.conf \
                  /etc/dbus-1/session.conf; do
                  if [ -r "$candidate" ] && grep -q '<listen>' "$candidate" 2>/dev/null; then
                    printf '%s\n' "$candidate"
                    return 0
                  fi
                done

                printf '%s\n' ""
              }

              case "''${TRIAD_SESSION_DEV_MODE:-}" in
                1|true|TRUE|yes|YES|on|ON)
                  export TRIAD_DEV_MODE=1
                  ;;
                *)
                  unset TRIAD_DEV_MODE
                  unset TRIAD_BEHAVIOR_LOG
                  ;;
              esac

              printf '%s\n' "river-triad-session: starting at $(date -Is 2>/dev/null || date)"
              printf '%s\n' "river-triad-session: HOME=$HOME"
              printf '%s\n' "river-triad-session: XDG_RUNTIME_DIR=''${XDG_RUNTIME_DIR:-}"
              printf '%s\n' "river-triad-session: WAYLAND_DISPLAY=''${WAYLAND_DISPLAY:-}"
              printf '%s\n' "river-triad-session: river=$TRIAD_RIVER_BIN"
              printf '%s\n' "river-triad-session: manager=$TRIAD_MANAGER_LOOP"
              dbus_runner="$(find_dbus_run_session)"
              dbus_config="$(find_dbus_session_config)"

              start_river() {
                if [ -z "''${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -n "$dbus_runner" ]; then
                  if [ -n "$dbus_config" ]; then
                    printf '%s\n' "river-triad-session: starting River through $dbus_runner --config-file=$dbus_config"
                    "$dbus_runner" --config-file="$dbus_config" -- "$TRIAD_RIVER_BIN" -c "$TRIAD_MANAGER_LOOP"
                    return $?
                  fi

                  printf '%s\n' "river-triad-session: starting River through $dbus_runner"
                  "$dbus_runner" -- "$TRIAD_RIVER_BIN" -c "$TRIAD_MANAGER_LOOP"
                  return $?
                fi

                printf '%s\n' "river-triad-session: starting River directly"
                "$TRIAD_RIVER_BIN" -c "$TRIAD_MANAGER_LOOP"
              }

              if [ -z "''${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -n "$dbus_runner" ]; then
                :
              fi

              set +e
              start_river
              status="$?"
              set -e

              if [ "$status" -ne 0 ] &&
                [ -z "''${WLR_RENDERER:-}" ] &&
                grep -q 'RendererCreateFailed' "$session_log" 2>/dev/null; then
                printf '%s\n' "river-triad-session: hardware renderer failed; retrying with WLR_RENDERER=pixman"
                export WLR_RENDERER=pixman
                set +e
                start_river
                status="$?"
                set -e
              fi

              exit "$status"
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

        in
        {
          inherit
            triad
            triadSession
            riverTriadSession
            managerLoop
            ;

          default = triad;
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = {
            type = "app";
            program = "${pkgs.lib.getExe self.packages.${system}.triad}";
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          devNimble = pkgs.writeShellApplication {
            name = "nimble";
            runtimeInputs = [
              pkgs.coreutils
              pkgs.nimble
            ];
            text = ''
              nimble_dir="''${TRIAD_NIMBLE_DIR:-$PWD/.nimble}"
              mkdir -p "$nimble_dir"

              if [ "''${1:-}" = "build" ]; then
                has_define=0
                has_strip=0
                for arg in "$@"; do
                  case "$arg" in
                    -d:*|--define:*|--define=*)
                      has_define=1
                      ;;
                    --passL:-s|--passL=-s)
                      has_strip=1
                      ;;
                  esac
                done
                if [ "$has_define" -eq 0 ]; then
                  set -- "$@" -d:release
                fi
                if [ "$has_strip" -eq 0 ]; then
                  set -- "$@" --passL:-s
                fi
              fi

              exec ${pkgs.nimble}/bin/nimble \
                --nimbleDir:"$nimble_dir" \
                --useSystemNim \
                "$@"
            '';
          };
          devLl = pkgs.writeShellApplication {
            name = "ll";
            runtimeInputs = [ pkgs.coreutils ];
            text = ''
              exec ls -la "$@"
            '';
          };
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.nim
              devNimble
              devLl
              pkgs.nph
              pkgs.nimlangserver
              pkgs.pkg-config
              pkgs.git
              pkgs.wayland
              pkgs.wayland-protocols
              pkgs.libxkbcommon
              pkgs.pixman
            ];

            shellHook = ''
              export TRIAD_NIMBLE_DIR="''${TRIAD_NIMBLE_DIR:-$PWD/.nimble}"
              echo "Triad dev shell"
              echo "  build:         nimble build"
              echo "  nix build:     nix build .#triad"
              echo "  install seat:  tools/install_live_session.sh (uses native River)"
            '';
          };
        }
      );

      checks = forAllSystems (system: {
        triad = self.packages.${system}.triad;
        triadSession = self.packages.${system}.triadSession;
      });

      nixosModules = {
        default =
          {
            config,
            lib,
            pkgs,
            ...
          }:
          let
            cfg = config.programs.triad;
            triadSession = self.packages.${pkgs.stdenv.hostPlatform.system}.triadSession;
          in
          {
            options.programs.triad.enable = lib.mkEnableOption "the River (Triad) Wayland session";

            config = lib.mkIf cfg.enable {
              environment.systemPackages = [ triadSession ];
              services.displayManager.sessionPackages = [ triadSession ];
            };
          };

        triad = self.nixosModules.default;
      };

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
