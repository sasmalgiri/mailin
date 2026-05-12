import SwiftUI
import StoreKit

struct PaywallView: View {
    @EnvironmentObject private var store: StoreManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProduct: Product?
    @State private var selectedPeriod: BillingPeriod = .yearly
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                headerSection
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(AppColors.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(Spacing.medium)
                .accessibilityLabel("Close")
            }
            Divider()
            ScrollView {
                VStack(spacing: Spacing.large) {
                    featureComparison
                    billingPeriodPicker
                    purchaseCards
                    if store.purchasePending {
                        HStack(spacing: Spacing.xSmall) {
                            Image(systemName: "clock.fill")
                                .foregroundColor(.orange)
                            Text("Your purchase is pending approval. If you're using Ask to Buy, check with your family organizer.")
                                .font(Typography.caption1)
                                .foregroundColor(.orange)
                        }
                        .padding(Spacing.small)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(CornerRadius.medium)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.error)
                    }
                    purchaseButton
                    restoreSection
                    legalText
                }
                .padding(Spacing.large)
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, idealWidth: 640, minHeight: 500, idealHeight: 700)
        #endif
        .background(AppColors.backgroundPrimary)
        .onAppear {
            updateSelectedProduct()
        }
        .onChange(of: selectedPeriod, initial: false) {
            updateSelectedProduct()
        }
    }

    private func updateSelectedProduct() {
        if let pro = store.professionalProduct(for: selectedPeriod) {
            selectedProduct = pro
        } else if let personal = store.personalProduct(for: selectedPeriod) {
            selectedProduct = personal
        } else {
            selectedProduct = store.products.first
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: Spacing.small) {
            crownIcon

            Text("Unlock mailin")
                .font(.system(.title2, design: .rounded))
                .fontWeight(.bold)

            Text("Subscribe monthly, yearly, or buy once for lifetime access.")
                .font(.subheadline)
                .foregroundColor(AppColors.secondary)

            HStack(spacing: Spacing.medium) {
                Label("Complete Privacy", systemImage: "lock.shield.fill")
                Label("Native Apple AI", systemImage: "brain.head.profile")
            }
            .font(Typography.caption1)
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
            }
            .padding(.bottom, Spacing.xxSmall)

            Divider()

            featureRow("Parse emails", free: "500", personal: true, pro: true)
            featureRow("All formats (MBOX/EML/MSG/PST)", free: true, personal: true, pro: true)
            featureRow("View & filter emails", free: true, personal: true, pro: true)
            featureRow("Boolean/regex/proximity search", free: true, personal: true, pro: true)
            featureRow("Conversation threading", free: true, personal: true, pro: true)
            featureRow("AI Assistant", free: "3", personal: true, pro: true)
            featureRow("AI Smart Filters", free: "3", personal: true, pro: true)
            featureRow("Analytics & charts", free: true, personal: true, pro: true)
            featureRow("Export (EML/CSV/PDF)", free: "10", personal: true, pro: true)
            featureRow("Download attachments", free: "5", personal: true, pro: true)

            Divider().padding(.vertical, Spacing.xxxSmall)

            featureRow("S/MIME verify & decrypt", free: false, personal: true, pro: true)
            featureRow("Deduplication", free: false, personal: true, pro: true)
            featureRow("Export (PST/MSG/vCard/ICS)", free: false, personal: true, pro: true)

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
                .font(Typography.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            checkIcon(free)
                .frame(width: 50)
            checkIcon(personal)
                .frame(width: 65)
            checkIcon(pro)
                .frame(width: 50)
        }
        .padding(.vertical, Spacing.xxxSmall)
    }

    private func featureRow(_ name: String, free: String, personal: Bool, pro: Bool) -> some View {
        HStack {
            Text(name)
                .font(Typography.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(free)
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
                .frame(width: 50)
            checkIcon(personal)
                .frame(width: 65)
            checkIcon(pro)
                .frame(width: 50)
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
                        Text(period.rawValue)
                            .font(Typography.callout)
                            .fontWeight(selectedPeriod == period ? .semibold : .regular)
                        if period == .yearly {
                            Text(verbatim: "Save 40%")
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

    // MARK: - Purchase Cards

    private var purchaseCards: some View {
        VStack(spacing: Spacing.small) {
            if store.isPremium && !store.isProfessional {
                HStack(spacing: Spacing.xSmall) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.blue)
                    Text("You own Personal. Upgrade to Professional for forensic & advanced tools.")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }
                .padding(Spacing.small)
                .background(Color.blue.opacity(0.08))
                .cornerRadius(CornerRadius.medium)
            }

            if store.isProfessional {
                HStack(spacing: Spacing.xSmall) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Text("You own Professional. All features are unlocked.")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }
                .padding(Spacing.small)
                .background(Color.green.opacity(0.08))
                .cornerRadius(CornerRadius.medium)
            }

            if !store.products.isEmpty {
                if store.currentTier < .personal, let personal = store.personalProduct(for: selectedPeriod) {
                    purchaseCard(personal, tierName: "Personal", badge: nil, color: .blue)
                }
                if store.currentTier < .professional, let professional = store.professionalProduct(for: selectedPeriod) {
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
        case .monthly: return "Auto-renewable subscription"
        case .yearly: return "Auto-renewable subscription — save 40%"
        case .lifetime: return "One-time purchase — best value"
        }
    }

    // MARK: - Purchase Button

    private var purchaseButton: some View {
        Button {
            guard let product = selectedProduct else { return }
            Task {
                do {
                    try await store.purchase(product)
                    if store.isPremium { dismiss() }
                } catch {
                    errorMessage = "Purchase failed: \(error.localizedDescription)"
                }
            }
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
    }

    private var purchaseLabel: String {
        guard let product = selectedProduct else { return "Select a plan" }
        let tierName = StoreManager.professionalProductIDs.contains(product.id) ? "Professional" : "Personal"
        return "Buy \(tierName) — \(product.displayPrice)"
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

                Button("Continue Free") {
                    dismiss()
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
            Button("Restore Purchases") {
                Task { await store.restorePurchases() }
            }
            .font(Typography.callout)
            #if os(macOS)
            .buttonStyle(.link)
            #else
            .buttonStyle(.borderless)
            #endif

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

            Button("Continue with Free Version") {
                dismiss()
            }
            .font(Typography.caption1)
            .foregroundColor(AppColors.secondary)
            .accessibilityLabel("Continue using the free version")
        }
    }

    private var legalText: some View {
        VStack(spacing: Spacing.xxSmall) {
            Text("Subscriptions auto-renew unless cancelled 24 hours before the end of the billing period. Manage subscriptions in System Settings. Lifetime purchases are permanent. All purchases can be restored on your devices signed in with the same Apple ID.")
                .font(Typography.caption2)
                .foregroundColor(AppColors.secondary)
                .multilineTextAlignment(.center)

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
