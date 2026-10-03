@testable import ArchiveCore
import Foundation
#if !ENTERPRISE_EDITION
import StoreKit
#endif

enum PurchaseTier: Int, Comparable {
    case free = 0
    case personal = 1
    case professional = 2

    static func < (lhs: PurchaseTier, rhs: PurchaseTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .free: return String(localized: "Free")
        case .personal: return String(localized: "Personal")
        case .professional: return String(localized: "Professional")
        }
    }
}

enum BillingPeriod: String, CaseIterable {
    case monthly = "Monthly"
    case yearly = "Yearly"
    case lifetime = "Lifetime"

    var displayName: String {
        switch self {
        case .monthly: return String(localized: "Monthly")
        case .yearly: return String(localized: "Yearly")
        case .lifetime: return String(localized: "Lifetime")
        }
    }
}

/// Where a purchase request should be presented. Each SwiftUI root (main
/// window, Settings window, each tool window) hosts one presenter and shows
/// the paywall only for requests aimed at it, so a request is never shown
/// twice and never shown in a window the user is not looking at.
enum PurchasePresentationTarget: Hashable {
    case main
    case settings
    case window(String)
}

/// A request to show the purchase screen: the minimum tier the triggering
/// feature needs (`.free` = just show plans), the feature's name and the
/// reason, and the window to present in.
struct PurchaseRequest: Equatable {
    var requiredTier: PurchaseTier
    var feature: String?
    var reason: String?
    var target: PurchasePresentationTarget
}

/// What one purchase attempt did. Distinct cases so the UI never says
/// "unlocked" for a pending or unverified transaction.
enum PurchaseOutcome: Equatable {
    case success(PurchaseTier)
    case cancelled
    case pending
    case verificationFailed
    case failed(String)
    case alreadyInProgress
}

/// What Restore Purchases did.
enum RestoreOutcome: Equatable {
    case restored(PurchaseTier)
    case nothingFound
    case failed(String)

    var message: String {
        switch self {
        case .restored(let tier): return "Restored: your \(tier.displayName) access is active on this device."
        case .nothingFound: return String(localized: "No eligible purchases were found for this Apple Account.")
        case .failed(let detail): return "Restore failed: \(detail)"
        }
    }

    var isSuccess: Bool {
        if case .restored = self { return true }
        return false
    }
}

/// The Free plan's input allowance, applied at the one import funnel
/// (`ContentView.startImport`) and again at the service boundary
/// (`ContentViewModel.parseSelectedFiles`) so no caller can get past it.
/// Cumulative: what the archive already holds, from the `sources` table,
/// plus what this import would add. Pure functions, so the rule is tested
/// without StoreKit or a store.
enum ImportAllowance {
    struct Denial: Equatable {
        let requestedBytes: Int
        let ingestedBytes: Int
        let limitBytes: Int

        var remainingBytes: Int { max(0, limitBytes - ingestedBytes) }

        /// The sentence the alert, the sheet and the status line all use.
        var message: String {
            let f = { (n: Int) in ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
            let limit = f(limitBytes), requested = f(requestedBytes), ingested = f(ingestedBytes), remaining = f(remainingBytes)
            if ingestedBytes == 0 {
                return String(localized: "The Free plan imports up to \(limit) of input. These files total \(requested). Personal and Professional have no input limit.")
            }
            return String(localized: "The Free plan imports up to \(limit) of input in total. This archive already holds \(ingested); these files would add \(requested), \(remaining) remain. Personal and Professional have no input limit.")
        }
    }

    enum Decision: Equatable {
        case allowed
        case denied(Denial)

        var denial: Denial? {
            if case .denied(let d) = self { return d }
            return nil
        }
    }

    /// `limitBytes == nil` means the tier has no limit. A request that would
    /// take the cumulative total past the limit is denied as a whole: nothing
    /// is imported, nothing is silently truncated.
    static func evaluate(requestedBytes: Int, ingestedBytes: Int, limitBytes: Int?) -> Decision {
        guard let limitBytes else { return .allowed }
        if ingestedBytes + requestedBytes <= limitBytes { return .allowed }
        return .denied(Denial(requestedBytes: requestedBytes, ingestedBytes: ingestedBytes, limitBytes: limitBytes))
    }

