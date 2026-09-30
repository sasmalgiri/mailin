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
        case .free: return "Free"
        case .personal: return "Personal"
        case .professional: return "Professional"
        }
    }
}

enum BillingPeriod: String, CaseIterable {
    case monthly = "Monthly"
    case yearly = "Yearly"
    case lifetime = "Lifetime"
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
    @Published var showPaywall = false

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
    init(testTier: PurchaseTier) {
        currentTier = testTier
        debugUnlocksAllTiers = false
    }
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

    func purchase(_ product: Product) async throws {
        guard !purchaseInProgress else { return }
        purchaseInProgress = true
        purchasePending = false
        defer { purchaseInProgress = false }

        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            await checkEntitlements()

        case .userCancelled:
            break

        case .pending:
            purchasePending = true

        @unknown default:
            break
        }
    }

    // MARK: - Restore

    func restorePurchases() async {
        try? await AppStore.sync()
        await checkEntitlements()
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

    func requirePremium() -> Bool {
        if isPremium { return true }
        showPaywall = true
        return false
    }

    func requireProfessional() -> Bool {
        if isProfessional { return true }
        showPaywall = true
        return false
    }

    /// Purchase gate for a tier: true when the effective tier covers it,
    /// otherwise shows the paywall and returns false. `.free` always passes.
    @discardableResult
    func require(_ tier: PurchaseTier) -> Bool {
        if effectiveTier >= tier { return true }
        showPaywall = true
        return false
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
