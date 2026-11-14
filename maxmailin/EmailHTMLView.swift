@testable import ArchiveCore
import SwiftUI

struct EmailHTMLView: View {
    let html: String
    let minHeight: CGFloat
    var attachments: [AttachmentMetadata] = []

    @State private var cachedAttributed: NSAttributedString?
    @State private var didParse = false
    /// §3-S8: remote items the safe renderer removed (shown as a note).
    @State private var blockedRemoteItems = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if blockedRemoteItems > 0 {
                Label(String(localized: "\(blockedRemoteItems) remote images or styles were not loaded — opening this email contacted no one."),
                      systemImage: "shield.lefthalf.filled")
                    .font(Typography.caption2)
                    .foregroundColor(AppColors.secondary)
                    .padding([.horizontal, .top], Spacing.small)
            }
            if let attributed = cachedAttributed {
                AttributedTextView(attributedText: attributed)
                    .frame(minHeight: minHeight, maxHeight: .infinity)
                    .padding()
            } else if didParse {
                Label("Unable to render HTML.", systemImage: "exclamationmark.triangle")
                    .foregroundColor(AppColors.secondary)
                    .padding()
            } else {
                ProgressView()
                    .padding()
            }
        }
        .frame(minHeight: minHeight)
        .background(AppColors.backgroundTertiary)
        .cornerRadius(CornerRadius.medium)
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.medium)
                .stroke(AppColors.separatorLight, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Email HTML content")
        .onAppear {
            guard !didParse else { return }
            parseHTML()
        }
    }

    private func parseHTML() {
        var resolved = html
        if !attachments.isEmpty {
            resolved = resolveInlineImages(in: resolved, attachments: attachments)
        }

        guard !resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = resolved.data(using: .utf8) else {
            didParse = true
            return
        }
        // §3-S8: the safe renderer, when its switch is on. The previous
        // importer below is unchanged and runs when the switch is off.
        if SafeHTMLPolicy.isEnabled {
            let source = resolved
            Task { @MainActor in
                let token = EngineGuard.begin(.v3SafeHTML)
                defer { EngineGuard.end(token) }
                do {
                    let (attributed, blocked) = try await SafeHTMLRenderer.render(source)
                    cachedAttributed = attributed
                    blockedRemoteItems = blocked
                } catch {
                    EngineGuard.recordFallback(.v3SafeHTML, error: error)
                    cachedAttributed = SafeHTMLRenderer.plainTextFallback(source)
                }
                didParse = true
            }
            return
        }
        Task { @MainActor in
            cachedAttributed = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
            )
            didParse = true
        }
    }

    private func resolveInlineImages(in html: String, attachments: [AttachmentMetadata]) -> String {
        var result = html
        for att in attachments {
            guard let cid = att.contentID, !cid.isEmpty else { continue }
            guard let b64 = att.base64, !b64.isEmpty else { continue }
            let mime = att.mimeType.isEmpty ? "image/png" : att.mimeType
            let dataURI = "data:\(mime);base64,\(b64)"
            let cleanCID = cid.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            result = result.replacingOccurrences(of: "cid:\(cleanCID)", with: dataURI)
            result = result.replacingOccurrences(of: "cid:\(cid)", with: dataURI)
        }
        return result
    }
}
