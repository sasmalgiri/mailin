//
//  PIIReportView.swift
//  maxmailin
//
//  Personally Identifiable Information report over the CURRENT filter:
//  every detected email address, phone number, SSN/credit-card pattern,
//  IP, passport, DOB, driver's license and IBAN — grouped by type with
//  risk scores, the source email named for each hit, and a CSV export.
//  Detection is EmailNLPEngine.detectPII (regex + Luhn/IP validation),
//  100% on-device. Scans a bounded working set (cap 2,000) and says so.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct PIIReportView: View {
    var query: EmailQuery = .all
    /// When set (e.g. from the e-discovery workflow, which already holds its
    /// collection), scan these emails instead of loading from the query.
    var presetEmails: [MBOXParser.RawEmail]? = nil
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var findings: [EmailNLPEngine.PIIFinding] = []
    @State private var scannedCount = 0
    @State private var isScanning = true
    @State private var truncated = false
    @State private var exportError: String?

    static let scanCap = 2_000

    private var grouped: [(type: EmailNLPEngine.PIIType, items: [EmailNLPEngine.PIIFinding])] {
        Dictionary(grouping: findings, by: { $0.type })
            .sorted { $0.key.baseRisk > $1.key.baseRisk }
            .map { (type: $0.key, items: $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                    Label("PII Report", systemImage: "person.text.rectangle")
                        .font(Typography.title2)
                    Text(isScanning
                         ? "Scanning for personally identifiable information…"
                         : "\(findings.count) finding(s) in \(scannedCount) email(s) — detected on-device, nothing leaves this Mac")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }
                Spacer()
                if !findings.isEmpty {
                    Button {
                        exportCSV()
                    } label: {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                    }
                    .help("Save every finding (type, value, risk, source email) as a spreadsheet")
                }
                Button { if let onClose { onClose() } else { dismiss() } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColors.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .help("Close the PII report")
                .accessibilityLabel("Close PII report")
            }
            .padding(Spacing.medium)
            Divider()

            if isScanning {
                Spacer()
                HStack { Spacer(); ProgressView("Scanning…"); Spacer() }
                Spacer()
            } else if findings.isEmpty {
                Spacer()
                VStack(spacing: Spacing.small) {
                    Image(systemName: "checkmark.shield")
                        .font(.largeTitle).foregroundColor(.green)
                    Text("No personally identifiable information detected in the \(scannedCount) scanned email(s).")
                        .font(Typography.callout)
                        .foregroundColor(AppColors.secondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    if truncated {
                        Label("Large filter — the first \(Self.scanCap) emails were scanned. Narrow the filter to cover the rest.",
                              systemImage: "info.circle")
                            .font(Typography.caption1)
                            .foregroundColor(.orange)
                    }
                    ForEach(grouped, id: \.type) { group in
                        Section {
                            ForEach(group.items.prefix(200)) { finding in
                                HStack(alignment: .top) {
                                    Text(finding.value)
                                        .font(Typography.monoBody)
                                        .textSelection(.enabled)
                                    Spacer()
                                    Text(finding.emailSubject)
                                        .font(Typography.caption2)
                                        .foregroundColor(AppColors.secondary)
                                        .lineLimit(1)
                                        .frame(maxWidth: 220, alignment: .trailing)
                                }
                                .help("Found in “\(finding.emailSubject)” — risk \(String(format: "%.0f", finding.contextualRiskScore))/10")
                            }
                            if group.items.count > 200 {
                                Text("… and \(group.items.count - 200) more — use Export CSV for the complete list")
                                    .font(Typography.caption2)
                                    .foregroundColor(AppColors.secondary)
                            }
                        } header: {
                            HStack {
                                Text("\(group.type.rawValue)")
                                    .font(Typography.subheadline).fontWeight(.semibold)
                                Text("\(group.items.count)")
                                    .font(Typography.caption1)
                                    .foregroundColor(AppColors.secondary)
                                Spacer()
                                Text("risk \(String(format: "%.0f", group.type.baseRisk))/10")
                                    .font(Typography.caption2)
                                    .foregroundColor(group.type.baseRisk >= 7 ? .red : (group.type.baseRisk >= 4 ? .orange : AppColors.secondary))
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 400)
        .task { await scan() }
        .alert("PII Export Failed", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private func scan() async {
        let emails: [MBOXParser.RawEmail]
        if let preset = presetEmails {
            emails = Array(preset.prefix(Self.scanCap))
        } else {
            emails = await ArchiveDataService.shared.workingSet(query: query, cap: Self.scanCap)
        }
        scannedCount = emails.count
        truncated = emails.count >= Self.scanCap
        let detected = await Task.detached(priority: .userInitiated) {
            EmailNLPEngine.detectPII(in: emails)
        }.value
        findings = detected
        isScanning = false
    }

    private func exportCSV() {
        func esc(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var csv = "Type,Value,Risk,Context,Email Subject,Email ID\n"
        for finding in findings {
            csv += [finding.type.rawValue, finding.value,
                    String(format: "%.1f", finding.contextualRiskScore),
                    finding.riskContext.rawValue, finding.emailSubject,
                    finding.emailID.uuidString].map(esc).joined(separator: ",") + "\n"
        }
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "mailin_pii_report.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try csv.write(to: url, atomically: true, encoding: .utf8) }
        catch { exportError = error.localizedDescription }
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mailin_pii_report.csv")
        try? csv.write(to: url, atomically: true, encoding: .utf8)
        #endif
    }
}
