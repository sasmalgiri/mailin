//
//  IdentifierText.swift
//  maxmailin
//
//  Gate 1 walk 2026-11-18 (iOS 27): SwiftUI `Text` hyphenates when it wraps,
//  so a SHA-256 read "…c019e-" / "b5312…" and an address "carol@example.-com".
//  Someone copying a hash by eye from that gets it wrong. SwiftUI has no
//  hyphenation switch for `Text` (checked in the iOS 27 documentation: no
//  modifier, and `Text` ignores an AttributedString paragraph style), so
//  identifiers — hashes, digests, Message-IDs, addresses, paths — are drawn by
//  this one view: on iOS a selectable, non-editable `UITextView` whose
//  paragraph style turns hyphenation off (`hyphenationFactor = 0`,
//  `usesDefaultHyphenation = false`) and wraps by character — with word
//  wrapping iOS 27 still hyphenated "example.-com". A line is broken between
//  characters with no mark added, and the characters on screen are
//  exactly the value, so Copy returns the value. The Mac keeps `Text`
//  (selectable), which does not hyphenate there.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The paragraph and string an identifier is drawn with — no inserted
/// hyphens, no invisible characters: `.string` is always the value itself.
enum IdentifierFormatting {
    static func paragraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.hyphenationFactor = 0
        style.usesDefaultHyphenation = false
        // Character wrapping: iOS 27 still put a hyphen into "carol@example.-com"
        // with word wrapping and hyphenation off (simulator re-walk 2026-11-18);
        // a break between any two characters never adds one.
        style.lineBreakMode = .byCharWrapping
        style.lineBreakStrategy = []
        return style
    }

    #if canImport(UIKit)
    typealias PlatformFont = UIFont
    typealias PlatformColor = UIColor
    #else
    typealias PlatformFont = NSFont
    typealias PlatformColor = NSColor
    #endif

    static func attributedString(_ value: String, font: PlatformFont, color: PlatformColor) -> NSAttributedString {
        NSAttributedString(string: value, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle(),
        ])
    }
}

/// An identifier on screen: selectable, never hyphenated, copied exactly.
struct IdentifierText: View {
    enum Tone { case primary, secondary }

    let value: String
    var style: Font.TextStyle = .caption2
    var monospaced = true
    var tone: Tone = .secondary

    init(_ value: String, style: Font.TextStyle = .caption2, monospaced: Bool = true, tone: Tone = .secondary) {
        self.value = value
        self.style = style
        self.monospaced = monospaced
        self.tone = tone
    }

    var body: some View {
        #if os(iOS)
        IdentifierTextView(value: value, style: style, monospaced: monospaced, tone: tone)
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: value))
            .accessibilityAddTraits(.isStaticText)
        #else
        Text(verbatim: value)
            .font(monospaced ? .system(style, design: .monospaced) : .system(style))
            .foregroundStyle(tone == .primary ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        #endif
    }
}

#if os(iOS)
private struct IdentifierTextView: UIViewRepresentable {
    let value: String
    let style: Font.TextStyle
    let monospaced: Bool
    let tone: IdentifierText.Tone

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byCharWrapping
        view.dataDetectorTypes = []
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(context.environment.dynamicTypeSize))
        let text = IdentifierFormatting.attributedString(value, font: font(compatibleWith: traits),
                                                         color: tone == .primary ? .label : .secondaryLabel)
        if view.attributedText != text { view.attributedText = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let available = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? .greatestFiniteMagnitude
        let fit = uiView.sizeThatFits(CGSize(width: available, height: .greatestFiniteMagnitude))
        return CGSize(width: min(ceil(fit.width), available), height: ceil(fit.height))
    }

    private func font(compatibleWith traits: UITraitCollection) -> UIFont {
        let textStyle = Self.uiTextStyle(style)
        let base = UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traits)
        guard monospaced else { return base }
        return UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular)
    }

    static func uiTextStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
}

private extension UIContentSizeCategory {
    init(_ size: DynamicTypeSize) {
        switch size {
        case .xSmall: self = .extraSmall
        case .small: self = .small
        case .medium: self = .medium
        case .large: self = .large
        case .xLarge: self = .extraLarge
        case .xxLarge: self = .extraExtraLarge
        case .xxxLarge: self = .extraExtraExtraLarge
        case .accessibility1: self = .accessibilityMedium
        case .accessibility2: self = .accessibilityLarge
        case .accessibility3: self = .accessibilityExtraLarge
        case .accessibility4: self = .accessibilityExtraExtraLarge
        case .accessibility5: self = .accessibilityExtraExtraExtraLarge
        @unknown default: self = .large
        }
    }
}
#endif