    /// Bytes of input the user is asking to import: regular files by size,
    /// folders by the sum of the regular files inside them (symbolic links
    /// are not followed, so a link cannot smuggle a larger tree past the
    /// count nor inflate it).
    nonisolated static func totalBytes(of urls: [URL]) -> Int {
        let fm = FileManager.default
        var total = 0
        for url in urls {
            guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                  let type = attributes[.type] as? FileAttributeType else { continue }
            switch type {
            case .typeRegular:
                total += (attributes[.size] as? NSNumber)?.intValue ?? 0
            case .typeDirectory:
                guard let enumerator = fm.enumerator(at: url,
                                                     includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
                                                     options: [.skipsHiddenFiles]) else { continue }
                for case let child as URL in enumerator {
                    guard let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]),
                          values.isSymbolicLink != true, values.isRegularFile == true else { continue }
                    total += values.fileSize ?? 0
                }
            default:
                continue   // symlink at the top level, device, socket: not input
            }
        }
        return total
    }

    /// Bytes already ingested into this archive: the recorded size of every
    /// source the store holds.
    static func ingestedBytes(archive: ArchiveDataService = .shared) async -> Int {
        let sources = (try? await archive.sources()) ?? []
        return sources.reduce(0) { $0 + max(0, $1.byteSize) }
    }

    /// One call for the funnel: measures, sums, decides.
    static func check(urls: [URL], limitBytes: Int?, archive: ArchiveDataService = .shared) async -> Decision {
        guard let limitBytes else { return .allowed }
        let requested = totalBytes(of: urls)
        let ingested = await ingestedBytes(archive: archive)
        return evaluate(requestedBytes: requested, ingestedBytes: ingested, limitBytes: limitBytes)
    }
}

@MainActor
class StoreManager: ObservableObject {

    // MARK: - Product IDs

    static let personalLifetimeID = "mailin_personal"
    static let professionalLifetimeID = "Professional_Lifetime"
    static let personalMonthlyID = "personal_monthly"
    static let personalYearlyID = "personal_yearly_01"
    static let professionalMonthlyID = "professional_monthly"
    static let professionalYearlyID = "professional_yearly"

    static let premiumID = personalLifetimeID
    static let professionalID = professionalLifetimeID
    static let personalID = personalLifetimeID

    static let personalProductIDs: Set<String> = [
        personalLifetimeID, personalMonthlyID, personalYearlyID
    ]

    static let professionalProductIDs: Set<String> = [
        professionalLifetimeID, professionalMonthlyID, professionalYearlyID
    ]

    static let subscriptionProductIDs: Set<String> = [
        personalMonthlyID, personalYearlyID, professionalMonthlyID, professionalYearlyID
    ]

    static let lifetimeProductIDs: Set<String> = [
        personalLifetimeID, professionalLifetimeID
    ]

    static let allProductIDs: Set<String> = personalProductIDs.union(professionalProductIDs)

    nonisolated static let freeEmailLimit = 500

    /// Owner decision 2026-10-01: the Free plan ingests at most 100 MB of
    /// input in total (every file or folder it has ever imported into this
    /// archive, counted by the bytes on disk). Decimal megabytes, so the
    /// formatter and the number agree ("100 MB").
    nonisolated static let freeInputByteLimit = 100_000_000

    /// The input allowance for the current tier: nil = unlimited.
    var inputByteLimit: Int? { isPremium ? nil : Self.freeInputByteLimit }

    // MARK: - Daily Usage Reset

