import Foundation
import Testing
@testable import Ghostty

/// A temporary directory with a config file for settings store tests.
private final class TemporaryConfigDir {
    let url: URL

    init(_ files: [String: String]) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, contents) in files {
            try contents.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    func path(_ name: String) -> String {
        url.appendingPathComponent(name).path
    }

    func read(_ name: String) throws -> String {
        try String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

@Suite
@MainActor
struct SettingsStoreTests {
    private func store(_ dir: TemporaryConfigDir) -> SettingsStore {
        SettingsStore(app: nil, configPath: dir.path("config"), loadCLIArgs: false)
    }

    @Test func loadsSchemaAndValues() throws {
        let dir = try TemporaryConfigDir(["config": "font-size = 13\n"])
        let store = store(dir)
        #expect(store.schema.count > 100)
        #expect(store.schema(for: "font-size")?.kind == .float)
        #expect(store.value("font-size") == "13")
        #expect(store.isModified("font-size"))
        #expect(!store.isModified("cursor-style"))
        #expect(store.origin("font-size")?.line == 1)
    }

    @Test func setWritesInPlace() throws {
        let dir = try TemporaryConfigDir(["config": "# mine\nfont-size = 13\n# end\n"])
        let store = store(dir)
        #expect(store.set("font-size", "15"))
        #expect(try dir.read("config") == "# mine\nfont-size = 15\n# end\n")
        #expect(store.value("font-size") == "15")
    }

    @Test func setRejectsInvalidValues() throws {
        let dir = try TemporaryConfigDir(["config": "font-size = 13\n"])
        let store = store(dir)
        #expect(!store.set("cursor-style", "triangle"))
        #expect(store.lastError != nil)
        #expect(store.validate("cursor-style", "triangle") != nil)
        #expect(store.validate("cursor-style", "bar") == nil)
        #expect(try dir.read("config") == "font-size = 13\n")
    }

    @Test func resetAndUndo() throws {
        let dir = try TemporaryConfigDir(["config": "font-size = 13\ncursor-style = bar\n"])
        let store = store(dir)
        #expect(store.reset("cursor-style"))
        #expect(try dir.read("config") == "font-size = 13\n")
        #expect(!store.isModified("cursor-style"))

        store.undoManager.undo()
        #expect(store.value("cursor-style") == "bar")
        #expect(store.isModified("cursor-style"))

        store.undoManager.redo()
        #expect(!store.isModified("cursor-style"))
    }

    @Test func undoNewKeyRemovesIt() throws {
        let dir = try TemporaryConfigDir(["config": "font-size = 13\n"])
        let store = store(dir)
        #expect(store.set("cursor-style", "bar"))
        #expect(store.isModified("cursor-style"))
        store.undoManager.undo()
        #expect(!store.isModified("cursor-style"))
        #expect(!(try dir.read("config")).contains("cursor-style = bar"))
    }

    @Test func includedFilesAreEditedInPlace() throws {
        let dir = try TemporaryConfigDir([
            "config": "config-file = mac.ghostty\n",
            "mac.ghostty": "macos-option-as-alt = left\n",
        ])
        let store = store(dir)
        #expect(store.isSetInOtherFile("macos-option-as-alt"))
        #expect(store.set("macos-option-as-alt", "right"))
        #expect(try dir.read("mac.ghostty") == "macos-option-as-alt = right\n")
        #expect(try dir.read("config") == "config-file = mac.ghostty\n")
    }

    @Test func repeatableKeys() throws {
        let dir = try TemporaryConfigDir(["config": "font-family = A\nfont-size = 13\nfont-family = B\n"])
        let store = store(dir)
        #expect(store.setList("font-family", ["B", "A"]))
        #expect(try dir.read("config") == "font-family = B\nfont-family = A\nfont-size = 13\n")

        #expect(store.add("keybind", "ctrl+a=new_window"))
        let entry = try #require(store.fileEntries("keybind").first)
        #expect(store.replace("keybind", entry: entry, with: "ctrl+b=new_window"))
        #expect(store.fileEntries("keybind").first?.value == "ctrl+b=new_window")
        let updated = try #require(store.fileEntries("keybind").first)
        #expect(store.remove("keybind", entry: updated))
        #expect(store.fileEntries("keybind").isEmpty)
    }

    @Test func reloadsAfterExternalEdit() throws {
        let dir = try TemporaryConfigDir(["config": "font-size = 13\n"])
        let store = store(dir)
        try "font-size = 20\n".write(toFile: dir.path("config"), atomically: true, encoding: .utf8)
        store.reloadFromDisk()
        #expect(store.value("font-size") == "20")
    }
}

@Suite
struct KeybindStringTests {
    @Test func split() {
        #expect(KeybindString.split("super+t=new_tab")! == ("super+t", "new_tab"))
        #expect(KeybindString.split("ctrl+==increase_font_size:1")! == ("ctrl+=", "increase_font_size:1"))
        #expect(KeybindString.split("a>b=text:=")! == ("a>b", "text:="))
        #expect(KeybindString.split("clear") == nil)
    }

    @Test func normalize() {
        #expect(KeybindString.normalize("cmd+shift+T") == KeybindString.normalize("shift+super+t"))
        #expect(KeybindString.normalize("global:opt+space") == "global:alt+space")
        #expect(KeybindString.normalize("ctrl+a>n") == "ctrl+a>n")
    }

    @Test func keycaps() {
        let caps = KeybindString.keycaps("global:super+shift+arrow_up")
        #expect(caps.flags == ["global"])
        #expect(caps.sequence == [["⌘", "⇧", "↑"]])
        #expect(KeybindString.keycaps("ctrl+a>n").sequence == [["⌃", "A"], ["N"]])
    }
}

@Suite
struct ThemeValueTests {
    @Test func single() {
        let theme = ThemeValue("Dracula")
        #expect(theme.light == "Dracula")
        #expect(theme.dark == "Dracula")
        #expect(!theme.isPair)
        #expect(theme.configValue == "Dracula")
    }

    @Test func pair() {
        let theme = ThemeValue("light:Rose Pine Dawn,dark:Catppuccin Mocha")
        #expect(theme.light == "Rose Pine Dawn")
        #expect(theme.dark == "Catppuccin Mocha")
        #expect(theme.configValue == "light:Rose Pine Dawn,dark:Catppuccin Mocha")
    }

    @Test func onlyOneSide() {
        let theme = ThemeValue("dark:Nord")
        #expect(theme.light == "Nord")
        #expect(theme.dark == "Nord")
    }
}
