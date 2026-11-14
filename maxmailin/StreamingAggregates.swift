//
//  StreamingAggregates.swift
//  maxmailin
//
//  §3-F3: exact aggregates that are fed batch by batch, so a whole-archive
//  statistic never needs the whole archive in memory. Every type is Codable
//  (it can be a ScopeJob's checkpointed state, so a resumed job continues the
//  same totals) and mergeable (two partial results combine into the result of
//  the combined input).
//
//  Exact, not approximate: memory grows with the number of DISTINCT keys
//  (senders, domains, days), never with the number of emails. Results are
//  equal to the in-memory computations they replace.
//

import Foundation

/// A single running count with a sum (for averages).
struct RunningStat: Codable, Sendable, Equatable {
    private(set) var count = 0
    private(set) var sum: Double = 0
    private(set) var min: Double?
    private(set) var max: Double?

    mutating func add(_ value: Double) {
        count += 1
        sum += value
        min = Swift.min(min ?? value, value)
        max = Swift.max(max ?? value, value)
    }

    var mean: Double? { count > 0 ? sum / Double(count) : nil }

    mutating func merge(_ other: RunningStat) {
        count += other.count
        sum += other.sum
        if let m = other.min { min = Swift.min(min ?? m, m) }
        if let m = other.max { max = Swift.max(max ?? m, m) }
    }
}

/// Exact counts per key, with ranked output that always carries the total so
/// a "top 20" never reads as "everything".
struct KeyCounter: Codable, Sendable, Equatable {
    private(set) var counts: [String: Int] = [:]
    /// Number of `add` calls (items seen), independent of distinct keys.
    private(set) var itemsSeen = 0

    mutating func add(_ key: String, by n: Int = 1) {
        counts[key, default: 0] += n
        itemsSeen += n
    }

    mutating func add<S: Sequence>(contentsOf keys: S) where S.Element == String {
        for k in keys { add(k) }
    }

    mutating func merge(_ other: KeyCounter) {
        for (k, v) in other.counts { counts[k, default: 0] += v }
        itemsSeen += other.itemsSeen
    }

    var distinct: Int { counts.count }

    func count(of key: String) -> Int { counts[key] ?? 0 }

    /// Highest counts first; ties broken by key so the order is reproducible.
    func ranked() -> [(key: String, count: Int)] {
        counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (key: $0.key, count: $0.value) }
    }

    /// The top `k` with the number of keys and items not shown.
    func top(_ k: Int) -> TopKResult {
        let all = ranked()
        let shown = Array(all.prefix(k))
        let shownItems = shown.reduce(0) { $0 + $1.count }
        return TopKResult(entries: shown.map { .init(key: $0.key, count: $0.count) },
                          distinctTotal: all.count,
                          itemsTotal: itemsSeen,
                          otherKeys: max(0, all.count - shown.count),
                          otherItems: max(0, itemsSeen - shownItems))
    }
}

/// A top-K list that knows what it is not showing.
struct TopKResult: Codable, Sendable, Equatable {
    struct Entry: Codable, Sendable, Equatable { let key: String; let count: Int }
    let entries: [Entry]
    let distinctTotal: Int
    let itemsTotal: Int
    let otherKeys: Int
    let otherItems: Int

    /// "Top 20 of 4,812 senders" style caption.
    func caption(noun: String) -> String {
        otherKeys == 0
            ? String(localized: "All \(distinctTotal) \(noun)")
            : String(localized: "Top \(entries.count) of \(distinctTotal) \(noun)")
    }
}

/// Counts per calendar bucket (day / month / year / hour-of-day / weekday).
struct TimeHistogram: Codable, Sendable, Equatable {
    enum Bucket: String, Codable, Sendable { case day, month, year, hourOfDay, weekday }
    let bucket: Bucket
    private(set) var counts: [Int: Int] = [:]   // bucket key → count

    init(_ bucket: Bucket) { self.bucket = bucket }

    mutating func add(_ date: Date, calendar: Calendar = .current) {
        counts[Self.key(for: date, bucket: bucket, calendar: calendar), default: 0] += 1
    }

    mutating func merge(_ other: TimeHistogram) {
        precondition(other.bucket == bucket, "merging histograms of different buckets")
        for (k, v) in other.counts { counts[k, default: 0] += v }
    }

    /// Ascending by bucket key.
    var sorted: [(key: Int, count: Int)] { counts.sorted { $0.key < $1.key }.map { (key: $0.key, count: $0.value) } }
    var total: Int { counts.values.reduce(0, +) }

    /// day → yyyymmdd, month → yyyymm, year → yyyy, hourOfDay → 0…23, weekday → 1…7.
    static func key(for date: Date, bucket: Bucket, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .weekday], from: date)
        switch bucket {
        case .day: return (c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0)
        case .month: return (c.year ?? 0) * 100 + (c.month ?? 0)
        case .year: return c.year ?? 0
        case .hourOfDay: return c.hour ?? 0
        case .weekday: return c.weekday ?? 0
        }
    }
}

/// Exact distinct count of strings. Stores 8-byte hashes rather than the
/// strings, so ten million distinct keys cost ~160 MB at worst; collisions
/// are ~1 in 10^11 at that size (FNV-1a 64-bit, stable across launches —
/// Swift's `Hasher` is seeded per process and cannot be checkpointed).
struct DistinctCounter: Codable, Sendable, Equatable {
    private(set) var hashes: Set<UInt64> = []

    mutating func add(_ key: String) { hashes.insert(Self.fnv1a(key)) }
    mutating func merge(_ other: DistinctCounter) { hashes.formUnion(other.hashes) }
    var count: Int { hashes.count }

    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return h
    }
}
