import AppKit
import Combine
import GhosttyKit

/// The model behind the settings window. It wraps the libghostty
/// settings editor, which reads and writes the user's configuration
/// files, and applies changes to the running app.
@MainActor
final class SettingsStore: ObservableObject {
    /// Every configuration key for this platform.
    let schema: [SettingSchema]
    private let schemaByKey: [String: SettingSchema]

    /// The actions keybindings can trigger.
    let keybindActions: KeybindActions

    /// The current configuration state.
    @Published private(set) var snapshot: SettingsSnapshot = .empty

    /// The message for the last change that failed.
    @Published var lastError: String?

    /// Available themes. Loaded lazily with `loadThemes()`.
    @Published private(set) var themes: [ThemeInfo] = []

    /// Undo for changes made in the settings window.
    let undoManager = UndoManager()

    private nonisolated(unsafe) var editor: ghostty_config_editor_t?
    private weak var app: Ghostty.App?
    private var previewing = false
    private var themesLoading = false
    private var appReload: DispatchWorkItem?
    private var fileReload: DispatchWorkItem?
    private var ignoreFileEventsUntil = Date.distantPast
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var watchedPaths: Set<String> = []
    private var appearanceObserver: NSKeyValueObservation?
    private var configObserver: AnyCancellable?

    /// - Parameters:
    ///   - app: The running app, used to apply changes.
    ///   - configPath: Load only this file instead of the default files.
    ///     Defaults to the file the app was launched with, if any.
    ///   - loadCLIArgs: Whether CLI arguments are loaded, like the app does.
    init(app: Ghostty.App?, configPath: String? = nil, loadCLIArgs: Bool = !isRunningInXcode()) {
        self.app = app
        let schema = JSONDecoder.ghostty([SettingSchema].self, from: ghostty_config_schema_json()) ?? []
        self.schema = schema
        self.schemaByKey = Dictionary(schema.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        self.keybindActions = JSONDecoder.ghostty(
            KeybindActions.self,
            from: ghostty_config_keybind_actions_json()
        ) ?? .empty

        let path = configPath ?? app?.configPath
        self.editor = path.withOptionalCString { cPath in
            ghostty_config_editor_new(cPath, loadCLIArgs, Self.isDarkAppearance)
        }

        refresh()

        appearanceObserver = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.appearanceChanged() }
        }

