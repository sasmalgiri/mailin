@testable import ArchiveCore
//
//  AdvancedSearchView.swift
//  maxmailin
//
//  Five jobs FIND-04 (plan §5.3.3): the visual Advanced Search builder.
//  Three groups — Match all, Match any, Exclude — each a list of conditions
//  (field, how it matches, value) and attachment conditions (type, name and
//  text that must hold for ONE attachment). Empty rows have no effect; an
//  invalid value is shown in place and blocks Apply rather than running a
//  different query. The summary beneath is the same model that will run.
//  Cancel leaves the applied search untouched; the scope (sidebar folder,
//  source, date range) is shown and is not part of the groups.
//

import SwiftUI

struct AdvancedSearchView: View {
    /// The search currently applied; the builder starts from it.
    let applied: SearchSpec?
    /// What the sidebar and date scope currently limit the list to.
    let scopeDescription: String
    let onApply: (SearchSpec?) -> Void
    let onCancel: () -> Void

    @State private var spec: SearchSpec

    init(applied: SearchSpec?, scopeDescription: String, onApply: @escaping (SearchSpec?) -> Void, onCancel: @escaping () -> Void) {
        self.applied = applied
        self.scopeDescription = scopeDescription
        self.onApply = onApply
        self.onCancel = onCancel
        _spec = State(initialValue: Self.normalized(applied))
    }

    /// The builder's form of a spec: always the three groups in a fixed order,
    /// so the structure is visible. Adds only empty groups (no effect), so the
    /// spec that runs is the one that was applied (SEARCH-02 round-trip).
    static func normalized(_ applied: SearchSpec?) -> SearchSpec {
        var start = applied ?? SearchSpec()
        for kind in SearchGroup.Kind.allCases where !start.groups.contains(where: { $0.kind == kind }) {
            start.groups.append(SearchGroup(kind))
        }
        start.groups.sort { SearchGroup.Kind.allCases.firstIndex(of: $0.kind)! < SearchGroup.Kind.allCases.firstIndex(of: $1.kind)! }
        return start
    }

    private var problems: [SearchSpec.Problem] { spec.problems() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Advanced Search", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.headline)
                Spacer()
                Button { onCancel() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Close without changing the search"))
            }
            Label(String(localized: "Searching in: \(scopeDescription)"), systemImage: "scope")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("advancedSearch.scope")

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(spec.groups.indices, id: \.self) { g in
                        groupSection(g)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 460)

            Divider()
            Text(SearchSpecDescriber.summary(spec))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("advancedSearch.summary")
            ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                Label(SearchSpecDescriber.problemText(problem), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Clear conditions") { spec = SearchSpec(groups: SearchGroup.Kind.allCases.map { SearchGroup($0) }) }
                    .buttonStyle(.bordered)
                    .help("Removes every condition; the scope on the left stays")
                Spacer()
                Button("Cancel") { onCancel() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { onApply(spec.isEmpty ? nil : spec) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!problems.isEmpty)
                    .accessibilityIdentifier("advancedSearch.apply")
            }
        }
        .padding()
        #if os(macOS)
        .frame(width: 620)
        #endif
    }

    // MARK: Groups

