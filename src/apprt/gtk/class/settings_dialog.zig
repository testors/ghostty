//! The settings dialog: every configuration key as a preferences row,
//! grouped into pages. Changes are written to the user's configuration
//! files by `configpkg.Editor` and the `changed` signal is emitted so
//! the application can reload its configuration.
const std = @import("std");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const configpkg = @import("../../../config.zig");
const i18n = @import("../../../os/main.zig").i18n;
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;

const Editor = configpkg.Editor;
const schema = configpkg.schema;

const log = std.log.scoped(.gtk_ghostty_settings_dialog);

pub const SettingsDialog = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.PreferencesDialog;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySettingsDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const signals = struct {
        /// Emitted after a setting was written. The configuration should
        /// be reloaded to apply it.
        pub const changed = struct {
            pub const name = "changed";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };
    };

    const Private = struct {
        editor: ?*Editor,

        /// Memory for the widgets' callback data. Reset when the whole
        /// dialog is rebuilt.
        arena: std.heap.ArenaAllocator,

        /// The pages we added, so they can be removed on rebuild.
        pages: std.ArrayList(*adw.PreferencesPage),

        /// Theme names, loaded once.
        theme_names: ?[]const [:0]const u8,
        theme_arena: std.heap.ArenaAllocator,

        /// Groups whose rows are rebuilt when their keys change.
        theme_group: ?*DynGroup,
        keybind_groups: ?*KeybindGroups,

        pub var offset: c_int = 0;
    };

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const alloc = Application.default().allocator();
        const priv = self.private();
        priv.* = .{
            .editor = null,
            .arena = .init(alloc),
            .pages = .empty,
            .theme_names = null,
            .theme_arena = .init(alloc),
            .theme_group = null,
            .keybind_groups = null,
        };

        const dialog = self.as(adw.PreferencesDialog);
        dialog.setSearchEnabled(1);
        self.as(adw.Dialog).setTitle(i18n._("Settings"));
        self.as(adw.Dialog).setContentWidth(760);
        self.as(adw.Dialog).setContentHeight(640);

        priv.editor = Editor.create(alloc, .{}) catch |err| editor: {
            log.warn("error loading settings err={}", .{err});
            break :editor null;
        };

        self.rebuild();
    }

    pub fn present(self: *Self, parent: ?*gtk.Widget) void {
        // Pick up any changes made outside the dialog since it was built.
        self.reload();
        self.as(adw.Dialog).present(parent);
    }

    /// Reload the configuration files and rebuild every page.
    pub fn reload(self: *Self) void {
        const priv = self.private();
        if (priv.editor) |editor| editor.reload() catch |err| {
            log.warn("error reloading settings err={}", .{err});
        };
        self.rebuild();
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        // Removing the pages destroys the rows that reference our arena.
        self.clearPages();
        if (priv.editor) |editor| {
            editor.destroy();
            priv.editor = null;
        }

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.pages.deinit(Application.default().allocator());
        priv.arena.deinit();
        priv.theme_arena.deinit();
        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Building

    fn clearPages(self: *Self) void {
        const priv = self.private();
        const dialog = self.as(adw.PreferencesDialog);
        for (priv.pages.items) |page| dialog.remove(page);
        priv.pages.clearRetainingCapacity();
        priv.theme_group = null;
        priv.keybind_groups = null;
    }

    fn rebuild(self: *Self) void {
        const priv = self.private();
        const dialog = self.as(adw.PreferencesDialog);

        // Keep the visible page across rebuilds.
        var visible_buf: [64]u8 = undefined;
        const visible: ?[:0]const u8 = if (dialog.getVisiblePageName()) |name|
            std.fmt.bufPrintSentinel(&visible_buf, "{s}", .{std.mem.span(name)}, 0) catch null
        else
            null;

        self.clearPages();
        _ = priv.arena.reset(.retain_capacity);

        self.buildPages() catch |err| {
            log.warn("error building settings dialog err={}", .{err});
        };

        if (visible) |name| dialog.setVisiblePageName(name.ptr);
    }

    fn buildPages(self: *Self) !void {
        const priv = self.private();
        const editor = priv.editor orelse {
            const page = adw.PreferencesPage.new();
            const group = adw.PreferencesGroup.new();
            group.setTitle(i18n._("Settings could not be loaded"));
            group.setDescription(i18n._("Check the log for details or edit the configuration file directly."));
            page.add(group);
            try self.addPage(page);
            return;
        };

        inline for (pages) |p| {
            const page = adw.PreferencesPage.new();
            page.setTitle(p.title);
            page.setIconName(p.icon);
            page.setName(@tagName(p.category));

            switch (p.category) {
                .general => try self.buildFileGroup(page, editor),
                .appearance => try self.buildThemeGroup(page),
                .keybindings => try self.buildKeybindGroups(page),
                else => {},
            }

            try self.buildCategory(page, p.category);
            try self.addPage(page);
        }
    }

    fn addPage(self: *Self, page: *adw.PreferencesPage) !void {
        const priv = self.private();
        try priv.pages.append(Application.default().allocator(), page);
        self.as(adw.PreferencesDialog).add(page);
    }

    /// The curated sections of a category, then everything else of the
    /// category under "Advanced".
    fn buildCategory(self: *Self, page: *adw.PreferencesPage, category: schema.Category) !void {
        const section_list = sections(category);
        for (section_list) |section| {
            const group = adw.PreferencesGroup.new();
            group.setTitle(section.title);
            var any = false;
            for (section.keys) |key| {
                const entry = schema.get(key) orelse continue;
                if (!entry.platform.current()) continue;
                try self.addRow(group, entry);
                any = true;
            }
            if (any) page.add(group) else {
                // Unused groups are floating; sink and drop them.
                _ = group.as(gobject.Object).refSink();
                group.as(gobject.Object).unref();
            }
        }

        const advanced = adw.PreferencesGroup.new();
        advanced.setTitle(if (section_list.len > 0) i18n._("Advanced") else "");
        var any = false;
        for (schema.entries) |*entry| {
            if (entry.category != category) continue;
            if (!entry.platform.current()) continue;
            if (isCustomKey(category, entry.key)) continue;
            if (inSections(section_list, entry.key)) continue;
            try self.addRow(advanced, entry);
            any = true;
        }
        if (any) page.add(advanced) else {
            _ = advanced.as(gobject.Object).refSink();
            advanced.as(gobject.Object).unref();
        }
    }

    /// The configuration file, problems and a button to edit it.
    fn buildFileGroup(self: *Self, page: *adw.PreferencesPage, editor: *Editor) !void {
        const alloc = self.private().arena.allocator();
        const group = adw.PreferencesGroup.new();
        group.setTitle(i18n._("Configuration File"));

        const row = adw.ActionRow.new();
        row.as(adw.PreferencesRow).setTitle(try alloc.dupeSentinel(u8, std.fs.path.basename(editor.primary_path), 0));
        row.setSubtitle(try alloc.dupeSentinel(u8, editor.primary_path, 0));
        row.setSubtitleSelectable(1);

        const reload_button = gtk.Button.newFromIconName("view-refresh-symbolic");
        reload_button.as(gtk.Widget).setTooltipText(i18n._("Reload from disk"));
        reload_button.as(gtk.Widget).setValign(.center);
        reload_button.as(gtk.Widget).addCssClass("flat");
        _ = gtk.Button.signals.clicked.connect(reload_button, *Self, reloadClicked, self, .{});
        row.addSuffix(reload_button.as(gtk.Widget));

        const open_button = gtk.Button.newWithLabel(i18n._("Open in Editor"));
        open_button.as(gtk.Widget).setValign(.center);
        _ = gtk.Button.signals.clicked.connect(open_button, *Self, openClicked, self, .{});
        row.addSuffix(open_button.as(gtk.Widget));
        group.add(row.as(gtk.Widget));

        if (editor.config) |*cfg| {
            const diags = cfg._diagnostics.items();
            if (diags.len > 0) {
                const expander = adw.ExpanderRow.new();
                expander.as(adw.PreferencesRow).setTitle(try std.fmt.allocPrintSentinel(
                    alloc,
                    "{d} problem(s) in the configuration",
                    .{diags.len},
                    0,
                ));
                expander.as(gtk.Widget).addCssClass("warning");
                for (diags) |*diag| {
                    var buf: std.Io.Writer.Allocating = .init(alloc);
                    diag.format(&buf.writer) catch continue;
                    const msg_row = adw.ActionRow.new();
                    msg_row.as(adw.PreferencesRow).setTitle(try alloc.dupeSentinel(u8, buf.written(), 0));
                    msg_row.as(adw.PreferencesRow).setTitleSelectable(1);
                    msg_row.as(adw.PreferencesRow).setUseMarkup(0);
                    expander.addRow(msg_row.as(gtk.Widget));
                }
                group.add(expander.as(gtk.Widget));
            }
        }

        page.add(group);
    }

    fn reloadClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.reload();
    }

    fn openClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        _ = self.as(gtk.Widget).activateActionVariant(
            "app.open-config",
            glib.Variant.newString("os-open"),
        );
    }

    //---------------------------------------------------------------
    // Rows

    const RowKind = enum {
        switch_row,
        bool_combo,
        combo,
        spin,
        entry,
        color,
        flags,
        repeatable,
    };

    /// Callback data for a row. Allocated in the dialog arena.
    const RowCtx = struct {
        dialog: *Self,
        entry: *const schema.Entry,
        kind: RowKind,

        /// The row widget itself.
        row: *gtk.Widget,

        /// Shown when the key is set in a file.
        reset: *gtk.Button,

        /// For combos: the value of each position ("" means default).
        combo_values: []const []const u8 = &.{},

        /// For flags: one switch per flag.
        flag_rows: []*adw.SwitchRow = &.{},

        /// For colors: the color button.
        color_button: ?*gtk.ColorDialogButton = null,

        /// For repeatables: the child rows we added.
        children: std.ArrayList(*gtk.Widget) = .empty,

        /// Set while we update widgets so their signals are ignored.
        updating: bool = false,
    };

    const ChildCtx = struct {
        parent: *RowCtx,
        path: [:0]const u8,
        line: usize,
    };

    fn addRow(self: *Self, group: *adw.PreferencesGroup, entry: *const schema.Entry) !void {
        const alloc = self.private().arena.allocator();
        const title = try alloc.dupeSentinel(u8, try schema.label(alloc, entry), 0);

        const reset = gtk.Button.newFromIconName("edit-undo-symbolic");
        reset.as(gtk.Widget).setTooltipText(i18n._("Reset to default"));
        reset.as(gtk.Widget).setValign(.center);
        reset.as(gtk.Widget).addCssClass("flat");

        const ctx = try alloc.create(RowCtx);
        ctx.* = .{
            .dialog = self,
            .entry = entry,
            .kind = undefined,
            .row = undefined,
            .reset = reset,
        };

        if (entry.repeatable) {
            const row = adw.ExpanderRow.new();
            row.as(adw.PreferencesRow).setTitle(title);
            row.addSuffix(reset.as(gtk.Widget));
            ctx.kind = .repeatable;
            ctx.row = row.as(gtk.Widget);
        } else switch (entry.kind) {
            .bool => if (entry.optional) {
                const row = adw.ComboRow.new();
                row.as(adw.PreferencesRow).setTitle(title);
                ctx.combo_values = &.{ "", "true", "false" };
                const model = gtk.StringList.new(null);
                model.append(i18n._("Default"));
                model.append(i18n._("On"));
                model.append(i18n._("Off"));
                row.setModel(model.as(gio.ListModel));
                row.as(adw.ActionRow).addSuffix(reset.as(gtk.Widget));
                ctx.kind = .bool_combo;
                ctx.row = row.as(gtk.Widget);
                _ = gobject.Object.signals.notify.connect(row, *RowCtx, comboChanged, ctx, .{ .detail = "selected" });
            } else {
                const row = adw.SwitchRow.new();
                row.as(adw.PreferencesRow).setTitle(title);
                row.as(adw.ActionRow).addSuffix(reset.as(gtk.Widget));
                ctx.kind = .switch_row;
                ctx.row = row.as(gtk.Widget);
                _ = gobject.Object.signals.notify.connect(row, *RowCtx, switchChanged, ctx, .{ .detail = "active" });
            },

            .@"enum" => {
                const row = adw.ComboRow.new();
                row.as(adw.PreferencesRow).setTitle(title);
                const model = gtk.StringList.new(null);
                var values: std.ArrayList([]const u8) = .empty;
                if (entry.optional) {
                    try values.append(alloc, "");
                    model.append(i18n._("Default"));
                }
                for (entry.values) |v| {
                    try values.append(alloc, v);
                    model.append(try prettify(alloc, v));
                }
                ctx.combo_values = values.items;
                row.setModel(model.as(gio.ListModel));
                row.as(adw.ActionRow).addSuffix(reset.as(gtk.Widget));
                ctx.kind = .combo;
                ctx.row = row.as(gtk.Widget);
                _ = gobject.Object.signals.notify.connect(row, *RowCtx, comboChanged, ctx, .{ .detail = "selected" });
            },

            .flags => {
                const row = adw.ExpanderRow.new();
                row.as(adw.PreferencesRow).setTitle(title);
                row.addSuffix(reset.as(gtk.Widget));
                const flag_rows = try alloc.alloc(*adw.SwitchRow, entry.flags.len);
                for (entry.flags, flag_rows) |flag, *flag_row| {
                    flag_row.* = adw.SwitchRow.new();
                    flag_row.*.as(adw.PreferencesRow).setTitle(try prettify(alloc, flag));
                    row.addRow(flag_row.*.as(gtk.Widget));
                    _ = gobject.Object.signals.notify.connect(flag_row.*, *RowCtx, flagChanged, ctx, .{ .detail = "active" });
                }
                ctx.flag_rows = flag_rows;
                ctx.kind = .flags;
                ctx.row = row.as(gtk.Widget);
            },

            .float => if (isFraction(entry.key)) {
                const row = adw.SpinRow.newWithRange(0, 1, 0.05);
                row.as(adw.PreferencesRow).setTitle(title);
                row.setDigits(2);
                row.as(adw.ActionRow).addSuffix(reset.as(gtk.Widget));
                ctx.kind = .spin;
                ctx.row = row.as(gtk.Widget);
                _ = gobject.Object.signals.notify.connect(row, *RowCtx, spinChanged, ctx, .{ .detail = "value" });
            } else {
                try self.entryRow(ctx, title);
            },

            .color => {
                const row = adw.ActionRow.new();
                row.as(adw.PreferencesRow).setTitle(title);
                const button = gtk.ColorDialogButton.new(gtk.ColorDialog.new());
                button.as(gtk.Widget).setValign(.center);
                row.addSuffix(button.as(gtk.Widget));
                row.addSuffix(reset.as(gtk.Widget));
                ctx.color_button = button;
                ctx.kind = .color;
                ctx.row = row.as(gtk.Widget);
                _ = gobject.Object.signals.notify.connect(button, *RowCtx, colorChanged, ctx, .{ .detail = "rgba" });
            },

            else => try self.entryRow(ctx, title),
        }

        // When the change applies, as an icon next to the title.
        if (applyNote(entry.apply)) |note| {
            const icon = gtk.Image.newFromIconName(if (entry.apply == .restart)
                "system-reboot-symbolic"
            else
                "document-new-symbolic");
            icon.as(gtk.Widget).setTooltipText(note);
            icon.as(gtk.Widget).addCssClass("dim-label");
            switch (ctx.kind) {
                .flags, .repeatable => gobject.ext.cast(adw.ExpanderRow, ctx.row).?.addPrefix(icon.as(gtk.Widget)),
                .entry => gobject.ext.cast(adw.EntryRow, ctx.row).?.addPrefix(icon.as(gtk.Widget)),
                else => gobject.ext.cast(adw.ActionRow, ctx.row).?.addPrefix(icon.as(gtk.Widget)),
            }
        }

        const summary = try schema.summary(alloc, entry);
        ctx.row.setTooltipText(try alloc.dupeSentinel(u8, summary, 0));
        _ = gtk.Button.signals.clicked.connect(reset, *RowCtx, resetClicked, ctx, .{});

        self.sync(ctx);
        group.add(ctx.row);
    }

    fn entryRow(self: *Self, ctx: *RowCtx, title: [:0]const u8) !void {
        _ = self;
        const row = adw.EntryRow.new();
        row.as(adw.PreferencesRow).setTitle(title);
        row.setShowApplyButton(1);
        row.addSuffix(ctx.reset.as(gtk.Widget));
        ctx.kind = .entry;
        ctx.row = row.as(gtk.Widget);
        _ = adw.EntryRow.signals.apply.connect(row, *RowCtx, entryApplied, ctx, .{});
    }

    /// Update a row's widgets from the current configuration.
    fn sync(self: *Self, ctx: *RowCtx) void {
        const priv = self.private();
        const editor = priv.editor orelse return;
        const alloc = priv.arena.allocator();
        const key = ctx.entry.key;
        const value = editor.effectiveValue(alloc, key) catch "";
        const modified = editor.isModified(key);

        ctx.updating = true;
        defer ctx.updating = false;

        switch (ctx.kind) {
            .switch_row => {
                const row = gobject.ext.cast(adw.SwitchRow, ctx.row).?;
                row.setActive(@intFromBool(std.mem.eql(u8, value, "true")));
            },

            .bool_combo, .combo => {
                const row = gobject.ext.cast(adw.ComboRow, ctx.row).?;
                var selected: c_uint = 0;
                for (ctx.combo_values, 0..) |v, i| {
                    if (std.mem.eql(u8, v, value)) selected = @intCast(i);
                }
                row.setSelected(selected);
            },

            .spin => {
                const row = gobject.ext.cast(adw.SpinRow, ctx.row).?;
                row.setValue(std.fmt.parseFloat(f64, value) catch 1);
            },

            .entry => {
                const row = gobject.ext.cast(adw.EntryRow, ctx.row).?;
                const text = alloc.dupeSentinel(u8, value, 0) catch "";
                row.as(gtk.Editable).setText(text);
                row.as(gtk.Widget).removeCssClass("error");
            },

            .color => if (ctx.color_button) |button| {
                var rgba: gdk.RGBA = undefined;
                const spec = alloc.dupeSentinel(u8, value, 0) catch "";
                if (rgba.parse(spec) != 0) button.setRgba(&rgba);
            },

            .flags => {
                for (ctx.entry.flags, ctx.flag_rows) |flag, row| {
                    row.setActive(@intFromBool(flagEnabled(value, flag)));
                }
            },

            .repeatable => self.syncRepeatable(ctx) catch |err| {
                log.warn("error building repeatable row err={}", .{err});
            },
        }

        // Status: whether it's changed, where and when it applies.
        var status: std.Io.Writer.Allocating = .init(alloc);
        if (modified) {
            status.writer.writeAll(std.mem.span(i18n._("Changed"))) catch {};
            if (editor.lastFileEntry(key)) |origin| {
                if (!std.mem.eql(u8, origin.path, editor.primary_path)) {
                    status.writer.print(" · {s}:{d}", .{ std.fs.path.basename(origin.path), origin.line }) catch {};
                }
            }
        }
        if (editor.isSetByCli(key)) {
            if (status.written().len > 0) status.writer.writeAll(" · ") catch {};
            status.writer.writeAll(std.mem.span(i18n._("Set on the command line"))) catch {};
        }
        const status_text = alloc.dupeSentinel(u8, status.written(), 0) catch "";

        switch (ctx.kind) {
            .switch_row, .bool_combo, .combo, .spin, .color => {
                gobject.ext.cast(adw.ActionRow, ctx.row).?.setSubtitle(status_text);
            },
            .flags, .repeatable => {
                gobject.ext.cast(adw.ExpanderRow, ctx.row).?.setSubtitle(status_text);
            },
            .entry => if (status_text.len > 0) {
                const summary = schema.summary(alloc, ctx.entry) catch "";
                const tooltip = std.fmt.allocPrintSentinel(alloc, "{s}\n\n{s}", .{ status_text, summary }, 0) catch status_text;
                ctx.row.setTooltipText(tooltip);
            },
        }

        ctx.reset.as(gtk.Widget).setVisible(@intFromBool(modified));
    }

    fn syncRepeatable(self: *Self, ctx: *RowCtx) !void {
        const priv = self.private();
        const editor = priv.editor orelse return;
        const alloc = priv.arena.allocator();
        const expander = gobject.ext.cast(adw.ExpanderRow, ctx.row).?;

        for (ctx.children.items) |child| expander.remove(child);
        ctx.children.clearRetainingCapacity();

        const entries = try editor.fileEntries(alloc, ctx.entry.key);
        for (entries) |entry| {
            const child = try alloc.create(ChildCtx);
            child.* = .{
                .parent = ctx,
                .path = try alloc.dupeSentinel(u8, entry.path, 0),
                .line = entry.line,
            };

            const row = adw.EntryRow.new();
            row.as(adw.PreferencesRow).setTitle(try std.fmt.allocPrintSentinel(
                alloc,
                "{s}:{d}",
                .{ std.fs.path.basename(entry.path), entry.line },
                0,
            ));
            row.as(gtk.Editable).setText(try alloc.dupeSentinel(u8, entry.value orelse "", 0));
            row.setShowApplyButton(1);
            _ = adw.EntryRow.signals.apply.connect(row, *ChildCtx, childApplied, child, .{});

            const remove = gtk.Button.newFromIconName("list-remove-symbolic");
            remove.as(gtk.Widget).setTooltipText(i18n._("Remove"));
            remove.as(gtk.Widget).setValign(.center);
            remove.as(gtk.Widget).addCssClass("flat");
            _ = gtk.Button.signals.clicked.connect(remove, *ChildCtx, childRemoved, child, .{});
            row.addSuffix(remove.as(gtk.Widget));

            expander.addRow(row.as(gtk.Widget));
            try ctx.children.append(alloc, row.as(gtk.Widget));
        }

        const add = adw.EntryRow.new();
        add.as(adw.PreferencesRow).setTitle(i18n._("Add a value"));
        add.setShowApplyButton(1);
        _ = adw.EntryRow.signals.apply.connect(add, *RowCtx, repeatableAdded, ctx, .{});
        expander.addRow(add.as(gtk.Widget));
        try ctx.children.append(alloc, add.as(gtk.Widget));
    }

    //---------------------------------------------------------------
    // Writing

    /// Write a value and update the row. Shows a toast on failure.
    fn write(self: *Self, ctx: *RowCtx, value: ?[]const u8) void {
        const priv = self.private();
        const editor = priv.editor orelse return;
        const key = ctx.entry.key;

        const result = if (value) |v|
            editor.set(key, v)
        else
            editor.reset(key);

        result catch |err| {
            self.showError(editor, err);
            self.sync(ctx);
            if (ctx.kind == .entry) ctx.row.addCssClass("error");
            return;
        };

        self.sync(ctx);
        self.emitChanged();
    }

    fn showError(self: *Self, editor: *Editor, err: anyerror) void {
        const alloc = self.private().arena.allocator();
        const message = editor.lastMessage();
        const text = if (message.len > 0)
            alloc.dupeSentinel(u8, message, 0) catch "Error"
        else
            std.fmt.allocPrintSentinel(alloc, "Error: {t}", .{err}, 0) catch "Error";
        const toast = adw.Toast.new(text);
        toast.setUseMarkup(0);
        self.as(adw.PreferencesDialog).addToast(toast);
    }

    fn emitChanged(self: *Self) void {
        signals.changed.impl.emit(self, null, .{}, null);
    }

    fn switchChanged(row: *adw.SwitchRow, _: *gobject.ParamSpec, ctx: *RowCtx) callconv(.c) void {
        if (ctx.updating) return;
        ctx.dialog.write(ctx, if (row.getActive() != 0) "true" else "false");
    }

    fn comboChanged(row: *adw.ComboRow, _: *gobject.ParamSpec, ctx: *RowCtx) callconv(.c) void {
        if (ctx.updating) return;
        const selected = row.getSelected();
        if (selected >= ctx.combo_values.len) return;
        const value = ctx.combo_values[selected];
        ctx.dialog.write(ctx, if (value.len == 0) null else value);
    }

    fn spinChanged(row: *adw.SpinRow, _: *gobject.ParamSpec, ctx: *RowCtx) callconv(.c) void {
        if (ctx.updating) return;
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d:.2}", .{row.getValue()}) catch return;
        ctx.dialog.write(ctx, text);
    }

    fn entryApplied(row: *adw.EntryRow, ctx: *RowCtx) callconv(.c) void {
        if (ctx.updating) return;
        const text = std.mem.span(row.as(gtk.Editable).getText());
        ctx.dialog.write(ctx, if (text.len == 0 and ctx.entry.optional) null else text);
    }

    fn colorChanged(button: *gtk.ColorDialogButton, _: *gobject.ParamSpec, ctx: *RowCtx) callconv(.c) void {
        if (ctx.updating) return;
        const rgba = button.getRgba();
        var buf: [8]u8 = undefined;
        const hex = std.fmt.bufPrint(&buf, "#{x:0>2}{x:0>2}{x:0>2}", .{
            channel(rgba.f_red),
            channel(rgba.f_green),
            channel(rgba.f_blue),
        }) catch return;
        ctx.dialog.write(ctx, hex);
    }

    fn flagChanged(_: *adw.SwitchRow, _: *gobject.ParamSpec, ctx: *RowCtx) callconv(.c) void {
        if (ctx.updating) return;
        const alloc = ctx.dialog.private().arena.allocator();
        var buf: std.Io.Writer.Allocating = .init(alloc);
        for (ctx.entry.flags, ctx.flag_rows, 0..) |flag, row, i| {
            if (i > 0) buf.writer.writeByte(',') catch return;
            if (row.getActive() == 0) buf.writer.writeAll("no-") catch return;
            buf.writer.writeAll(flag) catch return;
        }
        ctx.dialog.write(ctx, buf.written());
    }

    fn resetClicked(_: *gtk.Button, ctx: *RowCtx) callconv(.c) void {
        ctx.dialog.write(ctx, null);
    }

    fn childApplied(row: *adw.EntryRow, child: *ChildCtx) callconv(.c) void {
        const ctx = child.parent;
        const self = ctx.dialog;
        const editor = self.private().editor orelse return;
        const text = std.mem.span(row.as(gtk.Editable).getText());
        editor.replaceEntry(ctx.entry.key, child.path, child.line, text) catch |err| {
            self.showError(editor, err);
            row.as(gtk.Widget).addCssClass("error");
            return;
        };
        self.afterListChange(ctx);
    }

    fn childRemoved(_: *gtk.Button, child: *ChildCtx) callconv(.c) void {
        const ctx = child.parent;
        const self = ctx.dialog;
        const editor = self.private().editor orelse return;
        editor.removeEntry(ctx.entry.key, child.path, child.line) catch |err| {
            self.showError(editor, err);
            return;
        };
        self.afterListChange(ctx);
    }

    fn repeatableAdded(row: *adw.EntryRow, ctx: *RowCtx) callconv(.c) void {
        const self = ctx.dialog;
        const editor = self.private().editor orelse return;
        const text = std.mem.span(row.as(gtk.Editable).getText());
        if (text.len == 0) return;
        editor.add(ctx.entry.key, text) catch |err| {
            self.showError(editor, err);
            row.as(gtk.Widget).addCssClass("error");
            return;
        };
        self.afterListChange(ctx);
    }

    fn afterListChange(self: *Self, ctx: *RowCtx) void {
        // Rebuilding the rows of the expander from inside one of its
        // children's signal handlers would destroy the emitting widget,
        // so do it on the next main loop iteration.
        _ = glib.idleAddOnce(idleSync, ctx);
        self.emitChanged();
    }

    fn idleSync(data: ?*anyopaque) callconv(.c) void {
        const ctx: *RowCtx = @ptrCast(@alignCast(data orelse return));
        ctx.dialog.sync(ctx);
    }

    //---------------------------------------------------------------
    // Theme

    /// A group whose rows are rebuilt when its settings change.
    const DynGroup = struct {
        dialog: *Self,
        group: *adw.PreferencesGroup,
        rows: std.ArrayList(*gtk.Widget) = .empty,
        updating: bool = false,

        /// For theme combos: which part of the theme the row changes.
        fn clear(self: *DynGroup) void {
            for (self.rows.items) |row| self.group.remove(row);
            self.rows.clearRetainingCapacity();
        }

        fn add(self: *DynGroup, row: *gtk.Widget) !void {
            const alloc = self.dialog.private().arena.allocator();
            self.group.add(row);
            try self.rows.append(alloc, row);
        }
    };

    const ThemeSlot = enum { single, light, dark };

    const ThemeCtx = struct {
        dyn: *DynGroup,
        slot: ThemeSlot,
    };

    fn themeNames(self: *Self) []const [:0]const u8 {
        const priv = self.private();
        if (priv.theme_names) |names| return names;
        const alloc = priv.theme_arena.allocator();
        const list = Editor.themes(alloc) catch return &.{};
        const names = alloc.alloc([:0]const u8, list.len) catch return &.{};
        for (list, names) |t, *name| {
            name.* = alloc.dupeSentinel(u8, t.name, 0) catch "";
        }
        priv.theme_names = names;
        return names;
    }

    fn buildThemeGroup(self: *Self, page: *adw.PreferencesPage) !void {
        const priv = self.private();
        const alloc = priv.arena.allocator();
        const group = adw.PreferencesGroup.new();
        group.setTitle(i18n._("Theme"));
        const dyn = try alloc.create(DynGroup);
        dyn.* = .{ .dialog = self, .group = group };
        priv.theme_group = dyn;
        try self.syncThemeGroup(dyn);
        page.add(group);
    }

    fn syncThemeGroup(self: *Self, dyn: *DynGroup) !void {
        const priv = self.private();
        const editor = priv.editor orelse return;
        const alloc = priv.arena.allocator();
        dyn.clear();
        dyn.updating = true;
        defer dyn.updating = false;

        const value = try editor.effectiveValue(alloc, "theme");
        const theme = parseTheme(value);

        const pair = adw.SwitchRow.new();
        pair.as(adw.PreferencesRow).setTitle(i18n._("Different themes for light and dark mode"));
        pair.setActive(@intFromBool(theme.paired));
        pair.as(gtk.Widget).setSensitive(@intFromBool(value.len > 0));
        _ = gobject.Object.signals.notify.connect(pair, *DynGroup, themePairChanged, dyn, .{ .detail = "active" });
        try dyn.add(pair.as(gtk.Widget));

        if (theme.paired) {
            try self.themeCombo(dyn, .light, i18n._("Light theme"), theme.light);
            try self.themeCombo(dyn, .dark, i18n._("Dark theme"), theme.dark);
        } else {
            try self.themeCombo(dyn, .single, i18n._("Theme"), theme.light);
        }
    }

    fn themeCombo(
        self: *Self,
        dyn: *DynGroup,
        slot: ThemeSlot,
        title: [*:0]const u8,
        current: []const u8,
    ) !void {
        const alloc = self.private().arena.allocator();
        const names = self.themeNames();

        const row = adw.ComboRow.new();
        row.as(adw.PreferencesRow).setTitle(title);
        row.setEnableSearch(1);
        const model = gtk.StringList.new(null);
        model.append(i18n._("Default"));
        var selected: c_uint = 0;
        for (names, 1..) |name, i| {
            model.append(name);
            if (std.mem.eql(u8, name, current)) selected = @intCast(i);
        }
        row.setModel(model.as(gio.ListModel));
        row.setSelected(selected);

        const ctx = try alloc.create(ThemeCtx);
        ctx.* = .{ .dyn = dyn, .slot = slot };
        _ = gobject.Object.signals.notify.connect(row, *ThemeCtx, themeChanged, ctx, .{ .detail = "selected" });
        try dyn.add(row.as(gtk.Widget));
    }

    fn themeChanged(row: *adw.ComboRow, _: *gobject.ParamSpec, ctx: *ThemeCtx) callconv(.c) void {
        const dyn = ctx.dyn;
        if (dyn.updating) return;
        const self = dyn.dialog;
        const priv = self.private();
        const editor = priv.editor orelse return;
        const alloc = priv.arena.allocator();
        const names = self.themeNames();

        const selected = row.getSelected();
        const name: ?[]const u8 = if (selected == 0 or selected > names.len)
            null
        else
            names[selected - 1];

        const current = parseTheme(editor.effectiveValue(alloc, "theme") catch "");
        const result = switch (ctx.slot) {
            .single => if (name) |n| editor.set("theme", n) else editor.reset("theme"),
            .light => editor.set("theme", std.fmt.allocPrint(alloc, "light:{s},dark:{s}", .{
                name orelse current.dark,
                current.dark,
            }) catch return),
            .dark => editor.set("theme", std.fmt.allocPrint(alloc, "light:{s},dark:{s}", .{
                current.light,
                name orelse current.light,
            }) catch return),
        };

        result catch |err| {
            self.showError(editor, err);
            return;
        };
        self.emitChanged();
    }

    fn themePairChanged(row: *adw.SwitchRow, _: *gobject.ParamSpec, dyn: *DynGroup) callconv(.c) void {
        if (dyn.updating) return;
        const self = dyn.dialog;
        const priv = self.private();
        const editor = priv.editor orelse return;
        const alloc = priv.arena.allocator();
        const current = parseTheme(editor.effectiveValue(alloc, "theme") catch "");
        if (current.light.len == 0) return;

        const value = if (row.getActive() != 0)
            std.fmt.allocPrint(alloc, "light:{s},dark:{s}", .{ current.light, current.dark }) catch return
        else
            current.light;

        editor.set("theme", value) catch |err| {
            self.showError(editor, err);
            return;
        };
        self.emitChanged();

        // The rows change shape, rebuild them after this signal returns.
        _ = glib.idleAddOnce(idleThemeSync, dyn);
    }

    fn idleThemeSync(data: ?*anyopaque) callconv(.c) void {
        const dyn: *DynGroup = @ptrCast(@alignCast(data orelse return));
        dyn.dialog.syncThemeGroup(dyn) catch |err| {
            log.warn("error rebuilding theme rows err={}", .{err});
        };
    }

    const ParsedTheme = struct {
        light: []const u8,
        dark: []const u8,
        paired: bool,
    };

    fn parseTheme(value: []const u8) ParsedTheme {
        var light: ?[]const u8 = null;
        var dark: ?[]const u8 = null;
        var it = std.mem.splitScalar(u8, value, ',');
        while (it.next()) |part| {
            const item = std.mem.trim(u8, part, " ");
            if (std.mem.startsWith(u8, item, "light:")) light = std.mem.trim(u8, item["light:".len..], " ");
            if (std.mem.startsWith(u8, item, "dark:")) dark = std.mem.trim(u8, item["dark:".len..], " ");
        }

        if (light == null and dark == null) {
            const single = std.mem.trim(u8, value, " ");
            return .{ .light = single, .dark = single, .paired = false };
        }

        return .{
            .light = light orelse dark.?,
            .dark = dark orelse light.?,
            .paired = true,
        };
    }

    //---------------------------------------------------------------
    // Keybindings

    const KeybindGroups = struct {
        custom: DynGroup,
        all: DynGroup,
    };

    const KeybindCtx = struct {
        dialog: *Self,
        /// For custom entries: the file and line.
        path: ?[:0]const u8 = null,
        line: usize = 0,
        /// For effective bindings: the trigger to unbind.
        trigger: ?[]const u8 = null,
    };

    fn buildKeybindGroups(self: *Self, page: *adw.PreferencesPage) !void {
        const priv = self.private();
        const alloc = priv.arena.allocator();

        const custom = adw.PreferencesGroup.new();
        custom.setTitle(i18n._("Your Keybindings"));
        custom.setDescription(i18n._("Lines written as keybind = trigger=action. Removing a default shortcut writes trigger=unbind."));
        const all = adw.PreferencesGroup.new();
        all.setTitle(i18n._("All Keybindings"));

        const groups = try alloc.create(KeybindGroups);
        groups.* = .{
            .custom = .{ .dialog = self, .group = custom },
            .all = .{ .dialog = self, .group = all },
        };
        priv.keybind_groups = groups;
        try self.syncKeybindGroups(groups);

        page.add(custom);
        page.add(all);
    }

    fn syncKeybindGroups(self: *Self, groups: *KeybindGroups) !void {
        const priv = self.private();
        const editor = priv.editor orelse return;
        const alloc = priv.arena.allocator();
        groups.custom.clear();
        groups.all.clear();

        const entries = try editor.fileEntries(alloc, "keybind");
        for (entries) |entry| {
            const ctx = try alloc.create(KeybindCtx);
            ctx.* = .{
                .dialog = self,
                .path = try alloc.dupeSentinel(u8, entry.path, 0),
                .line = entry.line,
            };

            const row = adw.ActionRow.new();
            row.as(adw.PreferencesRow).setTitle(try alloc.dupeSentinel(u8, entry.value orelse "", 0));
            row.as(adw.PreferencesRow).setUseMarkup(0);
            row.setSubtitle(try std.fmt.allocPrintSentinel(
                alloc,
                "{s}:{d}",
                .{ std.fs.path.basename(entry.path), entry.line },
                0,
            ));
            const remove = gtk.Button.newFromIconName("list-remove-symbolic");
            remove.as(gtk.Widget).setTooltipText(i18n._("Remove"));
            remove.as(gtk.Widget).setValign(.center);
            remove.as(gtk.Widget).addCssClass("flat");
            _ = gtk.Button.signals.clicked.connect(remove, *KeybindCtx, keybindRemoved, ctx, .{});
            row.addSuffix(remove.as(gtk.Widget));
            try groups.custom.add(row.as(gtk.Widget));
        }

        const add = adw.EntryRow.new();
        add.as(adw.PreferencesRow).setTitle(i18n._("Add keybinding, e.g. ctrl+shift+t=new_tab"));
        add.setShowApplyButton(1);
        _ = adw.EntryRow.signals.apply.connect(add, *Self, keybindAdded, self, .{});
        try groups.custom.add(add.as(gtk.Widget));

        // Every effective binding with a way to remove it.
        const values = try editor.effectiveValues(alloc, "keybind");
        for (values) |value| {
            const split = splitBinding(value) orelse continue;
            const ctx = try alloc.create(KeybindCtx);
            ctx.* = .{ .dialog = self, .trigger = split.trigger };

            const row = adw.ActionRow.new();
            row.as(adw.PreferencesRow).setTitle(try alloc.dupeSentinel(u8, split.action, 0));
            row.as(adw.PreferencesRow).setUseMarkup(0);
            row.setSubtitle(try alloc.dupeSentinel(u8, split.trigger, 0));
            const remove = gtk.Button.newFromIconName("list-remove-symbolic");
            remove.as(gtk.Widget).setTooltipText(i18n._("Remove shortcut"));
            remove.as(gtk.Widget).setValign(.center);
            remove.as(gtk.Widget).addCssClass("flat");
            _ = gtk.Button.signals.clicked.connect(remove, *KeybindCtx, keybindUnbound, ctx, .{});
            row.addSuffix(remove.as(gtk.Widget));
            try groups.all.add(row.as(gtk.Widget));
        }
    }

    /// Split "trigger=action" like the binding parser: the first "="
    /// not followed by "+" or "=" separates them.
    fn splitBinding(value: []const u8) ?struct { trigger: []const u8, action: []const u8 } {
        var i: usize = 0;
        while (i < value.len) : (i += 1) {
            if (value[i] != '=') continue;
            if (i + 1 < value.len and (value[i + 1] == '+' or value[i + 1] == '=')) continue;
            return .{ .trigger = value[0..i], .action = value[i + 1 ..] };
        }
        return null;
    }

    fn keybindChangedLater(self: *Self) void {
        self.emitChanged();
        _ = glib.idleAddOnce(idleKeybindSync, self);
    }

    fn idleKeybindSync(data: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data orelse return));
        const groups = self.private().keybind_groups orelse return;
        self.syncKeybindGroups(groups) catch |err| {
            log.warn("error rebuilding keybinding rows err={}", .{err});
        };
    }

    fn keybindAdded(row: *adw.EntryRow, self: *Self) callconv(.c) void {
        const editor = self.private().editor orelse return;
        const text = std.mem.span(row.as(gtk.Editable).getText());
        if (text.len == 0) return;
        editor.add("keybind", text) catch |err| {
            self.showError(editor, err);
            row.as(gtk.Widget).addCssClass("error");
            return;
        };
        self.keybindChangedLater();
    }

    fn keybindRemoved(_: *gtk.Button, ctx: *KeybindCtx) callconv(.c) void {
        const self = ctx.dialog;
        const editor = self.private().editor orelse return;
        const path = ctx.path orelse return;
        editor.removeEntry("keybind", path, ctx.line) catch |err| {
            self.showError(editor, err);
            return;
        };
        self.keybindChangedLater();
    }

    fn keybindUnbound(_: *gtk.Button, ctx: *KeybindCtx) callconv(.c) void {
        const self = ctx.dialog;
        const priv = self.private();
        const editor = priv.editor orelse return;
        const trigger = ctx.trigger orelse return;
        const value = std.fmt.allocPrint(priv.arena.allocator(), "{s}=unbind", .{trigger}) catch return;
        editor.add("keybind", value) catch |err| {
            self.showError(editor, err);
            return;
        };
        self.keybindChangedLater();
    }

    //---------------------------------------------------------------
    // Layout

    const PageInfo = struct {
        category: schema.Category,
        title: [:0]const u8,
        icon: [:0]const u8,
    };

    const pages = [_]PageInfo{
        .{ .category = .general, .title = "General", .icon = "preferences-system-symbolic" },
        .{ .category = .appearance, .title = "Appearance", .icon = "preferences-desktop-appearance-symbolic" },
        .{ .category = .font, .title = "Font", .icon = "font-x-generic-symbolic" },
        .{ .category = .window, .title = "Window & Tabs", .icon = "window-new-symbolic" },
        .{ .category = .terminal, .title = "Terminal", .icon = "utilities-terminal-symbolic" },
        .{ .category = .mouse, .title = "Mouse & Clipboard", .icon = "input-mouse-symbolic" },
        .{ .category = .keybindings, .title = "Keybindings", .icon = "input-keyboard-symbolic" },
        .{ .category = .quick_terminal, .title = "Quick Terminal", .icon = "view-dual-symbolic" },
        .{ .category = .notifications, .title = "Notifications", .icon = "preferences-system-notifications-symbolic" },
        .{ .category = .linux, .title = "GTK & Linux", .icon = "computer-symbolic" },
    };

    const Section = struct {
        title: [:0]const u8,
        keys: []const []const u8,
    };

    fn sections(category: schema.Category) []const Section {
        return switch (category) {
            .general => &.{
                .{ .title = "Startup", .keys = &.{ "window-save-state", "working-directory", "command", "initial-window" } },
                .{ .title = "Closing", .keys = &.{ "confirm-close-surface", "quit-after-last-window-closed", "quit-after-last-window-closed-delay", "undo-timeout" } },
            },
            .appearance => &.{
                .{ .title = "Background", .keys = &.{ "background-opacity", "background-blur", "background-opacity-cells" } },
                .{ .title = "Colors", .keys = &.{ "background", "foreground", "selection-background", "selection-foreground", "minimum-contrast" } },
                .{ .title = "Cursor", .keys = &.{ "cursor-style", "cursor-style-blink", "cursor-color", "cursor-opacity" } },
                .{ .title = "Splits", .keys = &.{ "unfocused-split-opacity", "unfocused-split-fill", "split-divider-color" } },
            },
            .font => &.{
                .{ .title = "Font", .keys = &.{ "font-family", "font-size", "font-thicken", "font-feature", "adjust-cell-height", "adjust-cell-width" } },
            },
            .window => &.{
                .{ .title = "Size", .keys = &.{ "window-width", "window-height", "maximize", "fullscreen" } },
                .{ .title = "Padding", .keys = &.{ "window-padding-x", "window-padding-y", "window-padding-balance", "window-padding-color" } },
                .{ .title = "Tabs", .keys = &.{ "window-new-tab-position", "window-show-tab-bar", "tab-title-format" } },
                .{ .title = "Window", .keys = &.{ "window-decoration", "window-theme", "window-remote-indicator", "title" } },
            },
            .terminal => &.{
                .{ .title = "Shell", .keys = &.{ "shell-integration", "shell-integration-features", "term" } },
                .{ .title = "Scrollback", .keys = &.{ "scrollback-limit-bytes", "scrollbar", "scroll-to-bottom" } },
            },
            .mouse => &.{
                .{ .title = "Mouse", .keys = &.{ "mouse-hide-while-typing", "mouse-scroll-multiplier", "focus-follows-mouse", "right-click-action", "middle-click-action" } },
                .{ .title = "Clipboard", .keys = &.{ "copy-on-select", "clipboard-read", "clipboard-write", "clipboard-paste-protection" } },
            },
            .quick_terminal => &.{
                .{ .title = "Quick Terminal", .keys = &.{ "quick-terminal-position", "quick-terminal-size", "quick-terminal-animation-duration", "quick-terminal-autohide" } },
            },
            .notifications => &.{
                .{ .title = "Bell", .keys = &.{ "bell-features", "bell-audio-path", "bell-audio-volume" } },
                .{ .title = "Notifications", .keys = &.{ "app-notifications", "desktop-notifications", "notify-on-command-finish" } },
            },
            .linux => &.{
                .{ .title = "Titlebar & Tabs", .keys = &.{ "gtk-titlebar", "gtk-titlebar-style", "gtk-tabs-location", "gtk-wide-tabs", "gtk-toolbar-style" } },
            },
            .keybindings, .macos => &.{},
        };
    }

    fn inSections(list: []const Section, key: []const u8) bool {
        for (list) |section| {
            for (section.keys) |k| if (std.mem.eql(u8, k, key)) return true;
        }
        return false;
    }

    /// Keys shown with custom UI instead of a row.
    fn isCustomKey(category: schema.Category, key: []const u8) bool {
        return switch (category) {
            .appearance => std.mem.eql(u8, key, "theme"),
            .keybindings => std.mem.eql(u8, key, "keybind"),
            else => false,
        };
    }

    fn isFraction(key: []const u8) bool {
        const fractions = [_][]const u8{
            "background-opacity",
            "background-image-opacity",
            "unfocused-split-opacity",
            "cursor-opacity",
            "faint-opacity",
            "bell-audio-volume",
        };
        for (fractions) |k| if (std.mem.eql(u8, k, key)) return true;
        return false;
    }

    fn applyNote(apply: schema.Apply) ?[*:0]const u8 {
        return switch (apply) {
            .live => null,
            .new_terminal => i18n._("Applies to new terminals only"),
            .new_window => i18n._("Applies to new windows only"),
            .restart => i18n._("Requires restarting Ghostty"),
        };
    }

    fn flagEnabled(value: []const u8, flag: []const u8) bool {
        var it = std.mem.splitScalar(u8, value, ',');
        while (it.next()) |part| {
            const item = std.mem.trim(u8, part, " ");
            if (std.mem.eql(u8, item, flag)) return true;
        }
        return false;
    }

    fn channel(v: f32) u8 {
        return @intFromFloat(std.math.clamp(v, 0, 1) * 255.0 + 0.5);
    }

    /// "block_hollow" becomes "Block hollow".
    fn prettify(alloc: Allocator, value: []const u8) ![:0]const u8 {
        if (std.mem.eql(u8, value, "true")) return std.mem.span(i18n._("On"));
        if (std.mem.eql(u8, value, "false")) return std.mem.span(i18n._("Off"));
        const result = try alloc.dupeSentinel(u8, value, 0);
        for (result) |*ch| {
            if (ch.* == '-' or ch.* == '_') ch.* = ' ';
        }
        if (result.len > 0) result[0] = std.ascii.toUpper(result[0]);
        return result;
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
            signals.changed.impl.register(.{});
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }
    };
};
