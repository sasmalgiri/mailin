@testable import ArchiveCore
import SwiftUI

// P-5 (owner decision 2026-09-27): the paywall is kept for the public mailin
// line and compiled out of the enterprise edition (ABM Custom App: every
// Professional feature is included, no in-app purchases exist). Only the
// tier badge and gate modifier below stay in both editions.
#if !ENTERPRISE_EDITION
import StoreKit

struct PaywallView: View {
    @EnvironmentObject private var store: StoreManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProduct: Product?
    @State private var selectedPeriod: BillingPeriod = .yearly
    @State private var selectedTier: SelectedTier?
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    /// What asked for the screen: the minimum tier, the feature and the
    /// reason. nil = "show plans" from a badge or Settings.
    let request: PurchaseRequest?

    init(request: PurchaseRequest? = nil) {
        self.request = request
    }

    private enum SelectedTier { case personal, professional }

    /// The tier the screen opens on: the minimum the triggering feature
    /// needs, never below the next tier the user does not own yet; nil for a
    /// Professional owner, who has nothing to buy here.
    static func initialSelectedTier(request: PurchaseRequest?, currentTier: PurchaseTier) -> PurchaseTier? {
        guard currentTier < .professional else { return nil }
        let nextTier: PurchaseTier = currentTier == .free ? .personal : .professional
        return max(request?.requiredTier ?? .free, nextTier)
    }

