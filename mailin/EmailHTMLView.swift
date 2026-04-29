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
                Label("Unable to render HTML.", systemImage: "exclamationmark.triangle")
                    .foregroundColor(AppColors.secondary)
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
