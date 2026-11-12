use super::*;
use objc2::rc::Retained;
use objc2_app_kit::{NSColor, NSPanel, NSView};

const TAB_HEIGHT: f64 = 18.;

fn raw_obj<T: objc2::Message>(value: &Retained<T>) -> *mut Object {
    Retained::as_ptr(value) as *mut Object
}

pub enum TabInput {
    Click(usize),
    Drag { source: usize, x: f64 },
    Drop { source: usize, x: f64 },
}

struct TabInputHandler {
    context: *mut c_void,
    callback: fn(*mut c_void, TabInput),
}

extern "C" fn on_tab_mouse_down(view: &mut Object, _: Sel, event: *mut Object) {
    unsafe {
        let point: Point = msg_send![event, locationInWindow];
        view.set_ivar("startX", point.x);
        view.set_ivar("dragging", false);
    }
}

extern "C" fn on_tab_mouse_dragged(view: &mut Object, _: Sel, event: *mut Object) {
    unsafe {
        let point: Point = msg_send![event, locationInWindow];
        let start = *view.get_ivar::<f64>("startX");
        if (point.x - start).abs() < 5. && !*view.get_ivar::<bool>("dragging") {
            return;
        }
        view.set_ivar("dragging", true);
        let handler = *view.get_ivar::<usize>("handler") as *const TabInputHandler;
        if !handler.is_null() {
            ((*handler).callback)(
                (*handler).context,
                TabInput::Drag {
                    source: *view.get_ivar::<usize>("index"),
                    x: point.x,
                },
            );
        }
    }
}

extern "C" fn on_tab_mouse_up(view: &Object, _: Sel, event: *mut Object) {
    unsafe {
        let handler = *view.get_ivar::<usize>("handler") as *const TabInputHandler;
        if handler.is_null() {
            return;
        }
        let source = *view.get_ivar::<usize>("index");
        let input = if *view.get_ivar::<bool>("dragging") {
            let point: Point = msg_send![event, locationInWindow];
            TabInput::Drop { source, x: point.x }
        } else {
            TabInput::Click(source)
        };
        ((*handler).callback)((*handler).context, input);
    }
}

fn tab_hit_class() -> Option<&'static Class> {
    static CLASS: OnceLock<Option<&'static Class>> = OnceLock::new();
    *CLASS.get_or_init(|| {
        let mut class = ClassDecl::new("YuwaiTabHitView", class!(NSView))?;
        class.add_ivar::<usize>("handler");
        class.add_ivar::<usize>("index");
        class.add_ivar::<f64>("startX");
        class.add_ivar::<bool>("dragging");
        unsafe {
            class.add_method(
                sel!(mouseDown:),
                on_tab_mouse_down as extern "C" fn(&mut Object, Sel, *mut Object),
            );
            class.add_method(
                sel!(mouseDragged:),
                on_tab_mouse_dragged as extern "C" fn(&mut Object, Sel, *mut Object),
            );
            class.add_method(
                sel!(mouseUp:),
                on_tab_mouse_up as extern "C" fn(&Object, Sel, *mut Object),
            );
        }
        Some(class.register())
    })
}

pub struct TabStrip {
    panel: Retained<NSPanel>,
    effect: *mut Object,
    marker: Retained<NSView>,
    hit_class: &'static Class,
    input_handler: Option<Box<TabInputHandler>>,
    signature: String,
    selected: usize,
    cells: Vec<*mut Object>,
}

