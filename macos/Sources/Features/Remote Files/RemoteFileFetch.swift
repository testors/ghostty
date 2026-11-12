import CoreServices
import CryptoKit
import Foundation

/// Downloads a file named in the output of a remote client (ssh, mosh) from
/// the host the client is connected to, over a separate ssh connection.
///
/// The terminal can't know the remote working directory: mosh passes no
/// OSC 7, and tmux keeps it to itself. So the host is sent a script that
/// looks for the path itself, in the directories of tmux panes (the client
/// used most recently first), of programs running on terminals, and in the
/// home directory. Nothing is ever written on the remote host.
struct RemoteFileFetch {
    /// Arguments for ssh(1) that reach the host: options, then the
    /// destination. See apprt.action.OpenRemotePath.
    let sshArgs: [String]

    /// The paths to look for, best first.
    let paths: [String]

    /// The host as the user named it, such as "spark3" or "me@host".
    var host: String { sshArgs.last ?? "" }

    /// The name of the file to show before it is found. The paths differ
    /// only in text that may follow the name, such as a line number or a
    /// Korean particle, so this is the longest one ending in an extension.
    var displayName: String {
        let path = paths.first { $0.range(of: #"\.[A-Za-z0-9]+$"#, options: .regularExpression) != nil }
            ?? paths.last
            ?? ""
        return (path as NSString).lastPathComponent
    }

    /// Files larger than this aren't downloaded.
    static let maxSize = 100 * 1024 * 1024

    /// How long a download may take, connecting included.
    static let timeout: TimeInterval = 60

    /// A downloaded file.
    struct File {
        /// The absolute path of the file on the remote host.
        let remotePath: String
        let data: Data
    }

    enum Failure: Error, Equatable {
        case notFound
        case notAFile(path: String)
        case unreadable(path: String)
        case tooLarge(path: String, size: Int)
        case incomplete
        case timedOut
        case ssh(message: String)

        /// A sentence for the user saying what went wrong.
        func message(host: String) -> String {
            switch self {
            case .notFound:
                return "The file wasn't found on \(host). Relative paths are looked for in the "
                    + "directories of tmux panes and of programs running in terminals there."
            case .notAFile(let path):
                return "\(path) on \(host) isn't a file."
            case .unreadable(let path):
                return "\(path) on \(host) can't be read."
            case .tooLarge(let path, let size):
                let formatter = ByteCountFormatter()
                return "\(path) on \(host) is too large to download "
                    + "(\(formatter.string(fromByteCount: Int64(size))))."
            case .incomplete:
                return "The download from \(host) ended early."
            case .timedOut:
                return "\(host) didn't respond in time."
            case .ssh(let message):
                var text = "ssh couldn't get the file from \(host)."
                if message.contains("Permission denied") {
                    text += " It needs to log in without asking for a password or passphrase, "
                        + "for example with a key in ssh-agent."
                }
                if !message.isEmpty { text += "\n\n\(message)" }
                return text
            }
        }
    }

    /// The ssh command that runs a shell on the host, reading the script
    /// from its input. Our options come first so they win over the user's
    /// (ssh uses the first value it gets): no password prompts, no tty, no
    /// port forwarding and no RemoteCommand from ~/.ssh/config.
    ///
    /// Setting up an ssh connection takes many round trips, seconds over a
    /// slow network, so the connection is kept for a while and reused by
    /// later downloads from the same host (see `controlDirectory`).
    var command: (executable: URL, arguments: [String]) {
        var options = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ClearAllForwardings=yes",
            "-o", "RequestTTY=no",
            "-o", "RemoteCommand=none",
            "-o", "PermitLocalCommand=no",
        ]
        if let directory = Self.controlDirectory() {
            options += [
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(directory)/%C",
                "-o", "ControlPersist=\(Self.controlPersist)",
            ]
        }
        return (URL(filePath: "/usr/bin/ssh"), options + sshArgs + ["sh -s"])
    }

    /// How long a connection is kept after its last download.
    static let controlPersist = "10m"

    /// The directory for the sockets of kept ssh connections, or nil if it
    /// can't be made safely. Anyone who could put a socket there could
    /// pose as the host, so it must be a directory only we can use. It is
    /// in /tmp because socket paths are limited to 104 bytes, which the
    /// per-user temporary directory leaves no room for.
    static func controlDirectory(base: String = "/tmp") -> String? {
        let uid = getuid()
        let path = "\(base)/ghostty-ssh-\(uid)"
        if mkdir(path, 0o700) != 0 && errno != EEXIST { return nil }

        // Not a symlink, ours, and closed to others.
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == uid,
              info.st_mode & 0o077 == 0
        else { return nil }
        return path
    }

    /// Downloads the file over ssh. This blocks, so call it off the main
    /// thread.
    func run() throws -> File {
        let command = self.command
        return try run(executable: command.executable, arguments: command.arguments)
    }

    /// Runs a program that reads a shell script from its input, writes the
    /// script to it and reads the file from its output. `run()` uses ssh;
    /// tests run sh directly.
    func run(executable: URL, arguments: [String]) throws -> File {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        // Drain stderr while we read stdout, so neither pipe fills up and
        // stalls ssh.
        var errorData = Data()
        let stderrDone = DispatchGroup()
        stderrDone.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorData = errors.fileHandleForReading.readDataToEndOfFile()
            stderrDone.leave()
        }

        let timedOut = TimeoutFlag()
        let timer = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            timedOut.set()
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout, execute: timer)
        defer { timer.cancel() }

