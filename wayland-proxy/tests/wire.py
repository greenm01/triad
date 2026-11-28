"""Exercise workspace discovery and activation using the public Wayland wire API."""
import socket
import struct

MANAGER = "ext_workspace_manager_v1"


def words(*values):
    return struct.pack(f"={len(values)}I", *values)


def string(value):
    data = value.encode() + b"\0"
    return words(len(data)) + data.ljust((len(data) + 3) & ~3, b"\0")


def read_string(payload):
    size, = struct.unpack_from("=I", payload)
    return payload[4:3 + size].decode(), 4 + ((size + 3) & ~3)


class WorkspaceClient:
    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(3)
        self.socket.connect(str(path))
        self.registry = 2
        self.manager = 3
        self.globals = {}
        self.workspaces = {}
        self.groups = {}
        self.outputs = {}
        self.events = []
        self.next_id = 4
        self.send(1, 1, words(self.registry))
        self.sync()

    def close(self):
        self.socket.close()

    def read(self, size):
        data = bytearray()
        while len(data) < size:
            packet = self.socket.recv(size - len(data))
            if not packet:
                raise EOFError("Wayland peer disconnected")
            data.extend(packet)
        return bytes(data)

    def send(self, target, opcode, data=b""):
        self.socket.sendall(words(target, ((8 + len(data)) << 16) | opcode) + data)

    def sync(self):
        callback = self.next_id
        self.next_id += 1
        self.send(1, 0, words(callback))
        while True:
            target, header = struct.unpack("=2I", self.read(8))
            opcode = header & 0xffff
            payload = self.read((header >> 16) - 8)
            if target == callback:
                return
            self.dispatch(target, opcode, payload)

    def dispatch(self, target, opcode, payload):
        self.events.append((target, opcode))
        value = struct.unpack_from("=I", payload)[0] if payload else None
        if target == 1 and opcode == 0:
            raise AssertionError(f"Wayland error: {payload!r}")
        if target == self.registry and opcode == 0:
            interface, end = read_string(payload[4:])
            version, = struct.unpack_from("=I", payload, 4 + end)
            self.globals[value] = (interface, version)
        elif target == self.registry and opcode == 1:
            del self.globals[value]
        elif target == self.manager and opcode == 0:
            self.groups[value] = {"outputs": set(), "workspaces": set()}
        elif target == self.manager and opcode == 1:
            self.workspaces[value] = {}
        elif target in self.groups:
            if opcode in (1, 2):
                (self.groups[target]["outputs"].add if opcode == 1 else
                 self.groups[target]["outputs"].remove)(value)
            elif opcode in (3, 4):
                (self.groups[target]["workspaces"].add if opcode == 3 else
                 self.groups[target]["workspaces"].remove)(value)
            elif opcode == 5:
                assert not self.groups[target]["workspaces"]
                del self.groups[target]
                self.send(target, 1)
        elif target in self.workspaces:
            if opcode == 1:
                self.workspaces[target]["name"] = read_string(payload)[0]
            elif opcode == 3:
                self.workspaces[target]["active"] = bool(value & 1)
            elif opcode == 5:
                assert all(target not in group["workspaces"] for group in self.groups.values())
                del self.workspaces[target]
                self.send(target, 0)

    def bind(self, name, interface, version, target):
        self.send(self.registry, 0, words(name) + string(interface) + words(version, target))

    def bind_manager(self):
        names = [name for name, (interface, _) in self.globals.items() if interface == MANAGER]
        assert len(names) == 1, names
        self.bind(names[0], MANAGER, 1, self.manager)
        self.sync()
        assert (self.manager, 2) in self.events, "initial snapshot did not end in done"

    def bind_outputs(self, version=2):
        for name, (interface, _) in self.globals.items():
            if interface == "wl_output" and name not in self.outputs:
                target = self.next_id
                self.next_id += 1
                self.outputs[name] = target
                # An older client binding must still get output_enter.
                self.bind(name, interface, version, target)
        self.sync()

    def release_outputs(self):
        for target in self.outputs.values():
            self.send(target, 0)
        self.outputs.clear()
        for group in self.groups.values():
            group["outputs"].clear()
        self.sync()

    def workspace_id(self, name):
        return next(key for key, value in self.workspaces.items() if value["name"] == name)
