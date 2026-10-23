import AppKit
import SwiftUI

/// Helpers for keybinding strings such as `global:super+shift+t=new_tab`.
enum KeybindString {
    /// Split a binding into its trigger and action. Mirrors the parser in
    /// `src/input/Binding.zig`: the first "=" that isn't followed by "+"
    /// or "=" separates them (so `ctrl+==action` binds "=").
    static func split(_ binding: String) -> (trigger: String, action: String)? {
        let chars = Array(binding)
        var i = 0
        while i < chars.count {
            if chars[i] == "=" {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                if next != "+" && next != "=" {
                    return (String(chars[..<i]), String(chars[(i + 1)...]))
                }
            }
            i += 1
        }
        return nil
    }

    private static let flagPrefixes = ["global:", "all:", "unconsumed:", "performable:"]

    /// Separate flag prefixes (global:, all:, ...) from the key sequence.
    static func flags(of trigger: String) -> (flags: [String], keys: String) {
        var rest = trigger
        var flags: [String] = []
        var found = true
        while found {
            found = false
            for prefix in flagPrefixes where rest.hasPrefix(prefix) {
                flags.append(String(prefix.dropLast()))
                rest = String(rest.dropFirst(prefix.count))
                found = true
            }
        }
        return (flags, rest)
    }

    private static func mod(_ name: String) -> String? {
        switch name.lowercased() {
        case "super", "cmd", "command": return "super"
        case "ctrl", "control": return "ctrl"
        case "alt", "opt", "option": return "alt"
        case "shift": return "shift"
        default: return nil
        }
    }