    static func resetDailyCountersIfNeeded() {
        let defaults = UserDefaults.standard
        let today = Calendar.current.startOfDay(for: Date())
        let lastReset = defaults.object(forKey: "freeLimitsLastResetDate") as? Date ?? .distantPast
        guard Calendar.current.startOfDay(for: lastReset) < today else { return }
        defaults.set(0, forKey: "freeAIQueryCount")
        defaults.set(0, forKey: "freeAIFilterUsageCount")
        defaults.set(0, forKey: "freeAttachmentDownloadCount")
        defaults.set(today, forKey: "freeLimitsLastResetDate")
    }

    // MARK: - Professional-Only Features

    enum ProFeature {
        case auditTrail
        case collaboration
        case chainOfCustody
        case batesNumbering
        case batchProcessing
        case prioritySupport
        case forensicMode
    }

    // MARK: - Published State

    #if !ENTERPRISE_EDITION
    @Published private(set) var products: [Product] = []
    #endif
    @Published private(set) var currentTier: PurchaseTier = .free
    @Published private(set) var purchaseInProgress = false
    @Published private(set) var purchasePending = false
    @Published private(set) var productLoadError: String?
    @Published private(set) var subscriptionExpirationDate: Date?
    @Published private(set) var isLifetimePurchase = false

    // MARK: - Purchase presentation (one coordinator, many presenters)

    /// The purchase request currently asking to be shown, if any. Exactly one
    /// presenter — the main window's root, the Settings window, or a tool
    /// window — matches its `target` and hosts the single `PaywallView`.
    /// Views bind to it through `purchasePresenter(target:)`; nothing else
    /// presents a paywall. There is one StoreManager per process, so every
    /// window sees the same tier the moment it changes.
    @Published private(set) var paywallRequest: PurchaseRequest?

    /// Compatibility surface for the 40-odd gates that set `showPaywall =
    /// true`: reads "a request is up", setting true raises a plain "show
    /// plans" request in the main window, setting false dismisses.
    var showPaywall: Bool {
        get { paywallRequest != nil }
        set {
            if newValue {
                requestPurchase(.free, feature: nil, reason: nil, target: .main)
            } else {
                dismissPaywall()
            }
        }
    }

    /// Asks for the purchase screen. `tier` is the minimum the triggering
    /// feature needs (`.free` = "show plans", nothing specific). If a request
    /// is already showing, it is UPDATED in place — same sheet, new tier and
    /// reason — so a second click never stacks a duplicate and never gets
    /// lost; the already-visible sheet keeps its window.
    func requestPurchase(_ tier: PurchaseTier,
                         feature: String? = nil,
                         reason: String? = nil,
                         target: PurchasePresentationTarget = .main) {
        if var current = paywallRequest {
            current.requiredTier = max(current.requiredTier, tier)
            current.feature = feature ?? current.feature
            current.reason = reason ?? current.reason
            paywallRequest = current
        } else {
            paywallRequest = PurchaseRequest(requiredTier: tier, feature: feature, reason: reason, target: target)
        }
    }

    func dismissPaywall() {
        paywallRequest = nil
    }

    // MARK: - Restore state

    /// What the last Restore Purchases did, for Settings and the paywall to
    /// report. Distinguishes restored / nothing found / failed; never silent.
    @Published private(set) var lastRestoreOutcome: RestoreOutcome?
    @Published private(set) var isRestoring = false

    #if DEBUG
    /// Debug builds unlock every paid tier by default so gated features can
    /// be exercised in the simulator without StoreKit. Tests that prove a
    /// gate denies set this to false on their own instance (see
    /// `init(testTier:)`); Release builds do not compile this property, so
    /// the override cannot reach the App Store.
    var debugUnlocksAllTiers = true
    #endif

    /// The single tier every purchase gate consults. Enterprise: everything is
    /// included in the purchase price. Debug (unless a test opts out): all
    /// unlocked. Otherwise the tier StoreKit's verified transactions proved.
    var effectiveTier: PurchaseTier {
        #if ENTERPRISE_EDITION
        return .professional
        #else
        #if DEBUG
        if debugUnlocksAllTiers { return .professional }
        #endif
        return currentTier
        #endif
    }