    private func groupSection(_ g: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(groupTitle(spec.groups[g].kind))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Menu {
                    Button(String(localized: "Add condition")) {
                        spec.groups[g].conditions.append(SearchCondition(.anyText, .allWords, ""))
                    }
                    Button(String(localized: "Add attachment condition")) {
                        spec.groups[g].attachmentGroups.append(AttachmentConditionGroup())
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(String(localized: "Add to \(groupTitle(spec.groups[g].kind))"))
            }
            if spec.groups[g].isEmpty {
                Text(groupHint(spec.groups[g].kind))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ForEach(spec.groups[g].conditions.indices, id: \.self) { c in
                conditionRow(g, c)
            }
            ForEach(spec.groups[g].attachmentGroups.indices, id: \.self) { a in
                attachmentRow(g, a)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private func groupTitle(_ kind: SearchGroup.Kind) -> String {
        switch kind {
        case .all: return String(localized: "Match all of these")
        case .any: return String(localized: "Match any of these")
        case .exclude: return String(localized: "Exclude messages matching any of these")
        }
    }

    private func groupHint(_ kind: SearchGroup.Kind) -> String {
        switch kind {
        case .all: return String(localized: "Every condition here must hold. Empty: no effect.")
        case .any: return String(localized: "At least one condition here must hold. Empty: no effect.")
        case .exclude: return String(localized: "Messages matching any condition here are left out. Where the text is not indexed yet, they are counted as “may still match”. Empty: no effect.")
        }
    }

    // MARK: Rows

    private static let builderFields: [SearchCondition.Field] = [
        .anyText, .subject, .body, .sender, .recipient, .recipientTo, .recipientCc, .recipientBcc,
        .attachmentName, .hasAttachments, .dateOnOrAfter, .dateOnOrBefore, .tag, .messageType,
    ]

    private func matchOptions(for field: SearchCondition.Field) -> [SearchCondition.Match] {
        switch field {
        case .body, .anyText: return [.allWords, .anyWords, .phrase, .contains]
        case .subject: return [.contains, .phrase, .allWords, .anyWords, .equals]
        case .sender, .recipient, .recipientTo, .recipientCc, .recipientBcc: return [.contains, .equals]
        case .attachmentName, .tag: return [.contains]
        default: return [.equals]
        }
    }

    private func conditionRow(_ g: Int, _ c: Int) -> some View {
        let binding = $spec.groups[g].conditions[c]
        return HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { binding.wrappedValue.field },
                set: { field in
                    binding.wrappedValue.field = field
                    let options = matchOptions(for: field)
                    if !options.contains(binding.wrappedValue.match) { binding.wrappedValue.match = options[0] }
                    if field == .hasAttachments { binding.wrappedValue.value = "yes" }
                    if field == .dateOnOrAfter || field == .dateOnOrBefore {
                        binding.wrappedValue.timeZone = TimeZone.current.identifier
                        if SearchSpec.parseDay(binding.wrappedValue.value, timeZone: nil) == nil { binding.wrappedValue.value = Self.dayString(Date()) }
                    }
                })) {
                ForEach(Self.builderFields, id: \.self) { field in
                    Text(SearchSpecDescriber.fieldName(field)).tag(field)
                }
            }
            .labelsHidden()
            .frame(width: 190)

            let field = binding.wrappedValue.field
            switch field {
            case .hasAttachments:
                Picker("", selection: binding.value) {
                    Text("Yes").tag("yes")
                    Text("No").tag("no")
                }
                .labelsHidden()
                .frame(width: 100)
            case .dateOnOrAfter, .dateOnOrBefore:
                DatePicker("", selection: Binding(
                    get: { SearchSpec.parseDay(binding.wrappedValue.value, timeZone: binding.wrappedValue.timeZone)?.start ?? Date() },
                    set: { binding.wrappedValue.value = Self.dayString($0, zone: binding.wrappedValue.timeZone) }),
                    displayedComponents: .date)
                    .labelsHidden()
                Text(binding.wrappedValue.timeZone ?? TimeZone.current.identifier)
                    .font(.caption2).foregroundStyle(.secondary)
            case .messageType:
                Picker("", selection: binding.value) {
                    Text("Sent").tag("sent")
                    Text("Received").tag("received")
                }
                .labelsHidden()
                .frame(width: 120)
            default:
                let options = matchOptions(for: field)
                if options.count > 1 {
                    Picker("", selection: binding.match) {
                        ForEach(options, id: \.self) { Text(SearchSpecDescriber.matchName($0)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
                TextField(String(localized: "value"), text: binding.value)
                    .textFieldStyle(.roundedBorder)
            }
            Button { spec.groups[g].conditions.remove(at: c) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Remove this condition"))
        }
    }

    private static let typeChoices: [(label: String, value: String)] = [
        (String(localized: "any type"), ""), ("PDF", "PDF"), (String(localized: "Images"), "Images"),
        (String(localized: "Office documents"), "Office documents"), (String(localized: "Text"), "Text"),
        (String(localized: "Archives"), "Archives"), ("DOCX", "docx"), ("XLSX", "xlsx"), ("PPTX", "pptx"),
    ]

    private func attachmentRow(_ g: Int, _ a: Int) -> some View {
        let binding = $spec.groups[g].attachmentGroups[a]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(String(localized: "One attachment"), systemImage: "paperclip")
                    .font(.caption.weight(.medium))
                Picker("", selection: Binding(get: { binding.wrappedValue.type ?? "" }, set: { binding.wrappedValue.type = $0.isEmpty ? nil : $0 })) {
                    ForEach(Self.typeChoices, id: \.value) { Text($0.label).tag($0.value) }
                }
                .labelsHidden()
                .frame(width: 170)
                TextField(String(localized: "name contains"), text: Binding(get: { binding.wrappedValue.nameContains ?? "" }, set: { binding.wrappedValue.nameContains = $0 }))
                    .textFieldStyle(.roundedBorder)
                Spacer()
                Button { spec.groups[g].attachmentGroups.remove(at: a) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Remove this attachment condition"))
            }
            HStack(spacing: 8) {
                Text(String(localized: "its text"))
                    .font(.caption).foregroundStyle(.secondary)
                Picker("", selection: binding.contentMatch) {
                    ForEach([SearchCondition.Match.phrase, .allWords, .anyWords, .contains], id: \.self) { Text(SearchSpecDescriber.matchName($0)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 170)
                TextField(String(localized: "words or phrase inside the file"), text: Binding(get: { binding.wrappedValue.content ?? "" }, set: { binding.wrappedValue.content = $0 }))
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
    }

    static func dayString(_ date: Date, zone: String? = nil) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? .current
        f.dateFormat = SearchSpec.dateFormat
        return f.string(from: date)
    }
}

// MARK: - Applied filters

/// Five jobs FIND-04: the applied search as removable chips, grouped so a
/// row of chips never hides whether conditions are all / any / excluded,
/// with the scope shown apart and the "may still match" count.
struct ActiveFiltersBar: View {
    let spec: SearchSpec
    let scopeDescription: String
    let unresolved: Int
    let onChange: (SearchSpec?) -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(scopeDescription, systemImage: "scope")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(String(localized: "Scope: \(scopeDescription)"))
                Spacer()
                Button(String(localized: "Edit…")) { onEdit() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                Button(String(localized: "Clear filters")) { onChange(nil) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Removes the conditions; the selected folder, source and date range stay")
                    .accessibilityIdentifier("activeFilters.clear")
            }
            ForEach(spec.indexedLiveGroups, id: \.index) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(SearchSpecDescriber.groupLabel(item.group.kind) + ":")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(item.group.kind == .exclude ? .orange : .secondary)
                    ChipFlowLayout(spacing: 6) {
                        ForEach(Array(item.group.conditions.enumerated()), id: \.offset) { c in
                            if !c.element.isEmpty {
                                chip(SearchSpecDescriber.chip(c.element)) {
                                    onChange(nonEmpty(spec.removingCondition(group: item.index, condition: c.offset)))
                                }
                            }
                        }
                        ForEach(Array(item.group.attachmentGroups.enumerated()), id: \.offset) { a in
                            if !a.element.isEmpty {
                                chip(SearchSpecDescriber.chip(a.element)) {
                                    onChange(nonEmpty(spec.removingAttachmentGroup(group: item.index, attachment: a.offset)))
                                }
                            }
                        }
                    }
                }
            }
            if unresolved > 0 {
                Label(String(localized: "\(unresolved) more may still match — their text is not indexed yet"), systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("activeFilters.unresolved")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activeFilters")
    }

    private func nonEmpty(_ spec: SearchSpec) -> SearchSpec? { spec.isEmpty ? nil : spec }

    /// Chips wrap to the next line. (Other screens keep their own private
    /// flow layouts; this one is the chips'.)
    struct ChipFlowLayout: Layout {
        var spacing: CGFloat = 6

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let width = proposal.width ?? 600
            var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
            for view in subviews {
                let size = view.sizeThatFits(.unspecified)
                if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
                x += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
            return CGSize(width: width, height: y + rowHeight)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
            for view in subviews {
                let size = view.sizeThatFits(.unspecified)
                if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
                view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
        }
    }

    private func chip(_ text: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(text).lineLimit(1)
            Button(action: remove) { Image(systemName: "xmark.circle.fill").font(.caption2) }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Remove \(text)"))
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }
}

