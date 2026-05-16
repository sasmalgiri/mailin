import SwiftUI

struct SubjectsListView: View {
    let emails: [MBOXParser.RawEmail]
    @Binding var clusterFilterIDs: Set<UUID>?
    @State private var searchText = ""
    @State private var sortOrder: SubjectSortOrder = .dateNewest

    enum SubjectSortOrder: String, CaseIterable {
        case dateNewest = "Date (Newest)"
        case dateOldest = "Date (Oldest)"
        case subjectAZ = "Subject (A–Z)"
        case subjectZA = "Subject (Z–A)"
        case senderAZ = "Sender (A–Z)"
        case senderZA = "Sender (Z–A)"

        var icon: String {
            switch self {
            case .dateNewest: return "arrow.down"
            case .dateOldest: return "arrow.up"
            case .subjectAZ, .senderAZ: return "textformat.abc"
            case .subjectZA, .senderZA: return "textformat.abc"
            }
        }
    }

    private var subjects: [(id: UUID, subject: String, from: String, date: Date?)] {
        emails.map { email in
            let subject = email.headers["Subject"] ?? "(No Subject)"
            let from = email.headers["From"] ?? ""
            let date = MBOXParser.parseDate(email.headers["Date"])
            return (id: email.id, subject: subject, from: from, date: date)
        }
    }

    private var filteredSubjects: [(id: UUID, subject: String, from: String, date: Date?)] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = query.isEmpty ? subjects : subjects.filter { $0.subject.lowercased().contains(query) || $0.from.lowercased().contains(query) }
        return base.sorted { a, b in
            switch sortOrder {
            case .dateNewest:
                return (a.date ?? .distantPast) > (b.date ?? .distantPast)
            case .dateOldest:
                return (a.date ?? .distantPast) < (b.date ?? .distantPast)
            case .subjectAZ:
                return a.subject.localizedCaseInsensitiveCompare(b.subject) == .orderedAscending
            case .subjectZA:
                return a.subject.localizedCaseInsensitiveCompare(b.subject) == .orderedDescending
            case .senderAZ:
                return a.from.localizedCaseInsensitiveCompare(b.from) == .orderedAscending
            case .senderZA:
                return a.from.localizedCaseInsensitiveCompare(b.from) == .orderedDescending
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.xSmall) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(AppColors.secondary)
                    .font(.system(size: 11))
                TextField("Filter subjects...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(Typography.caption1)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(AppColors.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Text("\(filteredSubjects.count) subjects")
                    .font(Typography.caption2)
                    .foregroundColor(AppColors.secondary)

                Menu {
                    ForEach(SubjectSortOrder.allCases, id: \.self) { order in
                        Button {
                            sortOrder = order
                        } label: {
                            HStack {
                                Text(order.rawValue)
                                if sortOrder == order {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 9))
                        Text("Sort")
                            .font(Typography.caption2)
                    }
                    .foregroundColor(AppColors.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(AppColors.primary.opacity(0.1))
                    .cornerRadius(CornerRadius.small)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, Spacing.small)
            .padding(.vertical, 6)
            .background(AppColors.backgroundSecondary)

            Divider()

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredSubjects, id: \.id) { item in
                        subjectRow(item)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func subjectRow(_ item: (id: UUID, subject: String, from: String, date: Date?)) -> some View {
        let isFiltered = clusterFilterIDs?.contains(item.id) == true && clusterFilterIDs?.count == 1
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if isFiltered {
                    clusterFilterIDs = nil
                } else {
                    clusterFilterIDs = Set([item.id])
                }
            }
        } label: {
            HStack(spacing: Spacing.xSmall) {
                Image(systemName: isFiltered ? "envelope.open.fill" : "envelope")
                    .font(.system(size: 10))
                    .foregroundColor(isFiltered ? AppColors.primary : AppColors.secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.subject)
                        .font(Typography.caption1)
                        .fontWeight(isFiltered ? .semibold : .regular)
                        .lineLimit(1)
                        .foregroundColor(Color.primary)
                    Text(senderName(item.from))
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let date = item.date {
                    Text(date, style: .date)
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                }
            }
            .padding(.horizontal, Spacing.small)
            .padding(.vertical, 4)
            .background(isFiltered ? AppColors.primary.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.subject), from \(senderName(item.from))")
        .accessibilityHint(isFiltered ? "Double tap to clear filter" : "Double tap to filter by this email")
        .accessibilityAddTraits(isFiltered ? .isSelected : [])
    }

    private func senderName(_ from: String) -> String {
        if let angleBracket = from.range(of: "<") {
            let name = from[from.startIndex..<angleBracket.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? from : name
        }
        return from
    }
}