    var isPremium: Bool { effectiveTier >= .personal }
    var isProfessional: Bool { effectiveTier >= .professional }
    var isSubscribed: Bool { effectiveTier >= .personal }

    #if !ENTERPRISE_EDITION
    private var transactionListener: Task<Void, Error>?
    #endif

    /// The app's store manager, for views hosted outside the SwiftUI
    /// environment (tool windows, the shared list pane). Claimed by the first
    /// instance the app creates; test instances made with `init(testTier:)`
    /// never claim it.
    static weak var live: StoreManager?

    // MARK: - Lifecycle

    init() {
        #if ENTERPRISE_EDITION
        // Enterprise edition: everything is included; never touch StoreKit.
        currentTier = .professional
        #else
        transactionListener = listenForTransactions()
        Task { await loadProducts() }
        Task { await checkEntitlements() }
        #endif
        if Self.live == nil { Self.live = self }
    }

    #if DEBUG
    /// Test fixture: a deterministic Free / Personal / Professional manager
    /// that never touches StoreKit and does not take the debug unlock, so a
    /// test can prove that a gate denies.
    init(testTier: PurchaseTier, lifetime: Bool = false) {
        currentTier = testTier
        isLifetimePurchase = lifetime
        debugUnlocksAllTiers = false
    }

    /// Developer switch: launching with `-mailinSimulateTier free|personal|
    /// professional` makes the LIVE manager behave as that tier in a Debug
    /// build (no all-unlocked shortcut), so the Free experience and every
    /// purchase entry point can be seen and screenshotted without StoreKit.
    /// Release builds do not compile this.
    func applyDebugLaunchOverride(arguments: [String] = CommandLine.arguments) {
        guard let index = arguments.firstIndex(of: "-mailinSimulateTier"), index + 1 < arguments.count else { return }
        let tier: PurchaseTier?
        switch arguments[index + 1].lowercased() {
        case "free": tier = .free
        case "personal": tier = .personal
        case "professional": tier = .professional
        default: tier = nil
        }
        guard let tier else { return }
        debugUnlocksAllTiers = false
        currentTier = tier
        isLifetimePurchase = arguments.contains("-mailinSimulateLifetime")
        // Keep the simulated tier even after StoreKit's entitlement pass.
        simulatedTier = tier
        // `-mailinShowPaywall <feature>` raises a contextual request at launch
        // so the purchase screen itself can be reviewed and screenshotted.
        if let flag = arguments.firstIndex(of: "-mailinShowPaywall"), flag + 1 < arguments.count {
            let feature = arguments[flag + 1]
            // A hub destination name gets its real tier; anything else asks
            // for the next tier up.
            let destination = HubDestination(rawValue: feature) ?? ProfessionalPageView.destination(forTitle: feature)
            let required = destination.map(Self.requiredTier(for:))
                ?? (tier == .free ? PurchaseTier.personal : .professional)
            requestPurchase(required, feature: feature,
                            reason: "\(feature) is part of the \(required.displayName) purchase.", target: .main)
        }
    }

    private var simulatedTier: PurchaseTier?
    #endif

    deinit {
        #if !ENTERPRISE_EDITION
        transactionListener?.cancel()
        #endif
    }

    // P-5: everything that talks to StoreKit is compiled only into the public
    // line. The enterprise edition (ABM Custom App) has no products, purchases,
    // restores or subscription management.
    #if !ENTERPRISE_EDITION

    // MARK: - Load Products

    func loadProducts() async {
        productLoadError = nil
        do {
            let storeProducts = try await Product.products(for: StoreManager.allProductIDs)

            products = storeProducts.sorted { lhs, rhs in lhs.price < rhs.price }

            if products.isEmpty {
                productLoadError = "No products found. Please check your App Store connection."
            }
        } catch {
            productLoadError = "Could not load products: \(error.localizedDescription)"
        }
    }

    // MARK: - Purchase

