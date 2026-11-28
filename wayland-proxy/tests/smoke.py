"""Run the bridge against an isolated two-output River session."""
import argparse
from contextlib import ExitStack, closing
import json
import os
from pathlib import Path
from socketserver import StreamRequestHandler, ThreadingUnixStreamServer
import struct
import subprocess
import sys
import tempfile
import threading
import time

from wire import MANAGER, WorkspaceClient, read_string, string, words


def wait_for(description, predicate):
    for _ in range(100):
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError(description)


def terminate(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=4)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


class NativeWorkspaceServer(StreamRequestHandler):
    def handle(self):
        while header := self.rfile.read(8):
            target, header = struct.unpack("=2I", header)
            opcode = header & 0xffff
            payload = self.rfile.read((header >> 16) - 8)
            if target == 1 and opcode == 1:
                registry, = struct.unpack("=I", payload)
                self.send(registry, 0, words(71) + string(MANAGER) + words(1))
            elif target == 1 and opcode == 0:
                callback, = struct.unpack("=I", payload)
                self.send(callback, 0, words(0))
                self.send(1, 1, words(callback))
            elif target == registry and opcode == 0:
                name, = struct.unpack_from("=I", payload)
                interface, end = read_string(payload[4:])
                version, manager = struct.unpack_from("=2I", payload, 4 + end)
                assert (name, interface, version) == (71, MANAGER, 1)
                workspace = 0xff000000
                self.send(manager, 1, words(workspace))
                self.send(workspace, 1, string("Native workspace"))
                self.send(manager, 2)

    def send(self, target, opcode, payload=b""):
        self.wfile.write(words(target, ((8 + len(payload)) << 16) | opcode) + payload)