impl TabStrip {
    pub fn new() -> Result<Self, String> {
        let hit_class = tab_hit_class().ok_or("tab hit view class registration failed")?;
        unsafe {
            let app: *mut Object = msg_send![class!(NSApplication), sharedApplication];
            if app.is_null() {
                return Err("NSApplication unavailable".into());
            }
            let _: bool = msg_send![app, setActivationPolicy: 1isize];
            let _: () = msg_send![app, finishLaunching];
            let rect = CGRect {
                origin: Point { x: 0., y: 0. },
                size: Size {
                    w: 200.,
                    h: TAB_HEIGHT,
                },
            };
            let panel: *mut Object = msg_send![class!(NSPanel), alloc];
            let panel: *mut Object = msg_send![panel, initWithContentRect: rect styleMask: 128usize backing: 2usize defer: false];
            if panel.is_null() {
                return Err("NSPanel creation failed".into());
            }
            // `initWithContentRect:` returns +1; `Retained` releases it on drop.
            let panel_owner = Retained::<NSPanel>::from_raw(panel as *mut NSPanel)
                .ok_or("NSPanel creation failed")?;
            let _: () = msg_send![panel, setLevel: 3isize];
            let _: () = msg_send![panel, setFloatingPanel: true];
            let _: () = msg_send![panel, setHidesOnDeactivate: false];
            let _: () = msg_send![panel, setIgnoresMouseEvents: false];
            let _: () = msg_send![panel, setBecomesKeyOnlyIfNeeded: true];
            let _: () = msg_send![panel, setHasShadow: false];
            let color: *mut Object = msg_send![class!(NSColor), clearColor];
            let _: () = msg_send![panel, setBackgroundColor: color];
            let _: () = msg_send![panel, setOpaque: false];
            let name: *mut Object = msg_send![class!(NSString), stringWithUTF8String: c"NSAppearanceNameDarkAqua".as_ptr()];
            let appearance: *mut Object = msg_send![class!(NSAppearance), appearanceNamed: name];
            let _: () = msg_send![panel, setAppearance: appearance];
            let shell: *mut Object = msg_send![class!(NSView), alloc];
            let shell: *mut Object = msg_send![shell, initWithFrame: rect];
            let _: () = msg_send![shell, setWantsLayer: true];
            let shell_layer: *mut Object = msg_send![shell, layer];
            let _: () = msg_send![shell_layer, setCornerRadius: 6f64];
            let _: () = msg_send![shell_layer, setMasksToBounds: true];
            let effect: *mut Object = msg_send![class!(NSVisualEffectView), alloc];
            let effect: *mut Object = msg_send![effect, initWithFrame: rect];
            let _: () = msg_send![effect, setMaterial: 13isize];
            let _: () = msg_send![effect, setBlendingMode: 0isize];
            let _: () = msg_send![effect, setState: 1isize];
            let _: () = msg_send![effect, setAppearance: appearance];
            let _: () = msg_send![effect, setAutoresizingMask: 18usize];
            let _: () = msg_send![shell, addSubview: effect];
            let _: () = msg_send![effect, release];
            let _: () = msg_send![panel, setContentView: shell];
            let _: () = msg_send![shell, release];
            let marker: *mut Object = msg_send![class!(NSView), alloc];
            let marker: *mut Object = msg_send![marker, initWithFrame: CGRect { origin: Point { x: 0., y: 1. }, size: Size { w: 2., h: 16. } }];
            if marker.is_null() {
                return Err("tab drop marker creation failed".into());
            }
            let marker_owner = Retained::<NSView>::from_raw(marker as *mut NSView)
                .ok_or("tab drop marker creation failed")?;
            let _: () = msg_send![marker, setWantsLayer: true];
            let marker_layer: *mut Object = msg_send![marker, layer];
            let _: () = msg_send![marker_layer, setCornerRadius: 1f64];
            let _: () = msg_send![marker, setHidden: true];
            let content: *mut Object = msg_send![panel, contentView];
            let _: () = msg_send![content, addSubview: marker];
            Ok(Self {
                panel: panel_owner,
                effect,
                marker: marker_owner,
                hit_class,
                input_handler: None,
                signature: String::new(),
                selected: usize::MAX,
                cells: Vec::new(),
            })
        }
    }

    /// `context` must remain valid while this strip can receive mouse events.
    pub fn set_input_handler(&mut self, context: *mut c_void, callback: fn(*mut c_void, TabInput)) {
        self.input_handler = Some(Box::new(TabInputHandler { context, callback }));
        self.signature.clear();
    }

    pub fn preview_drop(&mut self, x: f64) -> usize {
        let slot = self.drop_slot(x);
        let edge = unsafe {
            if let Some(cell) = self.cells.get(slot) {
                let frame: CGRect = msg_send![*cell, frame];
                frame.origin.x
            } else if let Some(cell) = self.cells.last() {
                let frame: CGRect = msg_send![*cell, frame];
                frame.origin.x + frame.size.w
            } else {
                3.
            }
        };
        unsafe {
            let marker_layer: *mut Object = msg_send![raw_obj(&self.marker), layer];
            let accent = NSColor::controlAccentColor();
            let accent_cg: CF = msg_send![raw_obj(&accent), CGColor];
            let _: () = msg_send![marker_layer, setBackgroundColor: accent_cg];
            let _: () = msg_send![raw_obj(&self.marker), setFrame: CGRect { origin: Point { x: edge - 1., y: 1. }, size: Size { w: 2., h: 16. } }];
            let _: () = msg_send![raw_obj(&self.marker), setHidden: false];
        }
        slot
    }

    pub fn finish_drop(&mut self, x: f64) -> usize {
        self.hide_drop_marker();
        self.drop_slot(x)
    }

