import SwiftUI

/// A download from a remote host shown in its terminal. See
/// `RemoteFileViewer`.
struct RemoteFileDownload: Equatable {
    /// Tells downloads apart, so finishing one doesn't hide the next.
    let id: Int

    /// The name of the file.
    let name: String

    /// The host it comes from.
    let host: String
}

/// Shows that a clicked path is being downloaded, at the bottom left of the
/// terminal like the link hover banner. Downloads over a slow network take
/// seconds, so the click needs an answer before the file appears.
struct RemoteFileBanner: View {
    let download: RemoteFileDownload
    let padding: CGFloat = 5
    let cornerRadius: CGFloat = 9

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(verbatim: "Downloading \(download.name) from \(download.host)…")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.init(top: padding, leading: padding, bottom: padding, trailing: padding))
            .background(
                UnevenRoundedRectangle(cornerRadii: .init(topTrailing: cornerRadius))
                    .fill(.background)
            )
            Spacer()
        }
    }
}
