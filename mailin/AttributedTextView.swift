//
//  AttributedTextView.swift
//  mailin
//
//  Created by administrator on 23/07/2025.
//


import SwiftUI

#if os(macOS)
import AppKit

struct AttributedTextView: NSViewRepresentable {
    let attributedText: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textStorage?.setAttributedString(attributedText)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = textView
        scrollView.autohidesScrollers = true

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let textView = nsView.documentView as? NSTextView {
            textView.textStorage?.setAttributedString(attributedText)
            textView.needsDisplay = true
        }
    }
}

#else
import UIKit

struct AttributedTextView: UIViewRepresentable {
    let attributedText: NSAttributedString

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isScrollEnabled = true
        tv.backgroundColor = .clear
        tv.attributedText = attributedText
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.attributedText = attributedText
    }
}
#endif