    fn drop_slot(&self, x: f64) -> usize {
        self.cells
            .iter()
            .position(|cell| unsafe {
                let frame: CGRect = msg_send![*cell, frame];
                x < frame.origin.x + frame.size.w / 2.
            })
            .unwrap_or(self.cells.len())
    }

    fn hide_drop_marker(&mut self) {
        unsafe {
            let _: () = msg_send![raw_obj(&self.marker), setHidden: true];
        }
    }

    fn style(cell: *mut Object, active: bool) {
        unsafe {
            let layer: *mut Object = msg_send![cell, layer];
            let bg: *mut Object = if active {
                msg_send![class!(NSColor), colorWithCalibratedWhite: 1f64 alpha: 0.1f64]
            } else {
                msg_send![class!(NSColor), clearColor]
            };
            let cg: CF = msg_send![bg, CGColor];
            let _: () = msg_send![layer, setBackgroundColor: cg];
            let _: () = msg_send![layer, setBorderWidth: if active { 1.5f64 } else { 0f64 }];
            let accent = NSColor::controlAccentColor();
            let accent_cg: CF = msg_send![raw_obj(&accent), CGColor];
            let _: () = msg_send![layer, setBorderColor: accent_cg];
        }
    }

    pub fn show(&mut self, frame: Rect, pid: i32, titles: &[String], selected: usize) {
        if titles.len() < 2 {
            self.hide();
            return;
        }
        let signature = format!("{frame:?}:{pid}:{titles:?}");
        if signature == self.signature {
            self.select(selected);
            return;
        }
        self.signature = signature;
        self.selected = selected;
        unsafe {
            let screens: *mut Object = msg_send![class!(NSScreen), screens];
            let primary: *mut Object = msg_send![screens, objectAtIndex: 0usize];
            let screen_frame: CGRect = msg_send![primary, frame];
            let font: *mut Object = msg_send![class!(NSFont), systemFontOfSize: 10f64];
            let budget = ((frame.w - 6.).max(0.)) / titles.len() as f64;
            let base = budget.min(25.);
            let label_cap = (budget - base).min(112.);
            let fields: Vec<_> = titles
                .iter()
                .enumerate()
                .map(|(i, title)| {
                    let label = if title.is_empty() {
                        format!("Window {}", i + 1)
                    } else {
                        title.clone()
                    };
                    let label = label.replace('\0', " ");
                    let text: *mut Object = msg_send![class!(NSString), stringWithBytes: label.as_ptr() length: label.len() encoding: 4usize];
                    let field: *mut Object = msg_send![class!(NSTextField), labelWithString: text];
                    let _: () = msg_send![field, setFont: font];
                    let _: () = msg_send![field, setLineBreakMode: 4usize];
                    let _: () = msg_send![field, setUsesSingleLineMode: true];
                    let fg: *mut Object = msg_send![class!(NSColor), whiteColor];
                    let _: () = msg_send![field, setTextColor: fg];
                    let fit: Size = msg_send![field, fittingSize];
                    (field, base + fit.w.ceil().min(label_cap))
                })
                .collect();
            let panel_width = 6. + fields.iter().map(|(_, width)| width).sum::<f64>();
            let panel_frame = CGRect {
                origin: Point {
                    x: frame.x,
                    y: screen_frame.origin.y + screen_frame.size.h - frame.y,
                },
                size: Size {
                    w: panel_width,
                    h: TAB_HEIGHT,
                },
            };
            let _: () = msg_send![raw_obj(&self.panel), setFrame: panel_frame display: true];
            let content: *mut Object = msg_send![raw_obj(&self.panel), contentView];
            // Mask only the material; keep labels and icons fully opaque above it.
            let mask: *mut Object = msg_send![class!(NSImage), alloc];
            let mask: *mut Object = msg_send![mask, initWithSize: panel_frame.size];
            let _: () = msg_send![mask, lockFocus];
            let fill: *mut Object =
                msg_send![class!(NSColor), colorWithCalibratedWhite: 1f64 alpha: 0.75f64];
            let _: () = msg_send![fill, setFill];
            let path: *mut Object = msg_send![class!(NSBezierPath), bezierPathWithRoundedRect: CGRect { origin: Point { x: 0., y: 0. }, size: panel_frame.size } xRadius: 6f64 yRadius: 6f64];
            let _: () = msg_send![path, fill];
            let _: () = msg_send![mask, unlockFocus];
            let _: () = msg_send![self.effect, setMaskImage: mask];
            let _: () = msg_send![mask, release];
            let subviews: *mut Object = msg_send![content, subviews];
            let count: usize = msg_send![subviews, count];
            self.cells.clear();
            self.hide_drop_marker();
            for i in (0..count).rev() {
                let view: *mut Object = msg_send![subviews, objectAtIndex: i];
                if view != self.effect && view != raw_obj(&self.marker) {
                    let _: () = msg_send![view, removeFromSuperview];
                }
            }
            let running: *mut Object = msg_send![class!(NSRunningApplication), runningApplicationWithProcessIdentifier: pid];
            let icon: *mut Object = if running.is_null() {
                ptr::null_mut()
            } else {
                msg_send![running, icon]
            };
            let mut x = 3.;
            for (i, (field, width)) in fields.into_iter().enumerate() {
                let cell_frame = CGRect {
                    origin: Point { x, y: 1.5 },
                    size: Size { w: width, h: 15. },
                };
                let cell: *mut Object = msg_send![class!(NSView), alloc];
                let cell: *mut Object = msg_send![cell, initWithFrame: cell_frame];
                let _: () = msg_send![cell, setWantsLayer: true];
                let layer: *mut Object = msg_send![cell, layer];
                let _: () = msg_send![layer, setCornerRadius: 4f64];
                Self::style(cell, i == selected);
                let icon_size = 13f64.min((base - 8.).max(0.));
                if !icon.is_null() && icon_size > 0. {
                    let icon_frame = CGRect {
                        origin: Point {
                            x: 5f64.min((base - icon_size) / 2.).max(0.),
                            y: (15. - icon_size) / 2.,
                        },
                        size: Size {
                            w: icon_size,
                            h: icon_size,
                        },
                    };
                    let image: *mut Object = msg_send![class!(NSImageView), alloc];
                    let image: *mut Object = msg_send![image, initWithFrame: icon_frame];
                    let _: () = msg_send![image, setImage: icon];
                    let _: () = msg_send![image, setImageScaling: 3usize];
                    let _: () = msg_send![cell, addSubview: image];
                    let _: () = msg_send![image, release];
                }
                let label_frame = CGRect {
                    origin: Point {
                        x: base - 3.,
                        y: 0.,
                    },
                    size: Size {
                        w: width - base,
                        h: 15.,
                    },
                };
                let _: () = msg_send![field, setFrame: label_frame];
                let _: () = msg_send![cell, addSubview: field];
                let hit: *mut Object = msg_send![self.hit_class, alloc];
                let hit: *mut Object = msg_send![hit, initWithFrame: CGRect { origin: Point { x: 0., y: 0. }, size: cell_frame.size }];
                (*hit).set_ivar(
                    "handler",
                    self.input_handler
                        .as_deref()
                        .map_or(0, |h| h as *const TabInputHandler as usize),
                );
                (*hit).set_ivar("index", i);
                (*hit).set_ivar("startX", 0f64);
                (*hit).set_ivar("dragging", false);
                let _: () = msg_send![cell, addSubview: hit];
                let _: () = msg_send![hit, release];
                let _: () = msg_send![content, addSubview: cell];
                let _: () = msg_send![cell, release];
                self.cells.push(cell);
                x += width;
            }
            let _: () = msg_send![raw_obj(&self.marker), removeFromSuperview];
            let _: () = msg_send![content, addSubview: raw_obj(&self.marker)];
            let _: () = msg_send![raw_obj(&self.panel), orderFrontRegardless];
        }
    }

    pub fn move_to(&mut self, frame: Rect) {
        unsafe {
            let screens: *mut Object = msg_send![class!(NSScreen), screens];
            let primary: *mut Object = msg_send![screens, objectAtIndex: 0usize];
            let screen_frame: CGRect = msg_send![primary, frame];
            let _: () = msg_send![raw_obj(&self.panel), setFrameOrigin: Point {
                x: frame.x,
                y: screen_frame.origin.y + screen_frame.size.h - frame.y,
            }];
        }
    }

    pub fn select(&mut self, selected: usize) {
        if let Some(cell) = self.cells.get(selected) {
            if self.selected != selected {
                if let Some(previous) = self.cells.get(self.selected) {
                    Self::style(*previous, false);
                }
            }
            // CGColor is a snapshot; refresh it when the system accent changes.
            Self::style(*cell, true);
            self.selected = selected;
        }
    }

    pub fn hide(&mut self) {
        if self.signature.is_empty() {
            return;
        }
        self.signature.clear();
        self.hide_drop_marker();
        unsafe {
            let _: () = msg_send![raw_obj(&self.panel), orderOut: ptr::null_mut::<Object>()];
        }
    }
}
