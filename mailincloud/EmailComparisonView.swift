import SwiftUI

struct EmailComparisonView: View {
    let emailA: MBOXParser.RawEmail
    let emailB: MBOXParser.RawEmail
    @State private var showRawDiff = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "arrow.left.arrow.right")
                Text("Email Comparison")
                    .font(Typography.title3)
                    .fontWeight(.bold)
                Spacer()
                Toggle("Raw Diff", isOn: $showRawDiff)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel("Toggle raw diff view")
                    .accessibilityHint("Shows inline text differences between the two emails")
                diffSummaryBadge
                    .accessibilityAddTraits(.isStaticText)
            }
            .padding(Spacing.medium)

            Divider()

            if showRawDiff {
                ScrollView {
                    inlineDiffView
                        .padding(Spacing.medium)
                }
            } else {
                HStack(spacing: 0) {
                    emailColumn(emailA, label: "Email A", side: .left)
                    Divider()
                    emailColumn(emailB, label: "Email B", side: .right)
                }
            }
        }
    }

    private var diffSummaryBadge: some View {
        let diffs = countDifferences()
        return Text("\(diffs) difference\(diffs == 1 ? "" : "s")")
            .font(Typography.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(diffs > 0 ? AppColors.error.opacity(0.15) : Color.green.opacity(0.15))
            .foregroundColor(diffs > 0 ? AppColors.error : .green)
            .cornerRadius(CornerRadius.medium)
            .accessibilityLabel("\(diffs) difference\(diffs == 1 ? "" : "s") found between emails")
    }

    private enum Side { case left, right }

    private func emailColumn(_ email: MBOXParser.RawEmail, label: String, side: Side) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(label)
                    .font(Typography.headline)
                    .foregroundColor(AppColors.primary)

                headerComparison(email, side: side)
                Divider()
                bodyComparison(email, side: side)

                if !email.attachments.isEmpty {
                    Divider()
                    attachmentComparison(email, side: side)
                }
            }
            .padding(Spacing.medium)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(label) details")
    }

    private func headerComparison(_ email: MBOXParser.RawEmail, side: Side) -> some View {
        let other = side == .left ? emailB : emailA
        return VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            diffRow("From", value: email.headers["From"] ?? "", otherValue: other.headers["From"] ?? "")
            diffRow("To", value: email.headers["To"] ?? "", otherValue: other.headers["To"] ?? "")
            diffRow("Cc", value: email.headers["Cc"] ?? "", otherValue: other.headers["Cc"] ?? "")
            diffRow("Subject", value: email.headers["Subject"] ?? "", otherValue: other.headers["Subject"] ?? "")
            diffRow("Date", value: email.headers["Date"] ?? email.timestamp, otherValue: other.headers["Date"] ?? other.timestamp)
            diffRow("Message-ID", value: email.headers["Message-ID"] ?? "", otherValue: other.headers["Message-ID"] ?? "")
            diffRow("Attachments", value: "\(email.attachments.count) file(s)", otherValue: "\(other.attachments.count) file(s)")
        }
    }

    private func diffRow(_ label: String, value: String, otherValue: String) -> some View {
        let differs = value != otherValue
        return HStack(alignment: .top, spacing: Spacing.xSmall) {
            Text(label + ":")
                .font(Typography.caption1)
                .fontWeight(.semibold)
                .foregroundColor(AppColors.secondary)
                .frame(width: 90, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(value.isEmpty ? "(empty)" : value)
                    .font(Typography.callout)
                    .foregroundColor(differs ? AppColors.error : .primary)
                    .padding(.horizontal, differs ? 4 : 0)
                    .padding(.vertical, differs ? 1 : 0)
                    .background(differs ? AppColors.error.opacity(0.1) : Color.clear)
                    .cornerRadius(2)
            }
            if differs {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value.isEmpty ? "empty" : value)\(differs ? ", differs from other email" : "")")
    }

    private func bodyComparison(_ email: MBOXParser.RawEmail, side: Side) -> some View {
        let other = side == .left ? emailB : emailA
        let body = email.plainBody.isEmpty ? stripHTML(email.htmlBody) : email.plainBody
        let otherBody = other.plainBody.isEmpty ? stripHTML(other.htmlBody) : other.plainBody
        let differs = body != otherBody

        return VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            HStack {
                Text("Body")
                    .font(Typography.headline)
                if differs {
                    Text("Modified")
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.error)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(AppColors.error.opacity(0.1))
                        .cornerRadius(4)
                }
                Spacer()
                Text("\(body.count) chars")
                    .font(Typography.caption2)
                    .foregroundColor(AppColors.secondary)
            }

            if differs {
                wordDiffView(original: side == .left ? body : otherBody,
                             modified: side == .left ? otherBody : body,
                             showSide: side)
            } else {
                Text(String(body.prefix(3000)))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func attachmentComparison(_ email: MBOXParser.RawEmail, side: Side) -> some View {
        let other = side == .left ? emailB : emailA
        let myNames = Set(email.attachments.map(\.filename))
        let otherNames = Set(other.attachments.map(\.filename))

        return VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            Text("Attachments")
                .font(Typography.headline)

            ForEach(email.attachments, id: \.filename) { att in
                let isUnique = !otherNames.contains(att.filename)
                HStack(spacing: Spacing.xSmall) {
                    Image(systemName: isUnique ? "plus.circle.fill" : "doc.fill")
                        .foregroundColor(isUnique ? .green : AppColors.secondary)
                        .font(.system(size: 12))
                    Text(att.filename)
                        .font(Typography.caption1)
                        .foregroundColor(isUnique ? .green : .primary)
                    Spacer()
                    Text(formatSize(att.size))
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                }
            }

            let missing = otherNames.subtracting(myNames)
            ForEach(Array(missing).sorted(), id: \.self) { name in
                HStack(spacing: Spacing.xSmall) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundColor(AppColors.error)
                        .font(.system(size: 12))
                    Text(name)
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.error)
                        .strikethrough()
                }
            }
        }
    }

    // MARK: - Inline Diff View

    private var inlineDiffView: some View {
        let bodyA = emailA.plainBody.isEmpty ? stripHTML(emailA.htmlBody) : emailA.plainBody
        let bodyB = emailB.plainBody.isEmpty ? stripHTML(emailB.htmlBody) : emailB.plainBody
        let linesA = bodyA.components(separatedBy: .newlines)
        let linesB = bodyB.components(separatedBy: .newlines)
        let diffLines = computeLineDiff(linesA, linesB)

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(diffLines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 4) {
                    Text(line.prefix)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(line.color)
                        .frame(width: 14)
                    Text(line.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(line.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(line.background)
            }
        }
    }

    private struct DiffLine {
        let prefix: String
        let text: String
        let color: Color
        let background: Color
    }

    private func computeLineDiff(_ linesA: [String], _ linesB: [String]) -> [DiffLine] {
        var result: [DiffLine] = []
        let maxLen = max(linesA.count, linesB.count)
        var ia = 0, ib = 0

        while ia < linesA.count || ib < linesB.count {
            if ia < linesA.count && ib < linesB.count {
                if linesA[ia] == linesB[ib] {
                    result.append(DiffLine(prefix: " ", text: linesA[ia], color: .primary, background: .clear))
                    ia += 1
                    ib += 1
                } else {
                    result.append(DiffLine(prefix: "-", text: linesA[ia], color: .red, background: Color.red.opacity(0.08)))
                    result.append(DiffLine(prefix: "+", text: linesB[ib], color: .green, background: Color.green.opacity(0.08)))
                    ia += 1
                    ib += 1
                }
            } else if ia < linesA.count {
                result.append(DiffLine(prefix: "-", text: linesA[ia], color: .red, background: Color.red.opacity(0.08)))
                ia += 1
            } else {
                result.append(DiffLine(prefix: "+", text: linesB[ib], color: .green, background: Color.green.opacity(0.08)))
                ib += 1
            }

            if result.count > 500 {
                result.append(DiffLine(prefix: " ", text: "... (\(maxLen - 500) more lines truncated)", color: AppColors.secondary, background: .clear))
                break
            }
        }
        return result
    }

    private func wordDiffView(original: String, modified: String, showSide: Side) -> some View {
        let text = showSide == .left ? String(original.prefix(3000)) : String(modified.prefix(3000))
        return Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    private func countDifferences() -> Int {
        var count = 0
        let headerKeys = ["From", "To", "Cc", "Subject", "Date", "Message-ID"]
        for key in headerKeys {
            if (emailA.headers[key] ?? "") != (emailB.headers[key] ?? "") { count += 1 }
        }
        let bodyA = emailA.plainBody.isEmpty ? emailA.htmlBody : emailA.plainBody
        let bodyB = emailB.plainBody.isEmpty ? emailB.htmlBody : emailB.plainBody
        if bodyA != bodyB { count += 1 }
        if emailA.attachments.count != emailB.attachments.count { count += 1 }
        if Set(emailA.attachments.map(\.filename)) != Set(emailB.attachments.map(\.filename)) { count += 1 }
        return count
    }

    private func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
    }
}
