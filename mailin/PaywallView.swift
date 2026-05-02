import SwiftUI
import StoreKit

struct PaywallView: View {
    @EnvironmentObject private var store: StoreManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProduct: Product?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            ScrollView {
                VStack(spacing: Spacing.large) {
                    featureComparison
                    productCards
                    if let errorMessage {
                        Text(errorMessage)
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.error)
                    }
                    restoreButton
                    legalText
                }
                .padding(Spacing.large)
            }
        }
        .frame(minWidth: 400, idealWidth: 540, minHeight: 500, idealHeight: 650)
        .background(AppColors.backgroundPrimary)
        .onAppear {
            selectedProduct = store.yearlyProduct
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: Spacing.small) {
            Image(systemName: "crown.fill")
                .font(.system(size: 44))
                .foregroundStyle(
                    .linearGradient(colors: [.orange, .yellow], startPoint: .topLeading, endPoint: .bottomTrailing)
                )

            Text("Unlock mailin Pro")
                .font(.system(size: 26, weight: .bold, design: .rounded))

            Text("Unlimited emails, AI insights, exports & more")
                .font(.system(size: 14))
                .foregroundColor(AppColors.secondary)

            HStack(spacing: Spacing.medium) {
                Label("Complete Privacy", systemImage: "lock.shield.fill")
                Label("Native Apple AI", systemImage: "brain.head.profile")
            }
            .font(Typography.caption1)
            .foregroundColor(AppColors.secondary)

            Text("Choose a one-time purchase or flexible subscription below")
                .font(Typography.caption2)
                .foregroundColor(AppColors.secondary.opacity(0.7))
        }
        .padding(.vertical, Spacing.large)
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
                    .frame(width: 60)
                Text("Pro")
                    .font(Typography.headline)
                    .foregroundColor(AppColors.primary)
                    .frame(width: 60)
            }
            .padding(.bottom, Spacing.xxSmall)

            Divider()

            featureRow("Parse emails", free: "50 max", pro: "Unlimited")
            featureRow("View & filter emails", free: true, pro: true)
            featureRow("AI Assistant (NLP)", free: false, pro: true)
            featureRow("Sentiment analysis", free: false, pro: true)
            featureRow("Export (EML/JSON/CSV)", free: false, pro: true)
            featureRow("Reply analytics", free: false, pro: true)
            featureRow("Download attachments", free: false, pro: true)
        }
        .padding(Spacing.medium)
        .background(AppColors.backgroundSecondary)
        .cornerRadius(CornerRadius.large)
    }

    private func featureRow(_ name: String, free: Bool, pro: Bool) -> some View {
        HStack {
            Text(name)
                .font(Typography.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: free ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(free ? AppColors.success : AppColors.secondary.opacity(0.4))
                .frame(width: 60)
            Image(systemName: pro ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(pro ? AppColors.success : AppColors.secondary.opacity(0.4))
                .frame(width: 60)
        }
        .padding(.vertical, Spacing.xxxSmall)
    }

    private func featureRow(_ name: String, free: String, pro: String) -> some View {
        HStack {
            Text(name)
                .font(Typography.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(free)
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
                .frame(width: 60)
            Text(pro)
                .font(Typography.caption1)
                .foregroundColor(AppColors.primary)
                .fontWeight(.semibold)
                .frame(width: 60)
        }
        .padding(.vertical, Spacing.xxxSmall)
    }

    // MARK: - Product Cards

    private var productCards: some View {
        VStack(spacing: Spacing.small) {
            if let monthly = store.monthlyProduct {
                productCard(monthly, badge: nil)
            }
            if let yearly = store.yearlyProduct {
                productCard(yearly, badge: "Best Value")
            }
            if let lifetime = store.lifetimeProduct {
                productCard(lifetime, badge: "Pay Once")
            }

            if !store.products.isEmpty {
                purchaseButton
            } else if let loadError = store.productLoadError {
                VStack(spacing: Spacing.small) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundColor(AppColors.warning)
                    Text(loadError)
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task { await store.loadProducts() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(Spacing.medium)
                .frame(maxWidth: .infinity)
                .background(AppColors.backgroundSecondary)
                .cornerRadius(CornerRadius.large)
            } else {
                VStack(spacing: Spacing.small) {
                    ProgressView()
                        .scaleEffect(0.9)
                    Text("Loading available plans from the App Store...")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                    Text("Make sure you're signed in to the App Store and have an internet connection.")
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .padding(Spacing.medium)
                .frame(maxWidth: .infinity)
                .background(AppColors.backgroundSecondary)
                .cornerRadius(CornerRadius.large)
            }
        }
    }

    private func productCard(_ product: Product, badge: String?) -> some View {
        let isSelected = selectedProduct?.id == product.id

        return Button {
            withAnimation(AnimationTiming.fast) {
                selectedProduct = product
            }
        } label: {
            HStack(spacing: Spacing.small) {
                VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                    HStack(spacing: Spacing.xSmall) {
                        Text(product.displayName)
                            .font(Typography.headline)
                        if let badge {
                            Text(badge)
                                .font(Typography.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .padding(.horizontal, Spacing.xSmall)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(
                                        product.id == StoreManager.lifetimeID
                                            ? Color.orange
                                            : AppColors.primary
                                    )
                                )
                        }
                    }
                    Text(product.description)
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(product.displayPrice)
                    .font(Typography.title3)
                    .fontWeight(.bold)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(isSelected ? AppColors.primary : AppColors.secondary.opacity(0.4))
            }
            .padding(Spacing.medium)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.large)
                    .fill(isSelected ? AppColors.primary.opacity(0.08) : AppColors.backgroundSecondary)
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.large)
                            .stroke(isSelected ? AppColors.primary : Color.clear, lineWidth: 2)
                    )
            )
        }
        .buttonStyle(.plain)
    }

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
        .padding(.top, Spacing.xSmall)
    }

    private var purchaseLabel: String {
        guard let product = selectedProduct else { return "Select a plan" }
        if product.id == StoreManager.lifetimeID {
            return "Buy Lifetime — \(product.displayPrice)"
        }
        return "Subscribe — \(product.displayPrice)"
    }

    // MARK: - Restore & Legal

    private var restoreButton: some View {
        Button("Restore Purchases") {
            Task { await store.restorePurchases() }
        }
        .buttonStyle(.link)
        .font(Typography.callout)
    }

    private var legalText: some View {
        VStack(spacing: Spacing.xxSmall) {
            Text("Payment will be charged to your Apple ID account at confirmation of purchase. Subscriptions automatically renew unless cancelled at least 24 hours before the end of the current period. Your account will be charged for renewal within 24 hours prior to the end of the current period. You can manage and cancel subscriptions in your Account Settings. Lifetime purchase is a one-time payment with no expiration.")
                .font(Typography.caption2)
                .foregroundColor(AppColors.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: Spacing.medium) {
                if let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/") {
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
