//
//  DesignSystem.swift
//  mailin
//
//  Apple Human Interface Guidelines compliant design tokens
//

import SwiftUI

// MARK: - Adaptive Layout

enum WindowSizeClass: Equatable {
    case compact    // < 800pt wide (small window / 11" screen)
    case regular    // 800–1200pt (typical laptop)
    case expanded   // > 1200pt (large monitor / ultrawide)

    static func from(width: CGFloat) -> WindowSizeClass {
        if width < 800 { return .compact }
        if width <= 1200 { return .regular }
        return .expanded
    }
}

struct WindowSizeClassKey: EnvironmentKey {
    static let defaultValue: WindowSizeClass = .regular
}

extension EnvironmentValues {
    var windowSizeClass: WindowSizeClass {
        get { self[WindowSizeClassKey.self] }
        set { self[WindowSizeClassKey.self] = newValue }
    }
}

struct AdaptiveLayoutModifier: ViewModifier {
    @State private var sizeClass: WindowSizeClass = .regular

    func body(content: Content) -> some View {
        content
            .environment(\.windowSizeClass, sizeClass)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { sizeClass = WindowSizeClass.from(width: geo.size.width) }
                        .onChange(of: geo.size.width) { _, newWidth in
                            sizeClass = WindowSizeClass.from(width: newWidth)
                        }
                }
            )
    }
}

extension View {
    func adaptiveLayout() -> some View {
        modifier(AdaptiveLayoutModifier())
    }
}

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

// MARK: - Typography (Dynamic Type compatible)
enum Typography {
    static let largeTitle = Font.largeTitle.weight(.bold)
    static let title1 = Font.title.weight(.bold)
    static let title2 = Font.title2.weight(.bold)
    static let title3 = Font.title3.weight(.semibold)
    static let headline = Font.headline
    static let body = Font.body
    static let callout = Font.callout
    static let subheadline = Font.subheadline
    static let footnote = Font.footnote
    static let caption1 = Font.caption
    static let caption2 = Font.caption2

    static let monoBody = Font.body.monospaced()
    static let monoSmall = Font.caption.monospaced()
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
    #if os(macOS)
    static let backgroundPrimary = Color(nsColor: .windowBackgroundColor)
    static let backgroundSecondary = Color(nsColor: .controlBackgroundColor)
    static let backgroundTertiary = Color(nsColor: .textBackgroundColor)
    #else
    static let backgroundPrimary = Color(uiColor: .systemBackground)
    static let backgroundSecondary = Color(uiColor: .secondarySystemBackground)
    static let backgroundTertiary = Color(uiColor: .tertiarySystemBackground)
    #endif

    // Separators
    #if os(macOS)
    static let separator = Color(nsColor: .separatorColor)
    static let separatorLight = Color(nsColor: .separatorColor).opacity(0.5)
    #else
    static let separator = Color(uiColor: .separator)
    static let separatorLight = Color(uiColor: .separator).opacity(0.5)
    #endif
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

// Shimmer loading effect (respects reduce motion + dark mode safe)
struct ShimmerEffect: ViewModifier {
    @State private var phase: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    colors: [
                        .clear,
                        (colorScheme == .dark ? Color.white : Color.black).opacity(0.15),
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .offset(x: phase)
                .mask(content)
                .opacity(reduceMotion ? 0 : 1)
            )
            .onAppear {
                guard !reduceMotion else { return }
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

// MARK: - Focus Visible (WCAG 2.4.7)

struct FocusRingModifier: ViewModifier {
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.medium)
                    .stroke(AppColors.primary, lineWidth: 2)
                    .opacity(isFocused ? 1 : 0)
                    .padding(-2)
            )
    }
}

