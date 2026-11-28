use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    io::{self, BufRead, BufReader, Read, Write},
    os::unix::net::UnixStream,
    path::PathBuf,
    sync::{Arc, Mutex, mpsc::SyncSender},
    thread,
    time::Duration,
};

const MAX_LINE: u64 = 16 * 1024 * 1024;
const IPC_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Debug, Default, PartialEq, Eq)]
pub struct Snapshot {
    pub outputs: BTreeSet<String>,
    pub workspaces: BTreeMap<u32, Workspace>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Workspace {
    pub index: u32,
    pub name: String,
    pub output: String,
    pub active: bool,
    pub urgent: bool,
    pub configured: bool,
}

#[derive(Deserialize)]
struct State {
    layout: Layout,
    outputs: Vec<Output>,
}

#[derive(Deserialize)]
struct Layout {
    workspaces: Vec<Row>,
}

#[derive(Deserialize)]
struct Output {
    name: String,
    connected: bool,
}

#[derive(Deserialize)]
struct Row {
    tag_id: u32,
    workspace_idx: u32,
    name: Option<String>,
    output: Option<String>,
    is_active: bool,
    is_output_visible: bool,
    is_configured: bool,
    is_urgent: bool,
    occupied: bool,
}

impl From<State> for Snapshot {
    fn from(state: State) -> Self {
        Self {
            outputs: state
                .outputs
                .into_iter()
                .filter(|o| o.connected)
                .map(|o| o.name)
                .collect(),
            workspaces: state
                .layout
                .workspaces
                .into_iter()
                .filter(|w| w.is_configured || w.occupied || w.is_active || w.is_output_visible)
                .map(|w| {
                    (
                        w.tag_id,
                        Workspace {
                            index: w.workspace_idx,
                            name: w
                                .name
                                .filter(|name| !name.is_empty())
                                .unwrap_or_else(|| w.workspace_idx.to_string()),
                            output: w.output.unwrap_or_default(),
                            active: w.is_output_visible,
                            urgent: w.is_urgent,
                            configured: w.is_configured,
                        },
                    )
                })
                .collect(),
        }
    }
}

#[derive(Default)]
struct Feed {
    epoch: u64,
    snapshot: Option<Arc<Snapshot>>,
}

#[derive(Clone)]
pub struct Ipc {
    feed: Arc<Mutex<Feed>>,
    actions: SyncSender<(u64, u32)>,
}

fn read_json(reader: &mut impl BufRead) -> io::Result<Value> {
    let mut frame = Vec::new();
    if reader.take(MAX_LINE + 1).read_until(b'\n', &mut frame)? == 0 {
        return Err(io::Error::from(io::ErrorKind::UnexpectedEof));
    }
    if frame.len() as u64 > MAX_LINE || !frame.ends_with(b"\n") {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "incomplete or oversized Triad IPC message",
        ));
    }
    Ok(serde_json::from_slice(&frame)?)
}

fn wake_main(mut wake: &UnixStream) {
    // WouldBlock means a wakeup is already queued.
    let _ = wake.write(&[1]);
}

fn subscribe(path: &PathBuf, feed: &Mutex<Feed>, wake: &UnixStream) -> io::Result<()> {
    let mut socket = UnixStream::connect(path)?;
    socket.set_write_timeout(Some(IPC_TIMEOUT))?;
    writeln!(
        socket,
        "{}",
        json!({"triad":{"version":1,"request":"event-stream","events":["state"]}})
    )?;
    socket.set_read_timeout(Some(IPC_TIMEOUT))?;
    let mut reader = BufReader::new(socket);
    if read_json(&mut reader)?["ok"] != true {
        return Err(io::Error::other("Triad rejected the state subscription"));
    }
    loop {
        let mut event = read_json(&mut reader)?;
        let event = &mut event["triad"];
        if event["event"] == "state-changed" && event["version"] == 1 {
            let snapshot = Snapshot::from(serde_json::from_value::<State>(event["state"].take())?);
            let mut feed = feed.lock().unwrap();
            if feed.snapshot.as_deref() != Some(&snapshot) {
                feed.snapshot = Some(Arc::new(snapshot));
                wake_main(wake);
            }
            reader.get_ref().set_read_timeout(None)?;
        }
    }
}