def smoke(args):
    with ExitStack() as cleanup:
        # Stick to short paths for Wayland and Unix socket limits.
        runtime = Path(cleanup.enter_context(tempfile.TemporaryDirectory(prefix="twp.", dir="/tmp")))
        env = os.environ.copy()
        for key in ("WAYLAND_SOCKET", "DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "NIRI_SOCKET", "TRIAD_NIRI_SOCKET"):
            env.pop(key, None)
        for key in ("CONFIG", "STATE", "CACHE"):
            path = runtime / key.lower()
            path.mkdir()
            env[f"XDG_{key}_HOME"] = str(path)
        env.update(XDG_RUNTIME_DIR=str(runtime), TRIAD_SOCKET=str(runtime / "triad.sock"))
        bin_dir = runtime / "bin"
        bin_dir.mkdir()
        (bin_dir / "triad-wayland-proxy").symlink_to(Path(args.proxy).resolve())
        env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
        launched = runtime / "shell-display"
        probe = runtime / "shell.py"
        probe.write_text("""import os, sys, time
from pathlib import Path
Path(sys.argv[1]).write_text(os.environ['WAYLAND_DISPLAY'])
if len(sys.argv) > 2:
    time.sleep(60)
""")
        stopped = runtime / "stop-display"
        replacement = runtime / "replacement-display"
        config = runtime / "triad.kdl"
        config.write_text('''workspaces {
    default-count 3
}
bindings {
    bind "Super+2" "focus-workspace 2"
}
''' + f'''
shells {{
    enabled #true
    active "probe"
    profile "probe" {{
        launch "{sys.executable}" "{probe}" "{launched}" "wait"
        stop "{sys.executable}" "{probe}" "{stopped}"
    }}
    profile "replacement" {{
        launch "{sys.executable}" "{probe}" "{replacement}" "wait"
    }}
}}
''')
        env["TRIAD_CONFIG"] = str(config)

        def start(name, argv, **overrides):
            log = runtime / f"{name}.log"
            with log.open("wb") as output:
                process = subprocess.Popen(argv, env=env | overrides, stdout=output, stderr=output)
            cleanup.callback(terminate, process)
            return process

        def run(*argv):
            return subprocess.check_output(argv, env=env, timeout=6)

        def workspaces():
            return json.loads(run(args.triad, "msg", "workspaces"))["triad"]["workspaces"]

        def active():
            return next(w["workspace_idx"] for w in workspaces() if w["is_active"])

        def match(client, description, predicate):
            def check():
                client.sync()
                return predicate()
            wait_for(description, check)

        try:
            with ThreadingUnixStreamServer(str(runtime / "native-wayland"), NativeWorkspaceServer) as native:
                threading.Thread(target=native.serve_forever, daemon=True).start()
                try:
                    fixture = runtime / "native-proxy"
                    probe_run = subprocess.run([args.proxy, "prepare", "--socket", fixture],
                                               env=env | {"WAYLAND_DISPLAY": "native-wayland"}, timeout=5)
                    assert probe_run.returncode == 2 and not fixture.exists()
                    forwarding = start("native-proxy", [args.proxy, "serve", "--socket", fixture],
                                       WAYLAND_DISPLAY="native-wayland")
                    wait_for("native proxy socket is not ready", fixture.is_socket)
                    with closing(WorkspaceClient(fixture)) as client:
                        client.bind_manager()
                        assert client.workspace_id("Native workspace")
                finally:
                    terminate(forwarding)
                    native.shutdown()

            river = start(
                "river", [args.river, "-no-xwayland", "-c", "true"],
                WLR_BACKENDS="headless", WLR_HEADLESS_OUTPUTS="2", WLR_RENDERER="pixman",
            )
            wait_for("River did not create a Wayland socket", lambda: any(runtime.glob("wayland-*.lock")))
            display_lock = next(runtime.glob("wayland-*.lock"))
            env["WAYLAND_DISPLAY"] = display_lock.stem
            wait_for("River socket is not ready", (runtime / display_lock.stem).is_socket)

            daemon = start("triad", [args.triad, "supervise"])
            wait_for("Triad socket is not ready", (runtime / "triad.sock").is_socket)
            address = runtime / f"triad-workspaces-{display_lock.stem}"
            wait_for("managed shell did not launch", launched.exists)
            assert launched.read_text() == address.name and address.is_socket()
            original_socket = address.stat().st_ino
            run(args.triad, "msg", "switch-shell", "replacement")
            wait_for("replacement shell did not launch", replacement.exists)
            assert replacement.read_text() == stopped.read_text() == address.name
            assert address.stat().st_ino == original_socket, "shell switch replaced the proxy"

            first = cleanup.enter_context(closing(WorkspaceClient(address)))
            first.bind_manager()
            second = cleanup.enter_context(closing(WorkspaceClient(address)))
            second.bind_outputs(version=3)
            second.bind_manager()
            first.bind_outputs()
            for client in (first, second):
                match(client, "incomplete two-output snapshot", lambda:
                      len(client.groups) == 2 and len(client.workspaces) == 3 and
                      sum(len(group["outputs"]) for group in client.groups.values()) == 2)
            second.release_outputs()
            second.bind_outputs()
            match(second, "rebound outputs missed group membership", lambda:
                  sum(len(group["outputs"]) for group in second.groups.values()) == 2)

            if args.wtype:
                run(args.wtype, "-M", "logo", "-k", "2", "-m", "logo")
            else:
                run(args.triad, "msg", "dispatch-binding", "key", "Super+2")
            for client in (first, second):
                match(client, "focus did not reach the workspace client",
                      lambda: client.workspaces[client.workspace_id("2")]["active"])
            first.send(first.workspace_id("1"), 1)
            first.sync()
            assert active() == 2, "activation took effect without commit"
            first.send(first.workspace_id("3"), 1)
            first.send(first.manager, 0)
            match(first, "committed activation did not reach Triad", lambda: active() == 3)

            run(args.triad, "msg", "rename-tag", "Web")
            match(first, "workspace rename did not arrive",
                  lambda: any(row.get("name") == "Web" for row in first.workspaces.values()))
            original = first.workspace_id("Web")
            old_group = next(key for key, group in first.groups.items() if original in group["workspaces"])
            current_output = next(w["output"] for w in workspaces() if w["is_active"])
            target = next(output for output in ("HEADLESS-1", "HEADLESS-2") if output != current_output)
            run(args.triad, "msg", "move-workspace-to-output", target)
            match(first, "workspace move did not reach its new group", lambda:
                  any(key != old_group and original in group["workspaces"]
                      for key, group in first.groups.items()))
            assert first.workspace_id("Web") == original
            if args.wlr_randr:
                run(args.wlr_randr, "--output", target, "--off")
                match(first, "removed display still has a workspace group", lambda: len(first.groups) == 1)

            first.send(first.manager, 1)
            first.sync()
            assert (first.manager, 3) in first.events, "stop did not complete"
            first.close()
            third = cleanup.enter_context(closing(WorkspaceClient(address)))
            third.bind_outputs()
            third.bind_manager()
            match(third, "reconnected client missed workspace state",
                  lambda: any(row.get("name") == "Web" for row in third.workspaces.values()))

            daemon.terminate()
            daemon.wait(timeout=4)
            match(third, "stale workspaces survived IPC disconnect", lambda: not third.workspaces and not third.groups)
            launched.unlink()
            start("triad-restarted", [args.triad, "supervise"], TRIAD_WORKSPACE_PROXY="0")
            match(third, "workspaces did not recover after Triad restart",
                  lambda: len(third.workspaces) == 3 and len(third.groups) == (1 if args.wlr_randr else 2))
            wait_for("opted-out shell did not launch", launched.exists)
            assert launched.read_text() == display_lock.stem

            river.terminate()
            river.wait(timeout=4)
            wait_for("automatic proxy did not exit with River", lambda: not address.exists())
        except Exception:
            for log in sorted(runtime.glob("*.log")):
                print(f"--- {log.name} ---")
                print(log.read_text(errors="replace")[-6000:])
            raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--river", default="river")
    parser.add_argument("--triad", default="./triad")
    parser.add_argument("--proxy", default="./wayland-proxy/target/debug/triad-wayland-proxy")
    parser.add_argument("--wlr-randr", help="also exercise output removal")
    parser.add_argument("--wtype", help="send the workspace shortcut through River")
    smoke(parser.parse_args())
    print("Workspace proxy smoke test passed")
