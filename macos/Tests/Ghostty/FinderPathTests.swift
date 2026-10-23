import Foundation
import Testing
@testable import Ghostty

@Suite
struct FinderPathTests {
    @Test(arguments: ["document.txt", "한글 문서.txt", "payload.command"])
    func revealsExistingFiles(_ filename: String) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: filename)
        try "contents".write(to: file, atomically: true, encoding: .utf8)

        #expect(FinderPath(file.path)?.url == file.standardizedFileURL)
    }

    @Test
    func revealsDirectoriesAndAppBundles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appending(path: "Example.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)

        #expect(FinderPath(directory.path)?.url == directory.standardizedFileURL)
        #expect(FinderPath(bundle.path)?.url == bundle.standardizedFileURL)
    }

    @Test
    func preservesSymlinkSelection() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "document.txt")
        let link = directory.appending(path: "link.txt")
        try "contents".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        #expect(FinderPath(link.path)?.url == link.standardizedFileURL)
    }

    @Test
    func ignoresMissingFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(FinderPath(directory.appending(path: "missing.txt").path) == nil)
    }

    @Test(arguments: ["document.txt", "./document.txt", "../document.txt", "src/main.zig"])
    func ignoresUnresolvedRelativePaths(_ path: String) {
        #expect(FinderPath(path) == nil)
    }

    @Test
    func expandsHomeDirectory() {
        let expected = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        #expect(FinderPath("~/")?.url == expected)
    }

    @Test(arguments: ["\u{0085}", "\u{2028}", "\u{202E}"])
    func ignoresUnsafeCharactersEvenWhenFileExists(_ scalar: String) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "before\(scalar)after.txt")
        try "contents".write(to: file, atomically: true, encoding: .utf8)

        #expect(FinderPath(file.path) == nil)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let result = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false)
        return result
    }
}