extension View {
    func focusRing() -> some View {
        self.focusable()
            .modifier(FocusRingModifier())
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

// MARK: - Compact Button Styles (for sidebar/toolbar use)

struct CompactPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.callout)
            .fontWeight(.semibold)
            .foregroundColor(.white)
            .padding(.horizontal, Spacing.small)
            .padding(.vertical, Spacing.xSmall)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.medium)
                    .fill(AppColors.primary)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(AnimationTiming.fast, value: configuration.isPressed)
    }
}

struct CompactSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.callout)
            .fontWeight(.medium)
            .foregroundColor(AppColors.primary)
            .padding(.horizontal, Spacing.small)
            .padding(.vertical, Spacing.xSmall)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.medium)
                    .fill(AppColors.backgroundSecondary)
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.medium)
                            .stroke(AppColors.primary.opacity(0.3), lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(AnimationTiming.fast, value: configuration.isPressed)
    }
}

// MARK: - Version-Adaptive Design (auto-upgrades with OS)

extension View {
    /// Applies Liquid Glass on macOS 26+ / iOS 26+, falls back to material on older OS
    @ViewBuilder
    func adaptiveGlass(in shape: some Shape = Capsule()) -> some View {
        if #available(macOS 26, iOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(shape.fill(.ultraThinMaterial))
        }
    }

    /// Adaptive card: glass on macOS 26+, material card on older
    @ViewBuilder
    func adaptiveCard(cornerRadius: CGFloat = CornerRadius.large) -> some View {
        if #available(macOS 26, iOS 26, *) {
            self
                .padding(Spacing.medium)
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.cardStyle(cornerRadius: cornerRadius)
        }
    }

    /// Adaptive toolbar background: glass on 26+, material on older
    @ViewBuilder
    func adaptiveToolbarBackground() -> some View {
        if #available(macOS 26, iOS 26, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: CornerRadius.medium))
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: CornerRadius.medium))
        }
    }

    /// Confirmation dialog on macOS 13+, alert as universal fallback
    func adaptiveDestructiveConfirmation(
        _ title: String,
        isPresented: Binding<Bool>,
        message: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        self.confirmationDialog(title, isPresented: isPresented) {
            Button(actionTitle, role: .destructive, action: action)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(message)
        }
    }

    /// Reduce-motion-aware animation
    func adaptiveAnimation<V: Equatable>(_ value: V) -> some View {
        self.modifier(ReduceMotionAnimationModifier(value: value))
    }
}

/// Respects the user's reduce motion accessibility setting
struct ReduceMotionAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: V

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.animation(AnimationTiming.normal, value: value)
        }
    }
}

/// Version-adaptive button style: Liquid Glass on 26+, bordered on older
struct AdaptiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26, iOS 26, *) {
            configuration.label
                .font(Typography.headline)
                .padding(.horizontal, Spacing.large)
                .padding(.vertical, Spacing.small)
                .glassEffect(.regular.interactive(), in: .capsule)
                .opacity(configuration.isPressed ? 0.8 : 1.0)
        } else {
            configuration.label
                .font(Typography.headline)
                .padding(.horizontal, Spacing.large)
                .padding(.vertical, Spacing.small)
                .background(.ultraThinMaterial, in: Capsule())
                .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
                .animation(AnimationTiming.fast, value: configuration.isPressed)
        }
    }
}

/// Version-adaptive prominent button: tinted glass on 26+, filled on older
struct AdaptiveProminentButtonStyle: ButtonStyle {
    var tint: Color = AppColors.primary

    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26, iOS 26, *) {
            configuration.label
                .font(Typography.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.large)
                .padding(.vertical, Spacing.small)
                .glassEffect(.regular.tint(tint).interactive(), in: .capsule)
                .opacity(configuration.isPressed ? 0.8 : 1.0)
        } else {
            configuration.label
                .font(Typography.headline)
                .foregroundColor(.white)
                .padding(.horizontal, Spacing.large)
                .padding(.vertical, Spacing.small)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.medium)
                        .fill(tint)
                )
                .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
                .animation(AnimationTiming.fast, value: configuration.isPressed)
        }
    }
}

