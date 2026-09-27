import Foundation

/// Unified, robust error type for all email and MIME extraction failures.
/// Use this as the only error enum in your pipeline for clarity and catch-all coverage.
public enum ExtractionError: Error, CustomStringConvertible {
    // --- Top-level parsing ---
    case invalidEmail(reason: String)
    case malformedHeaders(reason: String)
    case unsupportedFormat(reason: String)
    case missingRequiredHeader(String)
    case recursionLimitExceeded

    // --- MIME/Body Extraction ---
    case bodyDecodingFailed(reason: String)
    case htmlDecodingFailed(reason: String)
    case charsetDecodingFailed(charset: String, underlying: Error?)
    case quotedPrintableDecodingFailed(reason: String)
    case base64DecodingFailed(reason: String)
    case unsupportedEncoding(String)
    case multipartParseFailed(reason: String)
    case attachmentExtractionFailed(filename: String?, reason: String)

    // --- Attachment/File I/O ---
    case fileSavingFailed(filename: String, underlying: Error)
    case fileTooLarge(filename: String, size: Int)
    case tempDirectoryUnavailable
    case fileNameSanitizationFailed(input: String)

    // --- Utility/Other ---
    case decodingFailed
    case unknownError(underlying: Error?)

    /// Human-readable error messages (for logging/UI)
    public var description: String {
        switch self {
        case .invalidEmail(let reason):
            return "Invalid email: \(reason)"
        case .malformedHeaders(let reason):
            return "Malformed headers: \(reason)"
        case .unsupportedFormat(let reason):
            return "Unsupported format: \(reason)"
        case .missingRequiredHeader(let header):
            return "Missing required header: \(header)"
        case .recursionLimitExceeded:
            return "Recursion limit exceeded in MIME tree."
        case .bodyDecodingFailed(let reason):
            return "Failed to decode email body: \(reason)"
        case .htmlDecodingFailed(let reason):
            return "Failed to decode HTML body: \(reason)"
        case .charsetDecodingFailed(let charset, let underlying):
            return "Charset decoding failed (\(charset)): \(underlying?.localizedDescription ?? "Unknown error")"
        case .quotedPrintableDecodingFailed(let reason):
            return "Quoted-printable decoding failed: \(reason)"
        case .base64DecodingFailed(let reason):
            return "Base64 decoding failed: \(reason)"
        case .unsupportedEncoding(let enc):
            return "Unsupported encoding: \(enc)"
        case .multipartParseFailed(let reason):
            return "Multipart parsing failed: \(reason)"
        case .attachmentExtractionFailed(let filename, let reason):
            return "Attachment extraction failed (\(filename ?? "unnamed")): \(reason)"
        case .fileSavingFailed(let filename, let err):
            return "File saving failed (\(filename)): \(err.localizedDescription)"
        case .fileTooLarge(let filename, let size):
            return "File too large (\(filename)): \(size) bytes"
        case .tempDirectoryUnavailable:
            return "Temporary directory unavailable"
        case .fileNameSanitizationFailed(let input):
            return "File name sanitization failed for input: \(input)"
        case .decodingFailed:
            return "General decoding failed."
        case .unknownError(let err):
            return "Unknown error: \(err?.localizedDescription ?? "No details")"
        }
    }
}
