# mailin

**Email Archive Analyzer for macOS**

A professional, privacy-first macOS app that parses `.mbox` and `.eml` email archives with advanced filtering, reply analytics, AI-powered insights, and export capabilities.

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange)
![License](https://img.shields.io/badge/license-Proprietary-green)

---

## Features

### Advanced Email Parsing
- Full RFC 822 & MIME compliant parser
- Handles multipart messages, nested attachments, base64, quoted-printable encoding
- MIME header decoding (RFC 2047 / RFC 2231)
- Robust handling of malformed emails with anomaly detection

### Smart Filtering
- Filter by sender, recipient, date range, message type (sent/received)
- Full-text search across subjects and headers
- Domain-based filtering
- Real-time filter updates

### Reply Analytics
- Communication pattern tracking
- Reply frequency statistics per contact
- Conversation threading via Message-ID / In-Reply-To / References headers
- Send/receive ratio analysis

### AI Email Assistant
- Natural language queries about your email archive
- "Who did I email the most?"
- "What are the most common subjects?"
- "Show me reply statistics"
- "What's the date range of these emails?"

### Attachment Management
- View, save, and open attachments directly
- Supports PDF, images, Office documents, and more
- Smart file type detection via MIME types and magic bytes
- Inline image rendering in HTML emails

### Export
- Export filtered emails as individual `.eml` files
- JSON session export with full metadata
- Plain text export

### Privacy First
- **100% offline** — all processing happens locally on your Mac
- No data sent to any server, ever
- App Sandbox enabled
- Only accesses files you explicitly select

---

## Screenshots

> *Coming soon*

---

## System Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon or Intel Mac

---

## Installation

### Mac App Store
> *Coming soon*

### Build from Source

1. Clone the repository:
   ```bash
   git clone https://github.com/sasmalgiri/mailin.git
   ```
2. Open `mailin.xcodeproj` in Xcode 15+
3. Build and run (Cmd+R)

---

## Usage

1. Launch mailin
2. Enter your email address (for sent/received detection)
3. Click **Select .mbox File** and choose your email archive
4. Use the sidebar filters to narrow results
5. Click any email to view full content, headers, and attachments
6. Use **Analysis > Ask AI** (Cmd+K) for natural language queries

### Supported Formats
| Format | Extension | Description |
|--------|-----------|-------------|
| MBOX   | `.mbox`   | Standard mailbox format (Gmail Takeout, Thunderbird, etc.) |
| EML    | `.eml`    | Individual email message files |

---

## Architecture

```
mailin/
├── mailinApp.swift              # App entry point, window & menu configuration
├── ContentView.swift            # Main NavigationSplitView with sidebar
├── ContentViewModel.swift       # Parsing logic, progress tracking
├── ParsedEmailListView.swift    # Filtered email list with sort options
├── ParsedEmailListViewModel.swift # Filter state management
├── EmailDetailView.swift        # Email content viewer
├── EmailHTMLView.swift          # HTML email rendering
├── MBOXParser.swift             # Core MBOX parser & utilities
├── MIMEParser.swift             # MIME multipart parsing
├── MIMEPart.swift               # MIME part model & decoding
├── SwiftEmailKit.swift          # Full RFC 822 email message class
├── EmailBodyExtractor.swift     # Recursive MIME body/attachment extraction
├── QuotedPrintableDecoder.swift # QP encoding decoder
├── AIAssistantView.swift        # Chat-style AI assistant
├── AIWindowManager.swift        # Floating AI window
├── FileUtils.swift              # File I/O, locking, temp management
├── DesignSystem.swift           # UI theme & styling
├── SettingsView.swift           # Preferences window
└── AboutView.swift              # About window
```

---

## Tech Stack

- **SwiftUI** — Native macOS interface
- **AppKit** — Window management, NSWorkspace integration
- **Foundation** — Email parsing, date handling, regex
- **CryptoKit** — SHA1/SHA256 for email threading and file integrity
- **Combine** — Reactive state management

---

## Contributing

This is a proprietary project. For bug reports or feature requests, contact [sasmalgiri@gmail.com](mailto:sasmalgiri@gmail.com).

---

## Privacy Policy

mailin does not collect, transmit, or store any personal data on external servers. All email parsing and analysis happens entirely on your device. See the full [Privacy Policy](privacy-policy.html).

---

## License

Copyright 2025 mailin. All rights reserved.

---

*Built with Swift for macOS*
