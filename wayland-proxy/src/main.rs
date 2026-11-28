mod ipc;
mod proxy;
mod workspaces;

use crate::{
    ipc::Ipc,
    proxy::{Connection, Display},
};
use std::{
    cell::RefCell,
    env,
    ffi::OsString,
    fs::{self, File, OpenOptions},
    io::{self, Read},
    os::{
        fd::{AsRawFd, OwnedFd},
        unix::{
            fs::{FileTypeExt, OpenOptionsExt, PermissionsExt},
            net::{UnixListener, UnixStream},
            process::CommandExt,
        },
    },
    path::{Path, PathBuf},
    process::{Command, ExitCode, Stdio},
    rc::Rc,
    sync::atomic::{AtomicBool, Ordering},
    thread,
    time::{Duration, Instant},
};
use wl_proxy::{
    baseline::Baseline,
    client::ClientHandler,
    state::{Destructor, State},
};

const USAGE: &str = "Usage: triad-wayland-proxy serve [--socket PATH]\n       triad-wayland-proxy run [--socket PATH] -- COMMAND [ARG ...]\n       triad-wayland-proxy prepare [--socket PATH]";
static EXIT: AtomicBool = AtomicBool::new(false);

extern "C" fn stop(_: libc::c_int) {
    EXIT.store(true, Ordering::Relaxed);
}

struct Listener {
    socket: UnixListener,
    path: PathBuf,
    _lock: File,
}

impl Listener {
    fn bind(path: PathBuf) -> io::Result<Self> {
        let mut lock_path = path.as_os_str().to_owned();
        lock_path.push(".lock");
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(lock_path)?;
        // The lock stays on disk so concurrent starts always lock the same inode.
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(io::Error::last_os_error());
        }
        match fs::symlink_metadata(&path) {
            Ok(meta) if meta.file_type().is_socket() => match UnixStream::connect(&path) {
                Err(error) if error.kind() == io::ErrorKind::ConnectionRefused => {
                    fs::remove_file(&path)?
                }
                _ => {
                    return Err(io::Error::new(
                        io::ErrorKind::AddrInUse,
                        "proxy socket already in use",
                    ));
                }
            },
            Ok(_) => {
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    "proxy socket path exists and is not a socket",
                ));
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
        let socket = UnixListener::bind(&path)?;
        let listener = Self {
            socket,
            path,
            _lock: lock,
        };
        fs::set_permissions(&listener.path, fs::Permissions::from_mode(0o600))?;
        listener.socket.set_nonblocking(true)?;
        Ok(listener)
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

struct Peer {
    state: Rc<State>,
    connection: Rc<RefCell<Connection>>,
}

struct ClientLifetime {
    _destructor: Destructor,
}

impl ClientHandler for ClientLifetime {}

impl Peer {
    fn connect(
        upstream: &Path,
        socket: UnixStream,
        ipc: &Ipc,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        let upstream = Rc::new(OwnedFd::from(UnixStream::connect(upstream)?));
        let state = State::builder(Baseline::ALL_OF_THEM)
            .with_server_fd(&upstream)
            .build()?;
        let client = match state.add_client(&Rc::new(socket.into())) {
            Ok(client) => client,
            Err(error) => {
                state.destroy();
                return Err(error.into());
            }
        };
        client.set_handler(ClientLifetime {
            _destructor: state.create_destructor(),
        });
        let connection = Connection::new(ipc.clone());
        client.display().set_handler(Display(connection.clone()));
        Ok(Self { state, connection })
    }
}

impl Drop for Peer {
    fn drop(&mut self) {
        self.state.destroy();
    }
}

fn poll_input(fd: libc::c_int) -> libc::pollfd {
    libc::pollfd {
        fd,
        events: libc::POLLIN,
        revents: 0,
    }
}

fn same_user(socket: &UnixStream) -> bool {
    let mut credentials: libc::ucred = unsafe { std::mem::zeroed() };
    let mut size = std::mem::size_of_val(&credentials) as libc::socklen_t;
    let result = unsafe {
        libc::getsockopt(
            socket.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut credentials as *mut libc::ucred).cast(),
            &mut size,
        )
    };
    result == 0 && credentials.uid == unsafe { libc::geteuid() }
}

fn serve(path: PathBuf, upstream: &Path, ipc: &Ipc, mut wake: UnixStream) -> io::Result<()> {
    let river = UnixStream::connect(upstream)?;
    let listener = Listener::bind(path)?;
    eprintln!(
        "triad-wayland-proxy: listening on {}",
        listener.path.display()
    );
    let mut peers: Vec<Peer> = Vec::new();
    while !EXIT.load(Ordering::Relaxed) {
        peers.retain(|peer| {
            peer.connection.borrow_mut().publish(false);
            if let Err(error) = peer.state.before_poll() {
                eprintln!("triad-wayland-proxy: {error}");
            }
            peer.state.is_not_destroyed()
        });
        let mut ready = vec![
            poll_input(listener.socket.as_raw_fd()),
            libc::pollfd {
                fd: river.as_raw_fd(),
                events: 0,
                revents: 0,
            },
            poll_input(wake.as_raw_fd()),
        ];
        ready.extend(
            peers
                .iter()
                .map(|peer| poll_input(peer.state.poll_fd().as_raw_fd())),
        );
        let result = unsafe { libc::poll(ready.as_mut_ptr(), ready.len() as libc::nfds_t, 1000) };
        if result < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if ready[1].revents != 0 {
            return Ok(());
        }
        if ready[2].revents != 0 {
            let _ = wake.read(&mut [0; 4096]);
        }
        for (peer, fd) in peers.iter().zip(&ready[3..]) {
            if fd.revents != 0
                && let Err(error) = peer.state.dispatch_available()
            {
                eprintln!("triad-wayland-proxy: {error}");
            }
        }
        if ready[0].revents != 0 {
            // Work in bounded batches so new connections can't starve messages.
            for _ in 0..16 {
                match listener.socket.accept() {
                    Ok((socket, _)) if peers.len() < 128 && same_user(&socket) => {
                        match Peer::connect(upstream, socket, ipc) {
                            Ok(peer) => peers.push(peer),
                            Err(error) => eprintln!("triad-wayland-proxy: {error}"),
                        }
                    }
                    Ok(_) => {}
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                    Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                    Err(error) => return Err(error),
                }
            }
        }
    }
    Ok(())
}