        // ssh may exit before reading it all, for example if it can't
        // connect. Its exit status tells what happened.
        try? input.fileHandleForWriting.write(contentsOf: Data(Self.script(paths: paths).utf8))
        try? input.fileHandleForWriting.close()

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        stderrDone.wait()
        process.waitUntilExit()

        if timedOut.isSet { throw Failure.timedOut }

        // A response, even an error from our script, means we connected.
        if let file = try Self.parse(outputData) { return file }

        let message = (String(bytes: errorData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw Failure.ssh(message: message)
    }

    // MARK: Protocol

    /// Starts the line that our script prints before the file or an error.
    /// Anything the remote shell prints before it, such as a greeting from
    /// a shell startup file, is skipped.
    static let marker = "__GHOSTTY_REMOTE_FILE__"

    /// Quotes `value` for a POSIX shell.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The script the remote host runs with sh. It is wrapped in a function
    /// so sh has read all of it before any command runs; otherwise a command
    /// reading its input would eat the rest of the script.
    static func script(paths: [String]) -> String {
        let quoted = paths.map(shellQuote).joined(separator: " ")
        return #"""
        ghostty_fetch() {
            set -f
            m=\#(marker)
            max=\#(maxSize)
            nl='
        '
            found=
            other=

            # Where relative paths may be: the panes of tmux clients, the
            # one used last first, then the other panes.
            tmux_dirs() {
                command -v tmux >/dev/null 2>&1 || return 0
                tmux list-clients -F '#{client_activity} #{pane_current_path}' 2>/dev/null |
                    sort -rn | cut -d' ' -f2-
                tmux list-panes -a -F '#{session_attached}#{window_active}#{pane_active} #{pane_current_path}' 2>/dev/null |
                    sort -r | cut -d' ' -f2-
            }

            # ...then the directories of our programs running on terminals,
            # and home.
            other_dirs() {
                if [ -d /proc/self ]; then
                    ps -o pid= -o tty= -u "$(id -u)" 2>/dev/null | while read -r pid tty; do
                        case $tty in ''|'?'|'??') continue ;; esac
                        readlink "/proc/$pid/cwd" 2>/dev/null
                    done
                elif command -v lsof >/dev/null 2>&1; then
                    lsof -a -d cwd -u "$(id -u)" -Fn 2>/dev/null | sed -n 's/^n//p'
                fi
                printf '%s\n' "$HOME"
            }

            try_path() {
                if [ -f "$1" ]; then
                    found=$1
                    return 0
                fi
                if [ -z "$other" ] && [ -e "$1" ]; then other=$1; fi
                return 1
            }

            # Looks for the paths, best first, in the directories in $1.
            search() {
                dirs=$1
                shift
                for p in "$@"; do
                    case $p in
                        /*) try_path "$p" && return 0 ;;
                        '~/'*) try_path "$HOME/${p#??}" && return 0 ;;
                        *)
                            IFS=$nl
                            for d in $dirs; do
                                [ -n "$d" ] || continue
                                try_path "$d/$p" && { unset IFS; return 0; }
                            done
                            unset IFS
                            ;;
                    esac
                done
                return 1
            }

            if ! search "$(tmux_dirs | awk '!seen[$0]++')" "$@" &&
                ! search "$(other_dirs | awk '!seen[$0]++')" "$@"; then
                if [ -n "$other" ]; then
                    printf '%s ERR notfile %s\n' "$m" "$other"
                else
                    printf '%s ERR missing\n' "$m"
                fi
                return 0
            fi

            dir=$(cd -P -- "$(dirname -- "$found")" 2>/dev/null && pwd -P) || dir=$(dirname -- "$found")
            abs="${dir%/}/$(basename -- "$found")"
            if [ ! -r "$found" ]; then
                printf '%s ERR unreadable %s\n' "$m" "$abs"
                return 0
            fi
            size=$(wc -c <"$found" | tr -d ' ')
            if [ "$size" -gt "$max" ]; then
                printf '%s ERR toobig %s %s\n' "$m" "$size" "$abs"
                return 0
            fi
            printf '%s OK %s %s\n' "$m" "$size" "$abs"
            cat -- "$found"
        }
        ghostty_fetch \#(quoted) </dev/null

        """#
    }

    /// Reads the output of the script. Returns nil if it has no response,
    /// for example because ssh couldn't connect.
    static func parse(_ output: Data) throws -> File? {
        let marker = Data((self.marker + " ").utf8)
        var searchStart = output.startIndex
        var headerStart: Data.Index?
        while let range = output.range(of: marker, in: searchStart..<output.endIndex) {
            if range.lowerBound == output.startIndex || output[range.lowerBound - 1] == 0x0A {
                headerStart = range.upperBound
                break
            }
            searchStart = range.upperBound
        }
        guard let headerStart,
              let newline = output[headerStart...].firstIndex(of: 0x0A)
        else { return nil }

        let header = String(bytes: output[headerStart..<newline], encoding: .utf8) ?? ""
        let content = output[(newline + 1)...]
        let fields = header.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            .map(String.init)

        switch (fields.first, fields.count) {
        case ("OK", 3):
            // OK <size> <path>
            let rest = fields[2]
            guard let size = Int(fields[1]), !rest.isEmpty else { throw Failure.incomplete }
            guard content.count == size else { throw Failure.incomplete }
            return File(remotePath: rest, data: Data(content))

        case ("ERR", _):
            let kind = fields.count > 1 ? fields[1] : ""
            let detail = fields.count > 2 ? fields[2] : ""
            switch kind {
            case "notfile":
                throw Failure.notAFile(path: detail)
            case "unreadable":
                throw Failure.unreadable(path: detail)
            case "toobig":
                // toobig <size> <path>
                let parts = detail.split(separator: " ", maxSplits: 1).map(String.init)
                throw Failure.tooLarge(
                    path: parts.count > 1 ? parts[1] : "",
                    size: Int(parts.first ?? "") ?? 0
                )
            default:
                throw Failure.notFound
            }

        default:
            throw Failure.incomplete
        }
    }

    // MARK: Local copy

    /// Where downloads are kept: the per-user temporary directory, which
    /// macOS cleans up on its own.
    static var downloadsDirectory: URL {
        FileManager.default.temporaryDirectory
            .appending(path: "Ghostty Remote Files", directoryHint: .isDirectory)
    }

    /// Saves `file` under `directory` and returns where. Each remote file
    /// gets its own folder, named after the host and path, so the copy
    /// keeps the remote name and downloading it again replaces it.
    static func save(
        _ file: File,
        host: String,
        in directory: URL = downloadsDirectory
    ) throws -> URL {
        let digest = SHA256.hash(data: Data("\(host)\0\(file.remotePath)".utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        let folder = directory
            .appending(path: safeName(host, fallback: "host"), directoryHint: .isDirectory)
            .appending(path: digest, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let name = safeName(
            (file.remotePath as NSString).lastPathComponent,
            fallback: "file"
        )
        var url = folder.appending(path: name, directoryHint: .notDirectory)
        try file.data.write(to: url, options: .atomic)

        // Mark the copy as downloaded, so Gatekeeper checks it if it is
        // opened from Quick Look.
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
            kLSQuarantineAgentNameKey as String: "Ghostty",
        ]
        try? url.setResourceValues(values)

        return url
    }

    /// `name` as a single safe file name.
    private static func safeName(_ name: String, fallback: String) -> String {
        let cleaned = String(name.map { $0 == "/" || $0 == ":" || $0.isNewline ? "_" : $0 })
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return fallback }
        return cleaned
    }
}

/// A flag set from one thread and read from another.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
