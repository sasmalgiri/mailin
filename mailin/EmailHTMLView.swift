import SwiftUI

struct EmailHTMLView: View {
    let html: String
    let minHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let attributed = attributedHTML {
                AttributedTextView(attributedText: attributed)
                    .frame(minHeight: minHeight, maxHeight: .infinity)
                    .padding()
            } else {
                Text("⚠️ Unable to render HTML.")
                    .padding()
            }
        }
        .frame(minHeight: minHeight)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }

    private var attributedHTML: NSAttributedString? {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let data = html.data(using: .utf8) else { return nil }

        return try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        )
    }
}
