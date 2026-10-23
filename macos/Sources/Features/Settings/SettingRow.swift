import AppKit
import SwiftUI

/// Navigate to another settings page from inside a page.
struct SettingsNavigateKey: EnvironmentKey {
    static let defaultValue: (SettingsPage) -> Void = { _ in }
}

extension EnvironmentValues {
    var settingsNavigate: (SettingsPage) -> Void {
        get { self[SettingsNavigateKey.self] }
        set { self[SettingsNavigateKey.self] = newValue }
    }
}

/// One setting: its label, badges and a control picked from its kind.
struct SettingRow: View {
    @ObservedObject var store: SettingsStore
    let setting: SettingSchema

    /// Show the configuration key instead of the label (All Settings).
    var showKey = false

    /// Optional title override.
    var title: String?

    @State private var showingDoc = false

    private var modified: Bool { store.isModified(setting.key) }
    private var lockedByCLI: Bool { store.isSetByCLI(setting.key) }

    var body: some View {
        Group {
            if setting.repeatable && setting.kind != .keybind {
                VStack(alignment: .leading, spacing: 8) {
                    label
                    SettingControl(store: store, setting: setting)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                LabeledContent {
                    SettingControl(store: store, setting: setting)
                        .disabled(lockedByCLI)
                } label: {
                    label
                }
            }
        }
        .contextMenu { menu }
        .help(setting.summary)
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(modified ? Color.accentColor : Color.clear)
                .frame(width: 6, height: 6)
                .accessibilityLabel(modified ? "Changed from default" : "")
                .help(modified ? "Changed from default" : "")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if showKey {
                        Text(setting.key).font(.system(.body, design: .monospaced))
                    } else {
                        Text(title ?? setting.label)
                    }

                    Button {
                        showingDoc.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Show documentation for \(setting.key)")
                    .popover(isPresented: $showingDoc, arrowEdge: .trailing) {
                        SettingDocView(store: store, setting: setting)
                    }

                    if let note = setting.apply.note, let icon = setting.apply.systemImage {
                        Image(systemName: icon)
                            .foregroundStyle(.orange)
                            .help(note)
                            .accessibilityLabel(note)
                    }
                }

                badges
            }
        }
    }

    /// Where the value comes from, when that's not the main config file.
    @ViewBuilder
    private var badges: some View {
        let otherFile = store.isSetInOtherFile(setting.key) ? store.origin(setting.key) : nil
        if otherFile != nil || lockedByCLI {
            HStack(spacing: 4) {
                if let otherFile {
                    SettingBadge(text: otherFile.locationDescription, systemImage: "doc", tint: .blue)
                        .help("Set in \(otherFile.path ?? ""). Changes are saved there.")
                }
                if lockedByCLI {
                    SettingBadge(text: "Command line", systemImage: "lock", tint: .gray)
                        .help("Set by a command-line argument. Changes are saved but won't apply until Ghostty is launched without it.")
                }
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Reset to Default") { store.reset(setting.key) }
            .disabled(!modified)
        Button("Copy as Config Line") {
            let lines = store.values(setting.key).map { "\(setting.key) = \($0)" }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        }
        if let origin = store.origin(setting.key), let path = origin.path {
            Button("Show in \(origin.locationDescription)") {
                store.openInEditor(path: path)
            }
        }
        Divider()
        Button("Show Documentation") { showingDoc = true }
    }
}

/// A small capsule label next to a setting.
struct SettingBadge: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(0.12)))
    }
}

/// The documentation popover for a setting.
struct SettingDocView: View {
    @ObservedObject var store: SettingsStore
    let setting: SettingSchema

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(setting.key)
                .font(.system(.headline, design: .monospaced))
                .textSelection(.enabled)

            ScrollView {
                Text(Self.render(setting.doc))
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)

            Divider()

            HStack {
                Text("Default: ")
                    .foregroundColor(.secondary) +
                Text(setting.defaultValues.isEmpty || setting.defaultValue.isEmpty
                     ? "(none)" : setting.defaultValues.prefix(3).joined(separator: ", "))
                    .font(.system(.callout, design: .monospaced))
                Spacer()
                if store.isModified(setting.key) {
                    Button("Reset to Default") { store.reset(setting.key) }
                }
            }
            .font(.callout)
        }
        .padding()
        .frame(width: 420)
    }

    static func render(_ doc: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: doc, options: options)) ?? AttributedString(doc)
    }
}

