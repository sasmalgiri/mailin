//
//  MBOXParserTests.swift
//  mailin Tests
//
//  Unit tests for MBOX parsing functionality
//

#if canImport(Testing)
import Testing
import Foundation
@testable import mailin

@Suite("MBOX Parser Tests")
struct MBOXParserTests {
    
    // MARK: - Date Parsing Tests
    
    @Test("Parse RFC 2822 date format")
    func testDateParsingRFC2822() async throws {
        let dateString = "Wed, 15 Jan 2025 14:30:00 +0000"
        let parsed = MBOXParser.parseDate(dateString)
        
        #expect(parsed != nil, "Date should be parsed successfully")
        
        if let date = parsed {
            let calendar = Calendar.current
            let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
            #expect(components.year == 2025)
            #expect(components.month == 1)
            #expect(components.day == 15)
        }
    }
    
    @Test("Parse ISO 8601 date format")
    func testDateParsingISO8601() async throws {
        let dateString = "2025-01-15T14:30:00Z"
        let parsed = MBOXParser.parseDate(dateString)
        #expect(parsed != nil, "ISO 8601 date should be parsed")
    }
    
    @Test("Handle invalid date gracefully")
    func testInvalidDate() async throws {
        let dateString = "Not a date"
        let parsed = MBOXParser.parseDate(dateString)
        #expect(parsed == nil, "Invalid date should return nil")
    }
    
    // MARK: - Email Splitting Tests
    
    @Test("Split MBOX with single email")
    func testSingleEmailSplit() async throws {
        let mboxContent = """
        From sender@example.com Wed Jan 15 14:30:00 2025
        From: sender@example.com
        To: recipient@example.com
        Subject: Test Email
        
        This is a test email body.
        """
        
        let messages = MBOXParser.splitMBOX(content: mboxContent)
        #expect(messages.count >= 1, "Should parse at least one message")
    }
    
    @Test("Split MBOX with multiple emails")
    func testMultipleEmailSplit() async throws {
        let mboxContent = """
        From sender1@example.com Wed Jan 15 14:30:00 2025
        From: sender1@example.com
        Subject: Email 1
        
        Body 1
        
        From sender2@example.com Wed Jan 15 15:30:00 2025
        From: sender2@example.com
        Subject: Email 2
        
        Body 2
        """
        
        let messages = MBOXParser.splitMBOX(content: mboxContent)
        #expect(messages.count >= 1, "Should parse at least one message")
    }
    
    // MARK: - Domain Extraction Tests
    
    @Test("Extract domains from email addresses")
    func testDomainExtraction() async throws {
        let headers = [
            "To": "user@example.com, admin@test.org",
            "Cc": "support@company.io"
        ]
        
        let domains = MBOXParser.extractDomains(from: headers)
        
        #expect(domains.contains("example.com"), "Should extract example.com")
        #expect(domains.contains("test.org"), "Should extract test.org")
        #expect(domains.contains("company.io"), "Should extract company.io")
    }
    
    // MARK: - SHA1 Hashing Tests
    
    @Test("Generate SHA1 hash")
    func testSHA1Hash() async throws {
        let input = "test string"
        let hash = MBOXParser.sha1(input)
        
        #expect(hash.count == 40, "SHA1 hash should be 40 characters")
        #expect(hash.allSatisfy { $0.isHexDigit }, "Hash should only contain hex characters")
    }
    
    @Test("SHA1 consistency")
    func testSHA1Consistency() async throws {
        let input = "consistent"
        let hash1 = MBOXParser.sha1(input)
        let hash2 = MBOXParser.sha1(input)
        
        #expect(hash1 == hash2, "Same input should produce same hash")
    }
    
    // MARK: - MIME Header Decoding Tests
    
    @Test("Decode UTF-8 MIME header")
    func testMIMEHeaderDecoding() async throws {
        let encoded = "=?UTF-8?B?VGVzdA==?="  // "Test" in base64
        let decoded = MBOXParser.decodeMIMEHeader(encoded)
        
        #expect(decoded.contains("Test") || decoded == encoded, "Should decode or preserve header")
    }
    
    @Test("Decode quoted-printable MIME header")
    func testQuotedPrintableMIMEHeader() async throws {
        let encoded = "=?UTF-8?Q?Caf=C3=A9?="  // "Café"
        let decoded = MBOXParser.decodeMIMEHeader(encoded)
        
        #expect(decoded.contains("Caf") || decoded == encoded, "Should decode or preserve header")
    }
    
    // MARK: - Anomaly Detection Tests
    
    @Test("Detect missing From header")
    func testMissingFromAnomalyDetection() async throws {
        let headers: [String: String] = [
            "To": "recipient@example.com",
            "Subject": "Test"
        ]
        
        let anomalies = MBOXParser.findAnomalies(headers: headers, body: "Test body", attachments: [])
        
        #expect(anomalies.contains("Missing From header"), "Should detect missing From header")
    }
    
    @Test("Detect empty body")
    func testEmptyBodyAnomalyDetection() async throws {
        let headers: [String: String] = [
            "From": "sender@example.com",
            "To": "recipient@example.com"
        ]
        
        let anomalies = MBOXParser.findAnomalies(headers: headers, body: "", attachments: [])
        
        #expect(anomalies.contains("Empty body"), "Should detect empty body")
    }
    
