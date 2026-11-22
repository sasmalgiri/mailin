//
//  MailTransferMeter.swift
//  DL-02 (owner 2026-11-23, download-manager techniques): while an account
//  saves mail, the page shows how fast it goes and about how long is left —
//  messages per second, bytes per second, and the time left when the server's
//  list is complete. Measured from the account's own saved count and saved
//  bytes over the last 30 seconds (counts in code, rule 8); nothing is guessed
//  before two samples show progress.
//

import Foundation

struct MailTransferRate: Equatable {
    var messagesPerSecond: Double
    var bytesPerSecond: Double
    /// nil = the server's list is not complete yet, so nothing is promised.
    var secondsLeft: TimeInterval?
}

struct MailTransferMeter {
    struct Sample: Equatable {
        var time: Date
        var saved: Int
        var bytes: Int64
    }

    /// How far back the rate looks: long enough to smooth a slow message,
    /// short enough to follow a change of speed.
    var window: TimeInterval = 30
    private(set) var samples: [UUID: [Sample]] = [:]

    /// One reading of a running account (the 2 s page refresh).
    mutating func record(_ id: UUID, saved: Int, bytes: Int64, at time: Date = Date()) {
        var list = samples[id] ?? []
        // A count that went down (mail deleted, a new run) starts the measurement again.
        if let last = list.last, saved < last.saved || bytes < last.bytes || time < last.time { list = [] }
        list.append(Sample(time: time, saved: saved, bytes: bytes))
        // Keep the newest sample older than the window as the baseline.
        while list.count > 2, time.timeIntervalSince(list[1].time) >= window { list.removeFirst() }
        samples[id] = list
    }

    /// The account stopped saving: its measurement is forgotten.
    mutating func forget(_ id: UUID) { samples[id] = nil }

    /// nil until two readings at least a second apart show messages saved.
    func rate(_ id: UUID, remaining: Int?) -> MailTransferRate? {
        guard let list = samples[id], let first = list.first, let last = list.last else { return nil }
        let seconds = last.time.timeIntervalSince(first.time)
        let saved = last.saved - first.saved
        guard seconds >= 1, saved > 0 else { return nil }
        let perSecond = Double(saved) / seconds
        let bytesPerSecond = Double(max(0, last.bytes - first.bytes)) / seconds
        let left = remaining.map { Double(max(0, $0)) / perSecond }
        return MailTransferRate(messagesPerSecond: perSecond, bytesPerSecond: bytesPerSecond, secondsLeft: left)
    }
}

enum MailTransferText {
    /// "12 messages/s · 3.4 MB/s · about 25 min left" (localised pieces).
    static func line(_ rate: MailTransferRate) -> String {
        let number = rate.messagesPerSecond >= 10
            ? rate.messagesPerSecond.formatted(.number.precision(.fractionLength(0)))
            : rate.messagesPerSecond.formatted(.number.precision(.fractionLength(1)))
        var parts = [String(localized: "\(number) messages/s")]
        if rate.bytesPerSecond > 0 {
            let bytes = ByteCountFormatter.string(fromByteCount: Int64(rate.bytesPerSecond), countStyle: .file)
            parts.append(String(localized: "\(bytes)/s"))
        }
        if let left = rate.secondsLeft {
            if left < 60 {
                parts.append(String(localized: "less than a minute left"))
            } else {
                let formatter = DateComponentsFormatter()
                formatter.unitsStyle = .abbreviated
                formatter.allowedUnits = left >= 3_600 ? [.day, .hour, .minute] : [.minute]
                formatter.maximumUnitCount = 2
                let text = formatter.string(from: left) ?? ""
                parts.append(String(localized: "about \(text) left"))
            }
        }
        return parts.joined(separator: " · ")
    }
}
