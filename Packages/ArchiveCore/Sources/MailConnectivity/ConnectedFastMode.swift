//
//  ConnectedFastMode.swift
//  MailConnectivity
//
//  FAST-05 (owner decision 2026-11-20): the fast import switch
//  (`Capability.v4FastImport`, off by default) also speeds up downloads from
//  connected accounts — more downloads at once, decided again at every
//  download from the Mac's cores and heat, inside each provider's own rule:
//
//    • Gmail API: up to 8 per account (was 4) — far inside Google's per-user
//      quota for messages.get;
//    • IMAP: up to 4 connections per account (was 2) — most servers allow
//      more (Gmail 15), and a server that refuses a connection is handled by
//      the existing retry/backoff;
//    • Microsoft Graph: unchanged at 4 — Microsoft allows at most 4
//      concurrent requests per mailbox; more only earns throttling;
//    • all accounts together: up to 12 at once (was 6).
//
//  Under serious or critical heat every number falls back to the normal one.
//

import Foundation
import os

public enum ConnectedFastMode {
    private static let state = OSAllocatedUnfairLock(initialState: false)

    /// Set by the app from the module matrix.
    public static var isEnabled: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    public static let gmailCeiling = 8
    /// TOR-02: adaptive downloads may probe up to this for Gmail (still under
    /// `totalCeiling` for all accounts together) and halve when Google says slow down.
    public static let gmailAdaptiveCeiling = 12
    public static let imapCeiling = 4
    public static let totalCeiling = 12

    /// The number to use now: `normal` when the fast mode is off or the Mac is
    /// hot, otherwise up to `ceiling`, bounded by the cores.
    public static func downloads(normal: Int, ceiling: Int,
                                 enabled: Bool = isEnabled,
                                 cores: Int = ProcessInfo.processInfo.activeProcessorCount,
                                 thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) -> Int {
        guard enabled else { return normal }
        if thermal == .serious || thermal == .critical { return normal }
        return max(normal, min(ceiling, max(1, cores)))
    }
}