    /// One purchase attempt with a distinct outcome for each StoreKit result.
    /// A second submission while one is in flight is refused (`.alreadyInProgress`),
    /// a pending (Ask to Buy) purchase unlocks nothing until the transaction
    /// arrives through the listener, and a verification failure never unlocks.
    @discardableResult
    func purchase(_ product: Product) async -> PurchaseOutcome {
        guard !purchaseInProgress else { return .alreadyInProgress }
        purchaseInProgress = true
        purchasePending = false
        defer { purchaseInProgress = false }

        let result: Product.PurchaseResult
        do {
            result = try await product.purchase()
        } catch {
            return .failed(error.localizedDescription)
        }

        switch result {
        case .success(let verification):
            do {
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await checkEntitlements()
                return .success(currentTier)
            } catch {
                return .verificationFailed
            }

        case .userCancelled:
            return .cancelled

        case .pending:
            purchasePending = true
            return .pending

        @unknown default:
            return .failed("The App Store returned an unknown result.")
        }
    }

    // MARK: - Restore

    /// Restore Purchases, reporting what happened: access restored (to which
    /// tier), nothing eligible on this Apple ID, or the sync itself failed.
    @discardableResult
    func restorePurchases() async -> RestoreOutcome {
        isRestoring = true
        defer { isRestoring = false }
        let outcome: RestoreOutcome
        do {
            try await AppStore.sync()
            await checkEntitlements()
            outcome = currentTier > .free ? .restored(currentTier) : .nothingFound
        } catch {
            outcome = .failed(error.localizedDescription)
        }
        lastRestoreOutcome = outcome
        return outcome
    }

    // MARK: - Entitlement Check

    func checkEntitlements() async {
        var highestTier: PurchaseTier = .free
        var hasLifetime = false
        var latestExpiration: Date?

        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            guard transaction.revocationDate == nil else { continue }

            let isProProduct = StoreManager.professionalProductIDs.contains(transaction.productID)
            let isPersonalProduct = StoreManager.personalProductIDs.contains(transaction.productID)

            if isProProduct {
                highestTier = .professional
            } else if isPersonalProduct && highestTier < .personal {
                highestTier = .personal
            }

            if StoreManager.lifetimeProductIDs.contains(transaction.productID) {
                hasLifetime = true
            }

            if let expirationDate = transaction.expirationDate {
                if let current = latestExpiration {
                    if expirationDate > current { latestExpiration = expirationDate }
                } else {
                    latestExpiration = expirationDate
                }
            }
        }

