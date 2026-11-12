//! The only macOS boundary: Accessibility reads and the extracted AppKit tab strip.
use libc::c_void;
use objc::declare::ClassDecl;
use objc::runtime::{Class, Object, Sel};
use objc::{class, msg_send, sel, sel_impl};
use objc2_app_kit::NSWorkspace;
use objc2_core_foundation::{CFRetained, CFString};
use std::{collections::HashMap, ptr, sync::OnceLock};

type CF = *const c_void;

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Point {
    x: f64,
    y: f64,
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Size {
    w: f64,
    h: f64,
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct CGRect {
    origin: Point,
    size: Size,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

#[link(name = "ApplicationServices", kind = "framework")]
unsafe extern "C" {
    fn AXIsProcessTrusted() -> bool;
    fn AXUIElementCreateApplication(pid: i32) -> CF;
    fn AXUIElementCopyAttributeValue(element: CF, attribute: CF, value: *mut CF) -> i32;
    fn AXValueGetValue(value: CF, kind: i32, output: *mut c_void) -> bool;
    fn CGWindowListCopyWindowInfo(options: u32, relative_to: u32) -> CF;
    fn CGRectMakeWithDictionaryRepresentation(dictionary: CF, rect: *mut CGRect) -> bool;
    static kCGWindowNumber: CF;
    static kCGWindowLayer: CF;
    static kCGWindowBounds: CF;
}
#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(value: CF);
    fn CFArrayGetCount(array: CF) -> isize;
    fn CFArrayGetValueAtIndex(array: CF, index: isize) -> CF;
    fn CFDictionaryGetValue(dictionary: CF, key: CF) -> CF;
    fn CFNumberGetValue(number: CF, kind: i32, output: *mut c_void) -> bool;
}

unsafe fn number(dictionary: CF, key: CF) -> Option<i32> {
    let value = unsafe { CFDictionaryGetValue(dictionary, key) };
    if value.is_null() {
        return None;
    }
    let mut result = 0i32;
    unsafe { CFNumberGetValue(value, 3, &mut result as *mut _ as *mut c_void) }.then_some(result)
}

pub fn window_frames() -> Result<HashMap<u32, Rect>, String> {
    unsafe {
        let list = CGWindowListCopyWindowInfo(1, 0);
        if list.is_null() {
            return Err("CGWindowListCopyWindowInfo failed".into());
        }
        let mut frames = HashMap::new();
        for index in 0..CFArrayGetCount(list) {
            let item = CFArrayGetValueAtIndex(list, index);
            if number(item, kCGWindowLayer) != Some(0) {
                continue;
            }
            let Some(id) = number(item, kCGWindowNumber) else {
                continue;
            };
            let bounds = CFDictionaryGetValue(item, kCGWindowBounds);
            let mut rect = CGRect::default();
            if bounds.is_null() || !CGRectMakeWithDictionaryRepresentation(bounds, &mut rect) {
                continue;
            }
            frames.insert(
                id as u32,
                Rect {
                    x: rect.origin.x,
                    y: rect.origin.y,
                    w: rect.size.w,
                    h: rect.size.h,
                },
            );
        }
        CFRelease(list);
        Ok(frames)
    }
}

fn attribute(element: CF, name: &str) -> Option<CF> {
    let key = CFString::from_str(name);
    let mut value = ptr::null();
    let rc = unsafe {
        AXUIElementCopyAttributeValue(element, CFRetained::as_ptr(&key).as_ptr() as CF, &mut value)
    };
    (rc == 0 && !value.is_null()).then_some(value)
}

pub fn trusted() -> bool {
    unsafe { AXIsProcessTrusted() }
}

pub fn frontmost_pid() -> Option<i32> {
    NSWorkspace::sharedWorkspace()
        .frontmostApplication()
        .map(|app| app.processIdentifier())
        .filter(|pid| *pid > 0)
}

pub fn chrome_is_frontmost() -> bool {
    NSWorkspace::sharedWorkspace()
        .frontmostApplication()
        .and_then(|app| app.bundleIdentifier())
        .is_some_and(|id| id.to_string() == "com.google.Chrome")
}

pub fn focused_frame(pid: i32) -> Option<Rect> {
    unsafe {
        let app = AXUIElementCreateApplication(pid);
        if app.is_null() {
            return None;
        }
        let focused = attribute(app, "AXFocusedWindow");
        CFRelease(app);
        let focused = focused?;
        let position = attribute(focused, "AXPosition");
        let size = attribute(focused, "AXSize");
        CFRelease(focused);
        let (Some(position), Some(size)) = (position, size) else {
            if let Some(value) = position {
                CFRelease(value);
            }
            if let Some(value) = size {
                CFRelease(value);
            }
            return None;
        };
        let mut point = Point::default();
        let mut dimensions = Size::default();
        let ok = AXValueGetValue(position, 1, &mut point as *mut _ as *mut c_void)
            && AXValueGetValue(size, 2, &mut dimensions as *mut _ as *mut c_void);
        CFRelease(position);
        CFRelease(size);
        ok.then_some(Rect {
            x: point.x,
            y: point.y,
            w: dimensions.w,
            h: dimensions.h,
        })
    }
}

pub fn run_event_loop() {
    let marker =
        objc2_foundation::MainThreadMarker::new().expect("AppKit must run on the main thread");
    objc2_app_kit::NSApplication::sharedApplication(marker).run();
}

#[path = "tabs.rs"]
mod tabs;
pub use tabs::{TabInput, TabStrip};
