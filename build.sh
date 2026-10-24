#!/bin/sh
set -e

install_app=false
for arg in "$@"; do
    case "$arg" in
        --install) install_app=true ;;
        -h|--help)
            printf 'Usage: ./build.sh [--install]\n\n'
            printf 'Build Ghostty+ with ReleaseLocal and Apple Development signing.\n'
            printf '  --install  Also replace /Applications/Ghostty+.app after building.\n'
            exit 0
            ;;
        *) printf 'Unknown option: %s\n' "$arg" >&2; exit 2 ;;
    esac
done

cd "$(dirname "$0")"
app_path="$PWD/macos/build/ReleaseLocal/Ghostty+.app"
install_path="/Applications/Ghostty+.app"

check_not_running() {
    swift - "$1" <<'SWIFT'
import AppKit
let target = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
if NSWorkspace.shared.runningApplications.contains(where: {
    $0.bundleURL?.resolvingSymlinksInPath() == target
}) {
    fputs("Quit Ghostty+ at \(target.path) before rebuilding or replacing it.\n", stderr)
    exit(1)
}
SWIFT
}

if ! security find-identity -v -p codesigning | /usr/bin/grep -Fq '"Apple Development: testors@gmail.com (P67F67JLT7)"'; then
    printf 'The configured Apple Development certificate with its private key is required.\n' >&2
    printf 'In Xcode Settings > Apple Accounts, select your team and Manage Certificates.\n' >&2
    exit 1
fi

check_not_running "$app_path"
zig build -Demit-macos-app=false -Doptimize=ReleaseFast
nu macos/build.nu --configuration ReleaseLocal
codesign --verify --deep --strict "$app_path"
printf 'Built: %s\n' "$app_path"

if [ "$install_app" = true ]; then
    check_not_running "$install_path"
    staging_dir=$(mktemp -d /Applications/.GhosttyPlus.XXXXXX)

    cleanup_install() {
        if { [ -e "$staging_dir/previous.app" ] || [ -L "$staging_dir/previous.app" ]; } &&
            [ ! -e "$install_path" ] && [ ! -L "$install_path" ]; then
            mv "$staging_dir/previous.app" "$install_path" || {
                printf 'Previous app preserved at: %s/previous.app\n' "$staging_dir" >&2
                return 1
            }
        fi
        rm -rf "$staging_dir"
    }
    trap cleanup_install EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    ditto "$app_path" "$staging_dir/Ghostty+.app"
    codesign --verify --deep --strict "$staging_dir/Ghostty+.app"
    check_not_running "$install_path"
    if [ -e "$install_path" ] || [ -L "$install_path" ]; then
        mv "$install_path" "$staging_dir/previous.app"
    fi
    mv "$staging_dir/Ghostty+.app" "$install_path"
    app_path="$install_path"
    printf 'Installed: %s\n' "$app_path"
fi

# Refresh Finder's icon after rebuilding the same app bundle in place.
touch "$app_path"
swift - "$app_path" <<'SWIFT'
import AppKit
NSWorkspace.shared.noteFileSystemChanged(CommandLine.arguments[1])
SWIFT
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f -R -trusted "$app_path"
