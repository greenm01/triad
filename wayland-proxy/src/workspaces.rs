use crate::ipc::{Ipc, Snapshot, Workspace, WorkspaceAction, WorkspaceKey};
use std::{
    cell::RefCell,
    collections::{BTreeMap, BTreeSet},
    rc::{Rc, Weak},
    sync::Arc,
};
use wl_proxy::{
    object::{ObjectCoreApi, ObjectUtils},
    protocols::{
        ext_workspace_v1::{
            ext_workspace_group_handle_v1::{
                ExtWorkspaceGroupHandleV1 as Group,
                ExtWorkspaceGroupHandleV1GroupCapabilities as GroupCapabilities,
                ExtWorkspaceGroupHandleV1Handler,
            },
            ext_workspace_handle_v1::{
                ExtWorkspaceHandleV1 as Handle, ExtWorkspaceHandleV1Handler,
                ExtWorkspaceHandleV1State as HandleState,
                ExtWorkspaceHandleV1WorkspaceCapabilities as WorkspaceCapabilities,
            },
            ext_workspace_manager_v1::{
                ExtWorkspaceManagerV1 as Manager, ExtWorkspaceManagerV1Handler,
            },
        },
        wayland::wl_output::WlOutput,
    },
};

#[derive(Default)]
pub struct Outputs {
    pub names: BTreeMap<u32, String>,
    pub bindings: BTreeMap<u32, BTreeMap<u64, Weak<WlOutput>>>,
}

struct GroupState {
    handle: Weak<Group>,
    output: u32,
    outputs: BTreeMap<u64, Weak<WlOutput>>,
}

struct WorkspaceState {
    handle: Weak<Handle>,
    row: Workspace,
    group: Option<String>,
}

pub struct Binding {
    manager: Weak<Manager>,
    groups: BTreeMap<String, GroupState>,
    workspaces: BTreeMap<WorkspaceKey, WorkspaceState>,
    pending: Vec<WorkspaceAction>,
    last_snapshot: Option<Arc<Snapshot>>,
    started: bool,
    epoch: u64,
}

impl Binding {
    pub fn forget_output(&mut self, id: u64) {
        for group in self.groups.values_mut() {
            group.outputs.remove(&id);
        }
    }

    pub fn new(manager: &Rc<Manager>, ipc: Ipc) -> Rc<RefCell<Self>> {
        let binding = Rc::new(RefCell::new(Self {
            manager: Rc::downgrade(manager),
            groups: BTreeMap::new(),
            workspaces: BTreeMap::new(),
            pending: Vec::new(),
            last_snapshot: None,
            started: false,
            epoch: 0,
        }));
        manager.set_forward_to_server(false);
        manager.set_handler(ManagerRequests {
            binding: Rc::downgrade(&binding),
            ipc,
        });
        binding
    }

    pub fn update(
        &mut self,
        outputs: &Outputs,
        epoch: u64,
        snapshot: Option<&Arc<Snapshot>>,
        outputs_changed: bool,
    ) -> bool {
        let Some(manager) = self.manager.upgrade().filter(|m| m.client_id().is_some()) else {
            return false;
        };
        let same_snapshot = match (&self.last_snapshot, snapshot) {
            (Some(old), Some(new)) => Arc::ptr_eq(old, new),
            (None, None) => true,
            _ => false,
        };
        if self.started && self.epoch == epoch && same_snapshot && !outputs_changed {
            return true;
        }
        let empty = Snapshot::default();
        let mut changed = !self.started;
        if self.epoch != epoch {
            self.pending.clear();
            changed |= self.reconcile(&manager, outputs, &empty);
            self.epoch = epoch;
        }
        changed |= self.reconcile(&manager, outputs, snapshot.map_or(&empty, |s| s.as_ref()));
        if changed {
            manager.send_done();
        }
        self.last_snapshot = snapshot.cloned();
        self.started = true;
        true
    }

