import SwiftUI
#if os(macOS)
import AppKit
#endif

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
    @State private var showAISheet = false
    #if os(macOS)
    @State private var aiWindow: NSWindow?
    @State private var windowObserver: NSObjectProtocol?
    #endif

    var body: some View {
        Button {
            openAIWindow()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.footnote)
                    .fontWeight(.semibold)
                Text("Ask AI")
                    .font(.system(.footnote, design: .rounded))
                    .fontWeight(.bold)
                if !storeManager.isPremium {
                    Text("Try Free")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.white.opacity(0.25))
                        .cornerRadius(4)
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, Spacing.small)
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
        .buttonStyle(.plain)
        #if os(macOS)
        .help("Open the AI assistant to analyze sentiment, extract topics, detect languages, and more")
        #endif
        .accessibilityLabel("Ask AI assistant")
        .accessibilityHint("Open AI assistant to analyze your emails")
        #if os(iOS)
        .sheet(isPresented: $showAISheet) {
            AIAssistantView(
                archiveScope: Self.aiScope(for: model),
                searchContext: model.searchText
            )
            .environmentObject(storeManager)
        }
        #endif
    }

    /// Part D: map the list's filter state to bounded scope semantics (query +
    /// selection) instead of handing the AI whole email arrays.
    static func aiScope(for model: ParsedEmailListViewModel) -> AIAssistantScope {
        var query = EmailQuery.all
        let text = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { query.text = text }
        if model.startDate > .distantPast { query.afterDate = model.startDate }
        if model.endDate < .distantFuture { query.beforeDate = model.endDate }
        return AIAssistantScope(filteredQuery: query, selectedIDs: [])
    }

    private func openAIWindow() {
        #if os(macOS)
        if let existing = aiWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let screenSize = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let windowWidth = min(720, screenSize.width * 0.5)
        let windowHeight = min(600, screenSize.height * 0.7)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "AI Assistant"
        newWindow.isReleasedWhenClosed = false
        newWindow.minSize = NSSize(width: 480, height: 400)

        newWindow.contentView = NSHostingView(rootView:
            AIAssistantView(
                archiveScope: Self.aiScope(for: model),
                searchContext: model.searchText
            )
            .environmentObject(storeManager)
        )

        if let main = NSApp.mainWindow {
            let mainFrame = main.frame
            newWindow.setFrameOrigin(NSPoint(x: mainFrame.maxX + 20, y: mainFrame.minY))
        }

        if let oldObserver = windowObserver {
            NotificationCenter.default.removeObserver(oldObserver)
        }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: newWindow, queue: .main) { _ in
            self.aiWindow = nil
            if let obs = self.windowObserver {
                NotificationCenter.default.removeObserver(obs)
                self.windowObserver = nil
            }
        }

        aiWindow = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate()
        #else
        showAISheet = true
        #endif
    }
}