/// The control for a setting, picked from its kind.
struct SettingControl: View {
    @ObservedObject var store: SettingsStore
    let setting: SettingSchema
    @Environment(\.settingsNavigate) private var navigate

    private var key: String { setting.key }
    private var value: String { store.value(key) }

    var body: some View {
        if setting.repeatable {
            switch setting.kind {
            case .keybind:
                Button("Edit Keybindings…") { navigate(.category(.keybindings)) }
            default:
                RepeatableEditor(store: store, setting: setting)
            }
        } else {
            scalar
        }
    }

    @ViewBuilder
    private var scalar: some View {
        switch setting.kind {
        case .bool:
            if setting.optional {
                Picker("", selection: binding(default: "")) {
                    Text("Default").tag("")
                    Text("On").tag("true")
                    Text("Off").tag("false")
                }
                .labelsHidden()
                .fixedSize()
            } else {
                Toggle("", isOn: Binding(
                    get: { value == "true" },
                    set: { store.set(key, $0 ? "true" : "false") }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

        case .enum:
            Picker("", selection: binding(default: "")) {
                if setting.optional {
                    Text("Default").tag("")
                }
                ForEach(setting.values, id: \.self) { v in
                    Text(Self.prettify(v)).tag(v)
                }
                if !value.isEmpty && !setting.values.contains(value) {
                    Text(value).tag(value)
                }
            }
            .labelsHidden()
            .fixedSize()

        case .flags:
            FlagsControl(store: store, setting: setting)

        case .float where SettingsLayout.fractions.contains(key):
            FractionControl(store: store, setting: setting)

        case .color:
            ColorControl(store: store, setting: setting)

        case .path:
            PathControl(store: store, setting: setting)

        case .font:
            FontFamilyPicker(store: store, setting: setting)

        case .theme:
            Button("Choose Theme…") { navigate(.category(.appearance)) }

        default:
            if setting.values.isEmpty {
                CommitTextField(
                    value: value,
                    placeholder: setting.optional ? "Default" : "",
                    width: setting.kind == .string ? 200 : 90,
                    monospaced: setting.kind == .string,
                    validate: { store.validate(key, $0) },
                    commit: { commit($0) }
                )
            } else {
                SuggestedValueControl(store: store, setting: setting)
            }
        }
    }

    /// A binding that writes on change and resets when set to `empty`.
    private func binding(default empty: String) -> Binding<String> {
        Binding(
            get: { value },
            set: { new in
                if new == empty {
                    store.reset(key)
                } else {
                    store.set(key, new)
                }
            }
        )
    }

    private func commit(_ text: String) {
        if text.isEmpty && setting.optional {
            store.reset(key)
        } else {
            store.set(key, text)
        }
    }

    static func prettify(_ value: String) -> String {
        switch value {
        case "true": return "On"
        case "false": return "Off"
        default: break
        }
        let spaced = value.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}

/// A picker of well known values (such as `true`, `false` and
/// `macos-glass-regular` for `background-blur`) with a custom value.
struct SuggestedValueControl: View {
    @ObservedObject var store: SettingsStore
    let setting: SettingSchema
    @State private var custom = false

    private static let customTag = "__custom"

    var body: some View {
        let value = store.value(setting.key)
        let known = setting.values.contains(value) || (value.isEmpty && setting.optional)
        let showField = custom || !known

        HStack(spacing: 6) {
            Picker("", selection: Binding(
                get: { showField ? Self.customTag : value },
                set: { new in
                    if new == Self.customTag {
                        custom = true
                        return
                    }
                    custom = false
                    if new.isEmpty {
                        store.reset(setting.key)
                    } else {
                        store.set(setting.key, new)
                    }
                }
            )) {
                if setting.optional {
                    Text("Default").tag("")
                }
                ForEach(setting.values, id: \.self) { v in
                    Text(SettingControl.prettify(v)).tag(v)
                }
                Divider()
                Text("Custom…").tag(Self.customTag)
            }
            .labelsHidden()
            .fixedSize()

            if showField {
                CommitTextField(
                    value: known ? "" : value,
                    width: 90,
                    validate: { store.validate(setting.key, $0) },
                    commit: { text in
                        if !text.isEmpty { store.set(setting.key, text) }
                    }
                )
            }
        }
    }
}

/// A text field that writes its value when editing ends (return or focus
/// loss) and shows validation errors while typing.
struct CommitTextField: View {
    let value: String
    var placeholder: String = ""
    var width: CGFloat? = 160
    var monospaced = false
    let validate: (String) -> String?
    let commit: (String) -> Void

    @State private var text = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            TextField("", text: $text, prompt: Text(placeholder))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .frame(width: width)
                .focused($focused)
                .onSubmit(submit)
                .onChange(of: focused) { isFocused in
                    if !isFocused { submit() }
                }
                .onChange(of: text) { newText in
                    error = newText == value || newText.isEmpty ? nil : validate(newText)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.red, lineWidth: error == nil ? 0 : 1.5)
                )
                .accessibilityValue(error ?? "")

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 280, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { text = value }
        .onChange(of: value) { newValue in
            if !focused {
                text = newValue
                error = nil
            }
        }
    }

    private func submit() {
        guard text != value, error == nil else { return }
        commit(text)
    }
}

/// Coalesces rapid calls (color wells, sliders).
final class Debouncer {
    private var work: DispatchWorkItem?

    func call(after delay: TimeInterval, _ action: @escaping () -> Void) {
        work?.cancel()
        let item = DispatchWorkItem(block: action)
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

/// A 0-1 slider with a text field.
struct FractionControl: View {
    @ObservedObject var store: SettingsStore
    let setting: SettingSchema
    @State private var current: Double = 0
    @State private var editing = false

    private var value: String { store.value(setting.key) }

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: $current, in: 0...1) { isEditing in
                editing = isEditing
                if !isEditing {
                    store.set(setting.key, Self.format(current))
                }
            }
            .frame(width: 150)
            .accessibilityLabel(setting.label)

            CommitTextField(
                value: value,
                width: 56,
                validate: { store.validate(setting.key, $0) },
                commit: { store.set(setting.key, $0) }
            )
        }
        .onAppear { current = Double(value) ?? 1 }
        .onChange(of: value) { newValue in
            if !editing { current = Double(newValue) ?? current }
        }
    }

    static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

/// A menu of checkboxes for flag lists such as `bell-features`.
struct FlagsControl: View {
    @ObservedObject var store: SettingsStore
    let setting: SettingSchema

    /// The state of each flag from the effective value.
    private var state: [String: Bool] {
        var result: [String: Bool] = [:]
        for token in store.value(setting.key).split(separator: ",") {
            let item = token.trimmingCharacters(in: .whitespaces)
            if item.hasPrefix("no-") {
                result[String(item.dropFirst(3))] = false
            } else {
                result[item] = true
            }
        }
        return result
    }

    var body: some View {
        let state = self.state
        let enabled = setting.flags.filter { state[$0] == true }
        Menu {
            ForEach(setting.flags, id: \.self) { flag in
                Toggle(SettingControl.prettify(flag), isOn: Binding(
                    get: { state[flag] == true },
                    set: { on in write(state, flag: flag, on: on) }
                ))
            }
        } label: {
            Text(enabled.isEmpty ? "None" : enabled.map(SettingControl.prettify).joined(separator: ", "))
                .lineLimit(1)
        }
        .fixedSize()
    }

    private func write(_ state: [String: Bool], flag: String, on: Bool) {
        var next = state
        next[flag] = on
        let value = setting.flags
            .map { (next[$0] ?? false) ? $0 : "no-\($0)" }
            .joined(separator: ",")
        store.set(setting.key, value)
    }
}

/// A color well with a text field for hex or named colors.
struct ColorControl: View {
    @ObservedObject var store: SettingsStore
    let setting: SettingSchema
    @State private var debouncer = Debouncer()

    private var value: String { store.value(setting.key) }

    var body: some View {
        HStack(spacing: 6) {
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: NSColor(hex: value) ?? NSColor(named: value) ?? .gray) },
                set: { color in
                    guard let hex = NSColor(color).hexString else { return }
                    debouncer.call(after: 0.4) { store.set(setting.key, hex.lowercased()) }
                }
            ), supportsOpacity: false)
            .labelsHidden()