fn activate(path: &PathBuf, id: u32) -> io::Result<()> {
    let mut socket = UnixStream::connect(path)?;
    socket.set_read_timeout(Some(IPC_TIMEOUT))?;
    socket.set_write_timeout(Some(IPC_TIMEOUT))?;
    writeln!(
        socket,
        "{}",
        json!({"Action":{"FocusWorkspace":{"reference":{"Id":id}}}})
    )?;
    if read_json(&mut BufReader::new(socket))?.get("Ok").is_none() {
        return Err(io::Error::other("Triad rejected workspace activation"));
    }
    Ok(())
}

impl Ipc {
    pub fn start(state_path: PathBuf, niri_path: PathBuf) -> io::Result<(Self, UnixStream)> {
        let (main, wake) = UnixStream::pair()?;
        main.set_nonblocking(true)?;
        wake.set_nonblocking(true)?;
        let feed = Arc::new(Mutex::new(Feed::default()));
        let reader = feed.clone();
        thread::spawn(move || {
            loop {
                let result = subscribe(&state_path, &reader, &wake);
                {
                    let mut feed = reader.lock().unwrap();
                    if feed.snapshot.take().is_some() {
                        feed.epoch += 1;
                        wake_main(&wake);
                        if let Err(error) = result {
                            eprintln!("triad-wayland-proxy: Triad state disconnected: {error}");
                        }
                    }
                }
                thread::sleep(Duration::from_millis(250));
            }
        });

        let (actions, requests) = std::sync::mpsc::sync_channel(32);
        let writer = feed.clone();
        thread::spawn(move || {
            while let Ok((epoch, id)) = requests.recv() {
                let ready = {
                    let feed = writer.lock().unwrap();
                    feed.epoch == epoch
                        && feed
                            .snapshot
                            .as_ref()
                            .is_some_and(|s| s.workspaces.contains_key(&id))
                };
                if ready && let Err(error) = activate(&niri_path, id) {
                    eprintln!("triad-wayland-proxy: workspace activation failed: {error}");
                }
            }
        });
        Ok((Self { feed, actions }, main))
    }

    pub fn current(&self) -> (u64, Option<Arc<Snapshot>>) {
        let feed = self.feed.lock().unwrap();
        (feed.epoch, feed.snapshot.clone())
    }

    pub fn queue_activation(&self, epoch: u64, id: u32) {
        if let Err(error) = self.actions.try_send((epoch, id)) {
            eprintln!("triad-wayland-proxy: could not queue workspace activation: {error}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn projects_configured_visible_and_occupied_workspaces() {
        let state: State = serde_json::from_value(json!({
            "outputs": [{"name":"DP-1","connected":true},{"name":"DP-2","connected":false}],
            "layout":{"workspaces":[
                {"tag_id":1,"workspace_idx":1,"name":null,"output":"DP-1","is_active":false,"is_output_visible":false,"is_configured":true,"is_urgent":false,"occupied":false},
                {"tag_id":2,"workspace_idx":2,"name":"Web","output":"DP-1","is_active":false,"is_output_visible":true,"is_configured":false,"is_urgent":true,"occupied":false},
                {"tag_id":3,"workspace_idx":3,"name":null,"output":"DP-1","is_active":false,"is_output_visible":false,"is_configured":false,"is_urgent":false,"occupied":true},
                {"tag_id":4,"workspace_idx":4,"name":null,"output":null,"is_active":false,"is_output_visible":false,"is_configured":false,"is_urgent":false,"occupied":false}
            ]}
        })).unwrap();
        let snapshot = Snapshot::from(state);
        assert_eq!(snapshot.outputs, BTreeSet::from(["DP-1".to_owned()]));
        assert_eq!(
            snapshot.workspaces.keys().copied().collect::<Vec<_>>(),
            [1, 2, 3]
        );
        assert_eq!(snapshot.workspaces[&1].name, "1");
        assert_eq!(snapshot.workspaces[&2].name, "Web");
        assert!(snapshot.workspaces[&2].active && snapshot.workspaces[&2].urgent);
        assert!(!snapshot.workspaces[&1].active);
    }
}