        #if DEBUG
        if let simulatedTier {
            currentTier = simulatedTier
            return
        }
        #endif
        currentTier = highestTier
        isLifetimePurchase = hasLifetime
        subscriptionExpirationDate = hasLifetime ? nil : latestExpiration
    }

    // MARK: - Subscription Management

    func manageSubscriptions() async {
        #if os(iOS)
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        try? await AppStore.showManageSubscriptions(in: windowScene)
        #else
        if let url = URL(string: "macappstores://showManageSubscriptions") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    #endif

    // MARK: - Feature Gating

    func requirePremium() -> Bool { require(.personal) }

    func requireProfessional() -> Bool { require(.professional) }

    /// Purchase gate for a tier: true when the effective tier covers it,
    /// otherwise raises a purchase request — with the feature's name and the
    /// reason, in the window that asked — and returns false. `.free` always
    /// passes.
    @discardableResult
    func require(_ tier: PurchaseTier,
                 feature: String? = nil,
                 reason: String? = nil,
                 target: PurchasePresentationTarget = .main) -> Bool {
        if effectiveTier >= tier { return true }
        requestPurchase(tier, feature: feature, reason: reason, target: target)
        return false
    }

    /// The plan badge every page shows: what the user has, and for Free the
    /// upgrade call in the same two words.
    static func planBadgeLabel(tier: PurchaseTier, lifetime: Bool) -> String {
        switch tier {
        case .free: return String(localized: "Free · Upgrade")
        case .personal: return lifetime ? String(localized: "Personal · Lifetime") : "Personal"
        case .professional: return lifetime ? String(localized: "Professional · Lifetime") : "Professional"
        }
    }

    /// What the plan badge asks for: Free and Personal see the next tier
    /// selected; a Professional owner sees their plan, not an upgrade demand.
    static func planBadgeRequestTier(current: PurchaseTier) -> PurchaseTier {
        switch current {
        case .free: return .personal
        case .personal: return .professional
        case .professional: return .free
        }
    }

    /// The purchase tier a tools-hub destination needs before it may EXECUTE,
    /// mirrored from the Archive page's hub so Page 3's strip, a workflow
    /// step and a keyboard shortcut all answer the same way. Enabling the
    /// Professional page is module consent, not purchase authorization.
    static func requiredTier(for destination: HubDestination) -> PurchaseTier {
        switch destination {
        case .eDiscovery, .predictiveCoding, .gdprCompliance, .chainOfCustody,
             .forensicReview, .investigationReport, .batesNumbering,
             .reviewBatches, .custodianPanel, .legalWorkspace, .achMatrix, .factMatrix,
             .evidenceDesks, .iocExtractor, .phishingTriage, .reviewDashboard:
            return .professional
        case .settings, .workCenter, .personaHub, .emailInbox, .customExperts,
             .workspaceManager, .personalOrganizer, .generalExplorer:
            return .free
        default:
            return .personal
        }
    }

    func hasAccess(to feature: ProFeature) -> Bool {
        return isProfessional
    }

    func tierRequired(for feature: ProFeature) -> PurchaseTier {
        return .professional
    }

    func featureLocked(_ feature: ProFeature) -> Bool {
        return currentTier < tierRequired(for: feature)
    }

    #if !ENTERPRISE_EDITION

    // MARK: - Product Helpers

    var premiumProduct: Product? { products.first { $0.id == StoreManager.personalLifetimeID } }
    var professionalProduct: Product? { products.first { $0.id == StoreManager.professionalLifetimeID } }
    var personalProduct: Product? { premiumProduct }

    func personalProduct(for period: BillingPeriod) -> Product? {
        switch period {
        case .monthly: return products.first { $0.id == StoreManager.personalMonthlyID }
        case .yearly: return products.first { $0.id == StoreManager.personalYearlyID }
        case .lifetime: return products.first { $0.id == StoreManager.personalLifetimeID }
        }
    }

    func professionalProduct(for period: BillingPeriod) -> Product? {
        switch period {
        case .monthly: return products.first { $0.id == StoreManager.professionalMonthlyID }
        case .yearly: return products.first { $0.id == StoreManager.professionalYearlyID }
        case .lifetime: return products.first { $0.id == StoreManager.professionalLifetimeID }
        }
    }

    var personalMonthlyProduct: Product? { personalProduct(for: .monthly) }
    var personalYearlyProduct: Product? { personalProduct(for: .yearly) }
    var professionalMonthlyProduct: Product? { professionalProduct(for: .monthly) }
    var professionalYearlyProduct: Product? { professionalProduct(for: .yearly) }

    var subscriptionProducts: [Product] {
        products.filter { StoreManager.subscriptionProductIDs.contains($0.id) }
    }

    var personalSubscriptions: [Product] {
        products.filter { StoreManager.personalProductIDs.contains($0.id) && $0.id != StoreManager.personalLifetimeID }
    }

    var professionalSubscriptions: [Product] {
        products.filter { StoreManager.professionalProductIDs.contains($0.id) && $0.id != StoreManager.professionalLifetimeID }
    }

    // MARK: - Helpers

    private nonisolated func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.verificationFailed
        case .verified(let safe):
            return safe
        }
    }

    private func listenForTransactions() -> Task<Void, Error> {
        Task { [weak self] in
            for await result in Transaction.updates {
                guard let self, let transaction = try? self.checkVerified(result) else { continue }
                await transaction.finish()
                await self.checkEntitlements()
            }
        }
    }

    #endif

    enum StoreError: Error {
        case verificationFailed
    }
}
