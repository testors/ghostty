import Foundation
import Testing
@testable import Ghostty

/// The script normally runs on the remote host through ssh. These tests
/// run it with the local sh instead, with a temporary directory as home.
@Suite
struct RemoteFileFetchTests {
    @Test
    func fetchesAbsolutePaths() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appending(path: "it's a file.png")
        try Data([0, 1, 2, 0x0A, 0xFF]).write(to: file)

        let result = try fetch([file.path], home: home)
        #expect(result.remotePath == realPath(file))
        #expect(result.data == Data([0, 1, 2, 0x0A, 0xFF]))
    }

    @Test
    func fetchesRelativePathsFromHomeAndTrimsTrailingText() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let name = "outputs/\(UUID().uuidString)/README.md"
        let file = home.appending(path: name)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "# Result\n".write(to: file, atomically: true, encoding: .utf8)

        // The core sends the whole match first, then shorter candidates.
        let result = try fetch(["\(name)에서", "\(name)에", name], home: home)
        #expect(result.remotePath == realPath(file))
        #expect(String(bytes: result.data, encoding: .utf8) == "# Result\n")
    }

    @Test
    func fetchesTildePaths() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try "notes".write(to: home.appending(path: "notes.md"), atomically: true, encoding: .utf8)

        let result = try fetch(["~/notes.md"], home: home)
        #expect(String(bytes: result.data, encoding: .utf8) == "notes")
    }

    @Test
    func reportsMissingFilesAndDirectories() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appending(path: "dir.d", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

        #expect(throws: RemoteFileFetch.Failure.notFound) {
            try fetch(["missing/\(UUID().uuidString).md"], home: home)
        }
        #expect(throws: RemoteFileFetch.Failure.notAFile(path: directory.resolvingSymlinksInPath().path)) {
            try fetch([directory.path], home: home)
        }
    }

    @Test
    func skipsOutputBeforeTheResponse() throws {
        let output = Data("Welcome!\nlast login\n\(RemoteFileFetch.marker) OK 3 /a b/c.txt\nabc".utf8)
        let file = try #require(try RemoteFileFetch.parse(output))
        #expect(file.remotePath == "/a b/c.txt")
        #expect(file.data == Data("abc".utf8))
    }

    @Test
    func parsesErrorsAndTruncatedFiles() throws {
        #expect(try RemoteFileFetch.parse(Data("Permission denied\n".utf8)) == nil)
        #expect(throws: RemoteFileFetch.Failure.tooLarge(path: "/big file", size: 200)) {
            try RemoteFileFetch.parse(Data("\(RemoteFileFetch.marker) ERR toobig 200 /big file\n".utf8))
        }
        #expect(throws: RemoteFileFetch.Failure.incomplete) {
            try RemoteFileFetch.parse(Data("\(RemoteFileFetch.marker) OK 10 /a\nabc".utf8))
        }
    }

    @Test
    func sshCommandPutsOurOptionsFirst() {
        let fetch = RemoteFileFetch(sshArgs: ["-p", "2222", "spark3"], paths: ["a/b.md"])
        let command = fetch.command
        #expect(command.executable.path == "/usr/bin/ssh")
        #expect(command.arguments.first == "-T")
        #expect(Array(command.arguments.suffix(4)) == ["-p", "2222", "spark3", "sh -s"])
        #expect(fetch.host == "spark3")
    }

    @Test(arguments: [
        (["docs/protocol.md에서", "docs/protocol.md에", "docs/protocol.md"], "protocol.md"),
        (["src/main.zig:42:10", "src/main.zig:42", "src/main.zig"], "main.zig"),
        (["~/notes/a b.txt for", "~/notes/a b.txt", "~/notes/a"], "a b.txt"),
        (["outputs/run/README.md"], "README.md"),
        (["bin/tool"], "tool"),
    ])
    func displayNameSkipsTrailingText(paths: [String], expected: String) {
        #expect(RemoteFileFetch(sshArgs: ["host"], paths: paths).displayName == expected)
    }

    @Test
    func savesCopiesNamedAfterTheRemoteFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = RemoteFileFetch.File(remotePath: "/home/me/run/pose.png", data: Data("png".utf8))

        let url = try RemoteFileFetch.save(file, host: "me@spark3", in: directory)
        #expect(url.lastPathComponent == "pose.png")
        #expect(url.path.hasPrefix(directory.appending(path: "me@spark3").path))
        #expect(try Data(contentsOf: url) == Data("png".utf8))

        // The same file again replaces the copy.
        #expect(try RemoteFileFetch.save(file, host: "me@spark3", in: directory) == url)
    }

    private func fetch(_ paths: [String], home: URL) throws -> RemoteFileFetch.File {
        try RemoteFileFetch(sshArgs: ["localhost"], paths: paths).run(
            executable: URL(filePath: "/usr/bin/env"),
            arguments: ["HOME=\(home.path)", "/bin/sh", "-s"]
        )
    }

    /// The path with symlinks resolved, as `pwd -P` gives it. Unlike
    /// resolvingSymlinksInPath, this keeps /private in /private/var.
    private func realPath(_ url: URL) -> String {
        guard let path = realpath(url.path, nil) else { return url.path }
        defer { free(path) }
        return String(cString: path)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.resolvingSymlinksInPath()
    }
}
