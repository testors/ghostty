import AppKit
import SwiftUI

/// The top of the Font page: a live preview and the ordered list of
/// font families (the first is the primary font, the rest are
/// fallbacks for characters it doesn't have).
struct FontSection: View {
    @ObservedObject var store: SettingsStore

    private static let key = "font-family"

    /// The families written in files, in order.
    private var families: [String] {
        store.fileEntries(Self.key).compactMap(\.value).filter { !$0.isEmpty }
    }

    var body: some View {
        Section {
            FontPreview(store: store)
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
        }

        Section {
            let families = self.families
            if families.isEmpty {
                HStack {
                    Text("Default")
                    Text("JetBrains Mono, bundled with Ghostty")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(Array(families.enumerated()), id: \.offset) { index, family in
                HStack(spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(family).font(.custom(family, size: 13))
                        Text(index == 0 ? "Primary" : "Fallback")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        move(index, by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(index == 0)
                    .accessibilityLabel("Move \(family) up")
                    Button {
                        move(index, by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(index == families.count - 1)
                    .accessibilityLabel("Move \(family) down")
                    Button {
                        var next = families
                        next.remove(at: index)
                        write(next)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .accessibilityLabel("Remove \(family)")
                }
                .buttonStyle(.borderless)
            }

            HStack {
                Menu {
                    Section("Monospaced") {
                        ForEach(MonospaceFonts.families, id: \.self) { family in
                            Button(family) { write(families + [family]) }
                        }
                    }
                    Menu("All Fonts") {
                        ForEach(NSFontManager.shared.availableFontFamilies.sorted(), id: \.self) { family in
                            Button(family) { write(families + [family]) }
                        }
                    }
                } label: {
                    Label(families.isEmpty ? "Choose Font…" : "Add Fallback Font…", systemImage: "plus")
                }
                .fixedSize()

                Spacer()

                if store.isModified(Self.key) {
                    Button("Use Default") { store.reset(Self.key) }
                        .buttonStyle(.link)
                }
            }
        } header: {
            Text("Family")
        } footer: {
            Text("Characters missing from a font are taken from the next one. Add a font for your language (for example Apple SD Gothic Neo for Korean) as a fallback.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func move(_ index: Int, by offset: Int) {
        var next = families
        let target = index + offset
        guard next.indices.contains(target) else { return }
        next.swapAt(index, target)
        write(next)
    }

    private func write(_ families: [String]) {
        if families.isEmpty {
            store.reset(Self.key)
        } else {
            store.setList(Self.key, families)
        }
    }
}

/// A sample of terminal output in the configured font and colors.
struct FontPreview: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        let families = store.values("font-family").filter { !$0.isEmpty }
        let size = CGFloat(Double(store.value("font-size")) ?? 13)
        let font: Font = families.first.map { .custom($0, size: size) }
            ?? .system(size: size, design: .monospaced)
        let background = Color(hex: store.value("background"), fallback: .black)
        let foreground = Color(hex: store.value("foreground"), fallback: .white)
        let palette = paletteColors

        VStack(alignment: .leading, spacing: 2) {
            Text("~/Projects/ghostty ").foregroundColor(palette[4] ?? foreground) +
                Text("main ").foregroundColor(palette[5] ?? foreground) +
                Text("❯ ").foregroundColor(palette[2] ?? foreground) +
                Text("zig build -Doptimize=ReleaseFast").foregroundColor(foreground)
            Text("Build Summary: ").foregroundColor(palette[2] ?? foreground) +
                Text("12/12 steps succeeded").foregroundColor(foreground)
            Text("const ok = a != b && c => d; ").foregroundColor(foreground) +
                Text("// ligatures").foregroundColor(palette[8] ?? foreground)
            Text("안녕하세요 こんにちは 你好 ").foregroundColor(foreground) +
                Text("— fallback fonts").foregroundColor(palette[8] ?? foreground)
        }
        .font(font)
        .lineLimit(1)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(background))
        .accessibilityLabel("Font preview")
    }

    /// The first 16 palette colors from the effective configuration.
    private var paletteColors: [Int: Color] {
        var result: [Int: Color] = [:]
        for entry in store.values("palette") {
            let parts = entry.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let index = Int(parts[0]), index < 16 else { continue }
            if let color = NSColor(hex: String(parts[1])) {
                result[index] = Color(nsColor: color)
            }
        }
        return result
    }
}
