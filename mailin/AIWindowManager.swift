import SwiftUI
import AppKit

// MARK: - AIMode Enum
enum AIMode: String, CaseIterable, Identifiable {
    case allEmails = "All Emails"
    case filteredEmails = "Filtered Emails"
    var id: String { self.rawValue }
}

// MARK: - AI Window Launcher
struct AIWindowButton: View {
    @ObservedObject var model: ParsedEmailListViewModel
    @EnvironmentObject var storeManager: StoreManager
    @State private var aiMode: AIMode = .filteredEmails
    @State private var aiWindow: NSWindow?

    var body: some View {
        Menu {
            Button {
                if storeManager.requirePremium() {
                    aiMode = .allEmails
                    openAIWindow()
                }
            } label: {
                Label("All Emails", systemImage: "tray.full")
            }
            Button {
                if storeManager.requirePremium() {
                    aiMode = .filteredEmails
                    openAIWindow()
                }
            } label: {
                Label("Filtered Emails", systemImage: "line.3.horizontal.decrease.circle")
            }
        } label: {
            Label("Ask AI", systemImage: "brain.head.profile")
                .font(Typography.headline)
                .foregroundColor(.white)
                .padding(.horizontal, Spacing.medium)
                .padding(.vertical, Spacing.xSmall)
                .background(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .cornerRadius(CornerRadius.medium)
        }
        .help("Open AI assistant to ask about emails")
    }

    private func openAIWindow() {
        if let existing = aiWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "AI Assistant"
        newWindow.isReleasedWhenClosed = false

        let selectedEmails = aiMode == .allEmails ? model.viewModel.parsedEmails : model.filteredEmails

        newWindow.contentView = NSHostingView(rootView:
            AskAIView(mode: aiMode, emails: selectedEmails)
        )

        if let main = NSApp.mainWindow {
            let mainFrame = main.frame
            newWindow.setFrameOrigin(NSPoint(x: mainFrame.maxX + 20, y: mainFrame.minY))
        }

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: newWindow, queue: .main) { _ in
            aiWindow = nil
        }

        aiWindow = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

// MARK: - AskAIView Interface
struct AskAIView: View {
    let mode: AIMode
    let emails: [MBOXParser.RawEmail]

    @Environment(\.dismiss) private var dismiss
    @State private var question: String = ""
    @State private var answer: String = ""
    @State private var loading: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            HStack {
                HStack(spacing: Spacing.xSmall) {
                    Image(systemName: "brain.head.profile")
                        .font(Typography.title2)
                        .foregroundStyle(
                            .linearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                    VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                        Text("AI Assistant")
                            .font(Typography.title3)
                        Text("Analyzing \(emails.count) \(mode.rawValue.lowercased())")
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                    }
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColors.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .help("Close AI window")
            }

            Divider()

            VStack(alignment: .leading, spacing: Spacing.xSmall) {
                Text("Ask a question about your emails")
                    .font(Typography.headline)

                HStack(spacing: Spacing.small) {
                    TextField("e.g. What's the sentiment of my emails?", text: $question)
                        .textFieldStyle(.plain)
                        .font(Typography.body)
                        .padding(.horizontal, Spacing.small)
                        .padding(.vertical, Spacing.xSmall)
                        .background(AppColors.backgroundSecondary)
                        .cornerRadius(CornerRadius.medium)
                        .onSubmit { runQA() }
                        .disabled(loading)

                    Button {
                        runQA()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canSend ? AppColors.primary : AppColors.secondary.opacity(0.5))
                    .disabled(!canSend)
                }
            }

            resultView

            Spacer()
        }
        .padding(Spacing.large)
        .frame(minWidth: 560, minHeight: 400)
        .background(AppColors.backgroundTertiary)
    }

    private var canSend: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !loading
    }

    // MARK: - Result UI
    @ViewBuilder
    private var resultView: some View {
        if loading {
            HStack(spacing: Spacing.xSmall) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Analyzing...")
                    .font(Typography.callout)
                    .foregroundColor(AppColors.secondary)
            }
            .padding(.vertical, Spacing.medium)
        } else if !answer.isEmpty {
            ScrollView {
                Text(answer)
                    .font(Typography.body)
                    .textSelection(.enabled)
                    .padding(Spacing.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColors.backgroundSecondary)
                    .cornerRadius(CornerRadius.large)
            }
            .frame(minHeight: 160, maxHeight: 320)
        }
    }

    // MARK: - QA Logic
    private func runQA() {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        answer = ""
        loading = true

        DispatchQueue.global(qos: .userInitiated).async {
            let result = simulateQA(question: question, emails: emails)
            DispatchQueue.main.async {
                withAnimation(AnimationTiming.normal) {
                    self.answer = result
                }
                self.loading = false
            }
        }
    }

    private func simulateQA(question: String, emails: [MBOXParser.RawEmail]) -> String {
        if emails.isEmpty { return "No emails to analyze." }
        let lower = question.lowercased()

        if lower.contains("sentiment") || lower.contains("tone") || lower.contains("mood") {
            let result = EmailNLPEngine.averageSentiment(of: emails)
            return "Sentiment: \(result.label) (score: \(String(format: "%.2f", result.average)))\nPositive: \(result.positive) | Neutral: \(result.neutral) | Negative: \(result.negative)"
        }

        if lower.contains("topic") || lower.contains("keyword") || lower.contains("discuss") {
            let topics = EmailNLPEngine.extractTopics(from: emails, limit: 8)
            if topics.isEmpty { return "Not enough text to extract topics." }
            return "Top topics:\n" + topics.enumerated().map { "\($0.offset + 1). \($0.element.word) (\($0.element.count)x)" }.joined(separator: "\n")
        }

        if lower.contains("people") || lower.contains("entities") || lower.contains("names") {
            let entities = EmailNLPEngine.extractEntities(from: emails, limit: 8)
            if entities.isEmpty { return "No named entities found." }
            return "Key entities:\n" + entities.map { "\($0.name) (\($0.type)) - \($0.count)x" }.joined(separator: "\n")
        }

        if lower.contains("language") {
            let langs = EmailNLPEngine.detectLanguages(in: emails)
            if langs.isEmpty { return "Could not detect languages." }
            return "Languages:\n" + langs.map { "\($0.language): \($0.count) emails (\(String(format: "%.0f", $0.percentage))%)" }.joined(separator: "\n")
        }

        if lower.contains("attachment") {
            let top = emails.max { $0.attachments.count < $1.attachments.count }
            return "Top email with most attachments:\nSubject: \(top?.headers["Subject"] ?? "(No Subject)")\nFrom: \(top?.headers["From"] ?? "-")\nAttachments: \(top?.attachments.count ?? 0)"
        }

        if lower.contains("summary") || lower.contains("overview") || lower.contains("analyze") {
            let sentiment = EmailNLPEngine.averageSentiment(of: emails)
            let topics = EmailNLPEngine.extractTopics(from: emails, limit: 5)
            return "Summary of \(emails.count) emails:\nTone: \(sentiment.label)\nTopics: \(topics.map(\.word).joined(separator: ", "))"
        }

        return "Try asking about: sentiment, topics, people mentioned, languages, attachments, or summary."
    }
}
