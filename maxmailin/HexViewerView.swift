@testable import ArchiveCore
import SwiftUI

struct HexViewerView: View {
    @State private var showASCII = true
    private let bytesPerRow = 16
    /// Built once per source (review 2026-11-16 E): reads only the bytes shown,
    /// instead of copying the whole raw source twice on every redraw.
    private let layout: Layout

    init(rawSource: String) {
        layout = Self.layout(of: rawSource, bytesPerRow: 16)
    }

    struct Row {
        let offset: Int
        let hex: String
        let ascii: String
    }

    struct Layout {
        let totalBytes: Int
        let rows: [Row]
        /// Bytes the rows cover; fewer than `totalBytes` → the screen says so.
        let shownBytes: Int
    }

    /// The stated display limit (rows of `bytesPerRow`); the screen names it when it applies.
    static let rowLimit = 2000

    static func layout(of source: String, bytesPerRow: Int) -> Layout {
        let utf8 = source.utf8
        let shown = Array(utf8.prefix(bytesPerRow * rowLimit))
        var rows: [Row] = []
        rows.reserveCapacity((shown.count + bytesPerRow - 1) / bytesPerRow)
        var start = 0
        while start < shown.count {
            let slice = shown[start..<min(start + bytesPerRow, shown.count)]
            let hex = slice.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = String(slice.map { byte -> Character in
                (0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : "."
            })
            rows.append(Row(offset: start, hex: hex, ascii: ascii))
            start += bytesPerRow
        }
        return Layout(totalBytes: utf8.count, rows: rows, shownBytes: shown.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Hex Viewer", systemImage: "rectangle.and.text.magnifyingglass")
                    .font(.headline)
                Spacer()
                Text("\(layout.totalBytes) bytes")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Toggle("ASCII", isOn: $showASCII)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if layout.shownBytes < layout.totalBytes {
                Text("Showing first \(layout.shownBytes) of \(layout.totalBytes) bytes")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(layout.rows, id: \.offset) { row in
                        HStack(spacing: 0) {
                            Text(String(format: "%08X", row.offset))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 80, alignment: .leading)

                            Text(row.hex)
                                .font(.system(.caption, design: .monospaced))
                                .frame(minWidth: CGFloat(bytesPerRow * 3) * 7.2, alignment: .leading)
                                .textSelection(.enabled)

                            if showASCII {
                                Text("│")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Text(row.ascii)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.orange)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(8)
            }
            .background(Color.black.opacity(0.05))
            .cornerRadius(8)
        }
        .padding()
    }
}
