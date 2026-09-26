//
//  LiveMailNetworkGate.swift
//  maxmailin
//
//  L1: the one gate every Live Mail network path asks before opening a
//  socket. While Page 4 is off the gate is closed: `permit()` throws, the
//  attempt is counted, and nothing connects. `NetworkBaselineTests` asserts
//  the closed gate refuses and that no permitted connection ever happened on
//  a Live-Mail-off launch. The registry opens and closes the gate through
//  `CapabilityWiring` when the page is enabled or disabled.
//
//  This is the runtime half of the zero-network claim on the consumer
//  build; the no-network edition keeps the structural half (no entitlement,
//  no code).
//

import Foundation
import os

enum LiveMailNetworkError: LocalizedError {
    case pageOff
    var errorDescription: String? {
        "Live Mail is switched off, so mailin will not connect to a mail server. Enable Live Mail in Settings ▸ Modules first."
    }
}

@MainActor
@Observable
final class LiveMailNetworkGate {
    static let shared = LiveMailNetworkGate()
    private let log = Logger(subsystem: "com.ecosanskriti.mailin", category: "LiveMailGate")

    /// Opened by the registry when Live Mail is enabled; closed when disabled.
    private(set) var isOpen = false
    /// Connection attempts refused because the page was off — evidence for L1.
    private(set) var refusedAttempts = 0
    /// Connections permitted this session (host names only, never credentials).
    private(set) var permittedHosts: [String] = []

    private init() {}

    func setOpen(_ open: Bool) {
        isOpen = open
        log.notice("Live Mail network gate \(open ? "opened" : "closed", privacy: .public)")
    }

    /// Ask before every connection. Throws while the page is off.
    func permit(host: String) throws {
        guard isOpen else {
            refusedAttempts += 1
            log.fault("refused a Live Mail connection to \(host, privacy: .public) while the page is off")
            throw LiveMailNetworkError.pageOff
        }
        permittedHosts.append(host)
        if permittedHosts.count > 200 { permittedHosts.removeFirst() }
    }

    /// Test hook.
    func resetForTesting() {
        isOpen = false
        refusedAttempts = 0
        permittedHosts = []
    }
}