    fn reconcile(&mut self, manager: &Manager, outputs: &Outputs, snapshot: &Snapshot) -> bool {
        let live: BTreeSet<&str> = outputs
            .names
            .values()
            .map(String::as_str)
            .filter(|name| snapshot.outputs.contains_key(*name))
            .collect();
        let mut changed = false;
        for (id, workspace) in &mut self.workspaces {
            let next = snapshot
                .workspaces
                .get(id)
                .and_then(|row| live.get(row.output.as_str()).copied());
            if (workspace.group.as_deref() != next
                || next.is_some_and(|name| {
                    self.groups
                        .get(name)
                        .is_some_and(|group| group.output != snapshot.outputs[name])
                }))
                && let Some(group) = workspace
                    .group
                    .take()
                    .and_then(|name| self.groups.get(&name))
                    .and_then(|group| group.handle.upgrade())
                    .filter(|g| g.client_id().is_some())
                && let Some(handle) = workspace
                    .handle
                    .upgrade()
                    .filter(|w| w.client_id().is_some())
            {
                group.send_workspace_leave(&handle);
                changed = true;
            }
        }

        self.workspaces.retain(|id, workspace| {
            if snapshot.workspaces.contains_key(id) {
                return true;
            }
            if let Some(handle) = workspace
                .handle
                .upgrade()
                .filter(|w| w.client_id().is_some())
            {
                handle.send_removed();
                changed = true;
            }
            false
        });

        self.groups.retain(|name, group| {
            if live.contains(name.as_str()) && snapshot.outputs[name] == group.output {
                return true;
            }
            if let Some(handle) = group.handle.upgrade().filter(|g| g.client_id().is_some()) {
                for output in group
                    .outputs
                    .values()
                    .filter_map(Weak::upgrade)
                    .filter(|o| o.client_id().is_some())
                {
                    handle.send_output_leave(&output);
                }
                handle.send_removed();
                changed = true;
            }
            false
        });

        for name in &live {
            let group = self.groups.entry((*name).to_owned()).or_insert_with(|| {
                let handle = manager.new_send_workspace_group();
                handle.set_forward_to_server(false);
                let output = snapshot.outputs[*name];
                if snapshot.session.is_some()
                    && output != 0
                    && let Ok(requests) = manager.try_get_handler_ref::<ManagerRequests>()
                {
                    handle.set_handler(GroupRequests {
                        name: (*name).to_owned(),
                        output,
                        binding: requests.binding.clone(),
                    });
                    handle.send_capabilities(GroupCapabilities::CREATE_WORKSPACE);
                } else {
                    handle.send_capabilities(GroupCapabilities::default());
                }
                changed = true;
                GroupState {
                    handle: Rc::downgrade(&handle),
                    output,
                    outputs: BTreeMap::new(),
                }
            });
            let Some(handle) = group.handle.upgrade().filter(|g| g.client_id().is_some()) else {
                continue;
            };
            let bindings: BTreeMap<_, _> = outputs
                .names
                .iter()
                .filter(|(_, connector)| connector.as_str() == *name)
                .filter_map(|(global, _)| outputs.bindings.get(global))
                .flat_map(|bindings| bindings.iter())
                .filter_map(|(&id, output)| {
                    output
                        .upgrade()
                        .filter(|o| o.client_id().is_some())
                        .map(|o| (id, o))
                })
                .collect();
            group.outputs.retain(|id, output| {
                if bindings.contains_key(id) {
                    return true;
                }
                if let Some(output) = output.upgrade().filter(|o| o.client_id().is_some()) {
                    handle.send_output_leave(&output);
                    changed = true;
                }
                false
            });
            for (id, output) in bindings {
                group.outputs.entry(id).or_insert_with(|| {
                    handle.send_output_enter(&output);
                    changed = true;
                    Rc::downgrade(&output)
                });
            }
        }

        for (&id, row) in &snapshot.workspaces {
            let group = live.get(row.output.as_str()).copied();
            let mut created = false;
            let workspace = self.workspaces.entry(id).or_insert_with(|| {
                let handle = manager.new_send_workspace();
                handle.set_forward_to_server(false);
                if let Ok(requests) = manager.try_get_handler_ref::<ManagerRequests>() {
                    handle.set_handler(WorkspaceRequests {
                        id,
                        binding: requests.binding.clone(),
                    });
                }
                if row.configured {
                    handle.send_id(&row.slot.to_string());
                }
                changed = true;
                created = true;
                WorkspaceState {
                    handle: Rc::downgrade(&handle),
                    row: row.clone(),
                    group: None,
                }
            });
            let Some(handle) = workspace
                .handle
                .upgrade()
                .filter(|w| w.client_id().is_some())
            else {
                continue;
            };
            if created || workspace.row.name != row.name {
                handle.send_name(&row.name);
                changed = true;
            }
            if created || workspace.row.index != row.index {
                handle.send_coordinates(&row.index.to_ne_bytes());
                changed = true;
            }
            if created || workspace.row.can_remove != row.can_remove {
                let mut capabilities = WorkspaceCapabilities::ACTIVATE;
                if snapshot.session.is_some() && matches!(id, WorkspaceKey::Runtime(_)) {
                    capabilities |=
                        WorkspaceCapabilities::ASSIGN | WorkspaceCapabilities::DEACTIVATE;
                    if row.can_remove {
                        capabilities |= WorkspaceCapabilities::REMOVE;
                    }
                }
                handle.send_capabilities(capabilities);
                changed = true;
            }
            if created || (workspace.row.active, workspace.row.urgent) != (row.active, row.urgent) {
                handle.send_state(HandleState(
                    u32::from(row.active) | (u32::from(row.urgent) << 1),
                ));
                changed = true;
            }
            if let Some(name) = group
                && workspace.group.as_deref() != group
                && let Some(group) = self
                    .groups
                    .get(name)
                    .and_then(|group| group.handle.upgrade())
                    .filter(|g| g.client_id().is_some())
            {
                group.send_workspace_enter(&handle);
                changed = true;
            }
            workspace.row = row.clone();
            workspace.group = group.map(str::to_owned);
        }
        changed
    }
}

