//
//  ConnectedSyncSchedule.swift
//  DL-05 (owner 2026-11-23, download-manager techniques: a scheduler). Live
//  Mail can save new mail by itself every so often, and the person can say
//  when automatic saving may run: only on Wi-Fi or a wired network (never on
//  mobile data or a hotspot), only while the device is charging, only at
//  night. The conditions apply to every automatic run — when mailin opens and
//  the timed runs; Sync now always runs because the person asked for it.
//  Off by default (rule 15): mail is saved when mailin opens and on Sync now,
//  as before, until the person chooses an interval.
//

import Foundation
import Network
#if os(macOS)
import IOKit.ps
#elseif os(iOS)
import UIKit
#endif

struct ConnectedSyncSchedule: Codable, Equatable {
    enum Interval: Int, Codable, CaseIterable, Identifiable {
        case off = 0, every15Minutes = 15, every30Minutes = 30, hourly = 60, every4Hours = 240
        var id: Int { rawValue }
        var seconds: TimeInterval? { self == .off ? nil : TimeInterval(rawValue * 60) }
        var title: String {
            switch self {
            case .off: return String(localized: "Off")
            case .every15Minutes: return String(localized: "Every 15 minutes")
            case .every30Minutes: return String(localized: "Every 30 minutes")
            case .hourly: return String(localized: "Every hour")
            case .every4Hours: return String(localized: "Every 4 hours")
            }
        }
    }

    var interval: Interval = .off
    var wifiOnly = false
    var whileChargingOnly = false
    var nightOnly = false

    /// The night window for `nightOnly`: 22:00 to 07:00, local time.
    static let nightStartsAtHour = 22
    static let nightEndsAtHour = 7

    static let defaultsKey = "mailin.connected.syncSchedule"

    static func load(_ defaults: UserDefaults = .standard) -> ConnectedSyncSchedule {
        guard let data = defaults.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(ConnectedSyncSchedule.self, from: data) else { return ConnectedSyncSchedule() }
        return saved
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// What the device is doing now (read when an automatic run is due).
struct ConnectedSyncConditions: Equatable {
    /// Wi-Fi or a wired network that is not marked expensive (no mobile data, no hotspot).
    var unmeteredNetwork: Bool
    /// On power (charging, full, or a Mac without a battery).
    var charging: Bool
    var now: Date
}

enum ConnectedSyncGate {
    enum Decision: Equatable {
        case run
        case wait(String)
    }

    /// Whether an automatic run may start now. `lastAutomatic` nil = never ran
    /// in this process; `forLaunch` = the run when mailin opens (no interval).
    static func decide(_ schedule: ConnectedSyncSchedule, _ c: ConnectedSyncConditions,
                       lastAutomatic: Date?, forLaunch: Bool, calendar: Calendar = .current) -> Decision {
        if !forLaunch {
            guard let every = schedule.interval.seconds else { return .wait(String(localized: "Automatic sync is off")) }
            if let last = lastAutomatic, c.now.timeIntervalSince(last) < every {
                return .wait(String(localized: "Waiting for the next automatic sync"))
            }
        }
        if schedule.wifiOnly && !c.unmeteredNetwork {
            return .wait(String(localized: "Waiting for Wi-Fi: automatic sync does not use mobile data"))
        }
        if schedule.whileChargingOnly && !c.charging {
            return .wait(String(localized: "Waiting for power: automatic sync runs while charging"))
        }
        if schedule.nightOnly && !isNight(c.now, calendar: calendar) {
            return .wait(String(localized: "Waiting for night: automatic sync runs between 10 pm and 7 am"))
        }
        return .run
    }

    static func isNight(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= ConnectedSyncSchedule.nightStartsAtHour || hour < ConnectedSyncSchedule.nightEndsAtHour
    }
}

/// Runs the automatic syncs: the one when mailin opens and the timed ones.
@MainActor
final class ConnectedSyncScheduler {
    static let shared = ConnectedSyncScheduler()

    private var loop: Task<Void, Never>?
    private let monitor = NWPathMonitor()
    private var path: NWPath?
    private var monitoring = false
    private(set) var lastAutomatic: Date?
    /// The run when mailin opens had to wait (no Wi-Fi, not charging, not
    /// night): the timer keeps checking until it can run, even with no interval.
    private(set) var launchRunPending = false
    /// Why the last automatic run did not start (shown on the Accounts page).
    private(set) var lastWaitReason: String?
    /// How often the timer looks whether a run is due.
    var tick: TimeInterval = 60

    private init() {}

    func start(_ runtime: ConnectedMailRuntime) {
        startMonitoring()
        loop?.cancel()
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.tick ?? 60) * 1_000_000_000))
                guard let self, !Task.isCancelled, let runtime = ConnectedMailRuntime.shared else { return }
                await self.runIfDue(runtime, forLaunch: self.launchRunPending)
            }
        }
        _ = runtime   // the timer always uses the current runtime (it may be replaced)
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// The automatic run when mailin opens, and every timed one.
    func runIfDue(_ runtime: ConnectedMailRuntime, forLaunch: Bool) async {
        startMonitoring()
        // The first network reading arrives within moments of starting the monitor.
        for _ in 0..<20 where path == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        let schedule = ConnectedSyncSchedule.load()
        switch ConnectedSyncGate.decide(schedule, conditions(), lastAutomatic: lastAutomatic, forLaunch: forLaunch) {
        case .run:
            lastWaitReason = nil
            lastAutomatic = Date()
            if forLaunch { launchRunPending = false }
            await runtime.syncAll()
        case .wait(let reason):
            lastWaitReason = reason
            if forLaunch { launchRunPending = true }
        }
    }

    func conditions(now: Date = Date()) -> ConnectedSyncConditions {
        ConnectedSyncConditions(unmeteredNetwork: Self.unmetered(path), charging: Self.onPower(), now: now)
    }

    private func startMonitoring() {
        guard !monitoring else { return }
        monitoring = true
        monitor.pathUpdateHandler = { [weak self] newPath in
            Task { @MainActor in self?.path = newPath }
        }
        monitor.start(queue: DispatchQueue(label: "mailin.connected.network"))
    }

    nonisolated static func unmetered(_ path: NWPath?) -> Bool {
        guard let path, path.status == .satisfied else { return false }
        if path.isExpensive || path.isConstrained { return false }
        return path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
    }

    static func onPower() -> Bool {
        #if os(macOS)
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return true }
        return type == kIOPMACPowerKey
        #elseif os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let state = UIDevice.current.batteryState
        return state == .charging || state == .full || state == .unknown
        #else
        return true
        #endif
    }
}
