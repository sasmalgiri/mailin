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
    @State private var aiMode: AIMode = .filteredEmails
    @State private var aiWindow: NSWindow?

    var body: some View {
        Menu {
            Button("Ask AI (All Emails)") {
                aiMode = .allEmails
                openAIWindow()
            }
            Button("Ask AI (Filtered Emails)") {
                aiMode = .filteredEmails
                openAIWindow()
            }
        } label: {
            Label("Ask AI", systemImage: "brain.head.profile")
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.13))
                .cornerRadius(8)
        }
        .help("Open AI assistant to ask about emails")
    }

    private func openAIWindow() {
        if let existing = aiWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Ask AI"
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
        NSApp.activate(ignoringOtherApps: true)
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
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack {
                Label("Ask AI (\(mode.rawValue))", systemImage: "brain.head.profile")
                    .font(.title2.bold())
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                }
                .help("Close AI window")
            }

            Divider()

            // Input
            VStack(alignment: .leading, spacing: 8) {
                Text("Type your question about your emails:")
                    .font(.headline)

                HStack(spacing: 12) {
                    TextField("e.g. Which client sent the most attachments?", text: $question)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { runQA() }
                        .disabled(loading)

                    Button {
                        runQA()
                    } label: {
                        Label("Get Answer", systemImage: "sparkle.magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)
                }
            }

            // Results
            resultView

            Spacer()
        }
        .padding(28)
        .frame(minWidth: 560, minHeight: 380)
    }

    // MARK: - Result UI
    @ViewBuilder
    private var resultView: some View {
        if loading {
            HStack(spacing: 10) {
                ProgressView()
                Text("AI is thinking…")
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 20)

        } else if !answer.isEmpty {
            ScrollView {
                Text(answer)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
                    .font(.body)
            }
            .frame(minHeight: 160, maxHeight: 320)
        }
    }

    // MARK: - QA Logic (Simulated)
    private func runQA() {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        answer = ""
        loading = true

        DispatchQueue.global(qos: .userInitiated).async {
            let result = simulateQA(question: question, emails: emails)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.answer = result
                self.loading = false
            }
        }
    }

    private func simulateQA(question: String, emails: [MBOXParser.RawEmail]) -> String {
        if emails.isEmpty { return "No emails to analyze." }
        let lowerQ = question.lowercased()

        if lowerQ.contains("attachment") {
            let top = emails.max { $0.attachments.count < $1.attachments.count }
            return """
            Top email with most attachments:
            Subject: \(top?.headers["Subject"] ?? "(No Subject)")
            From: \(top?.headers["From"] ?? "-")
            Attachments: \(top?.attachments.count ?? 0)
            """
        }

        if lowerQ.contains("date") {
            let dates = emails.compactMap { $0.headers["Date"] }
            return "Sample of parsed email dates:\n" + dates.prefix(5).joined(separator: "\n")
        }

        return """
        Demo answer for:
        \"\(question)\"

        (Tip: Integrate your Core ML QA here!)
        """
    }
}
