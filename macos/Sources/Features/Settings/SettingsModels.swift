import Foundation
import GhosttyKit

/// The settings pages. Mirrors `schema.Category` in `src/config/schema.zig`.
enum SettingsCategory: String, CaseIterable, Identifiable, Hashable, Decodable {
    case general
    case appearance
    case font
    case window
    case terminal
    case mouse
    case keybindings
    case quickTerminal = "quick_terminal"
    case notifications
    case macos
    case linux

    var id: String { rawValue }

    /// Categories shown in the sidebar on this platform.
    static var visible: [SettingsCategory] {
        allCases.filter { $0 != .linux }
    }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .font: return "Font"
        case .window: return "Window & Tabs"
        case .terminal: return "Terminal"
        case .mouse: return "Mouse & Clipboard"
        case .keybindings: return "Keybindings"
        case .quickTerminal: return "Quick Terminal"
        case .notifications: return "Notifications & Bell"
        case .macos: return "macOS"
        case .linux: return "Linux"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "circle.lefthalf.filled"
        case .font: return "textformat"
        case .window: return "macwindow"
        case .terminal: return "terminal"
        case .mouse: return "cursorarrow.click"
        case .keybindings: return "command"
        case .quickTerminal: return "rectangle.topthird.inset.filled"
        case .notifications: return "bell"
        case .macos: return "laptopcomputer"
        case .linux: return "server.rack"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SettingsCategory(rawValue: raw) ?? .general
    }
}

/// One configuration key. Mirrors the JSON written by `schema.writeJson`.
struct SettingSchema: Decodable, Identifiable, Hashable {
    enum Kind: String, Decodable {
        case bool, int, float, string, `enum`, flags, color, path, font, theme, keybind, palette, duration

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .string
        }
    }

    enum Apply: String, Decodable {
        case live
        case newTerminal = "new_terminal"
        case newWindow = "new_window"
        case restart

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Apply(rawValue: raw) ?? .live
        }

        /// A short note for settings that don't apply to open terminals
        /// right away. Shown as the tooltip of `systemImage`.
        var note: String? {
            switch self {
            case .live: return nil
            case .newTerminal: return "Applies to new terminals only"
            case .newWindow: return "Applies to new windows only"
            case .restart: return "Requires restarting Ghostty"
            }
        }

        /// The icon shown next to the setting's name.
        var systemImage: String? {
            switch self {
            case .live: return nil
            case .newTerminal, .newWindow: return "n.circle"
            case .restart: return "arrow.clockwise.circle"
            }
        }
    }

    let key: String
    let label: String
    let category: SettingsCategory
    let kind: Kind
    let optional: Bool
    let repeatable: Bool
    let values: [String]
    let flags: [String]
    let apply: Apply
    let defaultValues: [String]
    let summary: String
    let doc: String

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, label, category, kind, optional, repeatable, values, flags, apply, summary, doc
        case defaultValues = "default"
    }

    /// The default value as a single string (scalar keys).
    var defaultValue: String { defaultValues.first ?? "" }

    /// True if the text matches this setting for search.
    func matches(_ query: String) -> Bool {
        let q = query.lowercased()
        return label.lowercased().contains(q) ||
            key.contains(q) ||
            summary.lowercased().contains(q)
    }

    /// True if the name (not the documentation) matches.
    func nameMatches(_ query: String) -> Bool {
        let q = query.lowercased()
        return label.lowercased().contains(q) || key.contains(q)
    }
}

/// One entry for a key in a configuration file or the CLI.
struct SettingEntry: Decodable, Hashable {
    let value: String?
    let path: String?
    let line: Int?
    let cli: Int?

    var isCLI: Bool { cli != nil }

    /// "file.ghostty:12" or "command line".
    var locationDescription: String {
        if let cli { return "command-line argument \(cli)" }
        guard let path else { return "" }
        let name = (path as NSString).lastPathComponent
        if let line { return "\(name):\(line)" }
        return name
    }
}

/// The current state of the configuration. Mirrors the JSON written by
/// `Editor.writeSnapshotJson`.
struct SettingsSnapshot: Decodable, Equatable {
    var primaryPath: String
    var files: [String]
    var diagnostics: [String]
    var values: [String: [String]]
    var entries: [String: [SettingEntry]]

    enum CodingKeys: String, CodingKey {
        case primaryPath = "primary_path"
        case files, diagnostics, values, entries
    }

    static let empty = SettingsSnapshot(primaryPath: "", files: [], diagnostics: [], values: [:], entries: [:])
}

/// A theme that can be set with `theme`.
struct ThemeInfo: Decodable, Identifiable, Hashable {
    let name: String
    let path: String
    let location: String
    let dark: Bool
    let background: String
    let foreground: String
    let palette: [String]

    var id: String { name }
}

/// The actions a keybinding can trigger.
struct KeybindActions: Decodable {
    struct Command: Decodable, Hashable {
        let action: String
        let title: String
        let description: String
    }

    struct Action: Decodable, Hashable {
        let name: String
        let param: Bool
    }

    let commands: [Command]
    let actions: [Action]

    static let empty = KeybindActions(commands: [], actions: [])

    /// A human readable title for an action string such as
    /// "new_split:right", falling back to the action itself.
    func title(for action: String) -> String {
        if let command = commands.first(where: { $0.action == action }) {
            return command.title
        }

        let name = action.split(separator: ":", maxSplits: 1).first.map(String.init) ?? action
        let words = name.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let title = words.joined(separator: " ")
        if let colon = action.firstIndex(of: ":") {
            return "\(title) (\(action[action.index(after: colon)...]))"
        }
        return title
    }
}

/// The value of the `theme` key: either a single theme or a pair of
/// themes for light and dark mode (`light:A,dark:B`).
struct ThemeValue: Equatable {
    var light: String
    var dark: String

    init(light: String, dark: String) {
        self.light = light
        self.dark = dark
    }

    init(_ raw: String) {
        var light: String?
        var dark: String?
        for part in raw.split(separator: ",") {
            let item = part.trimmingCharacters(in: .whitespaces)
            if item.hasPrefix("light:") {
                light = String(item.dropFirst("light:".count)).trimmingCharacters(in: .whitespaces)
            } else if item.hasPrefix("dark:") {
                dark = String(item.dropFirst("dark:".count)).trimmingCharacters(in: .whitespaces)
            }
        }

        if light == nil && dark == nil {
            let single = raw.trimmingCharacters(in: .whitespaces)
            self.init(light: single, dark: single)
        } else {
            self.init(light: light ?? dark ?? "", dark: dark ?? light ?? "")
        }
    }

    /// True if light and dark mode use different themes.
    var isPair: Bool { light != dark }

    var configValue: String {
        if !isPair { return light }
        return "light:\(light),dark:\(dark)"
    }
}

extension JSONDecoder {
    /// Decode JSON returned by libghostty, freeing the string.
    static func ghostty<T: Decodable>(_ type: T.Type, from string: ghostty_string_s) -> T? {
        let json = Ghostty.AllocatedString(string).string
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            Ghostty.logger.warning("failed to decode settings json: \(error, privacy: .public)")
            return nil
        }
    }
}
