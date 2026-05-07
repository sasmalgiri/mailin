import Foundation
import StoreKit

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

@MainActor
class StoreManager: ObservableObject {

    // MARK: - Product IDs

    static let personalID = "com.ecosanskriti.mailin.personal"
    static let professionalID = "com.ecosanskriti.mailin.professional"

    static let allProductIDs: Set<String> = [personalID, professionalID]

    nonisolated static let freeEmailLimit = 200

    // MARK: - Professional-Only Features

    enum ProFeature {
        case auditTrail
        case collaboration
        case iCloudSync
        case chainOfCustody
        case batesNumbering
        case batchProcessing
        case prioritySupport
    }

    // MARK: - Published State

    @Published private(set) var products: [Product] = []
    @Published private(set) var currentTier: PurchaseTier = .free
    @Published private(set) var purchaseInProgress = false
    @Published private(set) var purchasePending = false
    @Published private(set) var productLoadError: String?
    @Published var showPaywall = false

    var isPremium: Bool { currentTier >= .personal }
    var isProfessional: Bool { currentTier >= .professional }

    private var transactionListener: Task<Void, Error>?

    // MARK: - Lifecycle

    init() {
        transactionListener = listenForTransactions()
        Task { await loadProducts() }
        Task { await checkEntitlements() }
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - Load Products

    func loadProducts() async {
        productLoadError = nil
        do {
            let storeProducts = try await Product.products(for: StoreManager.allProductIDs)
            products = storeProducts.sorted { lhs, _ in
                lhs.id == StoreManager.personalID
            }
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
        var detectedTier: PurchaseTier = .free

        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            guard transaction.revocationDate == nil else { continue }

            if transaction.productID == StoreManager.professionalID {
                detectedTier = .professional
            } else if transaction.productID == StoreManager.personalID && detectedTier < .professional {
                detectedTier = .personal
            }
        }
        currentTier = detectedTier
    }

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

    func hasAccess(to feature: ProFeature) -> Bool {
        return isProfessional
    }

    // MARK: - Helpers

    var personalProduct: Product? { products.first { $0.id == StoreManager.personalID } }
    var professionalProduct: Product? { products.first { $0.id == StoreManager.professionalID } }

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

    enum StoreError: Error {
        case verificationFailed
    }
}
