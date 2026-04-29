//
//  DesignSystem.swift
//  mailin
//
//  Apple Human Interface Guidelines compliant design tokens
//

import SwiftUI

// MARK: - Spacing System
enum Spacing {
    static let xxxSmall: CGFloat = 2
    static let xxSmall: CGFloat = 4
    static let xSmall: CGFloat = 8
    static let small: CGFloat = 12
    static let medium: CGFloat = 16
    static let large: CGFloat = 24
    static let xLarge: CGFloat = 32
    static let xxLarge: CGFloat = 48
    static let xxxLarge: CGFloat = 64
}

// MARK: - Corner Radius
enum CornerRadius {
    static let small: CGFloat = 4
    static let medium: CGFloat = 8
    static let large: CGFloat = 12
    static let xLarge: CGFloat = 16
    static let round: CGFloat = 9999
}

// MARK: - Typography
enum Typography {
    static let largeTitle = Font.system(size: 34, weight: .bold, design: .rounded)
    static let title1 = Font.system(size: 28, weight: .bold, design: .rounded)
    static let title2 = Font.system(size: 22, weight: .bold, design: .rounded)
    static let title3 = Font.system(size: 20, weight: .semibold, design: .rounded)
    static let headline = Font.system(size: 17, weight: .semibold)
    static let body = Font.system(size: 15, weight: .regular)
    static let callout = Font.system(size: 14, weight: .regular)
    static let subheadline = Font.system(size: 13, weight: .regular)
    static let footnote = Font.system(size: 12, weight: .regular)
    static let caption1 = Font.system(size: 11, weight: .regular)
    static let caption2 = Font.system(size: 10, weight: .regular)
    
    // Monospaced variants for email content
    static let monoBody = Font.system(size: 13, weight: .regular, design: .monospaced)
    static let monoSmall = Font.system(size: 11, weight: .regular, design: .monospaced)
}

// MARK: - Colors (Semantic)
enum AppColors {
    // Primary colors
    static let primary = Color.accentColor
    static let secondary = Color.secondary
    
    // Status colors
    static let success = Color.green
    static let warning = Color.orange
    static let error = Color.red
    static let info = Color.blue
    
    // Email type colors
    static let sentEmail = Color.blue
    static let receivedEmail = Color.green
    static let draftEmail = Color.orange
    
    // Background layers
    static let backgroundPrimary = Color(nsColor: .windowBackgroundColor)
    static let backgroundSecondary = Color(nsColor: .controlBackgroundColor)
    static let backgroundTertiary = Color(nsColor: .textBackgroundColor)
    
    // Separators
    static let separator = Color(nsColor: .separatorColor)
    static let separatorLight = Color(nsColor: .separatorColor).opacity(0.5)
}

// MARK: - Shadows
enum Shadows {
    static let small = ShadowStyle(radius: 2, y: 1)
    static let medium = ShadowStyle(radius: 4, y: 2)
    static let large = ShadowStyle(radius: 8, y: 4)
    static let xLarge = ShadowStyle(radius: 16, y: 8)
    
    struct ShadowStyle {
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
        
        init(radius: CGFloat, x: CGFloat = 0, y: CGFloat) {
            self.radius = radius
            self.x = x
            self.y = y
        }
    }
}

// MARK: - Animation Timing
enum AnimationTiming {
    static let instant = Animation.easeInOut(duration: 0.1)
    static let fast = Animation.easeInOut(duration: 0.2)
    static let normal = Animation.easeInOut(duration: 0.3)
    static let slow = Animation.easeInOut(duration: 0.5)
    
    static let spring = Animation.spring(response: 0.3, dampingFraction: 0.7)
    static let springBouncy = Animation.spring(response: 0.4, dampingFraction: 0.6)
}

// MARK: - View Modifiers

// Apple-style card modifier
struct CardStyle: ViewModifier {
    var padding: CGFloat = Spacing.medium
    var cornerRadius: CGFloat = CornerRadius.large
    
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(AppColors.backgroundTertiary)
            .cornerRadius(cornerRadius)
            .shadow(color: .black.opacity(0.05), radius: Shadows.small.radius, x: 0, y: Shadows.small.y)
    }
}

// Hover effect modifier
struct HoverEffect: ViewModifier {
    @State private var isHovering = false
    var scale: CGFloat = 1.02
    
    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovering ? scale : 1.0)
            .brightness(isHovering ? 0.05 : 0)
            .animation(AnimationTiming.fast, value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

// Shimmer loading effect
struct ShimmerEffect: ViewModifier {
    @State private var phase: CGFloat = 0
    
    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    colors: [
                        .clear,
                        .white.opacity(0.3),
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .offset(x: phase)
                .mask(content)
            )
            .onAppear {
                withAnimation(Animation.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 400
                }
            }
    }
}

// MARK: - View Extensions

extension View {
    /// Apply Apple-style card appearance
    func cardStyle(padding: CGFloat = Spacing.medium, cornerRadius: CGFloat = CornerRadius.large) -> some View {
        modifier(CardStyle(padding: padding, cornerRadius: cornerRadius))
    }
    
    /// Apply hover scaling effect
    func hoverEffect(scale: CGFloat = 1.02) -> some View {
        modifier(HoverEffect(scale: scale))
    }
    
    /// Apply shimmer loading animation
    func shimmerEffect() -> some View {
        modifier(ShimmerEffect())
    }
    
    /// Apply conditional modifier
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: - Custom Button Styles

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.headline)
            .foregroundColor(.white)
            .padding(.horizontal, Spacing.large)
            .padding(.vertical, Spacing.small)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.medium)
                    .fill(AppColors.primary)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(AnimationTiming.fast, value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.headline)
            .foregroundColor(AppColors.primary)
            .padding(.horizontal, Spacing.large)
            .padding(.vertical, Spacing.small)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.medium)
                    .fill(AppColors.backgroundSecondary)
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.medium)
                            .stroke(AppColors.primary.opacity(0.3), lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(AnimationTiming.fast, value: configuration.isPressed)
    }
}

// MARK: - Custom Components

/// Apple-style empty state view
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    
    var body: some View {
        VStack(spacing: Spacing.large) {
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundStyle(
                    .linearGradient(
                        colors: [AppColors.primary, AppColors.primary.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            VStack(spacing: Spacing.small) {
                Text(title)
                    .font(Typography.title2)
                    .fontWeight(.semibold)
                
                Text(message)
                    .font(Typography.body)
                    .foregroundColor(AppColors.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(Spacing.xxLarge)
    }
}

/// Apple-style loading indicator
struct LoadingView: View {
    let message: String
    @State private var isAnimating = false
    
    var body: some View {
        VStack(spacing: Spacing.medium) {
            ProgressView()
                .scaleEffect(1.5)
                .frame(width: 50, height: 50)
            
            Text(message)
                .font(Typography.headline)
                .foregroundColor(AppColors.secondary)
        }
        .padding(Spacing.xLarge)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.large)
                .fill(AppColors.backgroundTertiary)
                .shadow(color: .black.opacity(0.1), radius: 20)
        )
    }
}
