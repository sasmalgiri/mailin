import SwiftUI

struct GDPRReportConfigView: View {
    let emails: [MBOXParser.RawEmail]
    @State private var dataSubject = ""
    @State private var isGenerating = false
    @State private var generationError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "lock.shield.fill")
                    .foregroundColor(AppColors.primary)
                Text("GDPR Compliance Report")
                    .font(Typography.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppColors.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
            }
            .padding(Spacing.medium)

            Divider()

            VStack(alignment: .leading, spacing: Spacing.medium) {
                VStack(alignment: .leading, spacing: Spacing.xSmall) {
                    Text("Data Subject")
                        .font(Typography.callout)
                        .fontWeight(.semibold)
                    Text("Enter the email address or name of the person to generate a GDPR data protection report for.")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                    TextField("Email address or name", text: $dataSubject)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(AppColors.info)
                    Text("The report will identify all emails containing the data subject's information, inventory PII, analyze data flows, and provide GDPR compliance recommendations.")
                        .font(Typography.caption1)
                        .foregroundColor(AppColors.secondary)
                }

                if let error = generationError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(AppColors.error)
                        Text(error)
                            .font(Typography.caption1)
                            .foregroundColor(AppColors.error)
                    }
                }

                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .buttonStyle(SecondaryButtonStyle())

                    Button {
                        generateReport()
                    } label: {
                        HStack(spacing: Spacing.xSmall) {
                            if isGenerating {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 16, height: 16)
                            }
                            Text(isGenerating ? "Generating..." : "Generate GDPR Report")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(dataSubject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating)
                }
            }
            .padding(Spacing.medium)

            Spacer()
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 350)
        #endif
    }

    private func generateReport() {
        isGenerating = true
        generationError = nil
        let subject = dataSubject.trimmingCharacters(in: .whitespacesAndNewlines)

        Task.detached(priority: .userInitiated) {
            let pdfData = await GDPRComplianceReport.generate(emails: emails, dataSubject: subject)

            await MainActor.run {
                isGenerating = false

                guard !pdfData.isEmpty else {
                    generationError = "Failed to generate PDF report."
                    return
                }

                let fileName = "GDPR_Report_\(subject.replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression)).pdf"

                #if os(macOS)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = fileName
                panel.canCreateDirectories = true
                panel.allowedContentTypes = [.pdf]
                panel.begin { result in
                    if result == .OK, let url = panel.url {
                        do {
                            try pdfData.write(to: url, options: .atomic)
                            dismiss()
                        } catch {
                            generationError = "Failed to save: \(error.localizedDescription)"
                        }
                    }
                }
                #else
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                do {
                    try pdfData.write(to: url, options: .atomic)
                    dismiss()
                } catch {
                    generationError = "Failed to save: \(error.localizedDescription)"
                }
                #endif
            }
        }
    }
}
