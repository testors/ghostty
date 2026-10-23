/// How settings are grouped on each page. Keys listed here are shown
/// first, in sections. Every other key of the page's category is shown
/// under "Advanced", so every setting is reachable even if it isn't
/// listed here (new configuration keys show up automatically).
enum SettingsLayout {
    struct Section: Identifiable {
        let title: String
        let keys: [String]

        var id: String { title }
    }

    static func sections(for category: SettingsCategory) -> [Section] {
        switch category {
        case .general:
            return [
                Section(title: "Startup", keys: [
                    "window-save-state",
                    "working-directory",
                    "command",
                    "initial-window",
                ]),
                Section(title: "Closing", keys: [
                    "confirm-close-surface",
                    "quit-after-last-window-closed",
                    "quit-after-last-window-closed-delay",
                    "undo-timeout",
                ]),
                Section(title: "Updates", keys: [
                    "auto-update",
                    "auto-update-channel",
                ]),
                Section(title: "Configuration Files", keys: [
                    "config-file",
                ]),
            ]

        case .appearance:
            return [
                Section(title: "Background", keys: [
                    "background-opacity",
                    "background-blur",
                    "background-opacity-cells",
                ]),
                Section(title: "Colors", keys: [
                    "background",
                    "foreground",
                    "selection-background",
                    "selection-foreground",
                    "minimum-contrast",
                ]),
                Section(title: "Cursor", keys: [
                    "cursor-style",
                    "cursor-style-blink",
                    "cursor-color",
                    "cursor-opacity",
                ]),
                Section(title: "Splits", keys: [
                    "unfocused-split-opacity",
                    "unfocused-split-fill",
                    "split-divider-color",
                ]),
            ]

        case .font:
            return [
                Section(title: "Size & Rendering", keys: [
                    "font-size",
                    "font-thicken",
                    "font-thicken-strength",
                    "font-feature",
                    "adjust-cell-height",
                    "adjust-cell-width",
                ]),
            ]

        case .window:
            return [
                Section(title: "Size", keys: [
                    "window-width",
                    "window-height",
                    "maximize",
                    "fullscreen",
                ]),
                Section(title: "Padding", keys: [
                    "window-padding-x",
                    "window-padding-y",
                    "window-padding-balance",
                    "window-padding-color",
                ]),
                Section(title: "Tabs", keys: [
                    "window-new-tab-position",
                    "window-show-tab-bar",
                    "tab-title-format",
                ]),
                Section(title: "Window", keys: [
                    "window-decoration",
                    "window-theme",
                    "window-colorspace",
                    "title",
                ]),
            ]

        case .terminal:
            return [
                Section(title: "Shell", keys: [
                    "shell-integration",
                    "shell-integration-features",
                    "term",
                ]),
                Section(title: "Scrollback", keys: [
                    "scrollback-limit-bytes",
                    "scrollbar",
                    "scroll-to-bottom",
                ]),
                Section(title: "Links", keys: [
                    "link-url",
                    "link-previews",
                ]),
            ]

        case .mouse:
            return [
                Section(title: "Mouse", keys: [
                    "mouse-hide-while-typing",
                    "mouse-scroll-multiplier",
                    "focus-follows-mouse",
                    "right-click-action",
                    "middle-click-action",
                ]),
                Section(title: "Clipboard", keys: [
                    "copy-on-select",
                    "clipboard-read",
                    "clipboard-write",
                    "clipboard-paste-protection",
                    "clipboard-trim-trailing-spaces",
                ]),
            ]

        case .quickTerminal:
            return [
                Section(title: "Position", keys: [
                    "quick-terminal-position",
                    "quick-terminal-size",
                    "quick-terminal-screen",
                ]),
                Section(title: "Behavior", keys: [
                    "quick-terminal-animation-duration",
                    "quick-terminal-autohide",
                    "quick-terminal-space-behavior",
                ]),
            ]

        case .notifications:
            return [
                Section(title: "Bell", keys: [
                    "bell-features",
                    "bell-audio-path",
                    "bell-audio-volume",
                ]),
                Section(title: "Notifications", keys: [
                    "app-notifications",
                    "desktop-notifications",
                    "notify-on-command-finish",
                    "notify-on-command-finish-action",
                    "notify-on-command-finish-after",
                ]),
            ]

        case .macos:
            return [
                Section(title: "Titlebar", keys: [
                    "macos-titlebar-style",
                    "macos-titlebar-proxy-icon",
                    "macos-titlebar-remote-indicator",
                    "macos-window-buttons",
                ]),
                Section(title: "Keyboard", keys: [
                    "macos-option-as-alt",
                    "macos-auto-secure-input",
                    "macos-secure-input-indication",
                ]),
                Section(title: "App Icon", keys: [
                    "macos-icon",
                    "macos-icon-frame",
                    "macos-icon-ghost-color",
                    "macos-icon-screen-color",
                    "macos-custom-icon",
                ]),
            ]

        case .keybindings, .linux:
            return []
        }
    }

    /// Keys a page shows with its own custom UI instead of a row.
    static func customKeys(for category: SettingsCategory) -> Set<String> {
        switch category {
        case .appearance: return ["theme", "palette"]
        case .font: return ["font-family"]
        case .keybindings: return ["keybind"]
        default: return []
        }
    }

    /// Floats that are a fraction from 0 to 1 and get a slider.
    static let fractions: Set<String> = [
        "background-opacity",
        "background-image-opacity",
        "unfocused-split-opacity",
        "cursor-opacity",
        "faint-opacity",
        "bell-audio-volume",
    ]
}
