//! Yuwai's tab strip on top of AeroSpace. AeroSpace owns all window geometry.
use libc::c_void;
use std::{
    collections::{HashMap, HashSet},
    os::unix::{fs::FileTypeExt, net::UnixDatagram},
    path::PathBuf,
    process::Command,
    ptr, thread,
    time::{Duration, Instant},
};
mod macos;
use macos::{TabInput, TabStrip};

type CF = *const c_void;
const AEROSPACE: &str = "/run/current-system/sw/bin/aerospace";

#[repr(C)]
struct TimerContext {
    version: isize,
    info: *mut c_void,
    retain: Option<extern "C" fn(*const c_void) -> *const c_void>,
    release: Option<extern "C" fn(*const c_void)>,
    description: Option<extern "C" fn(*const c_void) -> CF>,
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRunLoopGetCurrent() -> CF;
    fn CFRunLoopAddTimer(loop_ref: CF, timer: CF, mode: CF);
    fn CFRunLoopRemoveTimer(loop_ref: CF, timer: CF, mode: CF);
    fn CFRunLoopTimerCreate(
        allocator: CF,
        fire: f64,
        interval: f64,
        flags: u32,
        order: isize,
        callback: extern "C" fn(CF, *mut c_void),
        context: *const TimerContext,
    ) -> CF;
    fn CFAbsoluteTimeGetCurrent() -> f64;
    fn CFRelease(value: CF);
    static kCFRunLoopCommonModes: CF;
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct Window {
    id: u32,
    app: String,
    parent: String,
    title: String,
}

fn socket_path() -> PathBuf {
    PathBuf::from(format!("/private/tmp/yuwai-tabs-{}.sock", unsafe {
        libc::geteuid()
    }))
}

fn aerospace(args: &[&str]) -> Result<String, String> {
    let output = Command::new(AEROSPACE)
        .args(args)
        .output()
        .map_err(|e| format!("aerospace {}: {e}", args.join(" ")))?;
    if !output.status.success() {
        return Err(format!(
            "aerospace {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    String::from_utf8(output.stdout).map_err(|e| format!("aerospace output: {e}"))
}

fn windows(workspace: &str) -> Result<Vec<Window>, String> {
    let output = aerospace(&[
        "list-windows", "--workspace", workspace, "--format",
        "%{window-id}%{tab}%{app-bundle-id}%{tab}%{window-parent-container-layout}%{tab}%{window-title}",
    ])?;
    output
        .lines()
        .map(|line| {
            let mut fields = line.splitn(4, '\t');
            let id = fields
                .next()
                .ok_or("missing window ID")?
                .parse()
                .map_err(|e| format!("window ID: {e}"))?;
            Ok(Window {
                id,
                app: fields.next().ok_or("missing bundle ID")?.to_owned(),
                parent: fields.next().ok_or("missing parent layout")?.to_owned(),
                title: fields.next().unwrap_or_default().to_owned(),
            })
        })
        .collect()
}

fn focused_window() -> Result<Option<(u32, i32, String)>, String> {
    let output = match aerospace(&[
        "list-windows", "--focused", "--format",
        "%{window-id}%{tab}%{app-pid}%{tab}%{workspace}",
    ]) {
        Ok(output) => output,
        Err(error) if error.contains("No window is focused") => return Ok(None),
        Err(error) => return Err(error),
    };
    let mut fields = output.trim().split('\t');
    let id = fields.next().unwrap_or_default().parse::<u32>()
        .map_err(|error| format!("focused window ID: {error}"))?;
    let pid = fields.next().unwrap_or_default().parse::<i32>()
        .map_err(|error| format!("focused app PID: {error}"))?;
    let workspace = fields.next().unwrap_or_default().to_owned();
    Ok(Some((id, pid, workspace)))
}

fn tiled(window: &Window) -> bool {
    !window.app.is_empty()
        && matches!(
            window.parent.as_str(),
            "h_tiles" | "v_tiles" | "h_accordion" | "v_accordion"
        )
}

fn tab_eligible(window: &Window) -> bool {
    !window.app.is_empty()
        && window.app != "com.google.Chrome"
        && window.parent != "macos_native_fullscreen"
}

fn tab_candidates(rows: &[Window]) -> Vec<&Window> {
    let mut counts = HashMap::new();
    for row in rows.iter().filter(|row| tab_eligible(row)) {
        *counts.entry(row.app.as_str()).or_insert(0usize) += 1;
    }
    rows.iter()
        .filter(|row| {
            tab_eligible(row)
                && (tiled(row) || counts.get(row.app.as_str()).copied().unwrap_or(0) > 1)
        })
        .collect()
}

fn groups(rows: &[Window]) -> Vec<(String, Vec<u32>)> {
    let mut result: Vec<(String, Vec<u32>)> = Vec::new();
    for row in tab_candidates(rows) {
        if let Some((_, ids)) = result.iter_mut().find(|(app, _)| *app == row.app) {
            ids.push(row.id);
        } else {
            result.push((row.app.clone(), vec![row.id]));
        }
    }
    result
}

fn group_ready(rows: &[Window], workspace: &str, app: &str) -> bool {
    let app_groups = groups(rows);
    let Some((_, ids)) = app_groups.iter().find(|(name, _)| name == app) else {
        return false;
    };
    if ids.len() < 2 {
        return false;
    }
    let expected = if workspace == "3" {
        "h_accordion"
    } else {
        "v_accordion"
    };
    let single_app_root =
        app_groups.len() == 1 && matches!(workspace, "1" | "5" | "6" | "7" | "8" | "9");
    ids.iter().all(|id| {
        rows.iter().any(|row| {
            row.id == *id
                && (row.parent == expected || (single_app_root && row.parent == "h_accordion"))
        })
    })
}

fn all_groups_ready(rows: &[Window], workspace: &str) -> bool {
    groups(rows)
        .iter()
        .filter(|(_, ids)| ids.len() > 1)
        .all(|(app, _)| group_ready(rows, workspace, app))
}

fn snapshot(rows: &[Window]) -> Vec<(u32, String, String)> {
    let mut signature: Vec<_> = tab_candidates(rows)
        .into_iter()
        .map(|row| (row.id, row.app.clone(), row.parent.clone()))
        .collect();
    signature.sort_unstable_by_key(|item| item.0);
    signature
}

fn ordered_tiles(workspace: &str, orientation: &str) -> Result<Vec<Window>, String> {
    let deadline = Instant::now() + Duration::from_millis(800);
    loop {
        let frames = macos::window_frames()?;
        let mut rows: Vec<_> = windows(workspace)?
            .into_iter()
            .filter(|row| tiled(row) && row.app != "com.google.Chrome")
            .collect();
        let primary = |row: &Window| {
            frames.get(&row.id).map(|frame| {
                if orientation == "v_tiles" {
                    frame.y
                } else {
                    frame.x
                }
            })
        };
        let mut positions: Vec<_> = rows.iter().filter_map(&primary).collect();
        positions.sort_by(f64::total_cmp);
        let settled = positions.len() == rows.len()
            && positions
                .windows(2)
                .all(|pair| (pair[1] - pair[0]).abs() > 1.0);
        if settled {
            rows.sort_by(|a, b| {
                primary(a)
                    .unwrap_or_default()
                    .total_cmp(&primary(b).unwrap_or_default())
                    .then_with(|| a.id.cmp(&b.id))
            });
            return Ok(rows);
        }
        if Instant::now() >= deadline {
            return Err("tiled window positions did not settle".into());
        }
        thread::sleep(Duration::from_millis(20));
    }
}

fn rebuild(workspace: &str, rows: &[Window]) -> Result<(), String> {
    if !matches!(
        workspace,
        "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9"
    ) {
        return Err("unsupported workspace name".into());
    }
    let focused_workspace =
        aerospace(&["list-workspaces", "--focused", "--format", "%{workspace}"])?;
    if focused_workspace.trim() != workspace {
        return Err("tab grouping requires the workspace to be focused".into());
    }
    if macos::chrome_is_frontmost() {
        return Err("Chrome is frontmost on its native macOS Space".into());
    }
    let app_groups = groups(rows);
    if !app_groups.iter().any(|(_, ids)| ids.len() > 1) {
        return Ok(());
    }
    let root = match workspace {
        "2" | "4" => "h_tiles",
        "3" => "v_tiles",
        _ => "h_accordion",
    };
    let (join_direction, move_direction, inner) = if root == "v_tiles" {
        ("down", "up", "h_accordion")
    } else {
        ("right", "left", "v_accordion")
    };
    let staging = if root == "h_accordion" {
        "h_tiles"
    } else {
        root
    };
    let frames = macos::window_frames()?;
    let candidate_ids: HashSet<_> = app_groups
        .iter()
        .flat_map(|(_, ids)| ids.iter().copied())
        .collect();
    if !candidate_ids.iter().all(|id| frames.contains_key(id)) {
        return Err("a tab candidate is not visible on the current macOS Space".into());
    }
    let floating: Vec<_> = rows
        .iter()
        .filter(|row| row.parent == "floating" && candidate_ids.contains(&row.id))
        .map(|row| row.id)
        .collect();
    let result = (|| {
        for id in &floating {
            aerospace(&["layout", "--window-id", &id.to_string(), "tiling"])?;
        }
        if app_groups.len() == 1 {
            let layout = if root == "h_accordion" { root } else { inner };
            aerospace(&["flatten-workspace-tree", "--workspace", workspace])?;
            aerospace(&["layout", "--workspace", workspace, "--root", layout])?;
            return Ok(());
        }
        aerospace(&["flatten-workspace-tree", "--workspace", workspace])?;
        aerospace(&["layout", "--workspace", workspace, "--root", staging])?;
        let flattened = ordered_tiles(workspace, staging)?;
        let mut current: Vec<_> = flattened
            .iter()
            .filter(|window| tiled(window))
            .map(|w| w.id)
            .collect();
        let mut desired = Vec::new();
        let mut ordered_groups = Vec::new();
        for (_, ids) in groups(&flattened) {
            desired.extend(&ids);
            ordered_groups.push(ids);
        }
        if current.len() != desired.len()
            || current.iter().copied().collect::<HashSet<_>>() != desired.iter().copied().collect()
        {
            return Err("window set changed during tab grouping".into());
        }
        let mut commands = Vec::new();
        for (target, id) in desired.iter().enumerate() {
            let mut position = current
                .iter()
                .position(|item| item == id)
                .ok_or("window disappeared")?;
            while position > target {
                commands.push(format!("swap --window-id {id} dfs-prev"));
                current.swap(position - 1, position);
                position -= 1;
            }
        }
        let mut grouped = HashSet::new();
        for ids in ordered_groups {
            if ids.len() < 2 {
                continue;
            }
            commands.push(format!("join-with --window-id {} {join_direction}", ids[0]));
            commands.push(format!("layout --window-id {} {inner}", ids[0]));
            for id in ids.iter().skip(2) {
                commands.push(format!("move --window-id {id} {move_direction}"));
            }
            grouped.extend(ids);
        }
        // One AeroSpace server transaction avoids interleaving user focus changes
        // between join, layout and move, which can pick a different neighbor.
        if macos::chrome_is_frontmost() {
            return Err("native macOS Space changed during tab grouping".into());
        }
        commands.push(format!("layout --workspace {workspace} --root {root}"));
        aerospace(&["eval", &commands.join(" && ")])?;
        let after = windows(workspace)?;
        if after
            .iter()
            .filter(|w| tiled(w))
            .map(|w| w.id)
            .collect::<HashSet<_>>()
            != desired.iter().copied().collect()
        {
            return Err("window set changed during tab grouping".into());
        }
        for row in after.into_iter().filter(tiled) {
            let expected = if grouped.contains(&row.id) {
                inner
            } else {
                root
            };
            if row.parent != expected {
                return Err(format!(
                    "unexpected app group: window {} has {} instead of {expected}",
                    row.id, row.parent
                ));
            }
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = aerospace(&["flatten-workspace-tree", "--workspace", workspace]);
        let _ = aerospace(&["layout", "--workspace", workspace, "--root", root]);
        for id in floating {
            let _ = aerospace(&["layout", "--window-id", &id.to_string(), "floating"]);
        }
    }
    result
}

struct State {
    tabs: TabStrip,
    socket: UnixDatagram,
    path: PathBuf,
    order: HashMap<(String, String), Vec<u32>>,
    signatures: HashMap<String, Vec<(u32, String, String)>>,
    retry_after: Option<Instant>,
    current_key: Option<(String, String)>,
    current_pid: Option<i32>,
    current_ids: Vec<u32>,
    selected: usize,
    pending_focus: Option<u32>,
    last_refresh: Instant,
    last_full_refresh: Instant,
    retry_refresh_after: Option<Instant>,
}

impl State {
    fn refresh_fast(&mut self) -> Result<bool, String> {
        if macos::chrome_is_frontmost() {
            self.hide();
            return Ok(true);
        }
        let Some((focused, pid, workspace)) = focused_window()? else {
            self.hide();
            return Ok(true);
        };
        if macos::frontmost_pid() != Some(pid) {
            self.hide();
            return Ok(true);
        }
        let Some((current_workspace, _)) = &self.current_key else {
            return Ok(false);
        };
        if current_workspace != &workspace || self.current_pid != Some(pid) {
            self.hide();
            return Ok(false);
        }
        let Some(selected) = self.current_ids.iter().position(|id| *id == focused) else {
            return Ok(false);
        };
        if selected != self.selected {
            let Some(frame) = macos::focused_frame(pid) else {
                return Ok(false);
            };
            self.tabs.move_to(frame);
            self.tabs.select(selected);
            self.selected = selected;
        }
        Ok(true)
    }

    fn refresh(&mut self) -> Result<(), String> {
        if macos::chrome_is_frontmost() {
            self.hide();
            return Ok(());
        }
        let Some((focused, pid, workspace)) = focused_window()? else {
            self.hide();
            return Ok(());
        };
        let workspace = workspace.as_str();
        if workspace.is_empty() {
            self.hide();
            return Ok(());
        }
        let mut rows = windows(workspace)?;
        // AeroSpace also sees windows on other native macOS Spaces. Never
        // mutate their tree while Chrome (or another Space) has the keyboard.
        if macos::frontmost_pid() != Some(pid)
            || !tab_candidates(&rows).iter().any(|row| row.id == focused)
        {
            self.hide();
            return Ok(());
        }
        let present: HashSet<_> = rows.iter().map(|w| w.id).collect();
        for ((space, app), ids) in &mut self.order {
            if space == workspace {
                ids.retain(|id| {
                    present.contains(id) && rows.iter().any(|w| w.id == *id && &w.app == app)
                });
            }
        }
        for (app, observed) in groups(&rows) {
            let ids = self.order.entry((workspace.to_owned(), app)).or_default();
            for id in observed {
                if !ids.contains(&id) {
                    ids.push(id);
                }
            }
        }
        let current_signature = snapshot(&rows);
        let ready = all_groups_ready(&rows, workspace);
        if ready {
            self.retry_after = None;
        }
        let mut regroup_failed = false;
        if !ready
            && self.signatures.get(workspace) != Some(&current_signature)
            && self.retry_after.is_none_or(|until| Instant::now() >= until)
        {
            if let Err(error) = rebuild(workspace, &rows) {
                eprintln!("tab grouping: {error}");
                self.retry_after = Some(Instant::now() + Duration::from_secs(3));
                regroup_failed = true;
            } else {
                self.retry_after = None;
            }
            rows = windows(workspace)?;
        }
        if regroup_failed {
            // A failed rebuild may have reset the tree. Retry only after its
            // window topology changes, rather than toggling it every few seconds.
            self.signatures
                .insert(workspace.to_owned(), snapshot(&rows));
        } else if self.retry_after.is_none() {
            self.signatures
                .insert(workspace.to_owned(), snapshot(&rows));
        }
        let Some(row) = rows
            .iter()
            .find(|w| w.id == focused && tiled(w) && w.app != "com.google.Chrome")
        else {
            self.hide();
            return Ok(());
        };
        let key = (workspace.to_owned(), row.app.clone());
        let Some(ids) = self.order.get(&key) else {
            self.hide();
            return Ok(());
        };
        if ids.len() < 2 || !group_ready(&rows, workspace, &row.app) {
            self.hide();
            return Ok(());
        }
        let Some(frame) = macos::focused_frame(pid) else {
            self.hide();
            return Ok(());
        };
        let titles: Vec<String> = ids
            .iter()
            .map(|id| {
                rows.iter().find(|row| row.id == *id).map_or_else(
                    || format!("Window {id}"),
                    |row| {
                        row.title
                            .split_once(" – Page ")
                            .map_or(row.title.as_str(), |(title, _)| title)
                            .to_owned()
                    },
                )
            })
            .collect();
        let selected = ids
            .iter()
            .position(|id| *id == focused)
            .ok_or("focused tab missing")?;
        self.tabs.show(frame, pid, &titles, selected);
        self.current_key = Some(key);
        self.current_pid = Some(pid);
        self.current_ids = ids.clone();
        self.selected = selected;
        Ok(())
    }

    fn hide(&mut self) {
        self.tabs.hide();
        self.current_key = None;
        self.current_pid = None;
        self.current_ids.clear();
    }

    fn focus(&mut self, id: u32) {
        if self.current_pid.is_none() || self.current_pid != macos::frontmost_pid() {
            self.hide();
            return;
        }
        if let Err(error) = aerospace(&["focus", "--window-id", &id.to_string()]) {
            eprintln!("tab focus {id}: {error}");
        } else if let Some(selected) = self.current_ids.iter().position(|current| *current == id) {
            self.tabs.select(selected);
            self.selected = selected;
            self.last_refresh = Instant::now();
        }
    }

    fn cycle(&mut self, step: isize) {
        if self.current_ids.len() < 2 {
            return;
        }
        let len = self.current_ids.len();
        let next = (self.selected + step.rem_euclid(len as isize) as usize) % len;
        self.focus(self.current_ids[next]);
    }

    fn on_input(&mut self, input: TabInput) {
        match input {
            TabInput::Click(index) => {
                self.pending_focus = self.current_ids.get(index).copied();
            }
            TabInput::Drag { source, x } => {
                if source < self.current_ids.len() {
                    self.tabs.preview_drop(x);
                }
            }
            TabInput::Drop { source, x } => {
                let before = self.tabs.finish_drop(x);
                let Some(key) = &self.current_key else {
                    return;
                };
                let Some(ids) = self.order.get_mut(key) else {
                    return;
                };
                if source >= ids.len() {
                    return;
                }
                let id = ids.remove(source);
                let target = before
                    .saturating_sub(usize::from(source < before))
                    .min(ids.len());
                ids.insert(target, id);
                self.last_refresh = Instant::now() - Duration::from_secs(1);
            }
        }
    }

    fn tick(&mut self) {
        if let Some(id) = self.pending_focus.take() {
            self.focus(id);
        }
        let mut message = [0u8; 32];
        let mut step = 0isize;
        loop {
            match self.socket.recv(&mut message) {
                Ok(size) => match &message[..size] {
                    b"next" => step = step.saturating_add(1),
                    b"prev" => step = step.saturating_sub(1),
                    _ => {}
                },
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(error) => {
                    eprintln!("tab socket: {error}");
                    break;
                }
            }
        }
        if step != 0 {
            self.cycle(step);
        }
        if self.last_refresh.elapsed() >= Duration::from_millis(250)
            && self
                .retry_refresh_after
                .is_none_or(|until| Instant::now() >= until)
        {
            self.last_refresh = Instant::now();
            let result = if self.last_full_refresh.elapsed() >= Duration::from_secs(2) {
                self.refresh().map(|()| {
                    self.last_full_refresh = Instant::now();
                })
            } else {
                match self.refresh_fast() {
                    Ok(true) => Ok(()),
                    Ok(false) => self.refresh().map(|()| {
                        self.last_full_refresh = Instant::now();
                    }),
                    Err(error) => Err(error),
                }
            };
            if let Err(error) = result {
                self.hide();
                eprintln!("tab refresh: {error}");
                self.retry_refresh_after = Some(Instant::now() + Duration::from_secs(5));
            } else {
                self.retry_refresh_after = None;
            }
        }
    }
}

impl Drop for State {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

extern "C" fn on_tick(_timer: CF, info: *mut c_void) {
    objc::rc::autoreleasepool(|| {
        let state = unsafe { &mut *(info as *mut State) };
        state.tick();
    });
}

fn on_tab_input(info: *mut c_void, input: TabInput) {
    let state = unsafe { &mut *(info as *mut State) };
    state.on_input(input);
}

pub fn send(direction: &str) -> Result<(), String> {
    if direction != "next" && direction != "prev" {
        return Err("expected next or prev".into());
    }
    UnixDatagram::unbound()
        .map_err(|e| e.to_string())?
        .send_to(direction.as_bytes(), socket_path())
        .map_err(|e| format!("tab daemon is not running: {e}"))?;
    Ok(())
}

pub fn run() -> Result<(), String> {
    if !macos::trusted() {
        return Err("Accessibility permission is required for tabs".into());
    }
    let path = socket_path();
    if path.exists() {
        if UnixDatagram::unbound()
            .map_err(|e| e.to_string())?
            .send_to(b"ping", &path)
            .is_ok()
        {
            return Err("tab daemon is already running".into());
        }
        if path
            .metadata()
            .map_err(|e| e.to_string())?
            .file_type()
            .is_socket()
        {
            std::fs::remove_file(&path).map_err(|e| e.to_string())?;
        } else {
            return Err(format!("socket path is not a socket: {}", path.display()));
        }
    }
    let socket = UnixDatagram::bind(&path).map_err(|e| format!("tab socket: {e}"))?;
    socket.set_nonblocking(true).map_err(|e| e.to_string())?;
    let tabs = TabStrip::new()?;
    let mut state = Box::new(State {
        tabs,
        socket,
        path,
        order: HashMap::new(),
        signatures: HashMap::new(),
        retry_after: None,
        current_key: None,
        current_pid: None,
        current_ids: Vec::new(),
        selected: 0,
        pending_focus: None,
        last_refresh: Instant::now() - Duration::from_secs(1),
        last_full_refresh: Instant::now() - Duration::from_secs(3),
        retry_refresh_after: None,
    });
    let info = state.as_mut() as *mut State as *mut c_void;
    state.tabs.set_input_handler(info, on_tab_input);
    state.tick();
    unsafe {
        let context = TimerContext {
            version: 0,
            info,
            retain: None,
            release: None,
            description: None,
        };
        let timer = CFRunLoopTimerCreate(
            ptr::null(),
            CFAbsoluteTimeGetCurrent() + 0.016,
            0.016,
            0,
            0,
            on_tick,
            &context,
        );
        if timer.is_null() {
            return Err("tab refresh timer creation failed".into());
        }
        let loop_ref = CFRunLoopGetCurrent();
        CFRunLoopAddTimer(loop_ref, timer, kCFRunLoopCommonModes);
        macos::run_event_loop();
        CFRunLoopRemoveTimer(loop_ref, timer, kCFRunLoopCommonModes);
        CFRelease(timer);
    }
    Ok(())
}

fn main() {
    let result = match std::env::args().nth(1).as_deref() {
        Some("next" | "prev") => send(&std::env::args().nth(1).unwrap_or_default()),
        Some("--check") => {
            println!("accessibility: {}", macos::trusted());
            aerospace(&["list-workspaces", "--focused"]).map(|_| ())
        }
        Some("--group-workspace") if std::env::var("YUWAI_TABS_TEST").as_deref() == Ok("1") => {
            let workspace = std::env::args().nth(2).unwrap_or_default();
            windows(&workspace).and_then(|rows| rebuild(&workspace, &rows))
        }
        Some(value) => Err(format!("unknown argument: {value}")),
        None => run(),
    };
    if let Err(error) = result {
        eprintln!("yuwai-tabs: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn same_app_windows_share_a_group() {
        let rows = vec![
            Window {
                id: 1,
                app: "terminal".into(),
                parent: "h_tiles".into(),
                title: "a".into(),
            },
            Window {
                id: 2,
                app: "notes".into(),
                parent: "h_tiles".into(),
                title: "n".into(),
            },
            Window {
                id: 3,
                app: "terminal".into(),
                parent: "h_tiles".into(),
                title: "b".into(),
            },
            Window {
                id: 4,
                app: "terminal".into(),
                parent: "floating".into(),
                title: "float".into(),
            },
        ];
        assert_eq!(
            groups(&rows),
            vec![
                ("terminal".into(), vec![1, 3, 4]),
                ("notes".into(), vec![2])
            ]
        );
        assert!(!group_ready(&rows, "2", "terminal"));
        let mut grouped = rows;
        grouped[0].parent = "v_accordion".into();
        grouped[2].parent = "v_accordion".into();
        grouped[3].parent = "v_accordion".into();
        assert!(group_ready(&grouped, "2", "terminal"));
    }

    #[test]
    fn chrome_and_lone_floating_windows_keep_their_layouts() {
        let row = |id, app: &str, parent: &str| Window {
            id,
            app: app.into(),
            parent: parent.into(),
            title: String::new(),
        };
        let rows = vec![
            row(1, "com.google.Chrome", "floating"),
            row(2, "com.google.Chrome", "macos_native_fullscreen"),
            row(3, "preview", "floating"),
            row(4, "terminal", "h_tiles"),
            row(5, "terminal", "h_tiles"),
            row(6, "preview", "macos_native_fullscreen"),
        ];
        assert_eq!(groups(&rows), vec![("terminal".into(), vec![4, 5])]);
        assert!(!tiled(&rows[1]));
        assert!(!tiled(&rows[5]));
        assert!(!tab_candidates(&rows).iter().any(|window| window.id == 2));
    }
}
