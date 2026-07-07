//
//  GettingStartedView.swift
//  mailin
//
//  Brief first-run tour for new Personal users — 3 screens covering Import,
//  Review, and Insights. Shown automatically once, dismissable any time.
//

import SwiftUI

struct GettingStartedView: View {
    @Binding var isPresented: Bool
    @AppStorage("hasSeenGettingStarted") private var hasSeen: Bool = false

    @State private var index: Int = 0

    private let pages: [TourPage] = [
        TourPage(
            icon: "tray.and.arrow.down",
            title: "1. Import your emails",
            body: "Open an .mbox, .eml, .pst, or other email archive from Files. Everything stays on this device — nothing is uploaded.",
            tint: .blue
        ),
        TourPage(
            icon: "magnifyingglass",
            title: "2. Search and read",
            body: "Use the search bar to filter by sender, subject, or words inside the message. Tap an email to read the full thread and view attachments.",
            tint: .indigo
        ),
        TourPage(
            icon: "chart.bar.fill",
            title: "3. Get insights (optional)",
            body: "When you're ready, switch to a power workspace from the home picker — Forensic, Legal, IT, or Journalist — to unlock analytics, AI, and reports.",
            tint: .purple
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Page content
            TabView(selection: $index) {
                ForEach(Array(pages.enumerated()), id: \.offset) { idx, page in
                    pageView(page).tag(idx)
                }
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .always))
            #endif

            // Bottom bar
            HStack {
                Button("Skip") {
                    hasSeen = true
                    isPresented = false
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Spacer()

                // Page dots (macOS — TabView's PageTabViewStyle isn't available)
                #if os(macOS)
                HStack(spacing: 6) {
                    ForEach(0..<pages.count, id: \.self) { i in
                        Circle()
                            .fill(i == index ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }
                Spacer()
                #endif

                Button(index == pages.count - 1 ? "Get Started" : "Next") {
                    if index == pages.count - 1 {
                        hasSeen = true
                        isPresented = false
                    } else {
                        withAnimation { index += 1 }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 420, minHeight: 460)
    }

    @ViewBuilder
    private func pageView(_ page: TourPage) -> some View {
        VStack(spacing: 20) {
            Spacer(minLength: 24)

            ZStack {
                Circle()
                    .fill(page.tint.opacity(0.12))
                    .frame(width: 110, height: 110)
                Image(systemName: page.icon)
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(page.tint)
            }
            .accessibilityHidden(true)

            Text(page.title)
                .font(.system(.title2, design: .rounded))
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            Text(page.body)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(.horizontal)
    }

    private struct TourPage {
        let icon: String
        let title: String
        let body: String
        let tint: Color
    }
}

#Preview {
    GettingStartedView(isPresented: .constant(true))
}