            CommitTextField(
                value: value,
                placeholder: setting.optional ? "Default" : "",
                width: 110,
                monospaced: true,
                validate: { store.validate(setting.key, $0) },
                commit: { text in
                    if text.isEmpty && setting.optional {
                        store.reset(setting.key)
                    } else {
                        store.set(setting.key, text)
                    }
                }
            )

            if !setting.values.isEmpty {
                Menu {
                    ForEach(setting.values, id: \.self) { v in
                        Button(SettingControl.prettify(v)) { store.set(setting.key, v) }
                    }
                } label: {
                    Image(systemName: "chevron.down.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Special colors")
            }
        }
    }
}

/// A path with a file chooser.
struct PathControl: View {
    @ObservedObject var store: SettingsStore
    let setting: SettingSchema

    var body: some View {
        HStack(spacing: 6) {
            CommitTextField(
                value: store.value(setting.key),
                placeholder: "None",
                width: 200,
                monospaced: true,
                validate: { store.validate(setting.key, $0) },
                commit: { text in
                    if text.isEmpty {
                        store.reset(setting.key)
                    } else {
                        store.set(setting.key, text)
                    }
                }
            )
            Button("Choose…") {
                if let path = Self.choose() { store.set(setting.key, path) }
            }
        }
    }

    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}

