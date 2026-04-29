//  SwiftEmailKit.swift
//  mailin
//  Pythonic .mbox/.eml RFC822 Email Parser & Composer for Swift
//  Surpasses Python's email/mailbox in capability, safety, and ergonomics.

import Foundation

// MARK: - Policy and Defect Structures

public struct EmailParseDefect: Codable, CustomStringConvertible {
    public let message: String
    public let lineNumber: Int?
    public let context: String?
    public var description: String {
        var base = ""
        if let ln = lineNumber { base += "Line \(ln): " }
        if let ctx = context { base += "[\(ctx)] " }
        base += message
        return base
    }
}
public struct EmailPolicy {
    public enum Strictness { case tolerant, strict, preserveAll }
    public var mode: Strictness = .tolerant
    public var lineSeparator: String = "\r\n"
    public var foldHeadersAt: Int = 78
    public var maxHeaderLength: Int = 998
    public var allowDuplicateHeaders: Bool = true
    public var defectHandler: ((EmailParseDefect) -> Void)? = nil
    public init() {}
}
public let DefaultEmailPolicy = EmailPolicy()

public struct EmailHeaderPair: Codable {
    public var key: String
    public var value: String
    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}
public struct SwiftEmailAttachment: Codable {
    public let filename: String
    public let mimeType: String
    public let data: Data
    public let isInline: Bool
    public let contentID: String?
}
public struct SwiftEmailAddress: Codable {
    public let name: String?
    public let email: String
}

// MARK: - Decoding Helpers

