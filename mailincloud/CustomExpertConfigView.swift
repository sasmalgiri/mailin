import SwiftUI

// MARK: - Custom Expert Configuration View (v3.5.1)

struct CustomExpertConfigView: View {
    @ObservedObject var manager = CustomExpertManager.shared
    @State private var showingAddSheet = false
    @State private var editingExpert: CustomExpert?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            if manager.experts.isEmpty {
                emptyState
            } else {
                expertList
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .sheet(isPresented: $showingAddSheet) {
            ExpertEditSheet(onSave: { expert in
                manager.addExpert(expert)
            })
        }
        .sheet(item: $editingExpert) { expert in
            ExpertEditSheet(existing: expert, onSave: { updated in
                manager.updateExpert(updated)
            })
        }
    }

    private var headerBar: some View {
        HStack {
            Label("Custom Experts", systemImage: "brain")
                .font(.headline)
            Spacer()
            Text("\(manager.experts.count) expert\(manager.experts.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                showingAddSheet = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add custom expert")
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "brain.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No Custom Experts")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Create custom AI experts with specialized instructions and keywords to analyze your emails.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Button("Create Expert") {
                showingAddSheet = true
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var expertList: some View {
        List {
            ForEach(manager.experts) { expert in
                ExpertRow(expert: expert, onToggle: {
                    var updated = expert
                    updated.enabled.toggle()
                    manager.updateExpert(updated)
                }, onEdit: {
                    editingExpert = expert
                }, onDelete: {
                    manager.deleteExpert(id: expert.id)
                })
            }
        }
        .listStyle(.inset)
    }
}

// MARK: - Expert Row

private struct ExpertRow: View {
    let expert: CustomExpert
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { expert.enabled },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(expert.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(expert.enabled ? .primary : .secondary)
                Text(expert.keywords.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                onEdit()
            } label: {
                Image(systemName: "pencil")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Edit expert")

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
            .help("Delete expert")
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Expert Edit Sheet

private struct ExpertEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var instructions: String
    @State private var keywordsText: String
    @State private var enabled: Bool

    private let existingID: UUID?
    private let onSave: (CustomExpert) -> Void

    init(existing: CustomExpert? = nil, onSave: @escaping (CustomExpert) -> Void) {
        self.existingID = existing?.id
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _instructions = State(initialValue: existing?.instructions ?? "")
        _keywordsText = State(initialValue: existing?.keywords.joined(separator: ", ") ?? "")
        _enabled = State(initialValue: existing?.enabled ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existingID == nil ? "New Custom Expert" : "Edit Expert")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption.weight(.medium))
                TextField("e.g., Legal Compliance", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Instructions").font(.caption.weight(.medium))
                TextEditor(text: $instructions)
                    .font(.body)
                    .frame(minHeight: 80)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3))
                    )
                Text("Tell the AI expert what to focus on and how to analyze emails.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Keywords (comma-separated)").font(.caption.weight(.medium))
                TextField("e.g., compliance, regulation, GDPR, legal, contract", text: $keywordsText)
                    .textFieldStyle(.roundedBorder)
                Text("Used to match queries to this expert via semantic similarity.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Toggle("Enabled", isOn: $enabled)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    let keywords = keywordsText
                        .components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    var expert = CustomExpert(name: name, instructions: instructions, keywords: keywords, enabled: enabled)
                    if let existingID {
                        expert.id = existingID
                    }
                    onSave(expert)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || instructions.isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
    }
}