// MARK: - macOS 15 / iOS 18 Adaptive Features (MeshGradient, SF Symbol effects)

extension View {
    /// MeshGradient hero background on macOS 15+ / iOS 18+, linear gradient fallback
    @ViewBuilder
    func adaptiveHeroBackground(colors: [Color] = [.blue, .purple, .indigo, .teal]) -> some View {
        if #available(macOS 15, iOS 18, *) {
            self.background(
                MeshGradient(width: 3, height: 3, points: [
                    .init(0, 0), .init(0.5, 0), .init(1, 0),
                    .init(0, 0.5), .init(0.5, 0.5), .init(1, 0.5),
                    .init(0, 1), .init(0.5, 1), .init(1, 1)
                ], colors: [
                    colors[0 % colors.count], colors[1 % colors.count].opacity(0.7), colors[2 % colors.count],
                    colors[1 % colors.count].opacity(0.5), colors[3 % colors.count].opacity(0.3), colors[0 % colors.count].opacity(0.5),
                    colors[2 % colors.count], colors[3 % colors.count].opacity(0.7), colors[1 % colors.count]
                ])
                .opacity(0.15)
                .ignoresSafeArea()
            )
        } else {
            self.background(
                LinearGradient(
                    colors: [colors.first?.opacity(0.1) ?? .clear, colors.last?.opacity(0.05) ?? .clear],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
        }
    }

    /// Scroll transition (fade + scale as items enter/exit visible area)
    /// Available at deployment target (macOS 14+ / iOS 17+)
    func adaptiveScrollTransition() -> some View {
        self.scrollTransition { content, phase in
            content
                .opacity(phase.isIdentity ? 1 : 0.7)
                .scaleEffect(phase.isIdentity ? 1 : 0.95)
        }
    }

    /// SF Symbol wiggle effect on macOS 15+ / iOS 18+, bounce on older
    @ViewBuilder
    func adaptiveSymbolEffect(isActive: Bool = true) -> some View {
        if #available(macOS 15, iOS 18, *) {
            self.symbolEffect(.wiggle, isActive: isActive)
        } else {
            self
        }
    }
}

extension View {
    @ViewBuilder
    func resizableSheet() -> some View {
        if #available(macOS 15, iOS 18, *) {
            self.presentationSizing(.fitted)
        } else {
            self
        }
    }
}

