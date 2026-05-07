import Foundation
import GroupActivities
import Combine

// MARK: - GroupActivity for sharing email review sessions

struct EmailReviewActivity: GroupActivity {
    static let activityIdentifier = "com.ecosanskriti.mailin.review"

    var metadata: GroupActivityMetadata {
        var meta = GroupActivityMetadata()
        meta.title = "Review Emails Together"
        meta.subtitle = "Collaborate on email analysis"
        meta.type = .generic
        return meta
    }
}

// MARK: - Sync Message Types

struct ReviewSyncMessage: Codable, Sendable {
    enum Action: String, Codable {
        case selectEmail
        case tagEmail
        case addAnnotation
        case navigateToEmail
    }
    let action: Action
    let emailID: String
    let payload: String  // JSON-encoded action data
    let senderName: String
    let timestamp: Date
}

// MARK: - SharePlay Session Manager

@MainActor
class SharePlayManager: ObservableObject {
    static let shared = SharePlayManager()

    @Published var isSessionActive = false
    @Published var participantCount = 0
    @Published var lastReceivedAction: ReviewSyncMessage?

    private var groupSession: GroupSession<EmailReviewActivity>?
    private var messenger: GroupSessionMessenger?
    private var subscriptions = Set<AnyCancellable>()
    private var tasks = Set<Task<Void, Never>>()

    private var sessionListenerTask: Task<Void, Never>?

    func listenForSessions() {
        guard sessionListenerTask == nil else { return }
        sessionListenerTask = Task {
            for await session in EmailReviewActivity.sessions() {
                configureGroupSession(session)
            }
        }
    }

    func startSession() {
        Task {
            let activity = EmailReviewActivity()
            switch await activity.prepareForActivation() {
            case .activationPreferred:
                _ = try? await activity.activate()
            case .activationDisabled:
                break
            default:
                break
            }
        }
    }

    func configureGroupSession(_ session: GroupSession<EmailReviewActivity>) {
        self.groupSession = session
        let messenger = GroupSessionMessenger(session: session)
        self.messenger = messenger

        session.$state.sink { [weak self] state in
            Task { @MainActor in
                self?.isSessionActive = (state == .joined)
            }
        }.store(in: &subscriptions)

        session.$activeParticipants.sink { [weak self] participants in
            Task { @MainActor in
                self?.participantCount = participants.count
            }
        }.store(in: &subscriptions)

        let task = Task {
            for await (message, _) in messenger.messages(of: ReviewSyncMessage.self) {
                await MainActor.run {
                    self.lastReceivedAction = message
                }
            }
        }
        tasks.insert(task)

        session.join()
    }

    func send(action: ReviewSyncMessage.Action, emailID: String, payload: String = "") {
        guard let messenger else { return }
        let message = ReviewSyncMessage(
            action: action,
            emailID: emailID,
            payload: payload,
            senderName: "User",
            timestamp: Date()
        )
        Task {
            try? await messenger.send(message)
        }
    }

    func endSession() {
        groupSession?.end()
        groupSession = nil
        messenger = nil
        subscriptions.removeAll()
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        isSessionActive = false
    }
}
