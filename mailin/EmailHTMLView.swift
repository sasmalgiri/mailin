import SwiftUI

struct EmailHTMLView: View {
    let html: String
    let minHeight: CGFloat
    var attachments: [AttachmentMetadata] = []

    @State private var cachedAttributed: NSAttributedString?
    @State private var didParse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