fileprivate extension String {
    func decodeRFC2047() -> String {
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]+)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return self }
        let nsrange = NSRange(self.startIndex..<self.endIndex, in: self)
        var result = self
        let matches = regex.matches(in: self, options: [], range: nsrange).reversed()
        for match in matches {
            guard match.numberOfRanges == 4 else { continue }
            let charset = (self as NSString).substring(with: match.range(at: 1))
            let encoding = (self as NSString).substring(with: match.range(at: 2)).uppercased()
            let encodedText = (self as NSString).substring(with: match.range(at: 3))
            let decoded: String
            if encoding == "B" {
                if let data = Data(base64Encoded: encodedText), let s = SwiftEmailMessage.decodeData(data, charset: charset) {
                    decoded = s
                } else {
                    decoded = encodedText
                }
            } else {
                let qp = encodedText.replacingOccurrences(of: "_", with: " ")
                if let data = SwiftEmailMessage.decodeQPData(qp), let s = SwiftEmailMessage.decodeData(data, charset: charset) {
                    decoded = s
                } else {
                    decoded = qp
                }
            }
            result = (result as NSString).replacingCharacters(in: match.range, with: decoded)
        }
        return result
    }
    func decodeRFC2231Param() -> String {
        let pattern = #"^([\w\-]+)?'([\w\-]*)?'(.+)"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        if let match = regex?.firstMatch(in: self, options: [], range: NSRange(self.startIndex..<self.endIndex, in: self)), match.numberOfRanges == 4 {
            let charset = Range(match.range(at: 1), in: self).flatMap { String(self[$0]) } ?? "utf-8"
            let value = Range(match.range(at: 3), in: self).flatMap { String(self[$0]) } ?? self
            let decoded = value.removingPercentEncoding ?? value
            if let data = decoded.data(using: .utf8), let str = SwiftEmailMessage.decodeData(data, charset: charset) {
                return str
            }
            return decoded
        }
        return self
    }
}
fileprivate func parseMIMEParams(_ headerValue: String) -> [String: String] {
    var params: [String: String] = [:]
    let components = headerValue.split(separator: ";", omittingEmptySubsequences: false)
    var continuation: [String: [Int: String]] = [:]
    for comp in components.dropFirst() {
        let trimmed = comp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let eqIdx = trimmed.firstIndex(of: "=") else { continue }
        let keyRaw = trimmed[..<eqIdx].trimmingCharacters(in: .whitespaces)
        var value = trimmed[trimmed.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        if let match = keyRaw.range(of: #"([a-zA-Z0-9_\-]+)\*(\d+)\*?"#, options: .regularExpression) {
            let base = String(keyRaw[match])
            let numStr = keyRaw[match].replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
            if let idx = Int(numStr) {
                continuation[base, default: [:]][idx] = value.decodeRFC2231Param()
            }
        } else if keyRaw.hasSuffix("*") {
            let base = String(keyRaw.dropLast())
            params[base] = value.decodeRFC2231Param()
        } else {
            params[String(keyRaw)] = String(value)
        }
    }
    for (key, pieces) in continuation {
        let merged = (0...pieces.keys.max()!).compactMap { pieces[$0] }.joined()
        params[key] = merged
    }
    return params
}

// MARK: - SwiftEmailMessage Main Class (Modernized)

public class SwiftEmailMessage: Codable {
    public private(set) var headerList: [EmailHeaderPair] = []
    public private(set) var headers: [String: String] = [:]
    public private(set) var headerParams: [String: [String: String]] = [:]
    public private(set) var rawHeaders: [String: String] = [:]
    public var defects: [EmailParseDefect] = []
    public var policy: EmailPolicy

    public var body: String
    public var rawBody: Data
    public var subparts: [SwiftEmailMessage]
    public var contentType: String
    public var contentTypeParams: [String: String]
    public var charset: String
    public var contentDisposition: String?
    public var contentDispositionParams: [String: String]
    public var contentID: String?
    public var filename: String?
    public var transferEncoding: String?
    public var partIndex: Int = 0
    public var parent: SwiftEmailMessage? = nil

    public var isMultipart: Bool { contentType.lowercased().hasPrefix("multipart/") }

    // MARK: - Codable keys
    private enum CodingKeys: String, CodingKey {
        case headerList, headers, headerParams, rawHeaders, defects,
             body, rawBody, subparts, contentType, contentTypeParams, charset,
             contentDisposition, contentDispositionParams, contentID, filename,
             transferEncoding, partIndex
    }
    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.headerList = try c.decode([EmailHeaderPair].self, forKey: .headerList)
        self.headers = try c.decode([String: String].self, forKey: .headers)
        self.headerParams = try c.decode([String: [String: String]].self, forKey: .headerParams)
        self.rawHeaders = try c.decode([String: String].self, forKey: .rawHeaders)
        self.defects = try c.decode([EmailParseDefect].self, forKey: .defects)
        self.body = try c.decode(String.self, forKey: .body)
        self.rawBody = try c.decode(Data.self, forKey: .rawBody)
        self.subparts = try c.decode([SwiftEmailMessage].self, forKey: .subparts)
        self.contentType = try c.decode(String.self, forKey: .contentType)
        self.contentTypeParams = try c.decode([String: String].self, forKey: .contentTypeParams)
        self.charset = try c.decode(String.self, forKey: .charset)
        self.contentDisposition = try c.decodeIfPresent(String.self, forKey: .contentDisposition)
        self.contentDispositionParams = try c.decode([String: String].self, forKey: .contentDispositionParams)
        self.contentID = try c.decodeIfPresent(String.self, forKey: .contentID)
        self.filename = try c.decodeIfPresent(String.self, forKey: .filename)
        self.transferEncoding = try c.decodeIfPresent(String.self, forKey: .transferEncoding)
        self.partIndex = try c.decode(Int.self, forKey: .partIndex)
        self.policy = DefaultEmailPolicy
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(headerList, forKey: .headerList)
        try c.encode(headers, forKey: .headers)
        try c.encode(headerParams, forKey: .headerParams)
        try c.encode(rawHeaders, forKey: .rawHeaders)
        try c.encode(defects, forKey: .defects)
        try c.encode(body, forKey: .body)
        try c.encode(rawBody, forKey: .rawBody)
        try c.encode(subparts, forKey: .subparts)
        try c.encode(contentType, forKey: .contentType)
        try c.encode(contentTypeParams, forKey: .contentTypeParams)
        try c.encode(charset, forKey: .charset)
        try c.encode(contentDisposition, forKey: .contentDisposition)
        try c.encode(contentDispositionParams, forKey: .contentDispositionParams)
        try c.encode(contentID, forKey: .contentID)
        try c.encode(filename, forKey: .filename)
        try c.encode(transferEncoding, forKey: .transferEncoding)
        try c.encode(partIndex, forKey: .partIndex)
    }

    public init(rawSource: Data, partIndex: Int = 0, policy: EmailPolicy = DefaultEmailPolicy) {
        self.partIndex = partIndex
        self.policy = policy
        let sourceStr = String(data: rawSource, encoding: .utf8) ?? String(data: rawSource, encoding: .isoLatin1) ?? ""
        let separator = sourceStr.contains("\r\n\r\n") ? "\r\n\r\n" : "\n\n"
        let split = sourceStr.components(separatedBy: separator)
        let headerBlock = split.first ?? ""
        let bodyBlock = split.dropFirst().joined(separator: separator)
        var headers: [String: String] = [:]
        var rawHeaders: [String: String] = [:]
        var headerParams: [String: [String: String]] = [:]
        var headerList: [EmailHeaderPair] = []

        var currentKey: String?
        var currentValue = ""
        let headerLines = headerBlock.components(separatedBy: .newlines)
        var lineNum = 0
        for line in headerLines {
            lineNum += 1
            if line.isEmpty { continue }
            if line.first == " " || line.first == "\t" {
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let range = line.range(of: ":") {
                if let key = currentKey {
                    let value = currentValue.decodeRFC2047().trimmingCharacters(in: .whitespaces)
                    headers[key] = value
                    rawHeaders[key] = currentValue
                    headerParams[key] = parseMIMEParams(currentValue)
                    headerList.append(EmailHeaderPair(key: key, value: value))
                }
                currentKey = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                currentValue = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else {
                let defect = EmailParseDefect(
                    message: "Malformed header line: \(line)",
                    lineNumber: lineNum,
                    context: "Header"
                )
                defects.append(defect)
                policy.defectHandler?(defect)
                if policy.mode == .strict {
                    fatalError("Strict policy: Malformed header line at \(lineNum): \(line)")
                }
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
            }
        }
        if let key = currentKey {
            let value = currentValue.decodeRFC2047().trimmingCharacters(in: .whitespaces)
            headers[key] = value
            rawHeaders[key] = currentValue
            headerParams[key] = parseMIMEParams(currentValue)
            headerList.append(EmailHeaderPair(key: key, value: value))
        }
        self.headers = headers
        self.rawHeaders = rawHeaders
        self.headerParams = headerParams
        self.headerList = headerList

        let contentType = headers["Content-Type"] ?? "text/plain"
        let contentTypeParams = parseMIMEParams(headers["Content-Type"] ?? "")
        let charset = contentTypeParams["charset"] ?? "utf-8"
        let contentDisposition = headers["Content-Disposition"]
        let contentDispositionParams = parseMIMEParams(headers["Content-Disposition"] ?? "")
        let contentID = headers["Content-ID"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
        let filename = SwiftEmailMessage.extractFilename(contentDisposition, contentType, contentDispositionParams, contentTypeParams)
        let transferEncoding = headers["Content-Transfer-Encoding"]

        self.contentType = contentType
        self.contentTypeParams = contentTypeParams
        self.charset = charset
        self.contentDisposition = contentDisposition
        self.contentDispositionParams = contentDispositionParams
        self.contentID = contentID
        self.filename = filename
        self.transferEncoding = transferEncoding
        self.subparts = []

        let isMultipart = contentType.lowercased().hasPrefix("multipart/")
        let boundary = contentTypeParams["boundary"]

        if isMultipart, let boundary = boundary, !boundary.isEmpty {
            self.body = ""
            self.rawBody = Data()
            let marker = "--\(boundary)"
            let segments = bodyBlock.components(separatedBy: marker)
            for (idx, segment) in segments.enumerated() {
                let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed.hasPrefix("--") { continue }
                let partSource = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
                let partData = partSource.data(using: .utf8) ?? Data()
                let partMsg = SwiftEmailMessage(rawSource: partData, partIndex: idx, policy: policy)
                partMsg.parent = self
                self.subparts.append(partMsg)
                if !partMsg.defects.isEmpty { self.defects.append(contentsOf: partMsg.defects) }
            }
        } else if contentType.lowercased().hasPrefix("message/rfc822") {
            self.body = ""
            self.rawBody = Data()
            let nested = SwiftEmailMessage(rawSource: bodyBlock.data(using: .utf8) ?? Data(), partIndex: 0, policy: policy)
            nested.parent = self
            self.subparts = [nested]
            if !nested.defects.isEmpty { self.defects.append(contentsOf: nested.defects) }
        } else {
            self.body = SwiftEmailMessage.decodeBody(bodyBlock, encoding: transferEncoding, charset: charset)
            self.rawBody = bodyBlock.data(using: .utf8) ?? Data()
        }
    }

    // --- API Methods below are unchanged from your code (getHeader, getPayload, etc.) ---

    public func getHeader(_ name: String) -> String? {
        for pair in headerList {
            if pair.key.caseInsensitiveCompare(name) == .orderedSame { return pair.value }
        }
        return nil
    }
    public func getHeaderAt(_ index: Int) -> (String, String)? {
        guard index >= 0, index < headerList.count else { return nil }
        let pair = headerList[index]
        return (pair.key, pair.value)
    }
    public func allHeadersOrdered() -> [(String, String)] {
        return headerList.map { ($0.key, $0.value) }
    }
    public func setHeader(_ name: String, value: String) {
        if let idx = headerList.firstIndex(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame }) {
            headerList[idx].value = value
        } else {
            headerList.append(EmailHeaderPair(key: name, value: value))
        }
        headers[name] = value
    }
    public func removeHeader(_ name: String) {
        headerList.removeAll { $0.key.caseInsensitiveCompare(name) == .orderedSame }
        headers.removeValue(forKey: name)
    }
    public func insertHeader(_ name: String, value: String, at index: Int) {
        headerList.insert(EmailHeaderPair(key: name, value: value), at: index)
        headers[name] = value
    }
    public func copy() -> SwiftEmailMessage {
        let msg = SwiftEmailMessage(rawSource: self.rawSourceData(), partIndex: self.partIndex, policy: self.policy)
        msg.parent = self.parent
        return msg
    }
    public func rawSourceData() -> Data {
        var headerStr = ""
        for pair in headerList {
            headerStr += "\(pair.key): \(pair.value)\r\n"
        }
        headerStr += "\r\n"
        let bodyData = rawBody
        var data = Data()
        data.append(headerStr.data(using: .utf8) ?? Data())
        data.append(bodyData)
        return data
    }
    public func getPayload(decode: Bool = true) -> Any {
        if isMultipart { return subparts }
        return decode ? body : rawBody
    }
    public func setPayload(_ value: String) { self.body = value }
    public func walk(_ filterMime: String? = nil) -> [SwiftEmailMessage] {
        var all = [self]
        for sub in subparts { all.append(contentsOf: sub.walk(filterMime)) }
        if let filter = filterMime {
            return all.filter { $0.contentType.lowercased().starts(with: filter.lowercased()) }
        }
        return all
    }
    public func getAttachments() -> [SwiftEmailAttachment] {
        var attachments: [SwiftEmailAttachment] = []
        for part in walk() where part.filename != nil && !part.isMultipart {
            let isInline = part.contentDispositionParams["inline"] != nil || (part.contentDisposition?.lowercased().contains("inline") ?? false)
            if part.rawBody.count > 0 {
                attachments.append(SwiftEmailAttachment(
                    filename: part.filename!,
                    mimeType: part.contentType,
                    data: part.rawBody,
                    isInline: isInline,
                    contentID: part.contentID
                ))
            }
        }
        return attachments
    }
    public func getAddresses(field: String) -> [SwiftEmailAddress] {
        guard let headerValue = getHeader(field) else { return [] }
        var results: [SwiftEmailAddress] = []
        let pattern = #"(?:\"?([^"<]+)\"?\s*)?<([^>]+)>"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let nsrange = NSRange(headerValue.startIndex..<headerValue.endIndex, in: headerValue)
        regex?.enumerateMatches(in: headerValue, options: [], range: nsrange) { match, _, _ in
            guard let match = match else { return }
            let name = match.range(at: 1).location != NSNotFound ? (headerValue as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces) : nil
            let email = match.range(at: 2).location != NSNotFound ? (headerValue as NSString).substring(with: match.range(at: 2)) : ""
            results.append(SwiftEmailAddress(name: name, email: email))
        }
        if results.isEmpty {
            let parts = headerValue.components(separatedBy: ",")
            for addr in parts {
                let trimmed = addr.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                if trimmed.contains("@") {
                    if let r = trimmed.range(of: "<"), let r2 = trimmed.range(of: ">") {
                        let name = trimmed[..<r.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                        let email = trimmed[r.upperBound..<r2.lowerBound]
                        results.append(SwiftEmailAddress(name: name.isEmpty ? nil : String(name), email: String(email)))
                    } else {
                        results.append(SwiftEmailAddress(name: nil, email: trimmed))
                    }
                }
            }
        }
        return results
    }

    public var plainBody: String? { extractBody(preferHTML: false) }
    public var htmlBody: String? { extractBody(preferHTML: true) }
    public var attachmentsFlat: [SwiftEmailAttachment] {
        var result: [SwiftEmailAttachment] = []
        collectAttachments(into: &result)
        return result
    }
    private func extractBody(preferHTML: Bool) -> String? {
        if contentType.lowercased().hasPrefix("multipart/alternative") {
            if preferHTML {
                for sub in subparts where sub.contentType.lowercased().hasPrefix("text/html") {
                    return sub.body
                }
            } else {
                for sub in subparts where sub.contentType.lowercased().hasPrefix("text/plain") {
                    return sub.body
                }
            }
            for sub in subparts {
                if let found = sub.extractBody(preferHTML: preferHTML) { return found }
            }
        }
        if contentType.lowercased().hasPrefix("multipart/") {
            for sub in subparts {
                if let found = sub.extractBody(preferHTML: preferHTML) { return found }
            }
        }
        if (preferHTML && contentType.lowercased().hasPrefix("text/html")) ||
            (!preferHTML && contentType.lowercased().hasPrefix("text/plain")) {
            return body
        }
        return nil
    }
    private func collectAttachments(into arr: inout [SwiftEmailAttachment]) {
        if let attachment = asAttachment() {
            arr.append(attachment)
        }
        for sub in subparts {
            sub.collectAttachments(into: &arr)
        }
    }
    private func asAttachment() -> SwiftEmailAttachment? {
        if let filename = self.filename, !filename.isEmpty {
            return SwiftEmailAttachment(
                filename: filename,
                mimeType: self.contentType,
                data: self.rawBody,
                isInline: self.contentDisposition?.lowercased().contains("inline") ?? false,
                contentID: self.contentID
            )
        }
        return nil
    }
    // Python mailbox-like convenience: .attachments property
    public var attachments: [SwiftEmailAttachment] {
        self.attachmentsFlat
    }

    fileprivate static func extractFilename(
        _ contentDisposition: String?, _ contentType: String?,
        _ dispParams: [String: String], _ typeParams: [String: String]
    ) -> String? {
        if let fname = dispParams["filename"], !fname.isEmpty { return fname }
        if let name = typeParams["name"], !name.isEmpty { return name }
        let fallback = contentDisposition ?? contentType ?? ""
        let filenamePattern = #"filename\s*=\s*"([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: filenamePattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: fallback, range: NSRange(fallback.startIndex..., in: fallback)),
           let range = Range(match.range(at: 1), in: fallback) {
            return String(fallback[range])
        }
        let simplePattern = #"filename\s*=\s*([^;\s]+)"#
        if let regex = try? NSRegularExpression(pattern: simplePattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: fallback, range: NSRange(fallback.startIndex..., in: fallback)),
           let range = Range(match.range(at: 1), in: fallback) {
            return String(fallback[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
    fileprivate static func decodeQPData(_ qp: String) -> Data? {
        var str = qp
        let pattern = #"=([A-Fa-f0-9]{2})"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let nsrange = NSRange(str.startIndex..<str.endIndex, in: str)
        var offset = 0
        regex?.enumerateMatches(in: str, options: [], range: nsrange) { match, _, _ in
            guard let match = match, match.numberOfRanges == 2 else { return }
            let hex = (str as NSString).substring(with: match.range(at: 1))
            if let val = UInt8(hex, radix: 16) {
                let replacement = String(bytes: [val], encoding: .isoLatin1) ?? ""
                let totalRange = NSRange(location: match.range.location + offset, length: match.range.length)
                str = (str as NSString).replacingCharacters(in: totalRange, with: replacement)
                offset -= match.range.length - replacement.count
            }
        }
        return str.data(using: .isoLatin1)
    }
    fileprivate static func decodeData(_ data: Data, charset: String) -> String? {
        switch charset.lowercased() {
            case "utf-8", "utf8": return String(data: data, encoding: .utf8)
            case "iso-8859-1", "latin1": return String(data: data, encoding: .isoLatin1)
            case "us-ascii", "ascii": return String(data: data, encoding: .ascii)
            case "windows-1252": return String(data: data, encoding: .windowsCP1252)
            default: return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        }
    }
    fileprivate static func decodeBody(_ text: String, encoding: String?, charset: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encoding = encoding?.lowercased() else {
            if let data = trimmed.data(using: .utf8) {
                return decodeData(data, charset: charset) ?? trimmed
            }
            return trimmed
        }
        switch encoding {
        case "base64":
            let filtered = trimmed.filter { !$0.isWhitespace }
            if let data = Data(base64Encoded: filtered) {
                return decodeData(data, charset: charset) ?? trimmed
            }
            return trimmed
        case "quoted-printable":
            if let data = decodeQPData(trimmed) {
                return decodeData(data, charset: charset) ?? trimmed
            }
            return trimmed
        default:
            if let data = trimmed.data(using: .utf8) {
                return decodeData(data, charset: charset) ?? trimmed
            }
            return trimmed
        }
    }
    

    // MARK: - Threading (Python-style thread matching)

    /// Returns the full conversation/thread family for this message, using Message-ID, References, and In-Reply-To headers.
    public func threadFamily(allMessages: [SwiftEmailMessage]) -> [SwiftEmailMessage] {
        guard let myID = self.getHeader("Message-ID") else { return [self] }
        var idMap: [String: SwiftEmailMessage] = [:]
        for msg in allMessages {
            if let mid = msg.getHeader("Message-ID") {
                idMap[mid] = msg
            }
        }
        var threadIDs = Set<String>()
        threadIDs.insert(myID)
        var stack: [String] = []
        if let refs = self.getHeader("References") {
            for ref in refs.split(separator: " ").map({ String($0) }) {
                threadIDs.insert(ref)
                stack.append(ref)
            }
        }
        if let inReplyTo = self.getHeader("In-Reply-To") {
            threadIDs.insert(inReplyTo)
            stack.append(inReplyTo)
        }
        while !stack.isEmpty {
            let currentID = stack.removeLast()
            if let parent = idMap[currentID] {
                if let refs = parent.getHeader("References") {
                    for ref in refs.split(separator: " ").map({ String($0) }) {
                        if !threadIDs.contains(ref) {
                            threadIDs.insert(ref)
                            stack.append(ref)
                        }
                    }
                }
                if let inReplyTo = parent.getHeader("In-Reply-To"), !threadIDs.contains(inReplyTo) {
                    threadIDs.insert(inReplyTo)
                    stack.append(inReplyTo)
                }
            }
        }
        var descendants: [SwiftEmailMessage] = []
        var foundNew = true
        while foundNew {
            foundNew = false
            for msg in allMessages {
                if let inReplyTo = msg.getHeader("In-Reply-To"), threadIDs.contains(inReplyTo), !threadIDs.contains(msg.getHeader("Message-ID") ?? "") {
                    if let mid = msg.getHeader("Message-ID") {
                        threadIDs.insert(mid)
                        descendants.append(msg)
                        foundNew = true
                    }
                } else if let refs = msg.getHeader("References") {
                    for ref in refs.split(separator: " ").map({ String($0) }) {
                        if threadIDs.contains(ref), !threadIDs.contains(msg.getHeader("Message-ID") ?? "") {
                            if let mid = msg.getHeader("Message-ID") {
                                threadIDs.insert(mid)
                                descendants.append(msg)
                                foundNew = true
                            }
                        }
                    }
                }
            }
        }
        let threadMessages = allMessages.filter { msg in
            if let mid = msg.getHeader("Message-ID") {
                return threadIDs.contains(mid)
            }
            return false
        }
        .sorted { a, b in
            let da = swiftParseEmailDate(a.getHeader("Date") ?? "") ?? Date.distantPast
            let db = swiftParseEmailDate(b.getHeader("Date") ?? "") ?? Date.distantPast
            return da < db
        }
        return threadMessages
    }
}

// MARK: - Helper: Parse email date string (robust)

public func swiftParseEmailDate(_ dateStr: String) -> Date? {
    let fmts = [
        "EEE, d MMM yyyy HH:mm:ss Z",
        "d MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm:ss",
        "d MMM yyyy HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss Z",
        "yyyy-MM-dd HH:mm:ss"
    ]
    for fmt in fmts {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = fmt
        if let date = formatter.date(from: dateStr) {
            return date
        }
    }
    return nil
}

// MARK: - Streaming .mbox Iterator (Chunked, Progress, Huge files)

public class SwiftMboxStreamingIterator: Sequence, IteratorProtocol {
    private let fileHandle: FileHandle
    private let encoding: String.Encoding
    private let chunkSize: Int
    private var buffer = Data()
    private var eofReached = false
    private var inMessage = false
    private(set) public var messageCount = 0

    public var onProgress: ((Int, Int64) -> Void)?

    private var fileOffset: Int64 {
        Int64((try? fileHandle.offset()) ?? 0)
    }

    public init(mboxPath: String,
                encoding: String.Encoding = .utf8,
                chunkSize: Int = 32768,
                progress: ((Int, Int64) -> Void)? = nil) throws {
        self.fileHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: mboxPath))
        self.encoding = encoding
        self.chunkSize = chunkSize
        self.onProgress = progress
    }
    public func next() -> SwiftEmailMessage? {
        var lines: [String] = []
        var inMsg = false

        while true {
            guard let line = readLine() else { break }
            if line.hasPrefix("From ") {
                if inMsg {
                    buffer.insert(contentsOf: (line + "\n").utf8, at: 0)
                    break
                } else {
                    inMsg = true
                    continue
                }
            }
            if inMsg {
                lines.append(line)
            }
        }

        if !lines.isEmpty {
            let rawMsg = lines.joined(separator: "\n")
            let msgData = rawMsg.data(using: encoding) ?? rawMsg.data(using: .isoLatin1) ?? Data()
            messageCount += 1
            onProgress?(messageCount, fileOffset)
            return SwiftEmailMessage(rawSource: msgData)
        }
        return nil
    }
    private func readLine() -> String? {
        while true {
            if let range = buffer.range(of: Data([UInt8(ascii: "\n")])) {
                let lineData = buffer[..<range.lowerBound]
                buffer = buffer[range.upperBound...]
                return decodeLine(lineData)
            } else if eofReached {
                if !buffer.isEmpty {
                    let line = decodeLine(buffer)
                    buffer.removeAll()
                    return line
                }
                return nil
            } else {
                let chunk = try? fileHandle.read(upToCount: chunkSize)
                if let chunk, !chunk.isEmpty {
                    buffer.append(chunk)
                } else {
                    eofReached = true
                }
            }
        }
    }
    private func decodeLine(_ data: Data) -> String? {
        String(data: data, encoding: encoding) ?? String(data: data, encoding: .isoLatin1)
    }
    public func close() { try? fileHandle.close() }
    deinit { close() }
}

// MARK: - Minimal Fuzz/Test Suite

#if DEBUG
public enum SwiftEmailFuzzTest {
    public static func fuzzHeaders() {
        let testCases = [
            "Subject: Test\r\n From: foo@example.com\r\n\r\nBody",
            "Malformed-Header No-Colon\r\nFrom: foo\r\n\r\n",
            "Subject: =?UTF-8?Q?=E2=9C=94_Test?=\r\n\r\n",
            "From: Foo <foo@example.com>\r\nTo: Bar <bar@example.com>\r\n\r\nBody"
        ]
        for input in testCases {
            let msg = SwiftEmailMessage(rawSource: input.data(using: .utf8)!)
            print("Decoded Subject:", msg.getHeader("Subject") ?? "<none>")
            print("Defects:", msg.defects)
        }
    }
}
#endif
extension SwiftEmailMessage {
    /// Returns the fully reconstructed RFC822 email source as a String.
    /// Tries UTF-8, ISO Latin1, and ASCII decoding. Will return a readable fallback if needed.
    public func asRFC822String() -> String {
        let data = self.rawSourceData()
        // Try most common encodings, in order
        if let str = String(data: data, encoding: .utf8) {
            return str.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let str = String(data: data, encoding: .isoLatin1) {
            return str.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let str = String(data: data, encoding: .ascii) {
            return str.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Fallback: present as space-separated hex values (for debugging only)
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        return "[Unable to decode RFC822 as text. Raw bytes: \(hex)]"
    }
}
