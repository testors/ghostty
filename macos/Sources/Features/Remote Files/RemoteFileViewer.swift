import AppKit
import QuickLookUI

/// Shows a file from the host that a terminal is connected to with ssh or
/// mosh, when its path is clicked in the terminal. The file is downloaded
/// (see `RemoteFileFetch`) and shown with Quick Look, which only displays
/// it; it can be opened in an app from there.
final class RemoteFileViewer: NSObject {
    static let shared = RemoteFileViewer()

    /// The downloaded file that Quick Look shows.
    private(set) var previewURL: URL?

    /// Counts requests so that a slow download can't replace the file of
    /// a later click.
    private var generation = 0

    /// Downloads the file and shows it. Call on the main thread.
    func open(_ fetch: RemoteFileFetch, from view: Ghostty.SurfaceView) {
        generation += 1
        let request = generation

        let download = RemoteFileDownload(id: request, name: fetch.displayName, host: fetch.host)
        view.remoteFileDownload = download

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> URL in
                let file = try fetch.run()
                return try RemoteFileFetch.save(file, host: fetch.host)
            }

            DispatchQueue.main.async { [weak view] in
                if view?.remoteFileDownload == download { view?.remoteFileDownload = nil }
                guard request == self.generation else { return }
                switch result {
                case .success(let url):
                    self.preview(url)
                case .failure(let error):
                    self.presentFailure(error, fetch: fetch, window: view?.window)
                }
            }
        }
    }

    private func preview(_ url: URL) {
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.reloadData()
            panel.orderFront(nil)
        } else {
            // The panel asks the responder chain for a controller; terminal
            // surfaces accept while there is a file to show.
            panel.makeKeyAndOrderFront(nil)
            if panel.currentController == nil {
                beginControl(panel)
                panel.reloadData()
            }
        }

        // Keys go to the preview, so Escape closes it instead of reaching
        // the terminal. A visible panel ignores makeKeyAndOrderFront, as
        // when the terminal was clicked again for another file, but it
        // takes makeKey.
        panel.makeKey()
    }

    /// Closes the panel for Close and Close Window. The panel can't become
    /// the main window, so actions it doesn't handle go on to the terminal
    /// behind it, where Close would close the terminal. Its delegate is
    /// asked first.
    @objc func close(_ sender: Any?) {
        QLPreviewPanel.shared()?.close()
    }

    @objc func closeWindow(_ sender: Any?) {
        QLPreviewPanel.shared()?.close()
    }

    private func presentFailure(_ error: Error, fetch: RemoteFileFetch, window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't Open \(fetch.displayName) from \(fetch.host)"
        if let failure = error as? RemoteFileFetch.Failure {
            alert.informativeText = failure.message(host: fetch.host)
        } else {
            alert.informativeText = error.localizedDescription
        }
        alert.addButton(withTitle: "OK")

        if let window = window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: Quick Look panel control

    func acceptsControl(_ panel: QLPreviewPanel) -> Bool {
        previewURL != nil
    }

    func beginControl(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }

    func endControl(_ panel: QLPreviewPanel) {
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
    }
}

extension RemoteFileViewer: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as NSURL?
    }
}

// Quick Look asks the responder chain who controls its panel. A terminal
// surface is the first responder after the click that asked for the file.
extension Ghostty.SurfaceView {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        RemoteFileViewer.shared.acceptsControl(panel)
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        RemoteFileViewer.shared.beginControl(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        RemoteFileViewer.shared.endControl(panel)
    }
}
