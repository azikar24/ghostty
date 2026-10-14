//! Session save and restore for the GTK sidebar layout.
//!
//! The layout of every window (sidebar groups, sidebar tabs, tabs and
//! splits, with each terminal's working directory) is saved as JSON to
//! $XDG_STATE_HOME/ghostty/session.json shortly after it changes, and
//! restored when Ghostty starts without an explicit command or directory.
//! Like cmux, running programs and scrollback are not restored.

const std = @import("std");
const Allocator = std.mem.Allocator;
const gobject = @import("gobject");
const glib = @import("glib");
const gtk = @import("gtk");

const internal_os = @import("../../os/main.zig");
const Application = @import("class/application.zig").Application;
const Window = @import("class/window.zig").Window;

const log = std.log.scoped(.gtk_session);

/// A split tree: a terminal (`pwd`) or a split of two subtrees.
pub const Node = struct {
    pwd: ?[]const u8 = null,
    horizontal: bool = true,
    /// Share of the left/top subtree.
    ratio: f32 = 0.5,
    left: ?*Node = null,
    right: ?*Node = null,

    pub fn isSplit(self: *const Node) bool {
        return self.left != null and self.right != null;
    }

    /// The first terminal's directory, depth first.
    pub fn firstPwd(self: *const Node) ?[]const u8 {
        if (self.left) |l| if (l.firstPwd()) |p| return p;
        if (self.pwd) |p| return p;
        if (self.right) |r| return r.firstPwd();
        return null;
    }
};

pub const Tab = struct {
    tree: Node,
};

pub const SidebarTab = struct {
    name: ?[]const u8 = null,
    selected: usize = 0,
    tabs: []Tab,
};

pub const Group = struct {
    name: []const u8,
    dir: ?[]const u8 = null,
    renamed: bool = false,
    collapsed: bool = false,
    tabs: []SidebarTab,
};

pub const WindowState = struct {
    sidebar_width: i32 = 240,
    /// Index of the shown sidebar tab, counting across groups.
    active: usize = 0,
    groups: []Group,
};

pub const Session = struct {
    version: u32 = 1,
    windows: []WindowState,
};

/// Whether this launch restored a session (only the first window does).
var restored = false;
var save_source: ?c_uint = null;

fn enabled() bool {
    const config = Application.default().getConfig();
    defer config.unref();
    return config.get().@"gtk-restore-session";
}

fn path(alloc: Allocator) ![]u8 {
    return internal_os.xdg.state(alloc, .{ .subdir = "ghostty/session.json" });
}

/// Save soon. Called after any layout change; changes in a burst save once.
pub fn scheduleSave() void {
    if (save_source != null) return;
    save_source = glib.timeoutAdd(1000, saveTimeout, null);
}

fn saveTimeout(_: ?*anyopaque) callconv(.c) c_int {
    save_source = null;
    save() catch |err| log.warn("unable to save session err={}", .{err});
    return 0;
}

/// Write every open window's layout. Windows being closed are skipped; if
/// none are left (the last window closed, or quit) the previous session is
/// kept so it comes back on the next start.
pub fn save() !void {
    if (!enabled()) return;
    const app = Application.default();
    var arena: std.heap.ArenaAllocator = .init(app.allocator());
    defer arena.deinit();
    const alloc = arena.allocator();

    var windows: std.ArrayList(WindowState) = .empty;
    var node: ?*glib.List = app.as(gtk.Application).getWindows();
    while (node) |n| : (node = n.f_next) {
        const obj: *gobject.Object = @ptrCast(@alignCast(n.f_data orelse continue));
        const win = gobject.ext.cast(Window, obj) orelse continue;
        if (win.isClosing() or win.isQuickTerminal()) continue;
        const state = win.snapshot(alloc) catch |err| {
            log.warn("unable to snapshot window err={}", .{err});
            continue;
        };
        if (state.groups.len > 0) try windows.append(alloc, state);
    }
    if (windows.items.len == 0) return;

    const json = try std.json.Stringify.valueAlloc(
        alloc,
        Session{ .windows = windows.items },
        .{ .emit_null_optional_fields = false },
    );

    const file_path = try path(alloc);
    if (std.fs.path.dirname(file_path)) |dir| try std.fs.cwd().makePath(dir);
    var atomic_buf: [4096]u8 = undefined;
    var atomic = try std.fs.cwd().atomicFile(file_path, .{ .write_buffer = &atomic_buf });
    defer atomic.deinit();
    try atomic.file_writer.interface.writeAll(json);
    try atomic.finish();
}

/// Open the saved windows, if this is the first window of the process and
/// there is a session. Returns false if nothing was restored, in which case
/// the caller opens a normal window.
pub fn restore(app: *Application) bool {
    if (restored) return false;
    restored = true;
    if (!enabled()) return false;

    const alloc = app.allocator();
    const file_path = path(alloc) catch return false;
    defer alloc.free(file_path);
    const data = std.fs.cwd().readFileAlloc(alloc, file_path, 16 * 1024 * 1024) catch |err| {
        if (err != error.FileNotFound) log.warn("unable to read session err={}", .{err});
        return false;
    };
    defer alloc.free(data);

    const parsed = std.json.parseFromSlice(Session, alloc, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        log.warn("ignoring unreadable session err={}", .{err});
        return false;
    };
    defer parsed.deinit();

    var any = false;
    for (parsed.value.windows) |*state| {
        if (restoreWindow(app, state)) any = true;
    }
    return any;
}

fn restoreWindow(app: *Application, state: *const WindowState) bool {
    const win = Window.new(app, .{});
    // As for any window: follow the application's config.
    _ = gobject.Object.bindProperty(
        app.as(gobject.Object),
        "config",
        win.as(gobject.Object),
        "config",
        .{},
    );
    if (!win.restoreState(state)) {
        win.as(gtk.Window).destroy();
        return false;
    }
    win.as(gtk.Window).present();
    return true;
}
