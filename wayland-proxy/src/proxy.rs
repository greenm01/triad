use crate::{
    ipc::Ipc,
    workspaces::{Binding, Outputs},
};
use std::{
    cell::{Cell, RefCell},
    collections::BTreeMap,
    os::{fd::OwnedFd, unix::net::UnixStream},
    path::Path,
    rc::{Rc, Weak},
    time::{Duration, Instant},
};
use wl_proxy::{
    baseline::Baseline,
    object::{Object, ObjectCoreApi, ObjectRcUtils, ObjectUtils},
    protocols::{
        ObjectInterface,
        ext_workspace_v1::ext_workspace_manager_v1::ExtWorkspaceManagerV1,
        wayland::{
            wl_callback::{WlCallback, WlCallbackHandler},
            wl_display::{WlDisplay, WlDisplayHandler},
            wl_output::{WlOutput, WlOutputHandler},
            wl_registry::{WlRegistry, WlRegistryHandler},
        },
    },
    state::State,
};

const SYNTHETIC_WORKSPACES: u32 = 1;
const WORKSPACE_INTERFACE: ObjectInterface = ObjectInterface::ExtWorkspaceManagerV1;

pub fn native_workspaces(upstream: &Path) -> Result<bool, Box<dyn std::error::Error>> {
    let fd = Rc::new(OwnedFd::from(UnixStream::connect(upstream)?));
    let state = State::builder(Baseline::ALL_OF_THEM)
        .with_server_fd(&fd)
        .build()?;
    let _cleanup = state.create_destructor();
    let found = Rc::new(Cell::new(false));
    let done = Rc::new(Cell::new(false));
    let display = state.display();
    display
        .new_try_send_get_registry()?
        .set_handler(NativeRegistry(found.clone()));
    display
        .new_try_send_sync()?
        .set_handler(ProbeDone(done.clone()));
    let deadline = Instant::now() + Duration::from_millis(700);
    while !done.get() {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err("River did not respond to the workspace protocol probe".into());
        }
        state.dispatch(Some(remaining))?;
    }
    Ok(found.get())
}

struct NativeRegistry(Rc<Cell<bool>>);

impl WlRegistryHandler for NativeRegistry {
    fn handle_global(&mut self, _: &Rc<WlRegistry>, _: u32, interface: ObjectInterface, _: u32) {
        if interface == WORKSPACE_INTERFACE {
            self.0.set(true);
        }
    }

    fn handle_global_remove(&mut self, _: &Rc<WlRegistry>, _: u32) {}
}

struct ProbeDone(Rc<Cell<bool>>);

impl WlCallbackHandler for ProbeDone {
    fn handle_done(&mut self, _: &Rc<WlCallback>, _: u32) {
        self.0.set(true);
    }
}

pub struct Connection {
    ipc: Ipc,
    outputs: Outputs,
    output_probes: BTreeMap<u32, Weak<WlOutput>>,
    managers: Vec<Rc<RefCell<Binding>>>,
    global_ids: BTreeMap<u32, u32>,
    next_global_id: u32,
    synthetic: Option<bool>,
}

impl Connection {
    pub fn new(ipc: Ipc) -> Rc<RefCell<Self>> {
        Rc::new(RefCell::new(Self {
            ipc,
            outputs: Outputs::default(),
            output_probes: BTreeMap::new(),
            managers: Vec::new(),
            global_ids: BTreeMap::new(),
            next_global_id: SYNTHETIC_WORKSPACES + 1,
            synthetic: None,
        }))
    }

    pub fn publish(&mut self, outputs_changed: bool) {
        let (epoch, snapshot) = self.ipc.current();
        self.managers.retain(|binding| {
            binding
                .borrow_mut()
                .update(&self.outputs, epoch, snapshot.as_ref(), outputs_changed)
        });
    }
}

pub struct Display(pub Rc<RefCell<Connection>>);

impl WlDisplayHandler for Display {
    fn handle_get_registry(&mut self, display: &Rc<WlDisplay>, registry: &Rc<WlRegistry>) {
        display.send_get_registry(registry);
        registry.set_handler(Registry {
            connection: self.0.clone(),
            globals: BTreeMap::new(),
            native_workspaces: false,
            synthetic_advertised: false,
        });
        // River sends the registry contents before this callback and before the
        // client's own startup round trip can finish.
        display
            .new_send_sync()
            .set_handler(RegistryReady(Rc::downgrade(registry)));
    }
}

struct RegistryReady(Weak<WlRegistry>);

impl WlCallbackHandler for RegistryReady {
    fn handle_done(&mut self, _callback: &Rc<WlCallback>, _serial: u32) {
        let Some(registry) = self.0.upgrade() else {
            return;
        };
        let mut handler = registry.get_handler_mut::<Registry>();
        let synthetic = *handler
            .connection
            .borrow_mut()
            .synthetic
            .get_or_insert(!handler.native_workspaces);
        if synthetic {
            handler.synthetic_advertised = true;
            registry.send_global(SYNTHETIC_WORKSPACES, WORKSPACE_INTERFACE, 1);
        }
    }
}

