# mailin

**Privacy-First Email Archive Analyzer for Mac, iPhone, and iPad**

Import, search, analyze, and export email archives from Gmail, Outlook, Thunderbird, Apple Mail, and Lotus Notes — powered by on-device AI. Zero data collection. Everything stays on your device.

![macOS](https://img.shields.io/badge/macOS-14.6+-blue)
![iOS](https://img.shields.io/badge/iOS-17.6+-blue)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange)
![License](https://img.shields.io/badge/license-Proprietary-green)

---

## Supported Formats

| Format | Extension | Source |
|--------|-----------|--------|
| MBOX   | `.mbox`   | Gmail Takeout, Thunderbird, Apple Mail |
| EML    | `.eml`    | Individual email files |
| EMLX   | `.emlx`   | Apple Mail |
| MSG    | `.msg`    | Microsoft Outlook |
| PST    | `.pst`    | Outlook archives |
| OST    | `.ost`    | Outlook offline data |
| NSF    | `.nsf`    | Lotus Notes |
| ZIP    | `.zip`    | Auto-extracts supported formats |

---

## Features

### Import & Parsing
- Full RFC 822 & MIME compliant parser with multipart, base64, quoted-printable support
- Drag-and-drop or file browser import
- Conversation threading via Message-ID / In-Reply-To / References headers
- Streaming parser for large archives (100MB+) with memory-safe batch mode
- Robust handling of malformed emails with anomaly detection

### Search
- Boolean operators (AND / OR / NOT)
- Regex and wildcard search
- Proximity search ("budget" NEAR/5 "deadline")
- BM25 relevance ranking
- Full-text search across subjects, headers, and body content
- Gmail label detection from Google Takeout

### On-Device AI & NLP
- AI Assistant — ask natural language questions about your emails
- Sentiment analysis on every email
- Topic and keyword extraction (Apple NaturalLanguage)
- Priority scoring and smart auto-tagging
- AI Digest — generate archive summaries
- Anomaly detection — flag unusual patterns
- Predictive coding — AI learns relevance as you review
- Near-duplicate detection across your archive
- PII and GDPR compliance scanning
- Language detection (11 languages)
- Apple Intelligence support on macOS 26+

### Analytics Dashboard
- Email volume timeline (sent vs. received)
- Top contacts and communication pairs
- Activity heatmap by day and hour
- Attachment type breakdown and size distribution
- Contact network visualization
- Exportable analytics reports

### Export
- EML, JSON, CSV, PDF, MSG, PST formats
- Bates-stamped PDF for legal compliance
- Forensic reports with SHA-256, SHA-1, MD5 hashes
- Concordance/Relativity load files
- vCard contact export and ICS calendar export
- Bulk attachment download
- Redacted exports with PII removed

### Forensic & Legal Tools
- Tamper-evident HMAC-chained audit log and chain-of-custody artifacts
- Evidence tagging and examiner annotations
- SPF, DKIM, DMARC authentication analysis
- S/MIME signature verification and encryption detection
- Spoofing and phishing detection
- MIME tree inspection and received chain analysis
- Bates numbering and custodian management
- Legal hold marking and review batching
- Investigation report generation

### Additional Features
- Email comparison — side-by-side diff view
- Keyword monitoring and smart alerts
- Automation rules — auto-tag by custom rules
- Encrypted storage (AES-256) and biometric lock
- Spotlight search integration and iCloud sync
- Command palette (Cmd+Shift+P)
- Duplicate detection and removal
- Available in 11 languages

---

## Privacy

- **Zero data collection** — no analytics, no tracking, no telemetry
- **100% on-device** — all processing uses Apple frameworks locally
- **App Sandbox** with minimal permissions
- **No network entitlement** — the app cannot connect to the internet
- Only accesses files you explicitly select

---

## System Requirements

- macOS 14.6 (Sonoma) or later / iOS 17.6 or later
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
3. Click **Select Files** or drag and drop your email archive
4. Use the sidebar filters to narrow results
5. Click any email to view full content, headers, and attachments
6. Use **Cmd+K** for AI Assistant or **Cmd+Shift+P** for Command Palette

---

## Pricing

| | Free | Personal | Professional |
|---|---|---|---|
| Emails | 500 | Unlimited | Unlimited |
| AI Queries | 5/day | Unlimited | Unlimited |
| Search & Filter | Full | Full | Full |
| Analytics | Basic | Full | Full |
| Export | EML, CSV (limited) | All formats | All formats |
| Forensic Mode | — | — | Full |
| Audit Trail | — | — | Full |
| | Free | $4.99/mo or $49.99 lifetime | $9.99/mo or $149.99 lifetime |

---

## Tech Stack

- **SwiftUI** — Native UI for macOS and iOS
- **AppKit / UIKit** — Platform-specific integration
- **NaturalLanguage** — On-device NLP and sentiment analysis
- **CryptoKit** — SHA-256, SHA-1, HMAC for forensic integrity
- **PDFKit** — PDF generation and attachment previews
- **Vision** — OCR on image attachments
- **StoreKit 2** — In-app purchases and subscriptions

---

## Contributing

This is a proprietary project. For bug reports or feature requests, contact [sasmalgiri@gmail.com](mailto:sasmalgiri@gmail.com).

---

## Privacy Policy

mailin does not collect, transmit, or store any personal data on external servers. All email parsing and analysis happens entirely on your device. See the full [Privacy Policy](https://sasmalgiri.github.io/mailin/privacy/).

---

## License

Copyright 2025-2026 EcoSanskriti Innovation Pvt Ltd. All rights reserved.

---

*Built with Swift for Apple platforms*
