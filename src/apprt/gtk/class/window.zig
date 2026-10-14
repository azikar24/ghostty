const std = @import("std");
const build_config = @import("../../../build_config.zig");
const assert = @import("../../../quirks.zig").inlineAssert;
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const i18n = @import("../../../os/main.zig").i18n;
const apprt = @import("../../../apprt.zig");
const configpkg = @import("../../../config.zig");
const TitlebarStyle = configpkg.Config.GtkTitlebarStyle;
const input = @import("../../../input.zig");
const CoreSurface = @import("../../../Surface.zig");
const ext = @import("../ext.zig");
const gtk_version = @import("../gtk_version.zig");
const adw_version = @import("../adw_version.zig");
const gresource = @import("../build/gresource.zig");
const winprotopkg = @import("../winproto.zig");
const Common = @import("../class.zig").Common;
const Config = @import("config.zig").Config;
const Application = @import("application.zig").Application;
const CloseConfirmationDialog = @import("close_confirmation_dialog.zig").CloseConfirmationDialog;
const SplitTree = @import("split_tree.zig").SplitTree;
const Surface = @import("surface.zig").Surface;
const Tab = @import("tab.zig").Tab;
const DebugWarning = @import("debug_warning.zig").DebugWarning;
const CommandPalette = @import("command_palette.zig").CommandPalette;
const TitleDialog = @import("title_dialog.zig").TitleDialog;
const WeakRef = @import("../weak_ref.zig").WeakRef;

const log = std.log.scoped(.gtk_ghostty_window);