    private var ownsEverything: Bool { store.effectiveTier >= .professional }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                headerSection
                Button {
                    closePaywall()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(AppColors.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(Spacing.medium)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("paywall.close")
            }
            Divider()
            ScrollView {
                VStack(spacing: Spacing.large) {
                    if ownsEverything {
                        ownershipDetails
                    } else {
                        if let request, let feature = request.feature {
                            unlockReason(feature: feature, tier: request.requiredTier, reason: request.reason)
                        }
                        featureComparison
                        billingPeriodPicker
                        purchaseCards
                    }
                    if store.purchasePending {
                        HStack(spacing: Spacing.xSmall) {
                            Image(systemName: "clock.fill")
                                .foregroundColor(.orange)
                            Text("Your purchase is pending approval. Nothing is unlocked until the App Store confirms it. If you're using Ask to Buy, check with your family organizer.")
                                .font(Typography.caption1)
                                .foregroundColor(.orange)
                        }
                        .padding(Spacing.small)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(CornerRadius.medium)
                        .accessibilityIdentifier("paywall.pending")
                    }
                    if let statusMessage {
                        Text(statusMessage)
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.secondary)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("paywall.status")
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.error)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("paywall.error")
                    }
                    if !ownsEverything {
                        purchaseButton
                    }
                    restoreSection
                    legalText
                }
                .padding(Spacing.large)
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, idealWidth: 640, minHeight: 380, idealHeight: 700)
        #endif
        .background(AppColors.backgroundPrimary)
        .accessibilityIdentifier("paywall")
        .onAppear {
            switch Self.initialSelectedTier(request: request, currentTier: store.effectiveTier) {
            case .personal?: selectedTier = .personal
            case .professional?: selectedTier = .professional
            default: selectedTier = nil
            }
            updateSelectedProduct()
        }
        .onChange(of: selectedPeriod, initial: false) {
            updateSelectedProduct()
        }
        .onChange(of: store.products.count, initial: false) {
            updateSelectedProduct()
        }
    }

    /// Dismisses both the sheet and the coordinator's request, whichever
    /// window hosts the screen. The user's page, selection and unfinished
    /// work are untouched: this view never navigates.
    private func closePaywall() {
        store.dismissPaywall()
        dismiss()
    }

    private func updateSelectedProduct() {
        if selectedTier == .personal, let personal = store.personalProduct(for: selectedPeriod) {
            selectedProduct = personal
        } else if selectedTier == .professional, let pro = store.professionalProduct(for: selectedPeriod) {
            selectedProduct = pro
        } else if selectedTier == nil, store.effectiveTier == .free, let personal = store.personalProduct(for: selectedPeriod) {
            selectedProduct = personal
            selectedTier = .personal
        } else if let pro = store.professionalProduct(for: selectedPeriod) {
            selectedProduct = pro
            selectedTier = .professional
        } else if let personal = store.personalProduct(for: selectedPeriod) {
            selectedProduct = personal
            selectedTier = .personal
        } else {
            selectedProduct = store.products.first
        }
    }

    // MARK: - Context

    /// Why the screen opened: the feature and the tier that unlocks it.
    private func unlockReason(feature: String, tier: PurchaseTier, reason: String?) -> some View {
        HStack(alignment: .top, spacing: Spacing.xSmall) {
            Image(systemName: "lock.open.fill")
                .foregroundColor(tier == .professional ? .purple : .blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(feature) needs \(tier.displayName)")
                    .font(Typography.callout)
                    .fontWeight(.semibold)
                Text(reason ?? "\(feature) is part of the \(tier.displayName) purchase\(tier == .personal ? " and of Professional" : "").")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }
            Spacer()
        }
        .padding(Spacing.small)
        .background((tier == .professional ? Color.purple : Color.blue).opacity(0.08))
        .cornerRadius(CornerRadius.medium)
        .accessibilityIdentifier("paywall.reason")
    }

    /// A Professional owner sees their plan, not an upgrade demand.
    private var ownershipDetails: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Label("You own Professional. Every feature is unlocked.", systemImage: "checkmark.seal.fill")
                .font(Typography.callout)
                .foregroundColor(.green)
            if store.isLifetimePurchase {
                Text("Lifetime purchase: it never expires and never renews. No subscription is needed to keep this access.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            } else if let expiration = store.subscriptionExpirationDate {
                Text("Subscription · renews or ends \(expiration.formatted(date: .abbreviated, time: .omitted)). Manage it below.")
                    .font(Typography.caption1)
                    .foregroundColor(AppColors.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .adaptiveCard(cornerRadius: CornerRadius.large)
        .accessibilityIdentifier("paywall.ownership")
    }

    // MARK: - Header

    private var headerTitle: String {
        if ownsEverything { return String(localized: "Your plan") }
        if let feature = request?.feature { return "Unlock \(feature)" }
        return store.effectiveTier == .personal ? "Upgrade to Professional" : "Unlock mailin"
    }

    private var headerSubtitle: String {
        if ownsEverything { return "Professional\(store.isLifetimePurchase ? " · Lifetime" : "")" }
        if store.effectiveTier == .personal {
            return store.isLifetimePurchase
                ? "You own Personal for life. Professional adds the legal and forensic tools; it is a separate purchase at its listed price."
                : "You have Personal. Professional adds the legal and forensic tools."
        }
        return String(localized: "Subscribe monthly or yearly, or buy once for lifetime access. Prices are shown by the App Store in your currency.")
    }

    private var headerSection: some View {
        VStack(spacing: Spacing.small) {
            crownIcon

            Text(headerTitle)
                .font(.system(.title2, design: .rounded))
                .fontWeight(.bold)
                .accessibilityIdentifier("paywall.title")

            Text(headerSubtitle)
                .font(.subheadline)
                .foregroundColor(AppColors.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.medium)

            HStack(spacing: Spacing.medium) {
                Label("Complete Privacy", systemImage: "lock.shield.fill")
                Label("Native Apple AI", systemImage: "brain.head.profile")
            }
            #if os(iOS)
            .font(Typography.caption2)
            #else
            .font(Typography.caption1)
            #endif
            .foregroundColor(AppColors.secondary)
        }
        .padding(.vertical, Spacing.large)
        .adaptiveHeroBackground(colors: [.orange, .yellow, .orange, .red])
    }

    @ViewBuilder
    private var crownIcon: some View {
        if #available(macOS 15, iOS 18, *) {
            Image(systemName: "crown.fill")
                .font(.largeTitle)
                .foregroundStyle(
                    MeshGradient(width: 2, height: 2, points: [
                        .init(0, 0), .init(1, 0),
                        .init(0, 1), .init(1, 1)
                    ], colors: [.orange, .yellow, .red, .orange])
                )
        } else {
            Image(systemName: "crown.fill")
                .font(.largeTitle)
                .foregroundStyle(
                    .linearGradient(colors: [.orange, .yellow], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        }
    }

    // MARK: - Feature Comparison

    private var featureComparison: some View {
        VStack(spacing: Spacing.xSmall) {
            HStack {
                Text("Feature")
                    .font(Typography.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                #if os(iOS)
                Text("Free")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                Text("Personal")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.blue)
                    .frame(maxWidth: .infinity)
                Text("Pro")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.purple)
                    .frame(maxWidth: .infinity)
                #else
                Text("Free")
                    .font(Typography.headline)
                    .frame(width: 50)
                Text("Personal")
                    .font(Typography.headline)
                    .foregroundColor(.blue)
                    .frame(width: 65)
                Text("Pro")
                    .font(Typography.headline)
                    .foregroundColor(.purple)
                    .frame(width: 50)
                #endif
            }
            .padding(.bottom, Spacing.xxSmall)

            Divider()

            featureRow("Import archives", free: "100 MB", personal: true, pro: true)
            featureRow("Browse & search emails", free: "500", personal: true, pro: true)
            featureRow("All formats (MBOX/EML/MSG/PST)", free: true, personal: true, pro: true)
            featureRow("View & filter emails", free: true, personal: true, pro: true)
            featureRow("Boolean/regex/proximity search", free: true, personal: true, pro: true)
            featureRow("Conversation threading", free: true, personal: true, pro: true)
            featureRow("AI Assistant", free: "5/day", personal: true, pro: true)
            featureRow("AI Smart Filters", free: "5/day", personal: true, pro: true)
            featureRow("Analytics & charts", free: true, personal: true, pro: true)
            featureRow("Export (EML/CSV)", free: "10", personal: true, pro: true)
            featureRow("Download attachments", free: "10", personal: true, pro: true)

            Divider().padding(.vertical, Spacing.xxxSmall)

            featureRow("S/MIME verify & decrypt", free: false, personal: true, pro: true)
            featureRow("Deduplication", free: false, personal: true, pro: true)
            featureRow("Export (PDF/PST/MSG/vCard/ICS)", free: false, personal: true, pro: true)

            Divider().padding(.vertical, Spacing.xxxSmall)

            featureRow("Forensic mode", free: false, personal: false, pro: true)
            featureRow("Audit trail", free: false, personal: false, pro: true)
            featureRow("Chain of custody", free: false, personal: false, pro: true)
            featureRow("Bates numbering", free: false, personal: false, pro: true)
            featureRow("Predictive coding (AI)", free: false, personal: false, pro: true)
            featureRow("Batch processing", free: false, personal: false, pro: true)
            featureRow("Custodian management", free: false, personal: false, pro: true)
            featureRow("Legal hold", free: false, personal: false, pro: true)
            featureRow("Priority support", free: false, personal: false, pro: true)
        }
        .adaptiveCard(cornerRadius: CornerRadius.large)
    }

    private func featureRow(_ name: String, free: Bool, personal: Bool, pro: Bool) -> some View {
        HStack {
            Text(name)
                #if os(iOS)
                .font(Typography.caption1)
                #else
                .font(Typography.callout)
                #endif
                .frame(maxWidth: .infinity, alignment: .leading)
            #if os(iOS)
            checkIcon(free)
                .frame(maxWidth: .infinity)
            checkIcon(personal)
                .frame(maxWidth: .infinity)
            checkIcon(pro)
                .frame(maxWidth: .infinity)
            #else
            checkIcon(free)
                .frame(width: 50)
            checkIcon(personal)
                .frame(width: 65)
            checkIcon(pro)
                .frame(width: 50)
            #endif
        }
        .padding(.vertical, Spacing.xxxSmall)
    }

    private func featureRow(_ name: String, free: String, personal: Bool, pro: Bool) -> some View {
        HStack {
            Text(name)
                #if os(iOS)
                .font(Typography.caption1)
                #else
                .font(Typography.callout)
                #endif
                .frame(maxWidth: .infinity, alignment: .leading)
            #if os(iOS)
            Text(free)
                .font(Typography.caption2)
                .foregroundColor(AppColors.secondary)
                .frame(maxWidth: .infinity)
            checkIcon(personal)
                .frame(maxWidth: .infinity)
            checkIcon(pro)
                .frame(maxWidth: .infinity)
            #else
            Text(free)
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
                .frame(width: 50)
            checkIcon(personal)
                .frame(width: 65)
            checkIcon(pro)
                .frame(width: 50)
            #endif
        }
        .padding(.vertical, Spacing.xxxSmall)
    }

    private func checkIcon(_ enabled: Bool) -> some View {
        Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle")
            .foregroundColor(enabled ? AppColors.success : AppColors.secondary.opacity(0.4))
    }

    // MARK: - Billing Period Picker

    private var billingPeriodPicker: some View {
        HStack(spacing: 0) {
            ForEach(BillingPeriod.allCases, id: \.self) { period in
                Button {
                    withAnimation(AnimationTiming.fast) {
                        selectedPeriod = period
                    }
                } label: {
                    VStack(spacing: 2) {
                        Text(period.displayName)
                            .font(Typography.callout)
                            .fontWeight(selectedPeriod == period ? .semibold : .regular)
                        if period == .yearly, let savings = yearlySavingsLabel {
                            Text(savings)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.green)
                        } else if period == .lifetime {
                            Text("Best Value")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.purple)
                        } else {
                            Text(" ")
                                .font(.system(size: 9))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.small)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.medium)
                            .fill(selectedPeriod == period ? AppColors.backgroundPrimary : Color.clear)
                            .shadow(color: selectedPeriod == period ? .black.opacity(0.1) : .clear, radius: 2, y: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.large)
                .fill(AppColors.secondary.opacity(0.1))
        )
    }

    /// Yearly saving against twelve months of the monthly price, from the
    /// App Store's own prices for the selected tier; nil when either product
    /// is missing, so no made-up percentage is ever shown.
    private var yearlySavingsLabel: String? {
        let monthly: Product?
        let yearly: Product?
        if selectedTier == .professional {
            monthly = store.professionalProduct(for: .monthly)
            yearly = store.professionalProduct(for: .yearly)
        } else {
            monthly = store.personalProduct(for: .monthly)
            yearly = store.personalProduct(for: .yearly)
        }
        guard let monthly, let yearly, monthly.price > 0 else { return nil }
        let twelveMonths = monthly.price * 12
        guard twelveMonths > yearly.price else { return nil }
        let fraction = (twelveMonths - yearly.price) / twelveMonths
        let percent = Int((NSDecimalNumber(decimal: fraction).doubleValue * 100).rounded())
        return percent >= 5 ? "Save \(percent)%" : nil
    }

    // MARK: - Purchase Cards

    private var purchaseCards: some View {
        VStack(spacing: Spacing.small) {
            if store.effectiveTier == .personal {
                HStack(spacing: Spacing.xSmall) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.blue)
                    Text(store.isLifetimePurchase
                         ? "You own Personal (lifetime). It stays yours; Professional is an optional separate purchase."
                         : "You have Personal. Professional adds the forensic and legal tools.")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }
                .padding(Spacing.small)
                .background(Color.blue.opacity(0.08))
                .cornerRadius(CornerRadius.medium)
                .accessibilityIdentifier("paywall.ownsPersonal")
            }

            if !store.products.isEmpty {
                if store.effectiveTier < .personal, let personal = store.personalProduct(for: selectedPeriod) {
                    purchaseCard(personal, tierName: "Personal", badge: nil, color: .blue)
                }
                if store.effectiveTier < .professional, let professional = store.professionalProduct(for: selectedPeriod) {
                    purchaseCard(professional, tierName: "Professional", badge: "Most Popular", color: .purple)
                }
            } else if store.productLoadError != nil {
                productLoadErrorView
            } else {
                productLoadingView
            }
        }
    }

    private func purchaseCard(_ product: Product, tierName: String, badge: String?, color: Color) -> some View {
        let isSelected = selectedProduct?.id == product.id

        return Button {
            withAnimation(AnimationTiming.fast) {
                selectedProduct = product
                selectedTier = StoreManager.professionalProductIDs.contains(product.id) ? .professional : .personal
            }
        } label: {
            HStack(spacing: Spacing.small) {
                VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                    HStack(spacing: Spacing.xSmall) {
                        Text(tierName)
                            .font(Typography.headline)
                        if let badge {
                            Text(badge)
                                .font(Typography.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .padding(.horizontal, Spacing.xSmall)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(color))
                        }
                    }
                    Text(product.description)
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                        .lineLimit(2)
                    Text(pricingSubtitle)
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary.opacity(0.7))
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(product.displayPrice)
                        .font(Typography.title3)
                        .fontWeight(.bold)
                    Text(pricingSuffix)
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                }

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(isSelected ? color : AppColors.secondary.opacity(0.4))
            }
            .adaptiveCard(cornerRadius: CornerRadius.large)
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.large)
                    .stroke(isSelected ? color : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    private var pricingSuffix: String {
        switch selectedPeriod {
        case .monthly: return "/month"
        case .yearly: return "/year"
        case .lifetime: return "one-time"
        }
    }

    private var pricingSubtitle: String {
        switch selectedPeriod {
        case .monthly: return String(localized: "Recurring: renews every month until cancelled")
        case .yearly: return String(localized: "Recurring: renews every year until cancelled")
        case .lifetime: return String(localized: "One-time payment, never renews")
        }
    }

    // MARK: - Purchase Button

    /// One submission at a time; each StoreKit outcome gets its own message.
    /// On verified success the request is dismissed and every window reads
    /// the new tier from the one StoreManager. The action that triggered the
    /// screen is NOT restarted: the user returns to it and starts it on purpose.
    private func submitPurchase() {
        guard let product = selectedProduct, !store.purchaseInProgress else { return }
        errorMessage = nil
        statusMessage = nil
        Task {
            switch await store.purchase(product) {
            case .success(let tier):
                statusMessage = "\(tier.displayName) is unlocked on this device."
                closePaywall()
            case .cancelled:
                statusMessage = "Purchase cancelled. Nothing was charged."
            case .pending:
                statusMessage = "Waiting for approval. You can close this and keep working; access arrives when the purchase is approved."
            case .verificationFailed:
                errorMessage = "The App Store's receipt could not be verified, so nothing was unlocked. Try Restore Purchases, or contact support."
            case .failed(let detail):
                errorMessage = "Purchase failed: \(detail)"
            case .alreadyInProgress:
                break
            }
        }
    }

    private var purchaseButton: some View {
        Button {
            submitPurchase()
        } label: {
            Group {
                if store.purchaseInProgress {
                    ProgressView()
                        .scaleEffect(0.8)
                        .frame(maxWidth: .infinity)
                } else {
                    Text(purchaseLabel)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(selectedProduct == nil || store.purchaseInProgress)
        .accessibilityIdentifier("paywall.buy")
    }

    private var purchaseLabel: String {
        guard let product = selectedProduct else { return String(localized: "Select a plan") }
        let tierName = StoreManager.professionalProductIDs.contains(product.id) ? "Professional" : "Personal"
        let billing: String
        if let period = product.subscription?.subscriptionPeriod {
            switch period.unit {
            case .month: billing = period.value == 1 ? " / month" : " / \(period.value) months"
            case .year: billing = period.value == 1 ? " / year" : " / \(period.value) years"
            case .week: billing = " / week"
            case .day: billing = " / day"
            @unknown default: billing = ""
            }
        } else {
            billing = " once"
        }
        return "Buy \(tierName) — \(product.displayPrice)\(billing)"
    }

    // MARK: - Shared Views

    private var productLoadErrorView: some View {
        VStack(spacing: Spacing.small) {
            Text("Unable to load products right now.")
                .font(Typography.callout)
                .foregroundColor(AppColors.secondary)
            Text("Make sure you're signed in to the App Store and have an internet connection.")
                .font(Typography.caption2)
                .foregroundColor(AppColors.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
            HStack(spacing: Spacing.medium) {
                Button("Retry") {
                    Task { await store.loadProducts() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("paywall.retryProducts")

                Button("Continue Free") {
                    closePaywall()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .adaptiveCard(cornerRadius: CornerRadius.large)
    }

    private var productLoadingView: some View {
        VStack(spacing: Spacing.small) {
            ProgressView()
                .scaleEffect(0.9)
            Text("Loading products from the App Store...")
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
        }
        .frame(maxWidth: .infinity)
        .adaptiveCard(cornerRadius: CornerRadius.large)
    }

    // MARK: - Restore & Legal

    private var restoreSection: some View {
        VStack(spacing: Spacing.xSmall) {
            Button {
                Task {
                    let outcome = await store.restorePurchases()
                    // Restored access that covers the request: the screen's
                    // job is done. Anything else stays visible with its message.
                    if case .restored(let tier) = outcome, tier >= (request?.requiredTier ?? .personal) {
                        closePaywall()
                    }
                }
            } label: {
                HStack(spacing: Spacing.xSmall) {
                    Text("Restore Purchases")
                    if store.isRestoring { ProgressView().controlSize(.small) }
                }
            }
            .font(Typography.callout)
            .disabled(store.isRestoring)
            #if os(macOS)
            .buttonStyle(.link)
            #else
            .buttonStyle(.borderless)
            #endif
            .accessibilityIdentifier("paywall.restore")

            if let outcome = store.lastRestoreOutcome {
                Label(outcome.message, systemImage: outcome.isSuccess ? "checkmark.circle.fill" : "info.circle")
                    .font(Typography.caption1)
                    .foregroundColor(outcome.isSuccess ? .green : (outcome == .nothingFound ? AppColors.secondary : AppColors.error))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("paywall.restoreResult")
            }

            if store.isPremium && !store.isLifetimePurchase {
                Button("Manage Subscription") {
                    Task { await store.manageSubscriptions() }
                }
                .font(Typography.caption1)
                #if os(macOS)
                .buttonStyle(.link)
                #else
                .buttonStyle(.borderless)
                #endif
            }

            if !ownsEverything {
                Button(store.effectiveTier == .free ? "Continue with Free Version" : "Not now") {
                    closePaywall()
                }
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
                .accessibilityLabel(store.effectiveTier == .free ? "Continue using the free version" : "Close without upgrading")
                .accessibilityIdentifier("paywall.continueFree")
            }
        }
    }

    private var legalText: some View {
        VStack(spacing: Spacing.xxSmall) {
            #if os(iOS)
            Text("Subscriptions auto-renew unless cancelled at least 24 hours before the end of the billing period. Your account will be charged for renewal within 24 hours prior to the end of the current period. Payment will be charged to your Apple ID account at confirmation of purchase. You can manage and cancel subscriptions in Settings > [your name] > Subscriptions. Lifetime purchases are permanent and do not auto-renew.")
                .font(Typography.caption2)
                .foregroundColor(AppColors.secondary)
                .multilineTextAlignment(.center)
            #else
            Text("Subscriptions auto-renew unless cancelled at least 24 hours before the end of the billing period. Your account will be charged for renewal within 24 hours prior to the end of the current period. Payment will be charged to your Apple ID account at confirmation of purchase. You can manage and cancel subscriptions in System Settings > Apple ID > Subscriptions. Lifetime purchases are permanent and do not auto-renew.")
                .font(Typography.caption2)
                .foregroundColor(AppColors.secondary)
                .multilineTextAlignment(.center)
            #endif

            HStack(spacing: Spacing.medium) {
                if let termsURL = URL(string: "https://sasmalgiri.github.io/mailin/terms") {
                    Link("Terms of Use", destination: termsURL)
                        .font(Typography.caption2)
                }
                if let privacyURL = URL(string: "https://sasmalgiri.github.io/mailin/privacy") {
                    Link("Privacy Policy", destination: privacyURL)
                        .font(Typography.caption2)
                }
            }
        }
        .padding(.top, Spacing.xSmall)
    }
}

#Preview {
    PaywallView()
        .environmentObject(StoreManager())
}
#endif

// MARK: - Presentation (one coordinator, one presenter per window)

private struct PurchasePresentationTargetKey: EnvironmentKey {
    static let defaultValue: PurchasePresentationTarget = .main
}

extension EnvironmentValues {
    /// The window a view lives in, for purchase requests it raises. Set by
    /// `purchasePresenter(target:)` on each SwiftUI root.
    var purchasePresentationTarget: PurchasePresentationTarget {
        get { self[PurchasePresentationTargetKey.self] }
        set { self[PurchasePresentationTargetKey.self] = newValue }
    }
}

/// Hosts the single paywall sheet for one window. Presents only the request
/// aimed at `target`, so two windows never show the same request, and a
/// request raised while the sheet is up just updates the sheet's content.
/// Dismissing clears the request and nothing else: page, selection and
/// unfinished work stay as they were. Compiled to a no-op in the enterprise
/// edition, which has no purchases.
struct PurchasePresenterModifier: ViewModifier {
    @EnvironmentObject private var store: StoreManager
    let target: PurchasePresentationTarget

    func body(content: Content) -> some View {
        #if ENTERPRISE_EDITION
        content
        #else
        content.sheet(isPresented: Binding(
            get: { store.paywallRequest?.target == target },
            set: { if !$0 { store.dismissPaywall() } }
        )) {
            PaywallView(request: store.paywallRequest)
                .environmentObject(store)
                .resizableSheet()
        }
        #endif
    }
}

extension View {
    /// Makes this view a window root for purchase presentation: hosts the
    /// paywall for requests aimed at `target` and tells every descendant
    /// which target to raise requests for.
    func purchasePresenter(target: PurchasePresentationTarget) -> some View {
        modifier(PurchasePresenterModifier(target: target))
            .environment(\.purchasePresentationTarget, target)
    }
}

// MARK: - Plan badge (every page, every platform)

/// The compact current-plan control: Free reads "Free · Upgrade" and opens
/// Personal selected; Personal shows the plan and opens Professional; a
/// Professional owner sees the plan and opens plan details, never an
/// upgrade demand. Lifetime ownership is named in the label.
struct PlanBadgeButton: View {
    @EnvironmentObject private var store: StoreManager
    @Environment(\.purchasePresentationTarget) private var target

    var body: some View {
        let tier = store.effectiveTier
        let label = StoreManager.planBadgeLabel(tier: tier, lifetime: store.isLifetimePurchase)
        Button {
            store.requestPurchase(StoreManager.planBadgeRequestTier(current: tier), target: target)
        } label: {
            Label(label, systemImage: tier == .free ? "arrow.up.circle.fill" : "checkmark.seal.fill")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(tier == .free ? .orange : .secondary)
        .help(tier == .free ? "You are on the Free plan. See plans and upgrade." : "Your plan: \(label). Plan details, restore and subscription management.")
        .accessibilityLabel(tier == .free ? "Free plan. Upgrade" : "Current plan: \(label)")
        .accessibilityIdentifier("plan.badge")
    }
}

// MARK: - Settings ▸ Plan & Purchases

/// The one Settings section for purchases: current tier, ownership kind,
/// renewal date when StoreKit reports one, View Plans / Upgrade, Restore
/// (always available, with a distinct result message), Manage Subscription
/// for subscribers, and product-load errors with a retry.
struct PlanAndPurchasesSection: View {
    @EnvironmentObject private var store: StoreManager
    @Environment(\.purchasePresentationTarget) private var target

    private var ownershipText: String {
        #if ENTERPRISE_EDITION
        return String(localized: "Enterprise edition: every feature is included in the purchase price.")
        #else
        switch store.effectiveTier {
        case .free: return String(localized: "No purchase. Import up to 100 MB, browse the first 500 results of any list or search, 5 Ask queries a day.")
        case .personal, .professional:
            if store.isLifetimePurchase { return String(localized: "Lifetime purchase: yours permanently, never renews.") }
            return String(localized: "Subscription")
        }
        #endif
    }

    var body: some View {
        Section {
            LabeledContent("Current plan") {
                Text(store.effectiveTier.displayName)
                    .fontWeight(.semibold)
                    .foregroundColor(store.isPremium ? .green : AppColors.secondary)
                    .accessibilityIdentifier("settings.plan.tier")
            }
            LabeledContent("Ownership") {
                Text(ownershipText)
                    .foregroundColor(AppColors.secondary)
                    .multilineTextAlignment(.trailing)
            }
            if !store.isLifetimePurchase, let expiration = store.subscriptionExpirationDate {
                LabeledContent("Renews or ends", value: expiration.formatted(date: .abbreviated, time: .omitted))
            }

            #if !ENTERPRISE_EDITION
            Button(store.effectiveTier == .free ? "View Plans / Upgrade…"
                   : (store.effectiveTier == .personal ? "Upgrade to Professional…" : "View Plan Details…")) {
                store.requestPurchase(StoreManager.planBadgeRequestTier(current: store.effectiveTier), target: target)
            }
            .accessibilityIdentifier("settings.plan.viewPlans")

            if store.isPremium && !store.isLifetimePurchase {
                Button("Manage Subscription…") {
                    Task { await store.manageSubscriptions() }
                }
                .accessibilityLabel("Manage or cancel subscription")
            }

            Button {
                Task { await store.restorePurchases() }
            } label: {
                HStack {
                    Text("Restore Purchases")
                    if store.isRestoring { ProgressView().controlSize(.small) }
                }
            }
            .disabled(store.isRestoring)
            .accessibilityLabel("Restore purchases")
            .accessibilityIdentifier("settings.plan.restore")

            if let outcome = store.lastRestoreOutcome {
                Label(outcome.message, systemImage: outcome.isSuccess ? "checkmark.circle.fill" : "info.circle")
                    .font(.caption)
                    .foregroundColor(outcome.isSuccess ? .green : (outcome == .nothingFound ? .secondary : AppColors.error))
                    .accessibilityIdentifier("settings.plan.restoreResult")
            }

            if let error = store.productLoadError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(AppColors.error)
                Button("Retry loading plans") { Task { await store.loadProducts() } }
            }
            #endif
        } header: {
            Text("Plan & Purchases")
                .font(.headline)
        } footer: {
            #if !ENTERPRISE_EDITION
            Text("Personal and Professional are each offered monthly, yearly, or as a one-time lifetime purchase. Professional includes everything in Personal. Prices are shown by the App Store in your currency.")
                .font(.caption)
                .foregroundColor(.secondary)
            #else
            EmptyView()
            #endif
        }
    }
}

// MARK: - Feature Locked Badge (pre-action visibility)

struct FeatureLockedBadge: View {
    let tierName: String

    init(tier: PurchaseTier = .professional) {
        self.tierName = tier.displayName
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "lock.fill")
            Text(tierName)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundColor(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.purple.opacity(0.8)))
    }
}

struct FeatureGateModifier: ViewModifier {
    @EnvironmentObject var store: StoreManager
    let requiredTier: PurchaseTier

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if store.currentTier < requiredTier {
                    FeatureLockedBadge(tier: requiredTier)
                        .padding(4)
                }
            }
    }
}

extension View {
    func featureGate(_ tier: PurchaseTier) -> some View {
        modifier(FeatureGateModifier(requiredTier: tier))
    }
}