fn prepare(path: &Path, upstream: &Path) -> Result<ExitCode, Box<dyn std::error::Error>> {
    if proxy::native_workspaces(upstream)? {
        return Ok(ExitCode::from(2));
    }
    if UnixStream::connect(path).is_ok() {
        return Ok(ExitCode::SUCCESS);
    }

    let mut server = Command::new(env::current_exe()?);
    server
        .args(["serve", "--socket"])
        .arg(path)
        .stdin(Stdio::null())
        .stdout(Stdio::null());
    // The proxy belongs to River's session and can survive WM and shell reloads.
    unsafe {
        server.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = server.spawn()?;
    let deadline = Instant::now() + Duration::from_secs(1);
    loop {
        let _ = child.try_wait()?;
        if UnixStream::connect(path).is_ok() {
            return Ok(ExitCode::SUCCESS);
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err("workspace proxy did not start listening".into());
        }
        thread::sleep(Duration::from_millis(15));
    }
}

fn main_impl() -> Result<ExitCode, Box<dyn std::error::Error>> {
    let mut args = env::args_os().skip(1).peekable();
    let verb = args.next().unwrap_or_else(|| "--help".into());
    if verb == "--help" || verb == "-h" {
        println!("{USAGE}");
        return Ok(ExitCode::SUCCESS);
    }
    if verb != "serve" && verb != "run" && verb != "prepare" {
        return Err(USAGE.into());
    }
    let custom_socket = if args.peek().is_some_and(|arg| arg == "--socket") {
        args.next();
        Some(PathBuf::from(args.next().ok_or(USAGE)?))
    } else {
        None
    };
    let runtime =
        PathBuf::from(env::var_os("XDG_RUNTIME_DIR").ok_or("XDG_RUNTIME_DIR is required")?);
    let display = env::var_os("WAYLAND_DISPLAY").unwrap_or_else(|| "wayland-0".into());
    let upstream = runtime.join(display);
    let basename = upstream.file_name().ok_or("invalid WAYLAND_DISPLAY")?;
    let mut name = OsString::from("triad-workspaces-");
    name.push(basename);
    let path = std::path::absolute(custom_socket.unwrap_or_else(|| runtime.join(name)))?;
    if verb == "run" {
        if args.next().as_deref() != Some("--".as_ref()) {
            return Err(USAGE.into());
        }
        let command = args.next().ok_or(USAGE)?;
        // Check that the service is reachable before replacing the launcher.
        UnixStream::connect(&path).map_err(|e| {
            format!(
                "could not connect to {}: {e}; start the proxy with serve",
                path.display()
            )
        })?;
        // Clients may use the display name to derive their own socket names.
        // Keep the usual basename for listeners in the session runtime dir.
        let runtime = std::path::absolute(&runtime)?;
        let client_display = path
            .strip_prefix(runtime)
            .ok()
            .filter(|relative| relative.components().count() == 1)
            .unwrap_or(&path);
        return Err(Command::new(command)
            .args(args)
            .env("WAYLAND_DISPLAY", client_display)
            .env_remove("WAYLAND_SOCKET")
            .exec()
            .into());
    }
    if args.next().is_some() {
        return Err(USAGE.into());
    }
    if path == upstream {
        return Err("proxy socket must differ from the River socket".into());
    }
    if verb == "prepare" {
        return prepare(&path, &upstream);
    }
    let state_path =
        env::var_os("TRIAD_SOCKET").map_or_else(|| runtime.join("triad.sock"), PathBuf::from);
    let niri_path = env::var_os("TRIAD_NIRI_SOCKET")
        .map_or_else(|| runtime.join("triad-niri.sock"), PathBuf::from);
    // The handlers only set an atomic flag. The main loop owns all cleanup.
    unsafe {
        libc::signal(libc::SIGINT, stop as *const () as libc::sighandler_t);
        libc::signal(libc::SIGTERM, stop as *const () as libc::sighandler_t);
    }
    let (ipc, wake) = Ipc::start(state_path, niri_path)?;
    serve(path, &upstream, &ipc, wake)?;
    Ok(ExitCode::SUCCESS)
}

fn main() -> ExitCode {
    match main_impl() {
        Ok(status) => status,
        Err(error) => {
            eprintln!("triad-wayland-proxy: {error}");
            ExitCode::FAILURE
        }
    }
}
