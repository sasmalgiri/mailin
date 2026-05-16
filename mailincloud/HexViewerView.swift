import SwiftUI

struct HexViewerView: View {
    let rawSource: String
    @State private var searchHex = ""
    @State private var bytesPerRow = 16
    @State private var showASCII = true

    private var data: Data { Data(rawSource.utf8) }

    private var rows: [(offset: Int, hex: String, ascii: String)] {
        let bytes = [UInt8](data)
        var result: [(Int, String, String)] = []
        let totalRows = (bytes.count + bytesPerRow - 1) / bytesPerRow
        let displayLimit = min(totalRows, 2000)

        for row in 0..<displayLimit {
            let start = row * bytesPerRow
            let end = min(start + bytesPerRow, bytes.count)
            let slice = bytes[start..<end]

            let hex = slice.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = slice.map { byte -> String in
                if byte >= 0x20 && byte <= 0x7E {
                    return String(UnicodeScalar(byte))
                }
                return "."
            }.joined()

            result.append((start, hex, ascii))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Hex Viewer", systemImage: "rectangle.and.text.magnifyingglass")
                    .font(.headline)
                Spacer()
                Text("\(data.count) bytes")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Toggle("ASCII", isOn: $showASCII)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if data.count > bytesPerRow * 2000 {
                Text("Showing first \(bytesPerRow * 2000) of \(data.count) bytes")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(rows, id: \.offset) { row in
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
