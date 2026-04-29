//
//  AboutView.swift
//  mailin
//
//  Professional About window following Apple design standards
//

import SwiftUI

struct AboutView: View {
    @Environment(\.openURL) private var openURL
    
    var body: some View {
        VStack(spacing: 0) {
            // App Icon & Info
            VStack(spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 128, height: 128)
                    .shadow(radius: 10)
                
                VStack(spacing: 4) {
                    Text("mailin")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    
                    Text("Email Archive Analyzer")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                   let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                    Text("Version \(version) (\(build))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, 40)
            .padding(.bottom, 30)
            
            Divider()
            
            // Features
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    featureRow(
                        icon: "envelope.open.fill",
                        title: "Advanced Parsing",
                        description: "RFC822 & MIME compliant email parser"
                    )
                    
                    featureRow(
                        icon: "chart.line.uptrend.xyaxis",
                        title: "Reply Analytics",
                        description: "Track communication patterns and frequency"
                    )
                    
                    featureRow(
                        icon: "brain.head.profile",
                        title: "AI Assistant",
                        description: "Natural language email analysis"
                    )
                    
                    featureRow(
                        icon: "shield.checkered",
                        title: "Privacy First",
                        description: "All processing happens locally on your device"
                    )
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            
            Divider()
            
            // Footer
            VStack(spacing: 12) {
                Button("Contact Support") {
                    openURL(URL(string: "mailto:sasmalgiri@gmail.com")!)
                }
                .buttonStyle(.link)

                Text("© 2025 mailin. All rights reserved.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 20)
        }
        .frame(width: 400, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - Feature Row
    private func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview {
    AboutView()
}
