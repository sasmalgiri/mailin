//
//  NoNetworkAttestation.swift
//  mailin
//
//  Task D1: make the offline claim checkable from the shipped artifact.
//
//  The claim had two supports, both true and neither sufficient as proof:
//  the `OFFLINE_MODE` compilation condition (a build setting, changeable) and
//  a measured run with zero network sockets (one run). What survives a
//  challenge is the signed binary — under the App Sandbox, a process with no
//  network entitlement cannot open a socket whatever the code asks for.
//
//  This file supplies the two things that proof needs:
//   1. a marker string present in the binary ONLY when OFFLINE_MODE was
//      defined, so `Scripts/verify-no-network.sh` can tell which
//      configuration produced a given build;
//   2. a runtime read of this process's OWN signed entitlements, so the app
//      states what it is actually permitted to do rather than what it intends.
//
//  Platform honesty: the entitlement read uses Code Signing Services
//  (`SecCodeCopySelf` / `SecCodeCopySigningInformation`), which is macOS-only.
//  On iOS there is no network entitlement to withhold — network access is
//  granted to every app by default — so `networkIsStructurallyImpossible` is
//  reported as FALSE on iOS rather than pretending the sandbox enforces
//  something it does not. The build flag is the only protection there, and
//  `summary` says exactly that.
//

import Foundation
#if os(macOS)
import Security
#endif

enum NoNetworkAttestation {

    /// The marker `Scripts/verify-no-network.sh` greps for. Present in the
    /// binary only under `OFFLINE_MODE`, which is what makes it evidence
    /// about the build rather than about our intentions.
    #if OFFLINE_MODE
    static let buildMarker = "mailin.offline.attested"
    static let offlineModeCompiledIn = true
    #else
    static let buildMarker = "mailin.online.capable"
    static let offlineModeCompiledIn = false
    #endif

    /// What the platform permits this process, read from the process itself.
    struct Verdict: Sendable, Equatable {
        var sandboxed: Bool
        var networkClientGranted: Bool
        var networkServerGranted: Bool
        var offlineModeCompiledIn: Bool
        /// False when the platform gives no way to read or withhold the
        /// network entitlement, so the other flags are intent, not proof.
        var entitlementsAreEnforceable: Bool

        /// True only when the platform can be relied on to refuse a
        /// connection. A build flag alone does not qualify.
        var networkIsStructurallyImpossible: Bool {
            entitlementsAreEnforceable
                && sandboxed
                && !networkClientGranted
                && !networkServerGranted
        }

        /// One line for the About panel and the assurance pack. States what is
        /// enforced and by what — and says so plainly when nothing enforces it.
        var summary: String {
            guard entitlementsAreEnforceable else {
                return offlineModeCompiledIn
                    ? "Built with OFFLINE_MODE: no networking code is compiled in. This platform grants network access to every app, so the build is the protection — not the sandbox."
                    : "This build has networking compiled in and this platform grants network access by default."
            }
            guard sandboxed else {
                return "This build is NOT sandboxed, so no entitlement prevents a network connection"
                    + (offlineModeCompiledIn ? " — only the OFFLINE_MODE build flag does." : ".")
            }
            if networkIsStructurallyImpossible {
                return "Sandboxed with no network entitlement: this process cannot open a network connection."
            }
            var granted: [String] = []
            if networkClientGranted { granted.append("outgoing") }
            if networkServerGranted { granted.append("incoming") }
            return "Sandboxed, but the network entitlement is GRANTED for \(granted.joined(separator: " and ")) connections."
        }
    }

    /// Not cached: it is cheap, and a value computed once at launch could not
    /// distinguish "never asked" from "asked and got nothing".
    static func verdict() -> Verdict {
        #if os(macOS)
        let entitlements = selfEntitlements()
        return Verdict(
            sandboxed: boolEntitlement(entitlements, "com.apple.security.app-sandbox"),
            networkClientGranted: boolEntitlement(entitlements, "com.apple.security.network.client"),
            networkServerGranted: boolEntitlement(entitlements, "com.apple.security.network.server"),
            offlineModeCompiledIn: offlineModeCompiledIn,
            // An unreadable entitlement dictionary must not read as "proved
            // safe": nil means we cannot demonstrate anything.
            entitlementsAreEnforceable: entitlements != nil
        )
        #else
        return Verdict(
            sandboxed: true,                     // every iOS app is
            networkClientGranted: true,          // granted by default on iOS
            networkServerGranted: false,
            offlineModeCompiledIn: offlineModeCompiledIn,
            entitlementsAreEnforceable: false
        )
        #endif
    }

    // MARK: - Entitlement read (macOS)

    #if os(macOS)
    /// This process's embedded entitlements, or nil when they cannot be read
    /// (unsigned build, or Code Signing Services refusing).
    private static func selfEntitlements() -> [String: Any]? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &code) == errSecSuccess, let code else { return nil }

        // `SecCodeCopySigningInformation` takes a static (on-disk) code
        // object; the entitlements live in the signature on disk.
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
              let staticCode else { return nil }

        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSRequirementInformation | kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }

        return dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
    }

    private static func boolEntitlement(_ entitlements: [String: Any]?, _ key: String) -> Bool {
        (entitlements?[key] as? Bool) ?? false
    }
    #endif
}