struct ManagerRequests {
    binding: Weak<RefCell<Binding>>,
    ipc: Ipc,
}

impl ExtWorkspaceManagerV1Handler for ManagerRequests {
    fn handle_commit(&mut self, _manager: &Rc<Manager>) {
        let Some(binding) = self.binding.upgrade() else {
            return;
        };
        let mut binding = binding.borrow_mut();
        let (epoch, _) = self.ipc.current();
        let batch = std::mem::take(&mut binding.pending);
        if epoch == binding.epoch && !batch.is_empty() {
            self.ipc.queue_batch(epoch, batch);
        }
    }

    fn handle_stop(&mut self, manager: &Rc<Manager>) {
        if let Some(binding) = self.binding.upgrade() {
            binding.borrow_mut().pending.clear();
        }
        manager.send_finished();
        manager.delete_id();
    }
}

struct WorkspaceRequests {
    id: WorkspaceKey,
    binding: Weak<RefCell<Binding>>,
}

impl WorkspaceRequests {
    fn queue(
        &self,
        handle: &Rc<Handle>,
        action: impl FnOnce(&Binding, &Workspace) -> Option<WorkspaceAction>,
    ) {
        let Some(binding) = self.binding.upgrade() else {
            return;
        };
        let mut binding = binding.borrow_mut();
        if let Some(workspace) = binding.workspaces.get(&self.id)
            && workspace.handle.ptr_eq(&Rc::downgrade(handle))
            && let Some(action) = action(&binding, &workspace.row)
        {
            binding.pending.push(action);
        }
    }
}

impl ExtWorkspaceHandleV1Handler for WorkspaceRequests {
    fn handle_activate(&mut self, handle: &Rc<Handle>) {
        self.queue(handle, |_, _| {
            Some(WorkspaceAction::Activate { workspace: self.id })
        });
    }

    fn handle_assign(&mut self, handle: &Rc<Handle>, group: &Rc<Group>) {
        self.queue(handle, |binding, _| {
            let requests = group.try_get_handler_ref::<GroupRequests>().ok()?;
            let current = binding.groups.get(&requests.name)?;
            (matches!(self.id, WorkspaceKey::Runtime(_))
                && current.output != 0
                && current.handle.ptr_eq(&Rc::downgrade(group)))
            .then_some(WorkspaceAction::Assign {
                workspace: self.id,
                output: current.output,
            })
        });
    }

    fn handle_deactivate(&mut self, handle: &Rc<Handle>) {
        self.queue(handle, |_, _| {
            matches!(self.id, WorkspaceKey::Runtime(_))
                .then_some(WorkspaceAction::Deactivate { workspace: self.id })
        });
    }

    fn handle_remove(&mut self, handle: &Rc<Handle>) {
        self.queue(handle, |_, row| {
            row.can_remove
                .then_some(WorkspaceAction::Remove { workspace: self.id })
        });
    }
}

struct GroupRequests {
    name: String,
    output: u32,
    binding: Weak<RefCell<Binding>>,
}

impl ExtWorkspaceGroupHandleV1Handler for GroupRequests {
    fn handle_create_workspace(&mut self, handle: &Rc<Group>, name: &str) {
        if let Some(binding) = self.binding.upgrade() {
            let mut binding = binding.borrow_mut();
            if binding
                .groups
                .get(&self.name)
                .is_some_and(|group| group.handle.ptr_eq(&Rc::downgrade(handle)))
            {
                binding.pending.push(WorkspaceAction::Create {
                    output: self.output,
                    name: name.to_owned(),
                });
            }
        }
    }
}