struct Registry {
    connection: Rc<RefCell<Connection>>,
    // The same upstream global gets the same downstream name on every registry.
    globals: BTreeMap<u32, (u32, ObjectInterface, u32)>,
    native_workspaces: bool,
    synthetic_advertised: bool,
}

impl Registry {
    fn invalid_bind(registry: &Rc<WlRegistry>) {
        if let Some(client) = registry.client() {
            client
                .display()
                .send_error(registry.clone(), 0, "invalid global bind");
        }
    }
}

impl WlRegistryHandler for Registry {
    fn handle_bind(&mut self, registry: &Rc<WlRegistry>, name: u32, id: Rc<dyn Object>) {
        if name == SYNTHETIC_WORKSPACES && self.synthetic_advertised {
            if id.interface() != WORKSPACE_INTERFACE || id.version() != 1 {
                return Self::invalid_bind(registry);
            }
            let manager = id.downcast::<ExtWorkspaceManagerV1>();
            let mut connection = self.connection.borrow_mut();
            let binding = Binding::new(&manager, connection.ipc.clone());
            connection.managers.push(binding);
            connection.publish(false);
            return;
        }
        let Some(&(global, interface, version)) = self.globals.get(&name) else {
            return Self::invalid_bind(registry);
        };
        if id.interface() != interface || id.version() == 0 || id.version() > version {
            return Self::invalid_bind(registry);
        }
        registry.send_bind(global, id.clone());
        if interface == ObjectInterface::WlOutput {
            let mut connection = self.connection.borrow_mut();
            if connection.synthetic == Some(false) {
                return;
            }
            let output = id.downcast::<WlOutput>();
            connection
                .outputs
                .bindings
                .entry(global)
                .or_default()
                .insert(output.unique_id(), Rc::downgrade(&output));
            output.set_handler(OutputBinding {
                connection: Rc::downgrade(&self.connection),
                global,
            });
            connection.publish(true);
        }
    }

    fn handle_global(
        &mut self,
        registry: &Rc<WlRegistry>,
        global: u32,
        interface: ObjectInterface,
        version: u32,
    ) {
        let mut connection = self.connection.borrow_mut();
        if interface == WORKSPACE_INTERFACE {
            self.native_workspaces = true;
            if connection.synthetic == Some(true) {
                return;
            }
        }
        let name = if let Some(&name) = connection.global_ids.get(&global) {
            name
        } else {
            let name = connection.next_global_id;
            connection.next_global_id += 1;
            connection.global_ids.insert(global, name);
            name
        };
        self.globals.insert(name, (global, interface, version));
        registry.send_global(name, interface, version);

        if interface == ObjectInterface::WlOutput
            && version >= 4
            && connection.synthetic != Some(false)
            && !connection.output_probes.contains_key(&global)
        {
            // The probe gets the connector name even when the client binds an
            // older wl_output version. Its events stay on the upstream side.
            let probe = registry.state().create_object::<WlOutput>(4);
            probe.set_forward_to_client(false);
            probe.set_handler(OutputProbe {
                connection: Rc::downgrade(&self.connection),
                global,
            });
            registry.send_bind(global, probe.clone());
            connection
                .output_probes
                .insert(global, Rc::downgrade(&probe));
        }
    }

    fn handle_global_remove(&mut self, registry: &Rc<WlRegistry>, global: u32) {
        let mut connection = self.connection.borrow_mut();
        if let Some(&name) = connection.global_ids.get(&global)
            && self.globals.remove(&name).is_some()
        {
            if let Some(probe) = connection
                .output_probes
                .remove(&global)
                .and_then(|probe| probe.upgrade())
            {
                probe.send_release();
            }
            let had_name = connection.outputs.names.remove(&global).is_some();
            let had_bindings = connection.outputs.bindings.remove(&global).is_some();
            if had_name || had_bindings {
                connection.publish(true);
            }
            registry.send_global_remove(name);
        }
    }
}

struct OutputProbe {
    connection: Weak<RefCell<Connection>>,
    global: u32,
}

impl WlOutputHandler for OutputProbe {
    fn handle_name(&mut self, _output: &Rc<WlOutput>, name: &str) {
        if let Some(connection) = self.connection.upgrade() {
            let mut connection = connection.borrow_mut();
            if connection.output_probes.contains_key(&self.global) {
                connection
                    .outputs
                    .names
                    .insert(self.global, name.to_owned());
                connection.publish(true);
            }
        }
    }
}

struct OutputBinding {
    connection: Weak<RefCell<Connection>>,
    global: u32,
}

impl WlOutputHandler for OutputBinding {
    fn handle_release(&mut self, output: &Rc<WlOutput>) {
        if let Some(connection) = self.connection.upgrade() {
            let mut connection = connection.borrow_mut();
            if let Some(bindings) = connection.outputs.bindings.get_mut(&self.global) {
                bindings.remove(&output.unique_id());
            }
            // The client has already destroyed this object. A later bind will
            // receive output_enter for the replacement object.
            for manager in &connection.managers {
                manager.borrow_mut().forget_output(output.unique_id());
            }
        }
        output.send_release();
    }
}
