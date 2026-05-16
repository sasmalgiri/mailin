import SwiftUI

struct GuidedSearchView: View {
    @Binding var searchText: String
    @Binding var isPresented: Bool
    var onSearch: () -> Void

    @State private var whoFrom = ""
    @State private var whoTo = ""
    @State private var aboutWhat = ""
    @State private var afterDate: Date?
    @State private var beforeDate: Date?
    @State private var hasAttachments = false
    @State private var showAfterPicker = false
    @State private var showBeforePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Find Emails", systemImage: "magnifyingglass")
                    .font(.headline)
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            }

            Text("Answer any of these questions — leave blank to skip.")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                fieldRow(icon: "person", label: "Who sent it?", placeholder: "e.g. john, mom, boss@company.com", text: $whoFrom)
                fieldRow(icon: "person.2", label: "Who was it sent to?", placeholder: "e.g. me, team, jane@work.com", text: $whoTo)
                fieldRow(icon: "text.quote", label: "What was it about?", placeholder: "e.g. vacation photos, invoice, contract", text: $aboutWhat)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("After")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if let date = afterDate {
                            HStack {
                                Text(date, style: .date)
                                    .font(.callout)
                                Button { afterDate = nil } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                            }
                        } else {
                            Button("Set date...") { showAfterPicker = true }
                                .font(.callout)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Before")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if let date = beforeDate {
                            HStack {
                                Text(date, style: .date)
                                    .font(.callout)
                                Button { beforeDate = nil } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                            }
                        } else {
                            Button("Set date...") { showBeforePicker = true }
                                .font(.callout)
                        }
                    }
                }
                .popover(isPresented: $showAfterPicker) {
                    DatePicker("After", selection: Binding(get: { afterDate ?? Date() }, set: { afterDate = $0; showAfterPicker = false }), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .padding()
                }
                .popover(isPresented: $showBeforePicker) {
                    DatePicker("Before", selection: Binding(get: { beforeDate ?? Date() }, set: { beforeDate = $0; showBeforePicker = false }), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .padding()
                }

                Toggle("Has attachments", isOn: $hasAttachments)
                    .toggleStyle(.switch)
            }

            Divider()

            HStack {
                if !buildQuery().isEmpty {
                    Text("Search: \(buildQuery())")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Clear") { clearAll() }
                    .buttonStyle(.bordered)
                Button("Search") {
                    searchText = buildQuery()
                    onSearch()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(buildQuery().isEmpty)
            }
        }
        .padding()
        #if os(macOS)
        .frame(width: 420)
        #endif
    }

    private func fieldRow(icon: String, label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: icon)
                .font(.caption)
                .foregroundColor(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func buildQuery() -> String {
        var parts: [String] = []
        if !whoFrom.isEmpty { parts.append("from:\(whoFrom.trimmingCharacters(in: .whitespaces))") }
        if !whoTo.isEmpty { parts.append("to:\(whoTo.trimmingCharacters(in: .whitespaces))") }
        if !aboutWhat.isEmpty { parts.append("subject:\(aboutWhat.trimmingCharacters(in: .whitespaces))") }
        if hasAttachments { parts.append("has:attachment") }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        if let after = afterDate { parts.append("after:\(formatter.string(from: after))") }
        if let before = beforeDate { parts.append("before:\(formatter.string(from: before))") }

        return parts.joined(separator: " ")
    }

    private func clearAll() {
        whoFrom = ""
        whoTo = ""
        aboutWhat = ""
        afterDate = nil
        beforeDate = nil
        hasAttachments = false
    }
}