pub const Window = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.ApplicationWindow;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyWindow",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        /// The active surface is the focus that should be receiving all
        /// surface-targeted actions. This is usually the focused surface,
        /// but may also not be focused if the user has selected a non-surface
        /// widget.
        pub const @"active-surface" = struct {
            pub const name = "active-surface";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Surface,
                        .{
                            .getter = Self.getActiveSurface,
                        },
                    ),
                },
            );
        };

        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Config,
                .{
                    .accessor = C.privateObjFieldAccessor("config"),
                },
            );
        };

        pub const debug = struct {
            pub const name = "debug";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = build_config.is_debug,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = struct {
                            pub fn getter(_: *Self) bool {
                                return build_config.is_debug;
                            }
                        }.getter,
                    }),
                },
            );
        };

        pub const @"titlebar-style" = struct {
            pub const name = "titlebar-style";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                TitlebarStyle,
                .{
                    .default = .native,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        TitlebarStyle,
                        .{
                            .getter = Self.getTitlebarStyle,
                        },
                    ),
                },
            );
        };

        pub const @"headerbar-visible" = struct {
            pub const name = "headerbar-visible";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getHeaderbarVisible,
                    }),
                },
            );
        };

        pub const @"quick-terminal" = struct {
            pub const name = "quick-terminal";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "quick_terminal",
                    ),
                },
            );
        };

        pub const @"tabs-autohide" = struct {
            pub const name = "tabs-autohide";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getTabsAutohide,
                    }),
                },
            );
        };

        pub const @"tabs-wide" = struct {
            pub const name = "tabs-wide";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getTabsWide,
                    }),
                },
            );
        };

        pub const @"tabs-visible" = struct {
            pub const name = "tabs-visible";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getTabsVisible,
                    }),
                },
            );
        };

        pub const @"toolbar-style" = struct {
            pub const name = "toolbar-style";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                adw.ToolbarStyle,
                .{
                    .default = .raised,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        adw.ToolbarStyle,
                        .{
                            .getter = Self.getToolbarStyle,
                        },
                    ),
                },
            );
        };
    };

    const Private = struct {
        /// Whether this window is a quick terminal. If it is then it
        /// behaves slightly differently under certain scenarios.
        quick_terminal: bool = false,

        /// The window decoration override. If this is not set then we'll
        /// inherit whatever the config has. This allows overriding the
        /// config on a per-window basis.
        window_decoration: ?configpkg.WindowDecoration = null,

        /// Binding group for our active tab.
        tab_bindings: *gobject.BindingGroup,

        /// The configuration that this surface is using.
        config: ?*Config = null,

        /// State and logic for windowing protocol for a window.
        winproto: winprotopkg.Window,

        /// Kind of hacky to have this but this lets us know if we've
        /// initialized any single surface yet. We need this because we
        /// gate default size on this so that we don't resize the window
        /// after surfaces already exist.
        ///
        /// I think long term we can probably get rid of this by implementing
        /// a property or method that gets us all the surfaces in all the
        /// tabs and checking if we have zero or one that isn't initialized.
        ///
        /// For now, this logic is more similar to our legacy GTK side.
        surface_init: bool = false,

        /// See tabOverviewOpen for why we have this.
        tab_overview_focus_timer: ?c_uint = null,

        /// A weak reference to a command palette.
        command_palette: WeakRef(CommandPalette) = .empty,

        /// Tab page that the context menu was opened for.
        /// setup by `setup-menu`.
        context_menu_page: ?*adw.TabPage = null,

        /// Flipped by `toggle_tab_sidebar`; the sidebar shows when this
        /// differs from `gtk-tab-sidebar`.
        sidebar_toggled: bool = false,

        /// Pending idle rebuild of the sidebar rows.
        sidebar_rebuild: ?c_uint = null,

        /// True while rebuildSidebar reorders pages, so the page-reordered
        /// signals it causes don't queue another rebuild.
        sidebar_rebuilding: bool = false,

        /// Sidebar groups in display order.
        groups: std.ArrayListUnmanaged(SidebarGroup),

        /// Sidebar tabs, each with its own tab view in tab_stack. Kept in
        /// sidebar order within each group.
        workspaces: std.ArrayListUnmanaged(Workspace),

        /// The selected sidebar tab's view: what the tab bar, tab overview
        /// and tab actions (new_tab, goto_tab, ...) operate on.
        tab_view: *adw.TabView,

        /// Group whose rename dialog is open.
        renaming_group: u32 = 0,

        /// Desktop notifications from this window's terminals, oldest
        /// first, listed in the sidebar until seen.
        notifications: std.ArrayListUnmanaged(SidebarNotification),

        // Template bindings
        tab_overview: *adw.TabOverview,
        tab_bar: *adw.TabBar,
        tab_stack: *gtk.Stack,
        tab_context_menu: *gio.MenuModel,
        toolbar: *adw.ToolbarView,
        toast_overlay: *adw.ToastOverlay,
        content_box: *gtk.Box,
        sidebar_paned: *gtk.Paned,
        sidebar_box: *gtk.Box,
        sidebar_rail: *gtk.Box,
        sidebar_list: *gtk.ListBox,

        pub var offset: c_int = 0;
    };

    pub fn new(
        app: *Application,
        overrides: struct {
            title: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) *Self {
        const win = gobject.ext.newInstance(Self, .{
            .application = app,
        });

        if (overrides.title) |title| {
            // If the overrides have a title set, we set that immediately
            // so that any applications inspecting the window states see an
            // immediate title set when the window appears, rather than waiting
            // possibly a few event loop ticks for it to sync from the surface.
            win.as(gtk.Window).setTitle(title);
        }

        return win;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // If our configuration is null then we get the configuration
        // from the application.
        const priv = self.private();

        const config = config: {
            if (priv.config) |config| break :config config.get();
            const app = Application.default();
            const config = app.getConfig();
            priv.config = config;
            break :config config.get();
        };

        // We initialize our windowing protocol to none because we can't
        // actually initialize this until we get realized.
        priv.winproto = .none;

        // Add our dev CSS class if we're in debug mode.
        if (comptime build_config.is_debug) {
            self.as(gtk.Widget).addCssClass("devel");
        }

        // Setup our tab binding group. This ensures certain properties
        // are only synced from the currently active tab.
        priv.tab_bindings = gobject.BindingGroup.new();
        priv.tab_bindings.bind("title", self.as(gobject.Object), "title", .{});

        // Set our window icon. We can't set this in the blueprint file
        // because its dependent on the build config.
        self.as(gtk.Window).setIconName(build_config.bundle_id);

        priv.groups = .empty;
        priv.workspaces = .empty;
        priv.notifications = .empty;
        const first = self.addWorkspace(self.addGroup(null));
        if (first == 0) @panic("oom");
        self.activateWorkspace(first);

        // Initialize our actions
        self.initActionMap();

        // Start states based on config.
        if (config.maximize) self.as(gtk.Window).maximize();
        if (config.fullscreen != .false) self.as(gtk.Window).fullscreen();

        // If we have an explicit title set, we set that immediately
        // so that any applications inspecting the window states see
        // an immediate title set when the window appears, rather than
        // waiting possibly a few event loop ticks for it to sync from
        // the surface.
        if (config.title) |title| {
            self.as(gtk.Window).setTitle(title);
        }

        // We always sync our appearance at the end because loading our
        // config and such can affect our bindings which are setup initially
        // in initTemplate.
        self.syncAppearance();

        // We need to do this so that the title initializes properly,
        // I think because its a dynamic getter.
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
    }

    /// Setup our action map.
    fn initActionMap(self: *Self) void {
        const s_variant_type = glib.ext.VariantType.newFor([:0]const u8);
        defer s_variant_type.free();
        const u_variant_type = glib.ext.VariantType.newFor(u32);
        defer u_variant_type.free();

        const actions = [_]ext.actions.Action(Self){
            .init("about", actionAbout, null),
            .init("close", actionClose, null),
            .init("close-tab", actionCloseTab, s_variant_type),
            .init("new-tab", actionNewTab, null),
            .init("new-window", actionNewWindow, null),
            .init("prompt-surface-title", actionPromptSurfaceTitle, null),
            .init("prompt-tab-title", actionPromptTabTitle, null),
            .init("prompt-context-tab-title", actionPromptContextTabTitle, null),
            .init("ring-bell", actionRingBell, null),
            .init("split-right", actionSplitRight, null),
            .init("split-left", actionSplitLeft, null),
            .init("split-up", actionSplitUp, null),
            .init("split-down", actionSplitDown, null),
            .init("copy", actionCopy, null),
            .init("paste", actionPaste, null),
            .init("reset", actionReset, null),
            .init("clear", actionClear, null),
            // TODO: accept the surface that toggled the command palette
            .init("toggle-command-palette", actionToggleCommandPalette, null),
            .init("toggle-inspector", actionToggleInspector, null),
            .init("new-group", actionNewGroup, null),
            .init("toggle-tab-sidebar", actionToggleTabSidebar, null),
            .init("clear-notifications", actionClearNotifications, null),
            .init("group-new-tab", actionGroupNewTab, u_variant_type),
            .init("group-rename", actionGroupRename, u_variant_type),
            .init("group-close", actionGroupClose, u_variant_type),
        };

        ext.actions.add(Self, self, &actions);
    }

    /// Winproto backend for this window.
    pub fn winproto(self: *Self) *winprotopkg.Window {
        return &self.private().winproto;
    }

    /// Create a new tab with the given parent. The tab will be inserted
    /// at the position dictated by the `window-new-tab-position` config.
    /// The new tab will be selected.
    pub fn newTab(self: *Self, parent_: ?*CoreSurface) void {
        _ = self.newTabPage(parent_, .tab, .none);
    }

    pub fn newTabForWindow(
        self: *Self,
        parent_: ?*CoreSurface,
        overrides: struct {
            command: ?configpkg.Command = null,
            working_directory: ?[:0]const u8 = null,
            title: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) void {
        _ = self.newTabPage(
            parent_,
            .window,
            .{
                .command = overrides.command,
                .working_directory = overrides.working_directory,
                .title = overrides.title,
            },
        );
    }

    fn newTabPage(
        self: *Self,
        parent_: ?*CoreSurface,
        context: apprt.surface.NewSurfaceContext,
        overrides: struct {
            command: ?configpkg.Command = null,
            working_directory: ?[:0]const u8 = null,
            title: ?[:0]const u8 = null,
            pub const none: @This() = .{};
        },
    ) *adw.TabPage {
        const priv: *Private = self.private();
        const tab_view = priv.tab_view;

        // Create our new tab object
        const tab = Tab.new(
            priv.config,
            .{
                .command = overrides.command,
                .working_directory = overrides.working_directory,
                .title = overrides.title,
            },
        );

        // Name a new group after the directory its first tab starts in.
        if (self.activeWorkspace()) |ws| if (self.findGroup(ws.group_id)) |group| {
            const dir = overrides.working_directory orelse
                if (parent_) |p| p.rt_surface.surface.getPwd() else null;
            if (dir) |d| setGroupDir(group, d);
        };

        if (parent_) |p| {
            // For a new window's first tab, inherit the parent's initial size hints.
            if (context == .window) {
                surfaceInit(p.rt_surface.gobj(), self);
            }
            tab.setParentWithContext(p, context);

        }

        // Get the position that we should insert the new tab at.
        const config = if (priv.config) |v| v.get() else {
            // If we don't have a config we just append it at the end.
            // This should never happen.
            return tab_view.append(tab.as(gtk.Widget));
        };
        const position = switch (config.@"window-new-tab-position") {
            .current => current: {
                const selected = tab_view.getSelectedPage() orelse
                    break :current tab_view.getNPages();
                const current = tab_view.getPagePosition(selected);
                break :current current + 1;
            },

            .end => tab_view.getNPages(),
        };

        // Add the page and select it
        const page = tab_view.insert(tab.as(gtk.Widget), position);
        tab_view.setSelectedPage(page);

        // Create some property bindings
        _ = tab.as(gobject.Object).bindProperty(
            "title",
            page.as(gobject.Object),
            "title",
            .{ .sync_create = true },
        );
        _ = tab.as(gobject.Object).bindProperty(
            "tooltip",
            page.as(gobject.Object),
            "tooltip",
            .{ .sync_create = true },
        );

        // Bind signals
        const split_tree = tab.getSplitTree();
        _ = SplitTree.signals.changed.connect(
            split_tree,
            *Self,
            tabSplitTreeChanged,
            self,
            .{},
        );

        // Run an initial notification for the surface tree so we can setup
        // initial state.
        tabSplitTreeChanged(
            split_tree,
            null,
            split_tree.getTree(),
            self,
        );

        return page;
    }

    pub const SelectTab = union(enum) {
        previous,
        next,
        last,
        n: usize,
    };

    /// Select the tab as requested. Returns true if the tab selection
    /// changed.
    pub fn selectTab(self: *Self, n: SelectTab) bool {
        const priv = self.private();
        const tab_view = priv.tab_view;

        // Get our current tab numeric position
        const selected = tab_view.getSelectedPage() orelse return false;
        const current = tab_view.getPagePosition(selected);

        // Get our total
        const total = tab_view.getNPages();

        const goto: c_int = switch (n) {
            .previous => if (current > 0)
                current - 1
            else
                total - 1,

            .next => if (current < total - 1)
                current + 1
            else
                0,

            .last => total - 1,

            .n => |v| n: {
                // 1-indexed
                if (v == 0) return false;

                const n_int = std.math.cast(
                    c_int,
                    v,
                ) orelse return false;
                break :n @min(n_int - 1, total - 1);
            },
        };
        assert(goto >= 0);
        assert(goto < total);

        // If our target is the same as our current then we do nothing.
        if (goto == current) return false;

        // Add the page and select it
        const page = tab_view.getNthPage(goto);
        tab_view.setSelectedPage(page);

        return true;
    }

    /// Move the tab containing the given surface by the given amount.
    /// Returns if this affected any tab positioning.
    pub fn moveTab(
        self: *Self,
        surface: *Surface,
        amount: isize,
    ) bool {
        const priv = self.private();
        const tab_view = priv.tab_view;

        // If we have one tab we never move.
        const total = tab_view.getNPages();
        if (total == 1) return false;

        // Get the tab that contains the given surface.
        const tab = ext.getAncestor(
            Tab,
            surface.as(gtk.Widget),
        ) orelse return false;

        // Get the page position that contains the tab.
        const page = tab_view.getPage(tab.as(gtk.Widget));
        const pos = tab_view.getPagePosition(page);

        // Move it
        const desired_pos: c_int = desired: {
            const initial: c_int = @intCast(pos + amount);
            const max = total - 1;
            break :desired if (initial < 0)
                max + initial + 1
            else if (initial > max)
                initial - max - 1
            else
                initial;
        };
        assert(desired_pos >= 0);
        assert(desired_pos < total);

        return tab_view.reorderPage(page, desired_pos) != 0;
    }

    /// Show or hide the tab sidebar in this window. Returns false if the
    /// sidebar doesn't apply to this window.
    pub fn toggleTabSidebar(self: *Self) bool {
        if (!self.sidebarAllowed()) return false;
        const priv = self.private();
        priv.sidebar_toggled = !priv.sidebar_toggled;
        self.syncSidebar();
        return true;
    }

    /// The quick terminal has no room for it and the `tabs` titlebar
    /// style needs the tab bar for the window controls.
    fn sidebarAllowed(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return false;
        return !priv.quick_terminal and config.@"gtk-titlebar-style" == .native;
    }

    fn sidebarShown(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return false;
        if (!self.sidebarAllowed()) return false;
        return config.@"gtk-tab-sidebar" != priv.sidebar_toggled;
    }

    /// Collapsed: the sidebar is enabled in the config but folded into
    /// the rail. When the config disables it, the tab bar is used instead.
    fn sidebarRailShown(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return false;
        return self.sidebarAllowed() and config.@"gtk-tab-sidebar" and !self.sidebarShown();
    }

    /// Sidebar width shared by all windows, so a resize sticks.
    var sidebar_width: c_int = 240;

    fn syncSidebar(self: *Self) void {
        const priv = self.private();
        const shown = self.sidebarShown();
        if (shown) priv.sidebar_paned.setPosition(sidebar_width);
        priv.sidebar_box.as(gtk.Widget).setVisible(@intFromBool(shown));
        priv.sidebar_rail.as(gtk.Widget).setVisible(@intFromBool(self.sidebarRailShown()));
        self.as(gobject.Object).notifyByPspec(properties.@"tabs-visible".impl.param_spec);
        self.scheduleSidebarRebuild();
    }

    fn sidebarPanedPosition(
        paned: *gtk.Paned,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // Ignore positions from layout while hidden or not yet mapped.
        const box = self.private().sidebar_box.as(gtk.Widget);
        if (box.getVisible() == 0 or box.getMapped() == 0) return;
        const pos = paned.getPosition();
        if (pos >= 180) sidebar_width = pos;
    }

    fn actionToggleTabSidebar(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        _ = self.toggleTabSidebar();
        self.focusActiveSurface();
    }

    //---------------------------------------------------------------
    // Sidebar groups and tabs
    //
    // Group -> sidebar tab ("workspace") -> tabs (the tab bar) -> splits.
    // Each workspace owns an Adw.TabView in tab_stack; priv.tab_view is
    // the selected workspace's, so the tab bar and all tab actions work
    // on that workspace's tabs.

    /// A named set of sidebar tabs. Disappears with its last sidebar tab.
    const SidebarGroup = struct {
        id: u32,
        name: [:0]u8,
        /// Where the group's new tabs start. Null until known.
        dir: ?[:0]u8,
        /// Set by the user, so a later `dir` doesn't rename it.
        renamed: bool = false,
        collapsed: bool = false,

        fn deinit(self: *SidebarGroup, alloc: std.mem.Allocator) void {
            alloc.free(self.name);
            if (self.dir) |d| alloc.free(d);
        }
    };

    /// A sidebar tab: its own row of tabs. Disappears with its last tab.
    const Workspace = struct {
        id: u32,
        group_id: u32,
        view: *adw.TabView,
    };

    var next_group_id: u32 = 1;
    var next_workspace_id: u32 = 1;

    /// Do not keep the pointer across anything that can add a group.
    fn findGroup(self: *Self, id: u32) ?*SidebarGroup {
        if (id == 0) return null;
        for (self.private().groups.items) |*g| if (g.id == id) return g;
        return null;
    }

    /// Do not keep the pointer across anything that can add a workspace.
    fn findWorkspace(self: *Self, id: u32) ?*Workspace {
        if (id == 0) return null;
        for (self.private().workspaces.items) |*ws| if (ws.id == id) return ws;
        return null;
    }

    fn workspaceForView(self: *Self, view: *adw.TabView) ?*Workspace {
        for (self.private().workspaces.items) |*ws| if (ws.view == view) return ws;
        return null;
    }

    fn activeWorkspace(self: *Self) ?*Workspace {
        return self.workspaceForView(self.private().tab_view);
    }

    /// Append a group for `dir` and return its id, or zero on OOM.
    fn addGroup(self: *Self, dir: ?[]const u8) u32 {
        const alloc = Application.default().allocator();
        const name = groupNameFor(alloc, dir) catch return 0;
        const dir_copy: ?[:0]u8 = if (dir) |d| alloc.dupeZ(u8, d) catch null else null;
        var group: SidebarGroup = .{ .id = next_group_id, .name = name, .dir = dir_copy };
        self.private().groups.append(alloc, group) catch {
            group.deinit(alloc);
            return 0;
        };
        next_group_id += 1;
        return group.id;
    }

    /// Add an empty sidebar tab at the end of a group and return its id,
    /// or zero on OOM. The caller adds its first tab.
    fn addWorkspace(self: *Self, group_id: u32) u32 {
        if (group_id == 0) return 0;
        const priv = self.private();
        const alloc = Application.default().allocator();

        var index = priv.workspaces.items.len;
        for (priv.workspaces.items, 0..) |ws, i| {
            if (ws.group_id == group_id) index = i + 1;
        }

        const view = self.newWorkspaceView();
        const ws: Workspace = .{ .id = next_workspace_id, .group_id = group_id, .view = view };
        priv.workspaces.insert(alloc, index, ws) catch {
            priv.tab_stack.remove(view.as(gtk.Widget));
            return 0;
        };
        next_workspace_id += 1;
        return ws.id;
    }

    /// A tab view wired up the way the template used to wire the single one.
    fn newWorkspaceView(self: *Self) *adw.TabView {
        const priv = self.private();
        const view = adw.TabView.new();
        view.setShortcuts(.{});
        view.setMenuModel(priv.tab_context_menu);
        _ = gobject.Object.signals.notify.connect(view, *Self, tabViewNPages, self, .{ .detail = "n-pages" });
        _ = gobject.Object.signals.notify.connect(view, *Self, tabViewSelectedPage, self, .{ .detail = "selected-page" });
        _ = adw.TabView.signals.close_page.connect(view, *Self, tabViewClosePage, self, .{});
        _ = adw.TabView.signals.page_attached.connect(view, *Self, tabViewPageAttached, self, .{});
        _ = adw.TabView.signals.page_detached.connect(view, *Self, tabViewPageDetached, self, .{});
        _ = adw.TabView.signals.page_reordered.connect(view, *Self, tabViewPageReordered, self, .{});
        _ = adw.TabView.signals.create_window.connect(view, *Self, tabViewCreateWindow, self, .{});
        _ = adw.TabView.signals.setup_menu.connect(view, *Self, setupTabMenu, self, .{});
        _ = priv.tab_stack.addChild(view.as(gtk.Widget));
        return view;
    }

    /// Show a sidebar tab: its tabs go in the tab bar and the content.
    fn activateWorkspace(self: *Self, id: u32) void {
        const priv = self.private();
        const ws = self.findWorkspace(id) orelse return;
        priv.tab_view = ws.view;
        priv.tab_stack.setVisibleChild(ws.view.as(gtk.Widget));
        priv.tab_bar.setView(ws.view);
        priv.tab_overview.setView(ws.view);
        self.syncSelectedTab();
        self.scheduleSidebarRebuild();
        self.focusActiveSurface();
    }

    fn setGroupDir(group: *SidebarGroup, dir: []const u8) void {
        const alloc = Application.default().allocator();
        if (group.dir != null) return;
        group.dir = alloc.dupeZ(u8, dir) catch return;
        if (group.renamed) return;
        const name = groupNameFor(alloc, dir) catch return;
        alloc.free(group.name);
        group.name = name;
    }

    /// Default group name: the directory's name, `~` for home.
    fn groupNameFor(alloc: std.mem.Allocator, dir_: ?[]const u8) ![:0]u8 {
        const dir = dir_ orelse return alloc.dupeZ(u8, "Terminal");
        const home = std.posix.getenv("HOME") orelse "";
        const trimmed = std.mem.trimRight(u8, dir, "/");
        if (home.len > 0 and std.mem.eql(u8, trimmed, std.mem.trimRight(u8, home, "/")))
            return alloc.dupeZ(u8, "~");
        const base = std.fs.path.basename(trimmed);
        return alloc.dupeZ(u8, if (base.len == 0) "/" else base);
    }

    fn groupWorkspaceCount(self: *Self, id: u32) usize {
        var count: usize = 0;
        for (self.private().workspaces.items) |ws| {
            if (ws.group_id == id) count += 1;
        }
        return count;
    }

    /// Open a sidebar tab in a new group that starts in the current
    /// tab's folder.
    pub fn newTabGroup(self: *Self) void {
        const dir: ?[:0]const u8 = if (self.getActiveSurface()) |s| s.getPwd() else null;
        self.newWorkspace(self.addGroup(dir), dir);
    }

    /// Open a sidebar tab at the end of a group, in the group's folder.
    pub fn newWorkspaceInGroup(self: *Self, group_id: u32) void {
        const group = self.findGroup(group_id) orelse return;
        group.collapsed = false;
        self.newWorkspace(group_id, group.dir);
    }

    fn newWorkspace(self: *Self, group_id: u32, dir: ?[:0]const u8) void {
        const id = self.addWorkspace(group_id);
        if (id == 0) return;
        self.activateWorkspace(id);
        _ = self.newTabPage(null, .tab, .{ .working_directory = dir });
        self.focusActiveSurface();
    }

    fn closeWorkspace(self: *Self, id: u32) void {
        const ws = self.findWorkspace(id) orelse return;
        const view = ws.view;
        // Backwards, since pages may be removed as we go.
        var i = view.getNPages();
        while (i > 0) {
            i -= 1;
            view.closePage(view.getNthPage(i));
        }
    }

    fn focusActiveSurface(self: *Self) void {
        if (self.getActiveSurface()) |surface| surface.grabFocus();
    }

    //---------------------------------------------------------------
    // Sidebar notifications

    const SidebarNotification = struct {
        id: u32,
        title: [:0]u8,
        body: [:0]u8,
        /// Unix seconds.
        time: i64,
        /// Only compared, never dereferenced, until found in this window
        /// by locateSurface: the terminal may have closed.
        surface: *Surface,

        fn deinit(self: *SidebarNotification, alloc: std.mem.Allocator) void {
            alloc.free(self.title);
            alloc.free(self.body);
        }
    };

    var next_notification_id: u32 = 1;
    const max_notifications = 30;

    /// List a desktop notification (OSC 9/99/777) from one of this
    /// window's terminals, unless the user is looking at that terminal.
    pub fn recordNotification(
        self: *Self,
        surface: *Surface,
        title: [:0]const u8,
        body: [:0]const u8,
    ) void {
        if (self.as(gtk.Window).isActive() != 0 and self.getActiveSurface() == surface) return;

        const priv = self.private();
        const alloc = Application.default().allocator();
        if (priv.notifications.items.len >= max_notifications) {
            var oldest = priv.notifications.orderedRemove(0);
            oldest.deinit(alloc);
        }

        const t = alloc.dupeZ(u8, if (title.len == 0) "Notification" else title) catch return;
        const b = alloc.dupeZ(u8, body) catch {
            alloc.free(t);
            return;
        };
        var n: SidebarNotification = .{
            .id = next_notification_id,
            .title = t,
            .body = b,
            .time = std.time.timestamp(),
            .surface = surface,
        };
        priv.notifications.append(alloc, n) catch {
            n.deinit(alloc);
            return;
        };
        next_notification_id += 1;
        self.scheduleSidebarRebuild();
    }

    const SurfaceLocation = struct {
        view: *adw.TabView,
        page: *adw.TabPage,
        surface: *Surface,
    };

    /// Where `surface` is in this window, if it still is.
    fn locateSurface(self: *Self, surface: *Surface) ?SurfaceLocation {
        for (self.private().workspaces.items) |ws| {
            for (0..@intCast(ws.view.getNPages())) |i| {
                const page = ws.view.getNthPage(@intCast(i));
                const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
                const tree = tab.getSurfaceTree() orelse continue;
                var it = tree.iterator();
                while (it.next()) |entry| {
                    if (entry.view == surface) return .{ .view = ws.view, .page = page, .surface = entry.view };
                }
            }
        }
        return null;
    }

    /// Drop notifications from terminals in `page` (seen) or that closed.
    fn clearNotificationsFor(self: *Self, page: ?*adw.TabPage) void {
        const priv = self.private();
        const alloc = Application.default().allocator();
        var changed = false;
        var i: usize = 0;
        while (i < priv.notifications.items.len) {
            const loc = self.locateSurface(priv.notifications.items[i].surface);
            if (loc == null or (page != null and loc.?.page == page.?)) {
                var n = priv.notifications.orderedRemove(i);
                n.deinit(alloc);
                changed = true;
            } else i += 1;
        }
        if (changed) self.scheduleSidebarRebuild();
    }

    /// Show the terminal a notification came from.
    fn jumpToNotification(self: *Self, id: u32) void {
        const priv = self.private();
        for (priv.notifications.items) |n| {
            if (n.id != id) continue;
            const loc = self.locateSurface(n.surface) orelse break;
            if (self.workspaceForView(loc.view)) |ws| {
                if (loc.view != priv.tab_view) self.activateWorkspace(ws.id);
            }
            loc.view.setSelectedPage(loc.page);
            loc.surface.grabFocus();
            self.clearNotificationsFor(loc.page);
            return;
        }
        // Its terminal is gone.
        self.clearNotificationsFor(null);
    }

    fn workspaceUnread(self: *Self, view: *adw.TabView) usize {
        var count: usize = 0;
        for (self.private().notifications.items) |n| {
            const loc = self.locateSurface(n.surface) orelse continue;
            if (loc.view == view) count += 1;
        }
        return count;
    }

    fn actionClearNotifications(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        const priv = self.private();
        const alloc = Application.default().allocator();
        for (priv.notifications.items) |*n| n.deinit(alloc);
        priv.notifications.clearRetainingCapacity();
        self.scheduleSidebarRebuild();
        self.focusActiveSurface();
    }

    fn sidebarSectionRow(label: [*:0]const u8, icon: [*:0]const u8) *gtk.ListBoxRow {
        const row = gtk.ListBoxRow.new();
        row.setSelectable(0);
        row.setActivatable(0);
        row.as(gtk.Widget).addCssClass("sidebar-section");
        const box = gtk.Box.new(.horizontal, 6);
        const image = gtk.Image.newFromIconName(icon);
        image.as(gtk.Widget).addCssClass("dim-label");
        box.append(image.as(gtk.Widget));
        const text = gtk.Label.new(label);
        text.setXalign(0);
        text.as(gtk.Widget).setHexpand(1);
        text.as(gtk.Widget).addCssClass("dim-label");
        text.as(gtk.Widget).addCssClass("caption-heading");
        box.append(text.as(gtk.Widget));
        row.setChild(box.as(gtk.Widget));
        return row;
    }

    fn notificationHeaderRow(count: usize) *gtk.ListBoxRow {
        const row = sidebarSectionRow(i18n._("NOTIFICATIONS"), "preferences-system-notifications-symbolic");
        const box = gobject.ext.cast(gtk.Box, row.getChild().?).?;

        var buf: [32]u8 = undefined;
        const badge = gtk.Label.new((std.fmt.bufPrintZ(&buf, "{d}", .{count}) catch "").ptr);
        badge.as(gtk.Widget).addCssClass("unread-badge");
        badge.as(gtk.Widget).setValign(.center);
        box.append(badge.as(gtk.Widget));

        const clear = gtk.Button.newFromIconName("edit-clear-all-symbolic");
        clear.as(gtk.Widget).addCssClass("flat");
        clear.as(gtk.Widget).setValign(.center);
        clear.as(gtk.Widget).setTooltipText(i18n._("Clear Notifications"));
        clear.as(gtk.Widget).setFocusOnClick(0);
        gtk.Actionable.setActionName(clear.as(gtk.Actionable), "win.clear-notifications");
        box.append(clear.as(gtk.Widget));
        return row;
    }

    fn notificationRow(self: *Self, n: SidebarNotification, now: i64) *gtk.ListBoxRow {
        const row = gtk.ListBoxRow.new();
        row.setSelectable(0);
        row.as(gtk.Widget).addCssClass("sidebar-notification");
        row.as(gobject.Object).setData("ghostty-notification", @ptrFromInt(n.id));

        const col = gtk.Box.new(.vertical, 1);

        const top = gtk.Box.new(.horizontal, 6);
        const title = gtk.Label.new(n.title.ptr);
        title.setXalign(0);
        title.setEllipsize(.end);
        title.as(gtk.Widget).setHexpand(1);
        title.as(gtk.Widget).addCssClass("notification-title");
        top.append(title.as(gtk.Widget));

        var buf: [64]u8 = undefined;
        const age: u64 = @intCast(@max(0, now - n.time));
        const when = if (age < 60)
            std.fmt.bufPrintZ(&buf, "now", .{}) catch ""
        else if (age < 3600)
            std.fmt.bufPrintZ(&buf, "{d}m", .{age / 60}) catch ""
        else if (age < 86400)
            std.fmt.bufPrintZ(&buf, "{d}h", .{age / 3600}) catch ""
        else
            std.fmt.bufPrintZ(&buf, "{d}d", .{age / 86400}) catch "";
        const time = gtk.Label.new(when.ptr);
        time.as(gtk.Widget).addCssClass("notification-meta");
        time.as(gtk.Widget).addCssClass("dim-label");
        top.append(time.as(gtk.Widget));
        col.append(top.as(gtk.Widget));

        if (n.body.len > 0) {
            const body = gtk.Label.new(n.body.ptr);
            body.setXalign(0);
            body.setEllipsize(.end);
            body.as(gtk.Widget).addCssClass("notification-body");
            body.as(gtk.Widget).addCssClass("dim-label");
            col.append(body.as(gtk.Widget));
        }

        // Which tab it came from.
        if (self.locateSurface(n.surface)) |loc| {
            const source = gtk.Label.new(null);
            source.setXalign(0);
            source.setEllipsize(.end);
            source.as(gtk.Widget).addCssClass("notification-meta");
            source.as(gtk.Widget).addCssClass("dim-label");
            _ = loc.page.as(gobject.Object).bindProperty("title", source.as(gobject.Object), "label", .{ .sync_create = true });
            col.append(source.as(gtk.Widget));
        }

        row.setChild(col.as(gtk.Widget));
        return row;
    }

    //---------------------------------------------------------------
    // Sidebar rows

    /// Rebuild the sidebar on idle, so a burst of changes rebuilds once.
    fn scheduleSidebarRebuild(self: *Self) void {
        const priv = self.private();
        if (priv.sidebar_rebuild != null or priv.sidebar_rebuilding) return;
        priv.sidebar_rebuild = glib.idleAdd(sidebarRebuildIdle, self);
    }

    fn sidebarRebuildIdle(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        priv.sidebar_rebuild = null;
        priv.sidebar_rebuilding = true;
        defer priv.sidebar_rebuilding = false;
        self.pruneWorkspaces();
        if (self.sidebarShown()) self.rebuildSidebar();
        return 0;
    }

    /// Drop sidebar tabs whose tabs have all closed, and then empty groups.
    /// Runs on idle: a view can't be destroyed inside its own signals.
    fn pruneWorkspaces(self: *Self) void {
        const priv = self.private();
        const alloc = Application.default().allocator();

        var i: usize = 0;
        while (i < priv.workspaces.items.len) {
            const ws = priv.workspaces.items[i];
            if (ws.view.getNPages() > 0 or priv.workspaces.items.len == 1) {
                i += 1;
                continue;
            }
            _ = priv.workspaces.orderedRemove(i);
            if (ws.view == priv.tab_view) {
                const next = priv.workspaces.items[@min(i, priv.workspaces.items.len - 1)];
                self.activateWorkspace(next.id);
            }
            priv.tab_stack.remove(ws.view.as(gtk.Widget));
        }

        var gi: usize = 0;
        while (gi < priv.groups.items.len) {
            if (self.groupWorkspaceCount(priv.groups.items[gi].id) == 0) {
                var group = priv.groups.orderedRemove(gi);
                group.deinit(alloc);
            } else gi += 1;
        }
    }

    /// Select the active sidebar tab's row without rebuilding, so open
    /// menus and hover state survive.
    fn syncSidebarSelection(self: *Self) void {
        if (!self.sidebarShown()) return;
        const priv = self.private();
        const ws = self.activeWorkspace() orelse return;
        var i: c_int = 0;
        while (priv.sidebar_list.getRowAtIndex(i)) |row| : (i += 1) {
            const raw = row.as(gobject.Object).getData("ghostty-workspace") orelse continue;
            if (@intFromPtr(raw) != ws.id) continue;
            priv.sidebar_list.selectRow(row);
            return;
        }
        // Its row is missing (e.g. a collapsed group), so redraw.
        self.scheduleSidebarRebuild();
    }

    fn rebuildSidebar(self: *Self) void {
        const priv = self.private();
        const list = priv.sidebar_list;
        list.removeAll();

        // Notifications, newest first, minus those whose terminal closed.
        self.clearNotificationsFor(null);
        if (priv.notifications.items.len > 0) {
            list.append(notificationHeaderRow(priv.notifications.items.len).as(gtk.Widget));
            const now = std.time.timestamp();
            var i = priv.notifications.items.len;
            while (i > 0) {
                i -= 1;
                list.append(self.notificationRow(priv.notifications.items[i], now).as(gtk.Widget));
            }
        }

        list.append(sidebarSectionRow(i18n._("TABS"), "view-list-symbolic").as(gtk.Widget));
        for (priv.groups.items) |*group| {
            list.append(sidebarGroupRow(group, self.groupWorkspaceCount(group.id)).as(gtk.Widget));
            for (priv.workspaces.items) |ws| {
                if (ws.group_id != group.id) continue;
                const active = ws.view == priv.tab_view;
                if (group.collapsed and !active) continue;
                const row = self.sidebarWorkspaceRow(ws);
                list.append(row.as(gtk.Widget));
                if (active) list.selectRow(row);
            }
        }
    }

    fn sidebarGroupRow(group: *const SidebarGroup, count: usize) *gtk.ListBoxRow {
        const row = gtk.ListBoxRow.new();
        row.setSelectable(0);
        row.as(gtk.Widget).addCssClass("sidebar-group");
        row.as(gobject.Object).setData("ghostty-group", @ptrFromInt(group.id));
        if (group.dir) |dir| {
            var buf: [std.fs.max_path_bytes + 2]u8 = undefined;
            row.as(gtk.Widget).setTooltipText(abbrevHome(&buf, dir));
        }

        const box = gtk.Box.new(.horizontal, 6);

        const arrow = gtk.Image.newFromIconName(
            if (group.collapsed) "pan-end-symbolic" else "pan-down-symbolic",
        );
        arrow.as(gtk.Widget).addCssClass("dim-label");
        box.append(arrow.as(gtk.Widget));
        box.append(gtk.Image.newFromIconName("folder-symbolic").as(gtk.Widget));

        const name = gtk.Label.new(group.name.ptr);
        name.setXalign(0);
        name.setEllipsize(.end);
        name.setWidthChars(6);
        name.as(gtk.Widget).setHexpand(1);
        name.as(gtk.Widget).addCssClass("group-name");
        box.append(name.as(gtk.Widget));

        var buf: [64]u8 = undefined;
        const count_label = gtk.Label.new((std.fmt.bufPrintZ(&buf, "{d}", .{count}) catch "").ptr);
        count_label.as(gtk.Widget).addCssClass("group-count");
        count_label.as(gtk.Widget).addCssClass("dim-label");
        count_label.as(gtk.Widget).setValign(.center);
        box.append(count_label.as(gtk.Widget));

        const add = gtk.Button.newFromIconName("list-add-symbolic");
        add.as(gtk.Widget).addCssClass("flat");
        add.as(gtk.Widget).addCssClass("hover-only");
        add.as(gtk.Widget).setTooltipText(i18n._("New Tab in Group"));
        add.as(gtk.Widget).setFocusOnClick(0);
        add.as(gtk.Widget).setValign(.center);
        gtk.Actionable.setDetailedActionName(
            add.as(gtk.Actionable),
            (std.fmt.bufPrintZ(&buf, "win.group-new-tab(uint32 {d})", .{group.id}) catch "").ptr,
        );
        box.append(add.as(gtk.Widget));

        const menu = gio.Menu.new();
        defer menu.unref();
        menu.append(
            i18n._("Rename Group…"),
            (std.fmt.bufPrintZ(&buf, "win.group-rename(uint32 {d})", .{group.id}) catch "").ptr,
        );
        menu.append(
            i18n._("Close Group"),
            (std.fmt.bufPrintZ(&buf, "win.group-close(uint32 {d})", .{group.id}) catch "").ptr,
        );
        const more = gtk.MenuButton.new();
        more.setIconName("view-more-symbolic");
        more.setMenuModel(menu.as(gio.MenuModel));
        more.as(gtk.Widget).addCssClass("flat");
        more.as(gtk.Widget).addCssClass("hover-only");
        more.as(gtk.Widget).setTooltipText(i18n._("Group Menu"));
        more.as(gtk.Widget).setFocusOnClick(0);
        more.as(gtk.Widget).setValign(.center);
        box.append(more.as(gtk.Widget));

        row.setChild(box.as(gtk.Widget));
        return row;
    }

    fn sidebarWorkspaceRow(self: *Self, ws: Workspace) *gtk.ListBoxRow {
        const row = gtk.ListBoxRow.new();
        row.as(gtk.Widget).addCssClass("sidebar-tab");
        row.as(gobject.Object).setData("ghostty-workspace", @ptrFromInt(ws.id));

        const box = gtk.Box.new(.horizontal, 6);

        // Shown only on the selected row, by CSS.
        const dot = gtk.Image.newFromIconName("media-record-symbolic");
        dot.as(gtk.Widget).addCssClass("active-dot");
        dot.as(gtk.Widget).setValign(.center);
        box.append(dot.as(gtk.Widget));

        // Named after its selected tab. Bound rather than rebuilt: shells
        // retitle the tab on every command.
        const title = gtk.Label.new(null);
        title.as(gtk.Widget).addCssClass("tab-title");
        title.setXalign(0);
        title.setEllipsize(.end);
        title.as(gtk.Widget).setHexpand(1);
        if (ws.view.getSelectedPage()) |page| {
            _ = page.as(gobject.Object).bindProperty("title", title.as(gobject.Object), "label", .{ .sync_create = true });
            _ = page.as(gobject.Object).bindProperty("tooltip", row.as(gobject.Object), "tooltip-markup", .{ .sync_create = true });
        }
        box.append(title.as(gtk.Widget));

        // Bell in a background tab.
        const n: usize = @intCast(ws.view.getNPages());
        var attention = false;
        for (0..n) |i| {
            if (ws.view.getNthPage(@intCast(i)).getNeedsAttention() != 0) attention = true;
        }
        if (attention) {
            const bell = gtk.Image.newFromIconName("media-record-symbolic");
            bell.as(gtk.Widget).addCssClass("attention");
            bell.as(gtk.Widget).setValign(.center);
            box.append(bell.as(gtk.Widget));
        }

        // Unseen notifications from its tabs.
        const unread = self.workspaceUnread(ws.view);
        if (unread > 0) {
            var buf: [32]u8 = undefined;
            const badge = gtk.Label.new((std.fmt.bufPrintZ(&buf, "{d}", .{unread}) catch "").ptr);
            badge.as(gtk.Widget).addCssClass("unread-badge");
            badge.as(gtk.Widget).setValign(.center);
            box.append(badge.as(gtk.Widget));
        }

        // How many tabs it holds, when more than one.
        if (n > 1) {
            var buf: [32]u8 = undefined;
            const count = gtk.Label.new((std.fmt.bufPrintZ(&buf, "{d}", .{n}) catch "").ptr);
            count.as(gtk.Widget).addCssClass("tab-count");
            count.as(gtk.Widget).addCssClass("dim-label");
            count.as(gtk.Widget).setValign(.center);
            box.append(count.as(gtk.Widget));
        }

        const close = gtk.Button.newFromIconName("window-close-symbolic");
        close.as(gtk.Widget).addCssClass("flat");
        close.as(gtk.Widget).addCssClass("circular");
        close.as(gtk.Widget).addCssClass("close");
        close.as(gtk.Widget).setValign(.center);
        close.as(gtk.Widget).setTooltipText(i18n._("Close All Its Tabs"));
        close.as(gtk.Widget).setFocusOnClick(0);
        close.as(gobject.Object).setData("ghostty-workspace", @ptrFromInt(ws.id));
        _ = gtk.Button.signals.clicked.connect(
            close,
            *Self,
            sidebarCloseClicked,
            self,
            .{},
        );
        box.append(close.as(gtk.Widget));

        row.setChild(box.as(gtk.Widget));
        return row;
    }

    fn sidebarRowActivated(
        _: *gtk.ListBox,
        row: *gtk.ListBoxRow,
        self: *Self,
    ) callconv(.c) void {
        const obj = row.as(gobject.Object);

        // Group header: collapse or expand.
        if (obj.getData("ghostty-group")) |raw| {
            const group = self.findGroup(@intCast(@intFromPtr(raw))) orelse return;
            group.collapsed = !group.collapsed;
            self.scheduleSidebarRebuild();
            return;
        }

        if (obj.getData("ghostty-notification")) |raw| {
            self.jumpToNotification(@intCast(@intFromPtr(raw)));
            return;
        }

        const raw = obj.getData("ghostty-workspace") orelse return;
        self.activateWorkspace(@intCast(@intFromPtr(raw)));
    }

    fn sidebarCloseClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        const raw = button.as(gobject.Object).getData("ghostty-workspace") orelse return;
        self.closeWorkspace(@intCast(@intFromPtr(raw)));
    }

    fn actionNewGroup(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.newTabGroup();
    }

    fn actionGroupNewTab(_: *gio.SimpleAction, param: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.newWorkspaceInGroup((param orelse return).getUint32());
    }

    fn actionGroupRename(_: *gio.SimpleAction, param: ?*glib.Variant, self: *Self) callconv(.c) void {
        const id = (param orelse return).getUint32();
        const group = self.findGroup(id) orelse return;
        self.private().renaming_group = id;
        const dialog = TitleDialog.new(.group, group.name);
        _ = TitleDialog.signals.set.connect(dialog, *Self, groupRenameSet, self, .{});
        dialog.present(self.as(gtk.Widget));
    }

    fn groupRenameSet(_: *TitleDialog, title_ptr: [*:0]const u8, self: *Self) callconv(.c) void {
        const group = self.findGroup(self.private().renaming_group) orelse return;
        const alloc = Application.default().allocator();
        const title = std.mem.span(title_ptr);
        // An empty name goes back to the folder name.
        const name = if (title.len == 0)
            groupNameFor(alloc, group.dir) catch return
        else
            alloc.dupeZ(u8, title) catch return;
        alloc.free(group.name);
        group.name = name;
        group.renamed = title.len != 0;
        self.scheduleSidebarRebuild();
    }

    fn actionGroupClose(_: *gio.SimpleAction, param: ?*glib.Variant, self: *Self) callconv(.c) void {
        const id = (param orelse return).getUint32();
        // Copy the ids first: closing can't change the list synchronously
        // (pruning is on idle) but don't rely on it.
        var ids: [256]u32 = undefined;
        var n: usize = 0;
        for (self.private().workspaces.items) |ws| {
            if (ws.group_id == id and n < ids.len) {
                ids[n] = ws.id;
                n += 1;
            }
        }
        for (ids[0..n]) |ws_id| self.closeWorkspace(ws_id);
    }

    /// `dir` with $HOME shortened to `~`, written to buf.
    fn abbrevHome(buf: []u8, dir: [:0]const u8) [:0]const u8 {
        const home = std.posix.getenv("HOME") orelse "";
        if (home.len > 1 and std.mem.startsWith(u8, dir, home) and
            (dir.len == home.len or dir[home.len] == '/'))
        {
            return std.fmt.bufPrintZ(buf, "~{s}", .{dir[home.len..]}) catch dir;
        }
        return dir;
    }

    pub fn toggleTabOverview(self: *Self) void {
        const priv = self.private();
        const tab_overview = priv.tab_overview;
        const is_open = tab_overview.getOpen() != 0;
        tab_overview.setOpen(@intFromBool(!is_open));
    }

    /// Toggle the visible property.
    pub fn toggleVisibility(self: *Self) void {
        const widget = self.as(gtk.Widget);
        widget.setVisible(@intFromBool(widget.isVisible() == 0));
    }

    /// Updates various appearance properties. This should always be safe
    /// to call multiple times. This should be called whenever a change
    /// happens that might affect how the window appears (config change,
    /// fullscreen, etc.).
    fn syncAppearance(self: *Self) void {
        const priv = self.private();
        const widget = self.as(gtk.Widget);

        // Toggle style classes based on whether we're using CSDs or SSDs.
        //
        // These classes are defined in the gtk.Window documentation:
        // https://docs.gtk.org/gtk4/class.Window.html#css-nodes.
        {
            // Reset all style classes first
            inline for (&.{
                "ssd",
                "csd",
                "solid-csd",
                "no-border-radius",
            }) |class|
                widget.removeCssClass(class);

            const csd_enabled = priv.winproto.clientSideDecorationEnabled();
            self.as(gtk.Window).setDecorated(@intFromBool(csd_enabled));

            if (csd_enabled) {
                const display = widget.getDisplay();

                // We do the exact same check GTK is doing internally and toggle
                // either the `csd` or `solid-csd` style, based on whether the user's
                // window manager is deemed _non-compositing_.
                //
                // In practice this only impacts users of traditional X11 window
                // managers (e.g. i3, dwm, awesomewm, etc.) and not X11 desktop
                // environments or Wayland compositors/DEs.
                if (display.isRgba() != 0 and display.isComposited() != 0) {
                    widget.addCssClass("csd");
                } else {
                    widget.addCssClass("solid-csd");
                }
            } else {
                widget.addCssClass("ssd");
                // Fix any artifacting that may occur in window corners.
                widget.addCssClass("no-border-radius");
            }
        }

        // Trigger all our dynamic properties that depend on the config.
        inline for (&.{
            "headerbar-visible",
            "tabs-autohide",
            "tabs-visible",
            "tabs-wide",
            "toolbar-style",
            "titlebar-style",
        }) |key| {
            self.as(gobject.Object).notifyByPspec(
                @field(properties, key).impl.param_spec,
            );
        }

        // Remainder uses the config
        const config = if (priv.config) |v| v.get() else return;

        // Only add a solid background if we're opaque.
        self.toggleCssClass(
            "background",
            config.@"background-opacity" >= 1,
        );

        // Apply class to color headerbar if window-theme is set to `ghostty` and
        // GTK version is before 4.16. The conditional is because above 4.16
        // we use GTK CSS color variables.
        self.toggleCssClass(
            "window-theme-ghostty",
            !gtk_version.atLeast(4, 16, 0) and
                config.@"window-theme" == .ghostty,
        );

        // Move the tab bar to the proper location: it lives in the content
        // column, next to the sidebar rather than above it.
        priv.content_box.reorderChildAfter(
            priv.tab_bar.as(gtk.Widget),
            switch (config.@"gtk-tabs-location") {
                .top => null,
                .bottom => priv.toast_overlay.as(gtk.Widget),
            },
        );

        self.syncSidebar();

        // Do our window-protocol specific appearance sync.
        priv.winproto.syncAppearance() catch |err| {
            log.warn("failed to sync winproto appearance error={}", .{err});
        };
    }

    /// Sync the state of any actions on this window.
    fn syncActions(self: *Self) void {
        const has_selection = selection: {
            const surface = self.getActiveSurface() orelse
                break :selection false;
            const core_surface = surface.core() orelse
                break :selection false;
            break :selection core_surface.hasSelection();
        };

        const action_map: *gio.ActionMap = gobject.ext.cast(
            gio.ActionMap,
            self,
        ) orelse return;
        const action: *gio.SimpleAction = gobject.ext.cast(
            gio.SimpleAction,
            action_map.lookupAction("copy") orelse return,
        ) orelse return;
        action.setEnabled(@intFromBool(has_selection));
    }

    fn toggleCssClass(self: *Self, class: [:0]const u8, value: bool) void {
        const widget = self.as(gtk.Widget);
        if (value)
            widget.addCssClass(class.ptr)
        else
            widget.removeCssClass(class.ptr);
    }

    /// Perform a binding action on the window's active surface.
    fn performBindingAction(
        self: *Self,
        action: input.Binding.Action,
    ) void {
        const surface = self.getActiveSurface() orelse return;
        const core_surface = surface.core() orelse return;
        _ = core_surface.performBindingAction(action) catch |err| {
            log.warn("error performing binding action error={}", .{err});
            return;
        };
    }

    /// Queue a simple text-based toast. All text-based toasts share the
    /// same timeout for consistency.
    ///
    // This is not `pub` because we should be using signals emitted by
    // other widgets to trigger our toasts. Other objects should not
    // trigger toasts directly.
    fn addToast(self: *Self, title: [*:0]const u8) void {
        const toast = adw.Toast.new(title);
        toast.setTimeout(3);
        self.private().toast_overlay.addToast(toast);
    }

    fn connectSurfaceHandlers(
        self: *Self,
        tree: *const Surface.Tree,
    ) void {
        const priv = self.private();
        var it = tree.iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            // Before adding any new signal handlers, disconnect any that we may
            // have added before. Otherwise we may get multiple handlers for the
            // same signal.
            _ = gobject.signalHandlersDisconnectMatched(
                surface.as(gobject.Object),
                .{ .data = true },
                0,
                0,
                null,
                null,
                self,
            );

            _ = Surface.signals.@"present-request".connect(
                surface,
                *Self,
                surfacePresentRequest,
                self,
                .{},
            );
            _ = Surface.signals.@"clipboard-write".connect(
                surface,
                *Self,
                surfaceClipboardWrite,
                self,
                .{},
            );
            _ = Surface.signals.menu.connect(
                surface,
                *Self,
                surfaceMenu,
                self,
                .{},
            );
            _ = Surface.signals.@"toggle-fullscreen".connect(
                surface,
                *Self,
                surfaceToggleFullscreen,
                self,
                .{},
            );
            _ = Surface.signals.@"toggle-maximize".connect(
                surface,
                *Self,
                surfaceToggleMaximize,
                self,
                .{},
            );
            _ = gobject.Object.signals.notify.connect(
                surface,
                *Self,
                surfacePwdChanged,
                self,
                .{ .detail = "pwd" },
            );

            // If we've never had a surface initialize yet, then we register
            // this signal. Its theoretically possible to launch multiple surfaces
            // before init so we could register this on multiple and that is not
            // a problem because we'll check the flag again in each handler.
            if (!priv.surface_init) {
                _ = Surface.signals.init.connect(
                    surface,
                    *Self,
                    surfaceInit,
                    self,
                    .{},
                );
            }
        }
    }

    /// Disconnect all the surface handlers for the given tree. This should
    /// be called whenever a tree is no longer present in the window, e.g.
    /// when a tab is detached or the tree changes.
    fn disconnectSurfaceHandlers(
        self: *Self,
        tree: *const Surface.Tree,
    ) void {
        var it = tree.iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            _ = gobject.signalHandlersDisconnectMatched(
                surface.as(gobject.Object),
                .{ .data = true },
                0,
                0,
                null,
                null,
                self,
            );
        }
    }

    //---------------------------------------------------------------
    // Properties

    /// Whether this terminal is a quick terminal or not.
    pub fn isQuickTerminal(self: *Self) bool {
        return self.private().quick_terminal;
    }

    /// Get the currently active surface. See the "active-surface" property.
    /// This does not ref the value.
    pub fn getActiveSurface(self: *Self) ?*Surface {
        const tab = self.getSelectedTab() orelse return null;
        return tab.getActiveSurface();
    }

    /// Returns the configuration for this window. The reference count
    /// is not increased.
    pub fn getConfig(self: *Self) ?*Config {
        return self.private().config;
    }

    /// Get the tab view for this window.
    pub fn getTabView(self: *Self) *adw.TabView {
        return self.private().tab_view;
    }

    /// Get the current window decoration value for this window.
    pub fn getWindowDecoration(self: *Self) configpkg.WindowDecoration {
        const priv = self.private();
        if (priv.window_decoration) |v| return v;
        if (priv.config) |v| return v.get().@"window-decoration";
        return .auto;
    }

    /// Toggle the window decorations for this window.
    pub fn toggleWindowDecorations(self: *Self) void {
        const priv = self.private();

        if (priv.window_decoration) |_| {
            // Unset any previously set window decoration settings
            self.setWindowDecoration(null);
            return;
        }

        const config = if (priv.config) |v| v.get() else return;
        self.setWindowDecoration(switch (config.@"window-decoration") {
            // Use auto when the decoration is initially none
            .none => .auto,

            // Anything non-none to none
            .auto, .client, .server => .none,
        });
    }

    /// Set the window decoration override for this window. If this is null,
    /// then we'll revert back to the configuration's default.
    fn setWindowDecoration(
        self: *Self,
        new_: ?configpkg.WindowDecoration,
    ) void {
        const priv = self.private();
        priv.window_decoration = new_;
        self.syncAppearance();
    }

    /// Get the currently selected tab as a Tab object.
    fn getSelectedTab(self: *Self) ?*Tab {
        const priv = self.private();
        // Template bindings ask before init creates the first tab view.
        if (priv.workspaces.items.len == 0) return null;
        const page = priv.tab_view.getSelectedPage() orelse return null;
        const child = page.getChild();
        assert(gobject.ext.isA(child, Tab));
        return gobject.ext.cast(Tab, child);
    }

    /// Returns true if this window needs confirmation before quitting.
    fn getNeedsConfirmQuit(self: *Self) bool {
        const priv = self.private();
        for (priv.workspaces.items) |ws| {
            if (viewNeedsConfirmQuit(ws.view)) return true;
        }
        return false;
    }

    fn viewNeedsConfirmQuit(view: *adw.TabView) bool {
        const n = view.getNPages();
        assert(n >= 0);

        for (0..@intCast(n)) |i| {
            const page = view.getNthPage(@intCast(i));
            const child = page.getChild();
            const tab = gobject.ext.cast(Tab, child) orelse {
                log.warn("unexpected non-Tab child in tab view", .{});
                continue;
            };
            if (tab.getNeedsConfirmQuit()) return true;
        }

        return false;
    }

    fn isFullscreen(self: *Window) bool {
        return self.as(gtk.Window).isFullscreen() != 0;
    }

    fn isMaximized(self: *Window) bool {
        return self.as(gtk.Window).isMaximized() != 0;
    }

    fn getHeaderbarVisible(self: *Self) bool {
        const priv = self.private();

        // Never display the header bar when CSDs are disabled.
        const csd_enabled = priv.winproto.clientSideDecorationEnabled();
        if (!csd_enabled) return false;

        // Never display the header bar as a quick terminal.
        if (priv.quick_terminal) return false;

        // If we're fullscreen we never show the header bar.
        if (self.isFullscreen()) return false;

        // The remainder needs a config
        const config_obj = self.private().config orelse return true;
        const config = config_obj.get();

        // *Conditionally* disable the header bar when maximized, and
        // gtk-titlebar-hide-when-maximized is set
        if (self.isMaximized() and config.@"gtk-titlebar-hide-when-maximized") {
            return false;
        }

        return switch (config.@"gtk-titlebar-style") {
            // If the titlebar style is tabs never show the titlebar.
            .tabs => false,

            // If the titlebar style is native show the titlebar if configured
            // to do so.
            .native => config.@"gtk-titlebar",
        };
    }

    fn getTabsAutohide(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return true;

        return switch (config.@"gtk-titlebar-style") {
            // If the titlebar style is tabs we cannot autohide.
            .tabs => false,

            .native => switch (config.@"window-show-tab-bar") {
                // Auto we always autohide... obviously.
                .auto => true,

                // Always we never autohide because we always show the tab bar.
                .always => false,

                // Never we autohide because it doesn't actually matter,
                // since getTabsVisible will return false.
                .never => true,
            },
        };
    }

    fn getTabsVisible(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return true;

        switch (config.@"gtk-titlebar-style") {
            .tabs => {
                // *Conditionally* disable the tab bar when maximized, the titlebar
                // style is tabs, and gtk-titlebar-hide-when-maximized is set.
                if (self.isMaximized() and config.@"gtk-titlebar-hide-when-maximized") return false;

                // If the titlebar style is tabs the tab bar must always be visible.
                return true;
            },
            .native => {
                return switch (config.@"window-show-tab-bar") {
                    .always, .auto => true,
                    .never => false,
                };
            },
        }
    }

    fn getTabsWide(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return true;
        return config.@"gtk-wide-tabs";
    }

    fn getToolbarStyle(self: *Self) adw.ToolbarStyle {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return .raised;
        return switch (config.@"gtk-toolbar-style") {
            .flat => .flat,
            .raised => .raised,
            .@"raised-border" => .raised_border,
        };
    }

    fn getTitlebarStyle(self: *Self) TitlebarStyle {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return .native;
        return config.@"gtk-titlebar-style";
    }

    fn propConfig(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.config) |config_obj| {
            const config = config_obj.get();
            if (config.@"app-notifications".@"config-reload") {
                self.addToast(i18n._("Reloaded the configuration"));
            }
        }

        self.syncAppearance();
    }

    fn propGdkSurfaceHeight(
        _: *gdk.Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // X11 needs to fix blurring on resize, but winproto implementations
        // could do anything.
        self.private().winproto.resizeEvent() catch |err| {
            log.warn(
                "winproto resize event failed error={}",
                .{err},
            );
        };
    }

    fn propIsActive(
        _: *gtk.Window,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // Hide quick-terminal if set to autohide
        if (self.isQuickTerminal()) {
            if (self.getConfig()) |cfg| {
                if (cfg.get().@"quick-terminal-autohide" and self.as(gtk.Window).isActive() == 0) {
                    self.toggleVisibility();
                }
            }
        }

        // Don't change urgency if we're not the active window.
        if (self.as(gtk.Window).isActive() == 0) return;

        // The selected tab's notifications have now been seen.
        if (self.private().tab_view.getSelectedPage()) |page| self.clearNotificationsFor(page);

        self.winproto().setUrgent(false) catch |err| {
            log.warn(
                "winproto failed to reset urgency={}",
                .{err},
            );
        };
    }

    fn propGdkSurfaceWidth(
        _: *gdk.Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // X11 needs to fix blurring on resize, but winproto implementations
        // could do anything.
        self.private().winproto.resizeEvent() catch |err| {
            log.warn(
                "winproto resize event failed error={}",
                .{err},
            );
        };
    }

    fn propFullscreened(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncAppearance();
    }

    fn propMaximized(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncAppearance();
    }

    fn propMenuActive(
        button: *gtk.MenuButton,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // Debian 12 is stuck on GTK 4.8
        if (!gtk_version.atLeast(4, 10, 0)) return;

        // We only care if we're activating. If we're activating then
        // we need to check the validity of our menu items.
        const active = button.getActive() != 0;
        if (!active) return;

        self.syncActions();
    }

    fn propQuickTerminal(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.surface_init) {
            log.warn("quick terminal property can't be changed after surfaces have been initialized", .{});
            return;
        }

        if (priv.quick_terminal) {
            // Initialize the quick terminal at the app-layer
            Application.default().winproto().initQuickTerminal(self) catch |err| {
                log.warn("failed to initialize quick terminal error={}", .{err});
                return;
            };
        }
    }

    fn propScaleFactor(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // On some platforms (namely X11) we need to refresh our appearance when
        // the scale factor changes. In theory this could be more fine-grained as
        // a full refresh could be expensive, but a) this *should* be rare, and
        // b) quite noticeable visual bugs would occur if this is not present.
        self.private().winproto.syncAppearance() catch |err| {
            log.warn(
                "failed to sync appearance after scale factor has been updated={}",
                .{err},
            );
            return;
        };
    }

    fn closureTitlebarStyleIsTab(
        _: *Self,
        value: TitlebarStyle,
    ) callconv(.c) c_int {
        return @intFromBool(switch (value) {
            .native => false,
            .tabs => true,
        });
    }

    fn closureSubtitle(
        _: *Self,
        config_: ?*Config,
        pwd_: ?[*:0]const u8,
    ) callconv(.c) ?[*:0]const u8 {
        const config = if (config_) |v| v.get() else return null;
        return switch (config.@"window-subtitle") {
            .false => null,
            .@"working-directory" => pwd: {
                const pwd = pwd_ orelse return null;
                break :pwd glib.ext.dupeZ(u8, std.mem.span(pwd));
            },
        };
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        priv.command_palette.set(null);

        if (priv.sidebar_rebuild) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove sidebar rebuild source", .{});
            }
            priv.sidebar_rebuild = null;
        }

        if (priv.config) |v| {
            v.unref();
            priv.config = null;
        }

        priv.tab_bindings.setSource(null);

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        const alloc = Application.default().allocator();
        for (priv.groups.items) |*g| g.deinit(alloc);
        priv.groups.deinit(alloc);
        priv.workspaces.deinit(alloc);
        for (priv.notifications.items) |*n| n.deinit(alloc);
        priv.notifications.deinit(alloc);
        priv.tab_bindings.unref();
        priv.winproto.deinit(Application.default().allocator());

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Signal handlers

    fn windowRealize(_: *gtk.Widget, self: *Window) callconv(.c) void {
        const app = Application.default();

        // Initialize our window protocol logic
        if (winprotopkg.Window.init(
            app.allocator(),
            app.winproto(),
            self,
        )) |wp| {
            self.private().winproto = wp;
        } else |err| {
            log.warn("failed to initialize window protocol error={}", .{err});
            return;
        }

        // We need to setup resize notifications on our surface,
        // which is only available after the window had been realized.
        if (self.as(gtk.Native).getSurface()) |gdk_surface| {
            _ = gobject.Object.signals.notify.connect(
                gdk_surface,
                *Self,
                propGdkSurfaceWidth,
                self,
                .{ .detail = "width" },
            );
            _ = gobject.Object.signals.notify.connect(
                gdk_surface,
                *Self,
                propGdkSurfaceHeight,
                self,
                .{ .detail = "height" },
            );
        }

        // When we are realized we always setup our appearance since this
        // calls some winproto functions.
        self.syncAppearance();
    }

    fn btnNewTab(_: *adw.SplitButton, self: *Self) callconv(.c) void {
        self.performBindingAction(.new_tab);
    }

    fn tabOverviewCreateTab(
        _: *adw.TabOverview,
        self: *Self,
    ) callconv(.c) *adw.TabPage {
        return self.newTabPage(if (self.getActiveSurface()) |v| v.core() else null, .tab, .none);
    }

    fn tabOverviewOpen(
        tab_overview: *adw.TabOverview,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // We only care about when the tab overview is closed.
        if (tab_overview.getOpen() != 0) return;

        // On tab overview close, focus is sometimes lost. This is an
        // upstream issue in libadwaita[1]. When this is resolved we
        // can put a runtime version check here to avoid this workaround.
        //
        // Our workaround is to start a timer after 500ms to refocus
        // the currently selected tab. We choose 500ms because the adw
        // animation is 400ms.
        //
        // [1]: https://gitlab.gnome.org/GNOME/libadwaita/-/issues/670

        // If we have an old timer remove it
        const priv = self.private();
        if (priv.tab_overview_focus_timer) |timer| {
            _ = glib.Source.remove(timer);
        }

        // Restart our timer
        priv.tab_overview_focus_timer = glib.timeoutAdd(
            500,
            tabOverviewFocusTimer,
            self,
        );
    }

    fn tabOverviewFocusTimer(
        ud: ?*anyopaque,
    ) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));

        // Always note our timer is removed
        self.private().tab_overview_focus_timer = null;

        // Get our currently active surface which should respect the newly
        // selected tab. Grab focus.
        const surface = self.getActiveSurface() orelse return 0;
        surface.grabFocus();

        // Remove the timer
        return 0;
    }

    fn windowCloseRequest(
        _: *gtk.Window,
        self: *Self,
    ) callconv(.c) c_int {
        if (self.getNeedsConfirmQuit()) {
            // Show a confirmation dialog
            const dialog: *CloseConfirmationDialog = .new(.window);
            _ = CloseConfirmationDialog.signals.@"close-request".connect(
                dialog,
                *Self,
                closeConfirmationClose,
                self,
                .{},
            );

            // Show it
            dialog.present(self.as(gtk.Widget));
            return @intFromBool(true);
        }

        self.as(gtk.Window).destroy();
        return @intFromBool(false);
    }

    fn closeConfirmationClose(
        _: *CloseConfirmationDialog,
        self: *Self,
    ) callconv(.c) void {
        self.as(gtk.Window).destroy();
    }

    fn closeConfirmationCloseTab(
        _: *CloseConfirmationDialog,
        page: *adw.TabPage,
    ) callconv(.c) void {
        const tab_view = ext.getAncestor(
            adw.TabView,
            page.getChild().as(gtk.Widget),
        ) orelse {
            log.warn("close confirmation called for non-existent page", .{});
            return;
        };
        tab_view.closePageFinish(page, @intFromBool(true));
    }

    fn closeConfirmationCancelTab(
        _: *CloseConfirmationDialog,
        page: *adw.TabPage,
    ) callconv(.c) void {
        const tab_view = ext.getAncestor(
            adw.TabView,
            page.getChild().as(gtk.Widget),
        ) orelse {
            log.warn("close confirmation called for non-existent page", .{});
            return;
        };
        tab_view.closePageFinish(page, @intFromBool(false));
    }

    fn tabViewClosePage(
        view: *adw.TabView,
        page: *adw.TabPage,
        self: *Self,
    ) callconv(.c) c_int {
        _ = self;
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse
            return @intFromBool(false);

        // If the tab says it doesn't need confirmation then we go ahead
        // and close immediately.
        if (!tab.getNeedsConfirmQuit()) {
            view.closePageFinish(page, @intFromBool(true));
            return @intFromBool(true);
        }

        // Show a confirmation dialog
        const dialog: *CloseConfirmationDialog = .new(.tab);
        _ = CloseConfirmationDialog.signals.@"close-request".connect(
            dialog,
            *adw.TabPage,
            closeConfirmationCloseTab,
            page,
            .{},
        );
        _ = CloseConfirmationDialog.signals.cancel.connect(
            dialog,
            *adw.TabPage,
            closeConfirmationCancelTab,
            page,
            .{},
        );

        // Show it
        dialog.present(child);
        return @intFromBool(true);
    }

    fn tabViewSelectedPage(
        view: *adw.TabView,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // Sidebar rows are named after their view's selected tab.
        self.scheduleSidebarRebuild();
        if (view == self.private().tab_view) self.syncSelectedTab();
    }

    /// Sync window state from the selected tab of the active view.
    fn syncSelectedTab(self: *Self) void {
        const priv = self.private();
        defer self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);

        // Always reset our binding source in case we have no pages.
        priv.tab_bindings.setSource(null);

        // Get our current page which MUST be a Tab object.
        const page = priv.tab_view.getSelectedPage() orelse return;
        const child = page.getChild();
        assert(gobject.ext.isA(child, Tab));

        // Setup our binding group. This ensures things like the title
        // are synced from the active tab.
        priv.tab_bindings.setSource(child.as(gobject.Object));

        // If the tab was previously marked as needing attention
        // (e.g. due to a bell character), we now unmark that
        page.setNeedsAttention(@intFromBool(false));

        if (self.as(gtk.Window).isActive() != 0) self.clearNotificationsFor(page);
    }

    fn tabViewPageReordered(
        _: *adw.TabView,
        _: *adw.TabPage,
        _: c_int,
        self: *Self,
    ) callconv(.c) void {
        self.scheduleSidebarRebuild();
    }

    fn pageSidebarPropChanged(
        _: *adw.TabPage,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.scheduleSidebarRebuild();
    }

    /// Name a group that started before its shell reported a directory.
    fn surfacePwdChanged(
        surface: *Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const view = ext.getAncestor(adw.TabView, surface.as(gtk.Widget)) orelse return;
        const ws = self.workspaceForView(view) orelse return;
        const group = self.findGroup(ws.group_id) orelse return;
        if (group.dir != null) return;
        const pwd = surface.getPwd() orelse return;
        setGroupDir(group, pwd);
        self.scheduleSidebarRebuild();
    }

    fn tabViewPageAttached(
        _: *adw.TabView,
        page: *adw.TabPage,
        _: c_int,
        self: *Self,
    ) callconv(.c) void {
        // Get the attached page which must be a Tab object.
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return;

        // Attach listeners for the tab.
        _ = Tab.signals.@"close-request".connect(
            tab,
            *Self,
            tabCloseRequest,
            self,
            .{},
        );

        // Attach listeners for the surface.
        //
        // Interesting behavior here that was previously undocumented but
        // I'm going to make it explicit here: we accept all the signals here
        // (like toggle-fullscreen) regardless of whether the surface or tab
        // is focused. At the time of writing this we have no API that could
        // really trigger these that way but its theoretically possible.
        //
        // What is DEFINITELY possible is something like OSC52 triggering
        // a clipboard-write signal on an unfocused tab/surface. We definitely
        // want to show the user a notification about that but our notification
        // right now is a toast that doesn't make it clear WHO used the
        // clipboard. We probably want to change that in the future.
        //
        // I'm not sure how desirable all the above is, and we probably
        // should be thoughtful about future signals here. But all of this
        // behavior is consistent with macOS and the previous GTK apprt,
        // but that behavior was all implicit and not documented, so here
        // I am.
        if (tab.getSurfaceTree()) |tree| {
            self.connectSurfaceHandlers(tree);
        }

        // A background tab's bell shows on its sidebar row.
        _ = gobject.Object.signals.notify.connect(
            page,
            *Self,
            pageSidebarPropChanged,
            self,
            .{ .detail = "needs-attention" },
        );
        self.scheduleSidebarRebuild();
    }

    fn tabViewPageDetached(
        _: *adw.TabView,
        page: *adw.TabPage,
        _: c_int,
        self: *Self,
    ) callconv(.c) void {
        // We need to get the tab to disconnect the signals.
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return;
        _ = gobject.signalHandlersDisconnectMatched(
            tab.as(gobject.Object),
            .{ .data = true },
            0,
            0,
            null,
            null,
            self,
        );

        _ = gobject.signalHandlersDisconnectMatched(
            page.as(gobject.Object),
            .{ .data = true },
            0,
            0,
            null,
            null,
            self,
        );

        // Remove the tree handlers
        if (tab.getSurfaceTree()) |tree| {
            self.disconnectSurfaceHandlers(tree);
        }

        self.scheduleSidebarRebuild();
    }

    fn tabViewCreateWindow(
        _: *adw.TabView,
        _: *Self,
    ) callconv(.c) ?*adw.TabView {
        // Create a new window without creating a new tab.
        const win = gobject.ext.newInstance(
            Self,
            .{
                .application = Application.default(),
            },
        );

        // We have to show it otherwise it'll just be hidden.
        gtk.Window.present(win.as(gtk.Window));

        // Get our tab view
        return win.private().tab_view;
    }

    fn tabCloseRequest(
        tab: *Tab,
        self: *Self,
    ) callconv(.c) void {
        _ = self;
        // The tab's own view: it may be in a sidebar tab that isn't shown.
        const view = ext.getAncestor(adw.TabView, tab.as(gtk.Widget)) orelse return;
        // TODO: connect close page handler to tab to check for confirmation
        view.closePage(view.getPage(tab.as(gtk.Widget)));
    }

    fn tabViewNPages(
        view: *adw.TabView,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        // Counts on sidebar rows; empty sidebar tabs are pruned on idle.
        self.scheduleSidebarRebuild();
        if (view.getNPages() != 0) return;

        // Another sidebar tab still has tabs: show it instead of closing.
        if (view == priv.tab_view) {
            for (priv.workspaces.items) |ws| {
                if (ws.view.getNPages() == 0) continue;
                self.activateWorkspace(ws.id);
                return;
            }
        } else return;

        {
            // If we have no pages left then we want to close window.

            // If the tab overview is open, then we don't close the window
            // because its a rather abrupt experience. This also fixes an
            // issue where dragging out the last tab in the tab overview
            // won't cause Ghostty to exit.
            if (priv.tab_overview.getOpen() != 0) return;

            self.as(gtk.Window).close();
        }
    }
    fn setupTabMenu(
        _: *adw.TabView,
        page: ?*adw.TabPage,
        self: *Self,
    ) callconv(.c) void {
        self.private().context_menu_page = page;
    }

    fn surfaceClipboardWrite(
        _: *Surface,
        clipboard_type: apprt.Clipboard,
        text: [*:0]const u8,
        self: *Self,
    ) callconv(.c) void {
        // We only toast for the standard clipboard.
        if (clipboard_type != .standard) return;

        // We only toast if configured to
        const priv = self.private();
        const config_obj = priv.config orelse return;
        const config = config_obj.get();
        if (!config.@"app-notifications".@"clipboard-copy") {
            return;
        }

        if (text[0] != 0)
            self.addToast(i18n._("Copied to clipboard"))
        else
            self.addToast(i18n._("Cleared clipboard"));
    }

    fn surfaceMenu(
        _: *Surface,
        self: *Self,
    ) callconv(.c) void {
        self.syncActions();
    }

    fn surfacePresentRequest(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        // Verify that this surface is actually in this window.
        {
            const surface_window = ext.getAncestor(
                Self,
                surface.as(gtk.Widget),
            ) orelse {
                log.warn(
                    "present request called for non-existent surface",
                    .{},
                );
                return;
            };
            if (surface_window != self) {
                log.warn(
                    "present request called for surface in different window",
                    .{},
                );
                return;
            }
        }

        // Get the tab for this surface.
        const tab = ext.getAncestor(
            Tab,
            surface.as(gtk.Widget),
        ) orelse {
            log.warn("present request surface not found", .{});
            return;
        };

        // Get the page that contains this tab, showing its sidebar tab.
        const priv = self.private();
        const tab_view = ext.getAncestor(adw.TabView, tab.as(gtk.Widget)) orelse priv.tab_view;
        if (self.workspaceForView(tab_view)) |ws| {
            if (tab_view != priv.tab_view) self.activateWorkspace(ws.id);
        }
        const page = tab_view.getPage(tab.as(gtk.Widget));
        tab_view.setSelectedPage(page);

        // Grab focus
        surface.grabFocus();

        // Bring the window to the front.
        self.as(gtk.Window).present();
    }

    fn surfaceToggleFullscreen(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        _ = surface;
        if (self.as(gtk.Window).isFullscreen() != 0) {
            self.as(gtk.Window).unfullscreen();
        } else {
            self.as(gtk.Window).fullscreen();
        }

        // We react to the changes in the propFullscreen callback
    }

    fn surfaceToggleMaximize(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        _ = surface;
        if (self.as(gtk.Window).isMaximized() != 0) {
            self.as(gtk.Window).unmaximize();
        } else {
            self.as(gtk.Window).maximize();
        }

        // We react to the changes in the propMaximized callback
    }

    fn surfaceInit(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();

        // Make sure we init only once
        if (priv.surface_init) return;
        priv.surface_init = true;

        // Setup our default and minimum size.
        if (surface.getDefaultSize()) |size| {
            self.as(gtk.Window).setDefaultSize(
                @intCast(size.width),
                @intCast(size.height),
            );
        }
        if (surface.getMinSize()) |size| {
            self.as(gtk.Widget).setSizeRequest(
                @intCast(size.width),
                @intCast(size.height),
            );
        }
    }

    fn tabSplitTreeChanged(
        _: *SplitTree,
        old_tree: ?*const Surface.Tree,
        new_tree: ?*const Surface.Tree,
        self: *Self,
    ) callconv(.c) void {
        if (old_tree) |tree| {
            self.disconnectSurfaceHandlers(tree);
        }

        if (new_tree) |tree| {
            self.connectSurfaceHandlers(tree);
        }

        self.scheduleSidebarRebuild();
    }

    fn actionAbout(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const name = "Ghostty";
        const icon = "com.mitchellh.ghostty";
        const website = "https://ghostty.org";

        if (adw_version.supportsDialogs()) {
            adw.showAboutDialog(
                self.as(gtk.Widget),
                "application-name",
                name,
                "developer-name",
                i18n._("Ghostty Developers"),
                "application-icon",
                icon,
                "version",
                build_config.version_string.ptr,
                "issue-url",
                "https://github.com/ghostty-org/ghostty/issues",
                "website",
                website,
                @as(?*anyopaque, null),
            );
        } else {
            gtk.showAboutDialog(
                self.as(gtk.Window),
                "program-name",
                name,
                "logo-icon-name",
                icon,
                "title",
                i18n._("About Ghostty"),
                "version",
                build_config.version_string.ptr,
                "website",
                website,
                @as(?*anyopaque, null),
            );
        }
    }

    fn actionClose(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        self.as(gtk.Window).close();
    }

    fn actionCloseTab(
        _: *gio.SimpleAction,
        param_: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        const param = param_ orelse {
            log.warn("win.close-tab called without a parameter", .{});
            return;
        };

        var str: ?[*:0]const u8 = null;
        param.get("&s", &str);

        const mode = std.meta.stringToEnum(
            input.Binding.Action.CloseTabMode,
            std.mem.span(
                str orelse {
                    log.warn("invalid mode provided to win.close-tab", .{});
                    return;
                },
            ),
        ) orelse {
            log.warn("invalid mode provided to win.close-tab: {s}", .{str.?});
            return;
        };

        self.performBindingAction(.{ .close_tab = mode });
    }

    fn actionNewWindow(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.new_window);
    }

    fn actionNewTab(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.new_tab);
    }

    fn actionPromptContextTabTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const page = priv.context_menu_page orelse return;
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return;
        tab.promptTabTitle();
    }

    fn actionPromptSurfaceTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.prompt_surface_title);
    }

    fn actionPromptTabTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.prompt_tab_title);
    }

    fn actionSplitRight(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .right });
    }

    fn actionSplitLeft(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .left });
    }

    fn actionSplitUp(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .up });
    }

    fn actionSplitDown(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .down });
    }

    fn actionCopy(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .copy_to_clipboard = .mixed });
    }

    fn actionPaste(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.paste_from_clipboard);
    }

    fn actionReset(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.reset);
    }

    fn actionClear(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.clear_screen);
    }

    fn actionRingBell(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return;

        if (config.@"bell-features".system) system: {
            const native = self.as(gtk.Native).getSurface() orelse {
                log.warn("unable to get native surface from window", .{});
                break :system;
            };
            native.beep();
        }

        if (config.@"bell-features".attention) attention: {
            // Dont set urgency if the window is already active.
            if (self.as(gtk.Window).isActive() != 0) break :attention;

            // Request user attention
            self.winproto().setUrgent(true) catch |err| {
                log.warn("winproto failed to set urgency={}", .{err});
            };
        }
    }

    /// Toggle the command palette.
    ///
    /// TODO: accept the surface that toggled the command palette as a parameter
    fn toggleCommandPalette(self: *Window) void {
        const priv = self.private();

        // Get a reference to a command palette. First check the weak reference
        // that we save to see if we already have one stored. If we don't then
        // create a new one.
        const command_palette = priv.command_palette.get() orelse command_palette: {
            // Create a fresh command palette.
            const command_palette = CommandPalette.new();

            // Synchronize our config to the command palette's config.
            _ = gobject.Object.bindProperty(
                self.as(gobject.Object),
                "config",
                command_palette.as(gobject.Object),
                "config",
                .{ .sync_create = true },
            );

            // Listen to the activate signal to know if the user selected an option in
            // the command palette.
            _ = CommandPalette.signals.trigger.connect(
                command_palette,
                *Window,
                signalCommandPaletteTrigger,
                self,
                .{},
            );

            // Save a weak reference to the command palette. We use a weak reference to avoid
            // reference counting cycles that might cause problems later.
            priv.command_palette.set(command_palette);

            break :command_palette command_palette;
        };
        defer command_palette.unref();

        // Tell the command palette to toggle itself. If the dialog gets
        // presented (instead of hidden) it will be modal over our window.
        command_palette.toggle(self);
    }

    // React to a signal from a command palette asking an action to be performed.
    fn signalCommandPaletteTrigger(_: *CommandPalette, action: *const input.Binding.Action, self: *Self) callconv(.c) void {
        // If the activation actually has an action, perform it.
        self.performBindingAction(action.*);
    }

    /// React to a GTK action requesting that the command palette be toggled.
    fn actionToggleCommandPalette(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        // TODO: accept the surface that toggled the command palette as a
        // parameter
        self.toggleCommandPalette();
    }

    /// Toggle the Ghostty inspector for the active surface.
    fn toggleInspector(self: *Self) void {
        const surface = self.getActiveSurface() orelse return;
        _ = surface.controlInspector(.toggle);
    }

    /// React to a GTK action requesting that the Ghostty inspector be toggled.
    fn actionToggleInspector(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        // TODO: accept the surface that toggled the command palette as a
        // parameter
        self.toggleInspector();
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(DebugWarning);
            gobject.ext.ensureType(SplitTree);
            gobject.ext.ensureType(Surface);
            gobject.ext.ensureType(Tab);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "window",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.@"active-surface".impl,
                properties.config.impl,
                properties.debug.impl,
                properties.@"headerbar-visible".impl,
                properties.@"quick-terminal".impl,
                properties.@"tabs-autohide".impl,
                properties.@"tabs-visible".impl,
                properties.@"tabs-wide".impl,
                properties.@"toolbar-style".impl,
                properties.@"titlebar-style".impl,
            });

            // Bindings
            class.bindTemplateChildPrivate("tab_overview", .{});
            class.bindTemplateChildPrivate("tab_bar", .{});
            class.bindTemplateChildPrivate("tab_stack", .{});
            class.bindTemplateChildPrivate("tab_context_menu", .{});
            class.bindTemplateChildPrivate("sidebar_paned", .{});
            class.bindTemplateChildPrivate("sidebar_box", .{});
            class.bindTemplateChildPrivate("sidebar_rail", .{});
            class.bindTemplateChildPrivate("sidebar_list", .{});
            class.bindTemplateChildPrivate("toolbar", .{});
            class.bindTemplateChildPrivate("toast_overlay", .{});
            class.bindTemplateChildPrivate("content_box", .{});

            // Template Callbacks
            class.bindTemplateCallback("realize", &windowRealize);
            class.bindTemplateCallback("new_tab", &btnNewTab);
            class.bindTemplateCallback("overview_create_tab", &tabOverviewCreateTab);
            class.bindTemplateCallback("overview_notify_open", &tabOverviewOpen);
            class.bindTemplateCallback("close_request", &windowCloseRequest);
            class.bindTemplateCallback("sidebar_row_activated", &sidebarRowActivated);
            class.bindTemplateCallback("sidebar_paned_position", &sidebarPanedPosition);
            class.bindTemplateCallback("notify_config", &propConfig);
            class.bindTemplateCallback("notify_fullscreened", &propFullscreened);
            class.bindTemplateCallback("notify_is_active", &propIsActive);
            class.bindTemplateCallback("notify_maximized", &propMaximized);
            class.bindTemplateCallback("notify_menu_active", &propMenuActive);
            class.bindTemplateCallback("notify_quick_terminal", &propQuickTerminal);
            class.bindTemplateCallback("notify_scale_factor", &propScaleFactor);
            class.bindTemplateCallback("titlebar_style_is_tabs", &closureTitlebarStyleIsTab);
            class.bindTemplateCallback("computed_subtitle", &closureSubtitle);

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
