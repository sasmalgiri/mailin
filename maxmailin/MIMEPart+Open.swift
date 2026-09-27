//
//  MIMEPart+Open.swift
//  maxmailin
//
//  C-1: opening a decoded attachment in the default app is platform UI, so
//  it lives on the app side of the ArchiveCore boundary.
//

import Foundation
@testable import ArchiveCore

extension MIMEPart {
    /// Opens the saved attachment in the default app.
    @MainActor
    public func openAttachmentInDefaultApp() {
        if let url = saveRobustDecodedAttachmentToTemp() {
            PlatformURLOpener.open(url)
        }
    }
}