/// MeshGradient on macOS 15+ / iOS 18+, LinearGradient fallback — for icon foreground styles
enum AdaptiveGradients {
    @ViewBuilder
    static func iconGradient(colors: [Color] = [.blue, .purple]) -> some View {
        if #available(macOS 15, iOS 18, *) {
            MeshGradient(width: 2, height: 2, points: [
                .init(0, 0), .init(1, 0),
                .init(0, 1), .init(1, 1)
            ], colors: [
                colors[0 % colors.count],
                colors[1 % colors.count],
                colors[1 % colors.count].opacity(0.7),
                colors[0 % colors.count].opacity(0.8)
            ])
        } else {
            LinearGradient(
                colors: colors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

extension View {
    /// Adaptive foreground gradient: MeshGradient on macOS 15+, LinearGradient on older
    @ViewBuilder
    func adaptiveIconGradient(colors: [Color] = [.blue, .purple]) -> some View {
        if #available(macOS 15, iOS 18, *) {
            self.foregroundStyle(
                MeshGradient(width: 2, height: 2, points: [
                    .init(0, 0), .init(1, 0),
                    .init(0, 1), .init(1, 1)
                ], colors: [
                    colors[0 % colors.count],
                    colors[1 % colors.count],
                    colors[1 % colors.count].opacity(0.7),
                    colors[0 % colors.count].opacity(0.8)
                ])
            )
        } else {
            self.foregroundStyle(
                .linearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        }
    }
}

// MARK: - Launch Animation

struct LaunchAnimationView: View {
    @State private var iconScale: CGFloat = 0.3
    @State private var iconOpacity: Double = 0
    @State private var titleOpacity: Double = 0
    @State private var subtitleOpacity: Double = 0
    @State private var ringScale: CGFloat = 0.5
    @State private var ringOpacity: Double = 0
    @State private var dismissOpacity: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var onComplete: () -> Void

    var body: some View {
        ZStack {
            AppColors.backgroundPrimary.ignoresSafeArea()

            VStack(spacing: Spacing.medium) {
                ZStack {
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [.blue.opacity(0.4), .purple.opacity(0.2), .clear],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            lineWidth: 2
                        )
                        .frame(width: 140, height: 140)
                        .scaleEffect(ringScale)
                        .opacity(ringOpacity)

                    PlatformApp.appIconImage
                        .resizable()
                        .scaledToFit()
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .shadow(color: .blue.opacity(0.3), radius: 20, y: 8)
                        .scaleEffect(iconScale)
                        .opacity(iconOpacity)
                }

                Text("mailin")
                    .font(.system(.title, design: .rounded))
                    .fontWeight(.bold)
                    .opacity(titleOpacity)

                Text("Email Archive Analyzer")
                    .font(Typography.subheadline)
                    .foregroundColor(AppColors.secondary)
                    .opacity(subtitleOpacity)
            }
        }
        .opacity(dismissOpacity)
        .onAppear {
            if reduceMotion {
                onComplete()
                return
            }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                iconScale = 1.0
                iconOpacity = 1
                ringScale = 1.0
                ringOpacity = 1
            }
            withAnimation(.easeOut(duration: 0.4).delay(0.3)) {
                titleOpacity = 1
            }
            withAnimation(.easeOut(duration: 0.4).delay(0.5)) {
                subtitleOpacity = 1
            }
            withAnimation(.easeOut(duration: 0.3).delay(1.2)) {
                ringOpacity = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                withAnimation(.easeInOut(duration: 0.4)) {
                    dismissOpacity = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    onComplete()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("mailin is loading")
    }
}

// MARK: - Liquid Glass Navigation Helpers

extension View {
    @ViewBuilder
    func liquidGlassToolbar() -> some View {
        if #available(macOS 26, iOS 26, *) {
            self.toolbarBackgroundVisibility(.hidden, for: .automatic)
        } else {
            self
        }
    }

    @ViewBuilder
    func liquidGlassSidebar() -> some View {
        if #available(macOS 26, iOS 26, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: 0))
        } else {
            self.background(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    func liquidGlassTabBar() -> some View {
        #if os(iOS)
        if #available(iOS 26, *) {
            self.toolbarBackgroundVisibility(.hidden, for: .tabBar)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

// MARK: - visionOS Adaptations

extension View {
    @ViewBuilder
    func adaptiveDepth() -> some View {
        #if os(visionOS)
        self.hoverEffect(.highlight)
        #else
        self
        #endif
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
                .font(.largeTitle)
                .foregroundStyle(
                    .linearGradient(
                        colors: [AppColors.primary.opacity(0.5), AppColors.primary.opacity(0.2)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(spacing: Spacing.xSmall) {
                Text(title)
                    .font(.system(.headline, design: .rounded))
                    .fontWeight(.semibold)

                Text(message)
                    .font(.footnote)
                    .foregroundColor(AppColors.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(Spacing.xLarge)
        .adaptiveHeroBackground(colors: [AppColors.primary, .purple, .indigo, .teal])
    }
}

/// Apple-style loading indicator (adaptive glass on macOS 26+)
struct LoadingView: View {
    let message: String

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
        .adaptiveCard(cornerRadius: CornerRadius.large)
    }
}

// MARK: - Contact Avatar
struct ContactAvatar: View {
    let name: String
    var size: CGFloat = 30

    private var initials: String {
        let parts = name.split(separator: " ").filter { !$0.isEmpty }
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private var gradientColors: [Color] {
        let hash = abs(name.hashValue)
        let palettes: [[Color]] = [
            [.blue, .purple],
            [.green, .teal],
            [.orange, .pink],
            [.indigo, .blue],
            [.purple, .pink],
            [.teal, .cyan],
            [.red, .orange],
            [.mint, .green],
        ]
        return palettes[hash % palettes.count]
    }

    var body: some View {
        ZStack {
            if #available(macOS 15, iOS 18, *) {
                Circle()
                    .fill(
                        MeshGradient(width: 2, height: 2, points: [
                            .init(0, 0), .init(1, 0),
                            .init(0, 1), .init(1, 1)
                        ], colors: [
                            gradientColors[0], gradientColors[1],
                            gradientColors[1].opacity(0.8), gradientColors[0].opacity(0.9)
                        ])
                    )
            } else {
                Circle()
                    .fill(LinearGradient(colors: gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            Text(initials)
                .font(.system(.caption, design: .rounded))
                .fontWeight(.semibold)
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Liquid Glass GroupBox Style

@available(macOS 26, iOS 26, *)
struct LiquidGlassGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            configuration.label
                .font(Typography.subheadline)
                .fontWeight(.semibold)
            configuration.content
        }
        .padding(Spacing.medium)
        .glassEffect(.regular, in: .rect(cornerRadius: CornerRadius.large))
    }
}

// MARK: - Adaptive GroupBox Extension

extension View {
    @ViewBuilder
    func adaptiveGroupBoxStyle() -> some View {
        if #available(macOS 26, iOS 26, *) {
            self.groupBoxStyle(LiquidGlassGroupBoxStyle())
        } else {
            self
        }
    }
}

// MARK: - Glass Badge Modifier

struct GlassBadgeModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, iOS 26, *) {
            content
                .font(Typography.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, Spacing.xSmall)
                .padding(.vertical, Spacing.xxxSmall)
                .glassEffect(.regular, in: .capsule)
        } else {
            content
                .font(Typography.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, Spacing.xSmall)
                .padding(.vertical, Spacing.xxxSmall)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }
}

extension View {
    func glassBadge() -> some View {
        modifier(GlassBadgeModifier())
    }
}

// MARK: - Glass Status Indicator

struct GlassStatusIndicator: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: Spacing.xxSmall) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(Typography.caption2)
                .foregroundColor(AppColors.secondary)
        }
        .glassBadge()
    }
}

// MARK: - Glass Segmented Picker

struct GlassSegmentedPicker<SelectionValue: Hashable, Content: View>: View {
    @Binding var selection: SelectionValue
    let content: Content

    init(selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self._selection = selection
        self.content = content()
    }

    var body: some View {
        Picker("", selection: $selection) {
            content
        }
        .pickerStyle(.segmented)
        .if(isLiquidGlassAvailable) { view in
            view.padding(Spacing.xxSmall)
        }
    }

    private var isLiquidGlassAvailable: Bool {
        if #available(macOS 26, iOS 26, *) { return true }
        return false
    }
}

// MARK: - Glass Info Banner

struct GlassInfoBanner: View {
    let icon: String
    let message: String
    let style: BannerStyle
    var onDismiss: (() -> Void)?

    enum BannerStyle {
        case info, success, warning, error

        var color: Color {
            switch self {
            case .info: return AppColors.info
            case .success: return AppColors.success
            case .warning: return AppColors.warning
            case .error: return AppColors.error
            }
        }
    }

    var body: some View {
        HStack(spacing: Spacing.xSmall) {
            Image(systemName: icon)
                .foregroundColor(style.color)
            Text(message)
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
            Spacer()
            if let onDismiss {
                Button { onDismiss() } label: {
                    Image(systemName: "xmark")
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Spacing.small)
        .adaptiveCard(cornerRadius: CornerRadius.medium)
    }
}

// MARK: - Glass Progress Indicator

struct GlassProgressView: View {
    let progress: Double
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            HStack {
                Text(label)
                    .font(Typography.caption1)
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(Typography.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(AppColors.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppColors.separator.opacity(0.3))
                    Capsule()
                        .fill(AppColors.primary)
                        .frame(width: geo.size.width * min(max(progress, 0), 1))
                        .animation(AnimationTiming.spring, value: progress)
                }
            }
            .frame(height: 6)
            .clipShape(Capsule())
        }
    }
}

// MARK: - Animated Stat Card

struct AnimatedStatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Spacing.xSmall) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
                .scaleEffect(appeared ? 1 : 0.5)
                .opacity(appeared ? 1 : 0)
            Text(value)
                .font(Typography.title2)
                .fontWeight(.bold)
                .opacity(appeared ? 1 : 0)
            Text(title)
                .font(Typography.caption1)
                .foregroundColor(AppColors.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.medium)
        .adaptiveCard(cornerRadius: CornerRadius.large)
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(AnimationTiming.springBouncy.delay(0.1)) {
                    appeared = true
                }
            }
        }
    }
}

// MARK: - Floating Action Button

struct FloatingActionButton: View {
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .frame(width: 56, height: 56)
        }
        .buttonStyle(AdaptiveProminentButtonStyle())
        .shadow(color: AppColors.primary.opacity(0.3), radius: 8, y: 4)
    }
}