        // The configuration can be reloaded from elsewhere (the reload
        // menu item, editing the file). Keep our view in sync.
        configObserver = NotificationCenter.default
            .publisher(for: .ghosttyConfigDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                // Only app level changes, not per-surface ones.
                guard notification.object == nil else { return }
                self?.fileEventReceived()
            }
    }

    deinit {
        if let editor { ghostty_config_editor_free(editor) }
    }

    /// Stop watching files and undo any preview. Called when the
    /// window closes.
    func close() {
        endPreview()
        watchers.forEach { $0.cancel() }
        watchers = []
        watchedPaths = []
        appearanceObserver = nil
        configObserver = nil
    }

    // MARK: Reading

    func schema(for key: String) -> SettingSchema? {
        schemaByKey[key]
    }

    func settings(in category: SettingsCategory) -> [SettingSchema] {
        schema.filter { $0.category == category }
    }

    /// The effective values of a key, as written in a configuration file.
    func values(_ key: String) -> [String] {
        snapshot.values[key] ?? []
    }

    /// The effective value of a scalar key.
    func value(_ key: String) -> String {
        values(key).first ?? ""
    }

    /// Every entry that sets the key, in load order.
    func entries(_ key: String) -> [SettingEntry] {
        snapshot.entries[key] ?? []
    }

    /// The entries that come from files (not the CLI).
    func fileEntries(_ key: String) -> [SettingEntry] {
        entries(key).filter { $0.path != nil }
    }

    /// True if a configuration file sets the key.
    func isModified(_ key: String) -> Bool {
        entries(key).contains { $0.path != nil }
    }

    /// True if a CLI argument sets the effective value, which file edits
    /// can't override.
    func isSetByCLI(_ key: String) -> Bool {
        entries(key).last?.isCLI == true
    }

    /// The file entry that determines the value (the last one).
    func origin(_ key: String) -> SettingEntry? {
        entries(key).last { $0.path != nil }
    }

    /// True if the key is set in a file other than the main config file.
    func isSetInOtherFile(_ key: String) -> Bool {
        guard let path = origin(key)?.path else { return false }
        return path != snapshot.primaryPath
    }

    /// Validate a value without writing it. Returns an error message or nil.
    func validate(_ key: String, _ value: String) -> String? {
        guard let editor else { return nil }
        let msg = Ghostty.AllocatedString(ghostty_config_editor_validate(editor, key, value)).string
        return msg.isEmpty ? nil : msg
    }

    // MARK: Writing

    /// Set a key. For repeatable keys this replaces all their values.
    @discardableResult
    func set(_ key: String, _ value: String) -> Bool {
        if value == self.value(key) && isModified(key) { return true }
        return perform(key) { editor in
            ghostty_config_editor_set(editor, key, value)
        }
    }

    /// Replace the values of a repeatable key.
    @discardableResult
    func setList(_ key: String, _ values: [String]) -> Bool {
        perform(key) { editor in
            withCStrings(values) { pointers in
                ghostty_config_editor_set_list(editor, key, pointers, UInt(values.count))
            }
        }
    }

    /// Add a value to a repeatable key.
    @discardableResult
    func add(_ key: String, _ value: String) -> Bool {
        perform(key) { editor in
            ghostty_config_editor_add(editor, key, value)
        }
    }

    /// Change one specific entry (line) of a key.
    @discardableResult
    func replace(_ key: String, entry: SettingEntry, with value: String) -> Bool {
        guard let path = entry.path, let line = entry.line else { return false }
        return perform(key) { editor in
            ghostty_config_editor_replace_entry(editor, key, path, UInt(line), value)
        }
    }

    /// Remove one specific entry (line) of a key.
    @discardableResult
    func remove(_ key: String, entry: SettingEntry) -> Bool {
        guard let path = entry.path, let line = entry.line else { return false }
        return perform(key) { editor in
            ghostty_config_editor_remove_entry(editor, key, path, UInt(line))
        }
    }

    /// Remove the key from the configuration files so the default applies.
    @discardableResult
    func reset(_ key: String) -> Bool {
        guard isModified(key) else { return true }
        return perform(key) { editor in
            ghostty_config_editor_reset(editor, key)
        }
    }

    private func perform(
        _ key: String,
        registerUndo: Bool = true,
        _ op: (ghostty_config_editor_t) -> ghostty_string_s
    ) -> Bool {
        guard let editor else { return false }
        let before = fileValues(key)
        let message = Ghostty.AllocatedString(op(editor)).string
        ignoreFileEventsUntil = Date().addingTimeInterval(1)

        guard message.isEmpty else {
            lastError = message
            refresh()
            return false
        }

        lastError = nil
        refresh()
        scheduleAppReload()
        if registerUndo { self.registerUndo(key: key, restoring: before) }
        return true
    }

    /// The values of a key as written in files, used to restore a key on undo.
    private func fileValues(_ key: String) -> [String] {
        fileEntries(key).map { $0.value ?? "true" }
    }

    private func registerUndo(key: String, restoring values: [String]) {
        let name = schema(for: key)?.label ?? key
        undoManager.registerUndo(withTarget: self) { store in
            store.restore(key: key, values: values)
        }
        undoManager.setActionName("Change \(name)")
    }

    private func restore(key: String, values: [String]) {
        let current = fileValues(key)
        let repeatable = schema(for: key)?.repeatable ?? false
        let ok: Bool
        if values.isEmpty {
            ok = perform(key, registerUndo: false) { ghostty_config_editor_reset($0, key) }
        } else if repeatable {
            ok = perform(key, registerUndo: false) { editor in
                withCStrings(values) { pointers in
                    ghostty_config_editor_set_list(editor, key, pointers, UInt(values.count))
                }
            }
        } else {
            let last = values.last ?? ""
            ok = perform(key, registerUndo: false) { ghostty_config_editor_set($0, key, last) }
        }

        // Register the opposite so redo works.
        if ok { registerUndo(key: key, restoring: current) }
    }

    // MARK: Previews

    /// Apply `key = value` to the running app without writing it. Call
    /// `endPreview` to go back to the saved configuration.
    func preview(_ key: String, _ value: String) {
        guard let editor, let ghosttyApp = app?.app else { return }
        guard let cfg = ghostty_config_editor_preview(editor, key, value) else { return }
        ghostty_app_update_config(ghosttyApp, cfg)
        ghostty_config_free(cfg)
        previewing = true
    }

    func endPreview() {
        guard previewing else { return }
        previewing = false
        app?.reloadConfig()
    }

    // MARK: Themes

    func loadThemes() {
        guard themes.isEmpty, !themesLoading else { return }
        themesLoading = true
        Task.detached(priority: .userInitiated) {
            let list = JSONDecoder.ghostty([ThemeInfo].self, from: ghostty_config_themes_json()) ?? []
            await MainActor.run {
                self.themes = list
                self.themesLoading = false
            }
        }
    }

    func theme(named name: String) -> ThemeInfo? {
        themes.first { $0.name == name }
    }

    // MARK: Files

    /// Reload everything from disk.
    func reloadFromDisk() {
        guard let editor else { return }
        let message = Ghostty.AllocatedString(ghostty_config_editor_reload(editor)).string
        if !message.isEmpty { lastError = message }
        refresh()
    }

    /// The path to open in a text editor.
    var primaryPath: String { snapshot.primaryPath }

    /// Open a configuration file in the default editor, optionally at a line.
    func openInEditor(path: String? = nil) {
        let target = path ?? primaryPath
        guard !target.isEmpty else { return }
        let url = URL(fileURLWithPath: target)
        if !FileManager.default.fileExists(atPath: target) {
            // Opening the main config via the app creates it if needed.
            app?.openConfig()
            return
        }

        NSWorkspace.shared.open(url)
    }

    /// Show a configuration file in Finder, or the nearest folder that
    /// exists if the file hasn't been created yet.
    func revealInFinder(path: String? = nil) {
        let target = path ?? primaryPath
        guard !target.isEmpty else { return }
        var url = URL(fileURLWithPath: target)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }

        // The path is absolute, so this stops at "/" at the latest.
        while !fileManager.fileExists(atPath: url.path) {
            url.deleteLastPathComponent()
        }
        NSWorkspace.shared.open(url)
    }

    private func refresh() {
        guard let editor else { return }
        if let snapshot = JSONDecoder.ghostty(
            SettingsSnapshot.self,
            from: ghostty_config_editor_snapshot_json(editor)
        ), snapshot != self.snapshot {
            self.snapshot = snapshot
        }

        updateWatchers()
    }

    private func scheduleAppReload() {
        appReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.previewing = false
            self?.app?.reloadConfig()
        }
        appReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Watch the configuration files and their directories so edits made
    /// in a text editor show up in the window.
    private func updateWatchers() {
        var paths = Set(snapshot.files)
        for file in snapshot.files {
            paths.insert((file as NSString).deletingLastPathComponent)
        }
        guard paths != watchedPaths else { return }

        watchers.forEach { $0.cancel() }
        watchers = []
        watchedPaths = paths

        for path in paths {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .delete, .rename, .extend],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.fileEventReceived() }
            }
            source.setCancelHandler { Darwin.close(fd) }
            source.resume()
            watchers.append(source)
        }
    }

    private func fileEventReceived() {
        guard Date() >= ignoreFileEventsUntil else { return }
        fileReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Files may have been replaced, so watch them again.
            self.watchedPaths = []
            self.reloadFromDisk()
        }
        fileReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: Appearance

    private static var isDarkAppearance: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func appearanceChanged() {
        guard let editor else { return }
        _ = Ghostty.AllocatedString(ghostty_config_editor_set_dark(editor, Self.isDarkAppearance))
        refresh()
    }
}

/// Call body with a C array of C strings for the given Swift strings.
private func withCStrings<R>(
    _ strings: [String],
    _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R
) -> R {
    let duplicated = strings.map { strdup($0) }
    defer { duplicated.forEach { free($0) } }
    let pointers: [UnsafePointer<CChar>?] = duplicated.map { UnsafePointer($0) }
    return pointers.withUnsafeBufferPointer { buffer in
        // An empty array still needs a valid pointer.
        guard let base = buffer.baseAddress else {
            var empty: UnsafePointer<CChar>?
            return withUnsafePointer(to: &empty) { body($0) }
        }
        return body(base)
    }
}

private extension Optional where Wrapped == String {
    func withOptionalCString<R>(_ body: (UnsafePointer<CChar>?) -> R) -> R {
        switch self {
        case .some(let string): return string.withCString { body($0) }
        case .none: return body(nil)
        }
    }
}
