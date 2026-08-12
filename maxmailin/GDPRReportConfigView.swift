import SwiftUI
import UniformTypeIdentifiers

struct GDPRReportConfigView: View {
    let emails: [MBOXParser.RawEmail]
    var isPresented: Binding<Bool>?
    @Environment(\.dismiss) private var envDismiss
    @State private var dataSubject = ""
    @State private var isGenerating = false
    @State private var generationError: String?
    @State private var showTutorial = false
    @State private var generatedPDFData: Data?
    @State private var showFileExporter = false
    @State private var savedSuccessfully = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "lock.shield.fill")
                    .foregroundColor(AppColors.primary)
                Text("GDPR Compliance Report")
                    .font(Typography.headline)
                Spacer()
                TutorialHelpButton(showTutorial: $showTutorial)
                Button { closeSheet() } label: {
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

                if savedSuccessfully {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Report saved successfully.")
                            .font(Typography.caption1)
                            .foregroundColor(.green)
                    }
                } else if generatedPDFData != nil {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Report generated successfully. Click Save PDF to save.")
                            .font(Typography.caption1)
                            .foregroundColor(.green)
                    }
                }

                HStack {
                    Spacer()
                    if savedSuccessfully {
                        Button("Done") { closeSheet() }
                            .buttonStyle(PrimaryButtonStyle())
                    } else {
                        Button("Cancel") { closeSheet() }
                            .buttonStyle(SecondaryButtonStyle())

                        if generatedPDFData != nil {
                            Button {
                                showFileExporter = true
                            } label: {
                                HStack(spacing: Spacing.xSmall) {
                                    Image(systemName: "square.and.arrow.down")
                                    Text("Save PDF")
                                }
                            }
                            .buttonStyle(PrimaryButtonStyle())
                        } else {
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
                            .keyboardShortcut("r", modifiers: .command)
                            .disabled(dataSubject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating)
                        }
                    }
                }
            }
            .padding(Spacing.medium)

            Spacer()
        }
        .featureTutorial(.gdprCompliance, key: "gdpr_compliance_tutorial_seen", isPresented: $showTutorial)
        .fileExporter(
            isPresented: $showFileExporter,
            document: GDPRPDFExportFile(data: generatedPDFData),
            contentType: .pdf,
            defaultFilename: pdfFileName
        ) { result in
            switch result {
            case .success:
                generatedPDFData = nil
                savedSuccessfully = true
            case .failure(let error):
                generationError = "Failed to save: \(error.localizedDescription)"
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 350)
        #endif
    }

    private func closeSheet() {
        if let isPresented {
            isPresented.wrappedValue = false
        } else {
            envDismiss()
        }
    }

    private var pdfFileName: String {
        let subject = dataSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        return "GDPR_Report_\(subject.replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression))"
    }

    private func generateReport() {
        let subject = dataSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        let subjectLower = subject.lowercased()

        let matchingEmails = emails.filter { email in
            let from = (email.headers["From"] ?? "").lowercased()
            let to = (email.headers["To"] ?? "").lowercased()
            let cc = (email.headers["Cc"] ?? "").lowercased()
            let body = email.plainBody.lowercased()
            return from.contains(subjectLower) || to.contains(subjectLower) ||
                   cc.contains(subjectLower) || body.contains(subjectLower)
        }

        guard !matchingEmails.isEmpty else {
            generationError = "No emails found mentioning \"\(subject)\". Enter a name or email address that appears in your archive."
            return
        }

        isGenerating = true
        generationError = nil

        Task.detached(priority: .userInitiated) {
            let pdfData = await GDPRComplianceReport.generate(emails: emails, dataSubject: subject)

            await MainActor.run {
                isGenerating = false

                guard !pdfData.isEmpty else {
                    generationError = "Failed to generate PDF report."
                    return
                }

                generatedPDFData = pdfData
                // Record a numbered document of this compliance report.
                let bytes = pdfData.count
                let body = "GDPR / COMPLIANCE REPORT\nGenerated: \(Date().formatted(date: .abbreviated, time: .shortened))\nPDF size: \(bytes) bytes"
                Task { await DocumentRegistry.captureStructured(.report,
                    summary: "GDPR compliance report",
                    document: CapturedDocument(title: "GDPR Compliance Report", sections: [
                      .init(name: "GDPR Report", fields: [.init(key: "PDF size (bytes)", value: "\(bytes)")])])) }
            }
        }
    }
}

struct GDPRPDFExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }

    let data: Data

    init?(data: Data?) {
        guard let data, !data.isEmpty else { return nil }
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
