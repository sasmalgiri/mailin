//
//  RenderedSource.swift
//  ArchiveCore
//
//  §13.8 step 6 (found by COMP-15): a message read from a PST, MSG or NSF
//  file has no RFC 5322 bytes of its own, and the archive keeps attachment
//  BYTES only inside the raw source — so every attachment of such a message
//  was lost the moment the import ended: not openable, not searchable, not
//  exported, and never comparable for duplicates. The fix is the same one
//  the OLM reader always used: render the message as RFC 5322 at import,
//  with an `X-Mailin-Rendered` header naming the source format, and store
//  that as the raw source. Every downstream path (hydrator, attachment
//  index, .eml export, duplicate verification) reads it like any mbox mail.
//

import Foundation

extension MBOXParser.RawEmail {
    /// The same message with a rendered raw source when it has none;
    /// unchanged when real source bytes exist.
    func withRenderedSource(_ provenance: String) -> MBOXParser.RawEmail {
        guard rawSource.isEmpty else { return self }
        var rendered = self
        rendered.rawSource = String(decoding: RFC822Renderer.render(self, provenance: provenance), as: UTF8.self)
        return rendered
    }
}
