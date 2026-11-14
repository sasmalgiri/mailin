// §3-P3: libFuzzer entry point. Each input is fed to the MIME parser
// directly and, as a file, through the parser factory under a format chosen
// by the input's first byte (mbox, eml, emlx, msg, pst, nsf, zip). A crash or
// an AddressSanitizer report is a finding; libFuzzer saves the input that
// caused it (`crash-<sha1>`), which reproduces with `./fuzz <file>`.

import Foundation
@testable import ArchiveCore

private let formats = ["mbox", "eml", "emlx", "msg", "pst", "nsf", "zip"]
private let scratch: URL = {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("archivecore-fuzz", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOne(_ start: UnsafeRawPointer, _ count: Int) -> CInt {
    let data = Data(bytes: start, count: count)

    // 1. The MIME parser on the text view of the input.
    _ = MIMEParser.parseEmail(rawEmail: String(decoding: data, as: UTF8.self))

    // 2. The parser factory, through a file, under one format per input.
    let ext = formats[Int(data.first ?? 0) % formats.count]
    let url = scratch.appendingPathComponent("input.\(ext)")
    guard (try? data.write(to: url)) != nil else { return 0 }
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        _ = try? await ParserFactory.parseStreamingCallback(
            fileURL: url, senderEmail: "", batchSize: 50,
            retainAttachmentBytes: false, materializeAttachments: false
        ) { @Sendable _ in }
        done.signal()
    }
    // A hang is a finding too: libFuzzer's -timeout flag reports it.
    done.wait()
    return 0
}