/// Font families installed on the system that are monospaced.
enum MonospaceFonts {
    static let families: [String] = {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { family in
            guard let members = manager.availableMembers(ofFontFamily: family) else { return false }
            return members.contains { member in
                guard let traits = member[safe: 3] as? UInt else { return false }
                return NSFontTraitMask(rawValue: traits).contains(.fixedPitchFontMask)
            }
        }.sorted()
    }()
}

/// A picker for a single font family.
struct FontFamilyPicker: View {
    @ObservedObject var store: SettingsStore
    let setting: SettingSchema

    var body: some View {
        let value = store.value(setting.key)
        Picker("", selection: Binding(
            get: { value },
            set: { new in
                if new.isEmpty { store.reset(setting.key) } else { store.set(setting.key, new) }
            }
        )) {
            Text("Default").tag("")
            Divider()
            ForEach(MonospaceFonts.families, id: \.self) { family in
                Text(family).tag(family)
            }
            if !value.isEmpty && !MonospaceFonts.families.contains(value) {
                Text(value).tag(value)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 220)
    }
}

/// Edits the values of a repeatable key. Values set in files can be
/// edited or removed; values that only come from defaults are listed.
struct RepeatableEditor: View {
    @ObservedObject var store: SettingsStore
    let setting: SettingSchema
    @State private var newValue = ""
    @State private var error: String?

    var body: some View {
        let entries = store.fileEntries(setting.key)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 6) {
                    CommitTextField(
                        value: entry.value ?? "",
                        width: 280,
                        monospaced: true,
                        validate: { store.validate(setting.key, $0) },
                        commit: { store.replace(setting.key, entry: entry, with: $0) }
                    )
                    if store.isSetInOtherFile(setting.key) || entry.path != store.primaryPath {
                        Text(entry.locationDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        store.remove(setting.key, entry: entry)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(entry.value ?? "")")
                }
            }

            HStack(spacing: 6) {
                TextField("", text: $newValue, prompt: Text("Add a value"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 280)
                    .onSubmit(add)
                    .onChange(of: newValue) { text in
                        error = text.isEmpty ? nil : store.validate(setting.key, text)
                    }
                Button("Add", action: add)
                    .disabled(newValue.isEmpty || error != nil)
                if setting.kind == .path {
                    Button("Choose…") {
                        if let path = PathControl.choose() { store.add(setting.key, path) }
                    }
                }
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            let defaults = store.values(setting.key).count - entries.count
            if entries.isEmpty && defaults > 0 && !store.values(setting.key).allSatisfy({ $0.isEmpty }) {
                Text("\(defaults) default value\(defaults == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func add() {
        guard !newValue.isEmpty, error == nil else { return }
        if store.add(setting.key, newValue) { newValue = "" }
    }
}