    /// The parts of one key combination ("super+shift+t").
    private static func parts(_ combo: String) -> (mods: [String], key: String) {
        // A trailing "+" key is written "++".
        var items = combo.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if combo.hasSuffix("++") {
            items = Array(items.dropLast(2)) + ["+"]
        }
        var mods: [String] = []
        var key = ""
        for item in items where !item.isEmpty {
            if let m = mod(item) { mods.append(m) } else { key = item }
        }
        let order = ["super", "ctrl", "alt", "shift"]
        mods.sort { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
        return (mods, key)
    }

    /// A canonical form for comparing triggers.
    static func normalize(_ trigger: String) -> String {
        let (flags, keys) = self.flags(of: trigger)
        let combos = keys.split(separator: ">").map { combo -> String in
            let (mods, key) = parts(String(combo))
            return (mods + [key.lowercased()]).joined(separator: "+")
        }
        return (flags.sorted().map { $0 + ":" }.joined()) + combos.joined(separator: ">")
    }

    /// Keycaps to display for a trigger, one array per key in a sequence.
    static func keycaps(_ trigger: String) -> (flags: [String], sequence: [[String]]) {
        let (flags, keys) = self.flags(of: trigger)
        let sequence = keys.split(separator: ">").map { combo -> [String] in
            let (mods, key) = parts(String(combo))
            return mods.map(symbol(forMod:)) + [symbol(forKey: key)]
        }
        return (flags, sequence)
    }

    private static func symbol(forMod mod: String) -> String {
        switch mod {
        case "super": return "⌘"
        case "ctrl": return "⌃"
        case "alt": return "⌥"
        case "shift": return "⇧"
        default: return mod
        }
    }

    private static let keySymbols: [String: String] = [
        "arrow_up": "↑", "arrow_down": "↓", "arrow_left": "←", "arrow_right": "→",
        "enter": "↩", "escape": "⎋", "tab": "⇥", "backspace": "⌫", "delete": "⌦",
        "space": "Space", "equal": "=", "comma": ",", "period": ".", "minus": "-",
        "slash": "/", "backslash": "\\", "semicolon": ";", "quote": "'", "backquote": "`",
        "bracket_left": "[", "bracket_right": "]", "page_up": "⇞", "page_down": "⇟",
        "home": "↖", "end": "↘",
    ]

    private static func symbol(forKey key: String) -> String {
        if let symbol = keySymbols[key.lowercased()] { return symbol }
        if key.count == 1 { return key.uppercased() }
        return key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Build a trigger from a key event, or nil for modifier-only events.
    static func trigger(for event: NSEvent) -> String? {
        guard let key = keyName(for: event) else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var parts: [String] = []
        if flags.contains(.command) { parts.append("super") }
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("alt") }
        if flags.contains(.shift) { parts.append("shift") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    private static let specialKeys: [UInt16: String] = [
        36: "enter", 76: "numpad_enter", 48: "tab", 49: "space", 51: "backspace",
        53: "escape", 117: "delete", 115: "home", 119: "end", 116: "page_up",
        121: "page_down", 123: "arrow_left", 124: "arrow_right", 125: "arrow_down",
        126: "arrow_up", 122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5",
        97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]

    private static func keyName(for event: NSEvent) -> String? {
        if let special = specialKeys[event.keyCode] { return special }
        guard let chars = event.characters(byApplyingModifiers: []),
              let char = chars.first,
              !char.isWhitespace else { return nil }
        switch char {
        case "=": return "equal"
        case "+": return "plus"
        case ">": return "greater"
        default: return String(char).lowercased()
        }
    }
}

/// A row on the keybindings page.
struct KeybindingRow: Identifiable, Hashable {
    let id: String
    let trigger: String
    let action: String

    /// The file entry for custom bindings. Nil for defaults.
    let entry: SettingEntry?

    /// True for `trigger=unbind` entries that remove a default.
    var isRemoval: Bool { action == "unbind" }
    var isCustom: Bool { entry != nil }
}

/// View and edit keybindings: defaults and custom bindings together.
struct KeybindingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var editing: KeybindEdit?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", customized = "Customized"
        var id: String { rawValue }
    }

    private static let key = "keybind"

    var body: some View {
        let rows = self.rows.filter { row in
            if filter == .customized && !row.isCustom { return false }
            guard !search.isEmpty else { return true }
            let title = store.keybindActions.title(for: row.action)
            return title.localizedCaseInsensitiveContains(search) ||
                row.action.localizedCaseInsensitiveContains(search) ||
                row.trigger.localizedCaseInsensitiveContains(search)
        }

        Form {
            Section {
                ForEach(rows) { row in
                    KeybindingRowView(store: store, row: row, edit: { editing = .edit(row) }, remove: { remove(row) })
                }
                if rows.isEmpty {
                    Text("No keybindings").foregroundStyle(.secondary)
                }
            } header: {
                HStack(spacing: 10) {
                    TextField("Filter", text: $search, prompt: Text("Filter by action or shortcut"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(maxWidth: 260)
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    Button {
                        editing = .new
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
                .textCase(nil)
            } footer: {
                Text("Custom shortcuts are saved as `keybind = …` lines. Removing a default shortcut writes `keybind = <shortcut>=unbind`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Keybindings")
        .sheet(item: $editing) { edit in
            KeybindEditorSheet(store: store, edit: edit, rows: self.rows)
        }
    }

    /// Effective bindings plus custom removals, custom ones first.
    private var rows: [KeybindingRow] {
        let entries = store.fileEntries(Self.key)
        var custom: [String: SettingEntry] = [:]
        var removals: [KeybindingRow] = []
        for (index, entry) in entries.enumerated() {
            guard let value = entry.value, let (trigger, action) = KeybindString.split(value) else { continue }
            let normalized = KeybindString.normalize(trigger)
            if action == "unbind" {
                removals.append(KeybindingRow(id: "removed-\(index)-\(normalized)", trigger: trigger, action: action, entry: entry))
            } else {
                custom[normalized] = entry
            }
        }

        var result: [KeybindingRow] = []
        var seen: Set<String> = []
        for value in store.values(Self.key) {
            guard let (trigger, action) = KeybindString.split(value) else { continue }
            let normalized = KeybindString.normalize(trigger)
            guard seen.insert(normalized).inserted else { continue }
            result.append(KeybindingRow(id: normalized, trigger: trigger, action: action, entry: custom[normalized]))
        }

        let title = { (row: KeybindingRow) in store.keybindActions.title(for: row.action) }
        result.sort { lhs, rhs in
            if lhs.isCustom != rhs.isCustom { return lhs.isCustom }
            return title(lhs).localizedCaseInsensitiveCompare(title(rhs)) == .orderedAscending
        }
        return removals + result
    }

    private func remove(_ row: KeybindingRow) {
        if let entry = row.entry {
            // Removing a custom binding (or a removal, which restores the
            // default) deletes its line.
            store.remove(Self.key, entry: entry)
        } else {
            store.add(Self.key, "\(row.trigger)=unbind")
        }
    }
}

/// One keybinding: action, keycaps, where it's defined and actions.
struct KeybindingRowView: View {
    @ObservedObject var store: SettingsStore
    let row: KeybindingRow
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(row.isCustom ? Color.accentColor : Color.clear)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                if row.isRemoval {
                    Text("Removed default shortcut")
                        .foregroundStyle(.secondary)
                } else {
                    Text(store.keybindActions.title(for: row.action))
                }
                Text(row.isRemoval ? "unbind" : row.action)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            KeycapsView(trigger: row.trigger)
                .opacity(row.isRemoval ? 0.5 : 1)

            Text(row.entry?.locationDescription ?? "Default")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
                .lineLimit(1)
                .truncationMode(.middle)

            Menu {
                if !row.isRemoval {
                    Button("Edit…", action: edit)
                }
                Button(row.isRemoval ? "Restore Default" : (row.isCustom ? "Remove" : "Remove Default Shortcut"), action: remove)
                if let path = row.entry?.path {
                    Divider()
                    Button("Show in \(row.entry?.locationDescription ?? "")") { store.openInEditor(path: path) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(row.trigger)")
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !row.isRemoval { edit() } }
    }
}

/// Keycaps for a trigger, with flag tags and sequence arrows.
struct KeycapsView: View {
    let trigger: String

    var body: some View {
        let caps = KeybindString.keycaps(trigger)
        HStack(spacing: 4) {
            ForEach(caps.flags, id: \.self) { flag in
                SettingBadge(text: flag.capitalized, systemImage: "globe", tint: .blue)
            }
            ForEach(Array(caps.sequence.enumerated()), id: \.offset) { index, keys in
                if index > 0 {
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    Text(key)
                        .font(.system(size: 12))
                        .padding(.horizontal, 6)
                        .frame(minWidth: 22, minHeight: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .shadow(color: .black.opacity(0.25), radius: 0, y: 1)
                        )
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.15)))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(trigger)
    }
}

/// What the keybinding editor sheet is doing.
enum KeybindEdit: Identifiable {
    case new
    case edit(KeybindingRow)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let row): return row.id
        }
    }
}

/// Record a shortcut and choose an action.
struct KeybindEditorSheet: View {
    @ObservedObject var store: SettingsStore
    let edit: KeybindEdit
    let rows: [KeybindingRow]

    @Environment(\.dismiss) private var dismiss
    @State private var trigger = ""
    @State private var action = ""
    @State private var customAction = false
    @State private var recording = false
    @State private var error: String?

    private static let key = "keybind"

    private var original: KeybindingRow? {
        if case .edit(let row) = edit { return row }
        return nil
    }

    private var binding: String { "\(trigger)=\(action)" }

    /// Another binding already using the trigger.
    private var conflict: KeybindingRow? {
        guard !trigger.isEmpty else { return nil }
        let normalized = KeybindString.normalize(trigger)
        return rows.first { row in
            !row.isRemoval && row.id == normalized && row.id != original?.id
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(original == nil ? "Add Keybinding" : "Edit Keybinding")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Shortcut")
                        .gridColumnAlignment(.trailing)
                    HStack {
                        ShortcutRecorder(trigger: $trigger, recording: $recording)
                            .frame(width: 220, height: 28)
                        TextField("Shortcut", text: $trigger, prompt: Text("super+shift+t"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 180)
                            .accessibilityLabel("Shortcut as text")
                    }
                }

                GridRow(alignment: .top) {
                    Text("Action")
                        .padding(.top, 3)
                    VStack(alignment: .leading) {
                        Picker("", selection: Binding(
                            get: { customAction ? "__custom" : action },
                            set: { new in
                                if new == "__custom" {
                                    customAction = true
                                } else {
                                    customAction = false
                                    action = new
                                }
                            }
                        )) {
                            Text("Choose an action").tag("")
                            ForEach(store.keybindActions.commands.sorted { $0.title < $1.title }, id: \.action) { command in
                                Text(command.title).tag(command.action)
                            }
                            Divider()
                            Text("Custom…").tag("__custom")
                        }
                        .labelsHidden()
                        .frame(width: 300)

                        if customAction {
                            TextField("Action", text: $action, prompt: Text("action:parameter"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 300)
                        }
                    }
                }
            }

            if let conflict {
                Label {
                    Text("This shortcut is already used by \(store.keybindActions.title(for: conflict.action)). Saving replaces it.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
            }

            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Text(trigger.isEmpty || action.isEmpty ? "" : "keybind = \(binding)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trigger.isEmpty || action.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear {
            if let original {
                trigger = original.trigger
                action = original.action
                customAction = !store.keybindActions.commands.contains { $0.action == original.action }
            } else {
                recording = true
            }
        }
        .onChange(of: trigger) { _ in error = nil }
        .onChange(of: action) { _ in error = nil }
    }

    private func save() {
        if let message = store.validate(Self.key, binding) {
            error = message
            return
        }

        let ok: Bool
        if let original, let entry = original.entry {
            // Editing a custom binding changes its line.
            ok = store.replace(Self.key, entry: entry, with: binding)
        } else if let conflict, let entry = conflict.entry {
            // Replace the custom binding that used this shortcut.
            ok = store.replace(Self.key, entry: entry, with: binding)
        } else {
            if let original, KeybindString.normalize(original.trigger) != KeybindString.normalize(trigger) {
                // Moving a default binding to a new shortcut removes the old one.
                store.add(Self.key, "\(original.trigger)=unbind")
            }
            ok = store.add(Self.key, binding)
        }

        if ok { dismiss() } else { error = store.lastError }
    }
}

/// A field that records the next key combination pressed.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var trigger: String
    @Binding var recording: Bool

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onChange = { trigger, recording in
            if let trigger { self.trigger = trigger }
            self.recording = recording
        }
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.onChange = { trigger, recording in
            if let trigger { self.trigger = trigger }
            self.recording = recording
        }
        view.trigger = trigger
        view.setRecording(recording)
    }

    final class RecorderView: NSView {
        var onChange: ((String?, Bool) -> Void)?
        var trigger = "" { didSet { needsDisplay = true } }
        private var recording = false

        override var acceptsFirstResponder: Bool { true }

        override func accessibilityRole() -> NSAccessibility.Role? { .button }
        override func accessibilityLabel() -> String? {
            recording ? "Recording shortcut" : "Shortcut \(trigger). Click to record."
        }

        func setRecording(_ value: Bool) {
            guard value != recording else { return }
            recording = value
            needsDisplay = true
            if value {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.window?.makeFirstResponder(self)
                }
            }
        }

        override func mouseDown(with event: NSEvent) {
            recording = true
            window?.makeFirstResponder(self)
            needsDisplay = true
            onChange?(nil, true)
        }

        override func resignFirstResponder() -> Bool {
            if recording {
                recording = false
                needsDisplay = true
                onChange?(nil, false)
            }
            return super.resignFirstResponder()
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { return super.keyDown(with: event) }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53 && flags.subtracting([.capsLock, .numericPad, .function]).isEmpty {
                // Escape alone stops recording.
                recording = false
                needsDisplay = true
                onChange?(nil, false)
                return
            }

            guard let trigger = KeybindString.trigger(for: event) else { return }
            self.trigger = trigger
            recording = false
            needsDisplay = true
            onChange?(trigger, false)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            // Capture shortcuts such as ⌘W instead of running them.
            guard recording, window?.firstResponder === self else { return false }
            keyDown(with: event)
            return true
        }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            NSColor.textBackgroundColor.setFill()
            path.fill()
            (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = recording ? 2 : 1
            path.stroke()

            let text: String
            if recording {
                text = "Press shortcut…"
            } else if trigger.isEmpty {
                text = "Click to record"
            } else {
                text = KeybindString.keycaps(trigger).sequence.map { $0.joined() }.joined(separator: " → ")
            }

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: recording || trigger.isEmpty ? NSColor.secondaryLabelColor : NSColor.labelColor,
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
        }
    }
}