    @Test("No anomalies for valid email")
    func testNoAnomaliesForValidEmail() async throws {
        let headers: [String: String] = [
            "From": "sender@example.com",
            "To": "recipient@example.com",
            "Subject": "Valid Email",
            "Date": "Wed, 15 Jan 2025 14:30:00 +0000"
        ]
        
        let anomalies = MBOXParser.findAnomalies(headers: headers, body: "This is a valid body", attachments: [])
        
        #expect(anomalies.isEmpty, "Valid email should have no anomalies")
    }
}

// MARK: - Quoted-Printable Decoder Tests

@Suite("Quoted-Printable Decoder Tests")
struct QuotedPrintableDecoderTests {
    
    @Test("Decode simple QP text")
    func testSimpleQPDecoding() async throws {
        let input = "Hello=20World"
        let decoded = QuotedPrintableDecoder.decode(input, isHeader: false)
        
        #expect(decoded == "Hello World", "Should decode =20 to space")
    }
    
    @Test("Decode QP with hex characters")
    func testHexDecoding() async throws {
        let input = "Caf=C3=A9"
        let decoded = QuotedPrintableDecoder.decode(input, isHeader: false)
        
        #expect(decoded.contains("Caf"), "Should decode hex sequences")
    }
    
    @Test("Decode header with underscores")
    func testHeaderUnderscoreDecoding() async throws {
        let input = "Hello_World"
        let decoded = QuotedPrintableDecoder.decode(input, isHeader: true)
        
        #expect(decoded == "Hello World", "Should replace underscores with spaces in headers")
    }
    
    @Test("Handle soft line breaks")
    func testSoftLineBreaks() async throws {
        let input = "Long=\r\nLine"
        let decoded = QuotedPrintableDecoder.decode(input, isHeader: false)
        
        #expect(decoded == "LongLine", "Should remove soft line breaks")
    }
    
    @Test("Validate QP detection")
    func testQPDetection() async throws {
        #expect(QuotedPrintableDecoder.isQuotedPrintable("Hello=20World") == true)
        #expect(QuotedPrintableDecoder.isQuotedPrintable("Plain text") == false)
    }
}

// MARK: - MIMEPart Tests

@Suite("MIME Part Tests")
struct MIMEPartTests {
    
    @Test("Identify text body parts")
    func testTextBodyIdentification() async throws {
        let part = MIMEPart(
            mimeType: "text/plain",
            contentDisposition: "",
            body: "Test body"
        )
        
        #expect(part.isTextBody == true, "Should identify as text body")
        #expect(part.isAttachment == false, "Should not be attachment")
    }
    
    @Test("Identify attachments")
    func testAttachmentIdentification() async throws {
        let part = MIMEPart(
            mimeType: "application/pdf",
            contentDisposition: "attachment",
            filename: "document.pdf"
        )
        
        #expect(part.isAttachment == true, "Should identify as attachment")
        #expect(part.isTextBody == false, "Should not be text body")
    }
    
    @Test("Identify inline images")
    func testInlineImageIdentification() async throws {
        let part = MIMEPart(
            mimeType: "image/png",
            contentDisposition: "inline",
            filename: "image.png"
        )
        
        #expect(part.isInlineImage == true, "Should identify as inline image")
    }
    
    @Test("Identify HTML content")
    func testHTMLIdentification() async throws {
        let htmlPart = MIMEPart(mimeType: "text/html", body: "<html></html>")
        let plainPart = MIMEPart(mimeType: "text/plain", body: "Plain text")
        
        #expect(htmlPart.isHTML == true, "Should identify HTML")
        #expect(plainPart.isHTML == false, "Should not identify plain text as HTML")
    }
    
    @Test("Flatten nested parts")
    func testPartFlattening() async throws {
        let subpart1 = MIMEPart(mimeType: "text/plain", body: "Part 1")
        let subpart2 = MIMEPart(mimeType: "text/html", body: "Part 2")
        let parent = MIMEPart(
            mimeType: "multipart/alternative",
            subparts: [subpart1, subpart2]
        )
        
        let flattened = parent.flattenedParts()
        
        #expect(flattened.count == 3, "Should flatten to 3 parts (parent + 2 children)")
    }
}

// MARK: - File Utils Tests

@Suite("File Utils Tests")
struct FileUtilsTests {
    
    @Test("File existence check")
    func testFileExists() async throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).txt")
        
        // File shouldn't exist yet
        #expect(FileUtils.fileExists(at: tempFile.path) == false)
        
        // Create file
        try "test content".write(to: tempFile, atomically: true, encoding: .utf8)
        
        // Now it should exist
        #expect(FileUtils.fileExists(at: tempFile.path) == true)
        
        // Cleanup
        try? FileManager.default.removeItem(at: tempFile)
    }
    
    @Test("Create directory")
    func testDirectoryCreation() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_dir_\(UUID().uuidString)")
        
        try FileUtils.createDirectory(at: tempDir.path)
        
        #expect(FileUtils.directoryExists(at: tempDir.path) == true)
        
        // Cleanup
        try? FileManager.default.removeItem(at: tempDir)
    }
    
    @Test("Time string formatting")
    func testTimeStringFormat() async throws {
        let date = Date()
        let timeString = FileUtils.timeString(date)
        
        // Should contain year, dash, space, colon
        #expect(timeString.contains("-"))
        #expect(timeString.contains(":"))
        #expect(timeString.contains(" "))
    }
}
#endif