// MARK: - Page Transition Modifier

struct PageTransitionModifier: ViewModifier {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isActive ? 1 : 0)
            .offset(y: isActive ? 0 : (reduceMotion ? 0 : 20))
            .animation(reduceMotion ? nil : AnimationTiming.spring, value: isActive)
    }
}

extension View {
    func pageTransition(isActive: Bool) -> some View {
        modifier(PageTransitionModifier(isActive: isActive))
    }
}

// MARK: - Modern Date Field

/// Modern date picker: a compact chip (calendar glyph + formatted date) that
/// opens the graphical month-grid calendar in a popover on macOS — replacing
/// the legacy stepper-field picker and its cramped drop-down. One click to
/// open, one click to pick (minimum-touch). On iOS the system compact picker
/// already presents the modern calendar, so it is used as-is.
struct ModernDateField: View {
    let label: String
    @Binding var date: Date

    #if os(macOS)
    @State private var showPicker = false
    #endif

    var body: some View {
        #if os(macOS)
        Button {
            showPicker = true
        } label: {
            HStack(spacing: Spacing.xxSmall) {
                Image(systemName: "calendar")
                    .foregroundColor(AppColors.primary)
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .foregroundColor(.primary)
            }
            .font(Typography.caption1)
            .padding(.horizontal, Spacing.xSmall)
            .padding(.vertical, Spacing.xxSmall)
            .background(AppColors.secondary.opacity(0.08))
            .cornerRadius(CornerRadius.small)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            VStack(spacing: Spacing.xSmall) {
                DatePicker(label, selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                HStack {
                    Button("Today") { date = Calendar.current.startOfDay(for: Date()) }
                        .font(Typography.caption1)
                        .help("Jump to today")
                    Spacer()
                    Button("Done") { showPicker = false }
                        .font(Typography.caption1)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(Spacing.small)
            .frame(width: 280)
        }
        #else
        DatePicker(label, selection: $date, displayedComponents: .date)
            .labelsHidden()
            .accessibilityLabel(label)
        #endif
    }
}

#Preview("Modern Date Field") {
    struct Demo: View {
        @State private var start = Date(timeIntervalSince1970: 1_693_600_000)
        @State private var end = Date(timeIntervalSince1970: 1_762_200_000)
        var body: some View {
            HStack(spacing: Spacing.xSmall) {
                ModernDateField(label: "Start date filter", date: $start)
                Text("–").font(Typography.caption1).foregroundColor(AppColors.secondary)
                ModernDateField(label: "End date filter", date: $end)
            }
            .padding()
        }
    }
    return Demo()
}
