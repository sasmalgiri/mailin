//
//  ProtectedContentPolicy.swift
//  maxmailin
//
//  Plan v4 §13.3 (12), §13.8 step 5: what the app does with protected
//  content, in one place.
//
//  • Passwords are never stored: an Unlock reads one attachment with the
//    password typed once (`AttachmentTextIndexJob.unlock`); the person
//    decides per unlock whether the text is kept in the index.
//  • S/MIME decryption with the keychain's private key is a module switch
//    (capability `.protectedMessageDecrypt`, off by default). Off, S/MIME
//    parts are recorded as locked and the record says what would open them.
//

import Foundation

enum ProtectedContentPolicy {
    /// Pushed by `CapabilityWiring` from the `.protectedMessageDecrypt` switch.
    nonisolated(unsafe) static var decryptSMIME = false
}
