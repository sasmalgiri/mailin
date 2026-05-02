import Foundation
import StoreKit

@MainActor
class StoreManager: ObservableObject {

    // MARK: - Product IDs

    static let monthlyID = "com.ecosanskriti.mailin.monthly"
    static let yearlyID = "com.ecosanskriti.mailin.yearly"
    static let lifetimeID = "com.ecosanskriti.mailin.lifetime"

    static let subscriptionIDs: Set<String> = [monthlyID, yearlyID]
    static let allProductIDs: Set<String> = [monthlyID, yearlyID, lifetimeID]

    nonisolated static let freeEmailLimit = 50

    // MARK: - Published State

    @Published private(set) var products: [Product] = []
    @Published private(set) var isPremium = false
    @Published private(set) var purchaseInProgress = false
    @Published private(set) var productLoadError: String?
    @Published var showPaywall = false

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
            products = storeProducts.sorted { lhs, rhs in
                let order: [String] = [StoreManager.monthlyID, StoreManager.yearlyID, StoreManager.lifetimeID]
                let lhsIndex = order.firstIndex(of: lhs.id) ?? 99
                let rhsIndex = order.firstIndex(of: rhs.id) ?? 99
                return lhsIndex < rhsIndex
            }
            if products.isEmpty {
                productLoadError = "No products found. Please check your App Store connection."
            }
        } catch {
            productLoadError = "Could not load plans: \(error.localizedDescription)"
        }
    }

    // MARK: - Purchase

    func purchase(_ product: Product) async throws {
        guard !purchaseInProgress else { return }
        purchaseInProgress = true
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
            break

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
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }

            if StoreManager.allProductIDs.contains(transaction.productID)
                && transaction.revocationDate == nil {
                isPremium = true
                return
            }
        }
        isPremium = false
    }

    func requirePremium() -> Bool {
        if isPremium { return true }
        showPaywall = true
        return false
    }

    // MARK: - Helpers

    var monthlyProduct: Product? { products.first { $0.id == StoreManager.monthlyID } }
    var yearlyProduct: Product? { products.first { $0.id == StoreManager.yearlyID } }
    var lifetimeProduct: Product? { products.first { $0.id == StoreManager.lifetimeID } }

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
