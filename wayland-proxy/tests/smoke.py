"""Run the bridge against an isolated two-output River session."""
import argparse
from contextlib import ExitStack, closing, suppress
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


def workspace_actions(first, second, match, workspaces):
    def group_for(client, name):
        handle = client.workspace_id(name)
        return next(key for key, group in client.groups.items() if handle in group["workspaces"])

    def has_workspace(client, name):
        return any(row.get("name") == name for row in client.workspaces.values())

    source = group_for(first, "Web")
    destination = next(group for group in first.groups if group != source)
    assert all(group["capabilities"] == 1 for group in first.groups.values())
    first.send(source, 0, string("Sandbox"))
    first.send(destination, 0, string("Standby"))
    first.sync()
    second.send(second.manager, 0)
    second.sync()
    assert not has_workspace(first, "Sandbox") and not has_workspace(second, "Sandbox")

    first.send(first.manager, 0)
    match(first, "create did not publish empty workspaces", lambda:
          has_workspace(first, "Sandbox") and has_workspace(first, "Standby"))
    sandbox = first.workspace_id("Sandbox")
    assert group_for(first, "Sandbox") == source
    assert not first.workspaces[sandbox]["active"]
    assert first.workspaces[sandbox]["capabilities"] == 15
    assert first.workspaces[first.workspace_id("Web")]["capabilities"] & 4 == 0

    first.send(sandbox, 3, words(destination))
    first.send(first.manager, 0)
    match(first, "assign did not move the inactive workspace", lambda:
          group_for(first, "Sandbox") == destination)
    assert not first.workspaces[sandbox]["active"]
    assert first.workspaces[first.workspace_id("Web")]["active"]

    before = len(first.events)
    first.send(sandbox, 3, words(source))
    first.send(sandbox, 1)
    first.send(first.manager, 0)
    match(first, "assign and activate did not apply together", lambda:
          group_for(first, "Sandbox") == source and first.workspaces[sandbox]["active"])
    assert first.events[before:].count((first.manager, 2)) == 1
    assert first.workspace_id("Sandbox") == sandbox
    assert first.workspaces[sandbox]["capabilities"] & 4 == 0

    first.send(sandbox, 4)
    first.send(first.manager, 0)
    first.sync()
    assert first.workspaces[sandbox]["active"]
    first.send(sandbox, 2)
    first.send(first.manager, 0)
    match(first, "deactivate did not select a replacement", lambda:
          not first.workspaces[sandbox]["active"] and
          any(first.workspaces[handle]["active"] for handle in first.groups[source]["workspaces"]))
    assert first.workspaces[sandbox]["capabilities"] & 4

    first.send(sandbox, 1)
    first.send(first.manager, 0)
    match(first, "workspace was not reactivated", lambda: first.workspaces[sandbox]["active"])
    source_output = next(row["output"] for row in workspaces() if row["name"] == "Sandbox")
    first.send(sandbox, 3, words(destination))
    first.send(first.manager, 0)
    match(first, "assign did not replace the active workspace on its old output", lambda:
          group_for(first, "Sandbox") == destination and not first.workspaces[sandbox]["active"])
    assert next(row["output"] for row in workspaces() if row["is_active"]) == source_output

    first.send(sandbox, 1)
    first.sync()
    match(second, "second client did not see removal capability", lambda:
          has_workspace(second, "Sandbox") and
          second.workspaces[second.workspace_id("Sandbox")]["capabilities"] & 4)
    old_slot = next(row["tag_id"] for row in workspaces() if row["name"] == "Sandbox")
    second.send(second.workspace_id("Sandbox"), 4)
    second.send(group_for(second, "Sandbox"), 0, string("Reused"))
    second.send(second.manager, 0)
    match(first, "remove and create did not replace the workspace", lambda:
          not has_workspace(first, "Sandbox") and has_workspace(first, "Reused"))
    reused = first.workspace_id("Reused")
    assert reused != sandbox
    assert next(row["tag_id"] for row in workspaces() if row["name"] == "Reused") == old_slot
    first.send(source, 0, string("Commit marker"))
    first.send(first.manager, 0)
    match(first, "stale-handle batch did not finish", lambda: has_workspace(first, "Commit marker"))
    assert not next(row["is_output_visible"] for row in workspaces() if row["name"] == "Reused")

    first.send(reused, 4)
    first.send(first.workspace_id("Standby"), 4)
    first.send(first.workspace_id("Commit marker"), 4)
    first.send(first.manager, 0)
    match(first, "remove did not clean up both workspaces", lambda: len(first.workspaces) == 3)


class NativeWorkspaceServer(StreamRequestHandler):
    def handle(self):
        with suppress(ConnectionResetError, BrokenPipeError):
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
            if args.legacy:
                assert all(group["capabilities"] == 0 for group in first.groups.values())
                assert all(row["capabilities"] == 1 for row in first.workspaces.values())
            else:
                workspace_actions(first, second, match, workspaces)
            if args.wlr_randr:
                if not args.legacy:
                    current_group = next(key for key, group in first.groups.items()
                                         if original in group["workspaces"])
                    first.send(current_group, 0, string("Disconnected"))
                    first.sync()
                run(args.wlr_randr, "--output", target, "--off")
                match(first, "removed display still has a workspace group", lambda: len(first.groups) == 1)
                if not args.legacy:
                    remaining_group = next(iter(first.groups))
                    first.send(remaining_group, 0, string("Still connected"))
                    first.send(first.manager, 0)
                    match(first, "hotplug batch did not finish", lambda:
                          any(row.get("name") == "Still connected" for row in first.workspaces.values()))
                    assert all(row["name"] != "Disconnected" for row in workspaces())
                    first.send(first.workspace_id("Still connected"), 4)
                    first.send(first.manager, 0)
                    match(first, "hotplug marker was not removed", lambda: len(first.workspaces) == 3)

            first.send(first.manager, 1)
            first.sync()
            assert (first.manager, 3) in first.events, "stop did not complete"
            first.close()
            third = cleanup.enter_context(closing(WorkspaceClient(address)))
            third.bind_outputs()
            third.bind_manager()
            match(third, "reconnected client missed workspace state",
                  lambda: any(row.get("name") == "Web" for row in third.workspaces.values()))
            if not args.legacy:
                third.send(next(iter(third.groups)), 0, string("Previous session"))
                third.sync()

            daemon.terminate()
            daemon.wait(timeout=4)
            match(third, "stale workspaces survived IPC disconnect", lambda: not third.workspaces and not third.groups)
            launched.unlink()
            start("triad-restarted", [args.triad, "supervise"], TRIAD_WORKSPACE_PROXY="0")
            match(third, "workspaces did not recover after Triad restart",
                  lambda: len(third.workspaces) == 3 and len(third.groups) == (1 if args.wlr_randr else 2))
            if not args.legacy:
                third.send(next(iter(third.groups)), 0, string("Current session"))
                third.send(third.manager, 0)
                match(third, "reconnected client could not create a workspace", lambda:
                      any(row.get("name") == "Current session" for row in third.workspaces.values()))
                assert all(row.get("name") != "Previous session" for row in third.workspaces.values())
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
    parser.add_argument("--legacy", action="store_true", help="test activation against an older Triad daemon")
    smoke(parser.parse_args())
    print("Workspace proxy smoke test passed")
