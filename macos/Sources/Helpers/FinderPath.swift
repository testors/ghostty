import Foundation

/// A path from terminal output that can be selected in Finder without opening it.
struct FinderPath {
    let url: URL

    init?(_ path: String) {
        guard !UntrustedURL.containsUnsafeCharacters(path) else { return nil }

        let expandedPath = NSString(string: path).expandingTildeInPath

        // The core resolves relative paths against the terminal's working
        // directory. If that failed, do not fall back to the app's directory.
        guard NSString(string: expandedPath).isAbsolutePath else { return nil }

        let url = URL(filePath: expandedPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        // Keep the symlink itself selected. Executable files and app bundles
        // are also safe here because Finder only reveals the item.
        self.url = url
    }
}
