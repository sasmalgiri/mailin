# App Store Connect — Copy/Paste Guide for mailin

Everything below is ready to paste into App Store Connect.

---

## App Name
```
mailin
```

## Subtitle (30 characters max)
```
Email Archive Analyzer
```

## App Category
```
Primary: Utilities
Secondary: Productivity
```

## App Description (4000 characters max)

```
mailin is a powerful, privacy-first email archive analyzer for Mac. Import your .mbox or .eml files from Gmail Takeout, Thunderbird, Apple Mail, or Outlook — and instantly search, filter, analyze, and export your email history. Everything runs on your device. Nothing leaves your Mac.

IMPORT & BROWSE
• Open .mbox, .eml, and .zip archives from any email provider
• Full MIME and RFC 822 support with attachment handling
• Conversation threading groups related emails together
• Full-text search across subjects, senders, and body content

SMART FILTERS
• Filter by sender, recipient, domain, date range, or labels
• Quick filters for attachments, flagged, unreviewed, and large emails
• Gmail label detection from Google Takeout exports
• Sort by date, sender, subject, or AI-powered priority

ON-DEVICE AI & NLP
• Sentiment analysis — see the emotional tone of every email
• Topic and keyword extraction powered by Apple NaturalLanguage
• Language detection for multilingual archives
• Priority scoring highlights what matters most
• PII and GDPR compliance scanning
• Apple Intelligence support on macOS 26 and later

ANALYTICS DASHBOARD
• Email volume timeline with sent vs. received breakdown
• Top contacts and communication pairs
• Activity heatmap by day and hour
• Attachment type breakdown and email size distribution
• Contact network visualization
• Exportable analytics reports

EXPORT ANYWHERE
• Export as EML, JSON, CSV, or PDF
• Bates-stamped PDF for legal and compliance
• Forensic reports with SHA-256 and MD5 hashes
• Bulk download all attachments at once
• Redacted exports with PII automatically removed

FORENSIC & LEGAL TOOLS
• Tamper-proof audit logging and chain of custody
• Evidence tagging and examiner annotations
• SPF, DKIM, and DMARC authentication analysis
• MIME tree inspection and received chain analysis
• Bates numbering and Concordance load file export

BUILT FOR PRIVACY
• Zero data collection — no analytics, no tracking, no telemetry
• All processing happens on-device using Apple frameworks
• App Sandbox with minimal permissions
• All AI features run on-device — your email data never leaves your Mac

FLEXIBLE PLANS
• Free tier: browse up to 50 emails with basic filtering and NLP
• Pro: unlimited emails, full analytics, AI assistant, all exports
• Choose monthly, yearly, or lifetime — cancel anytime

mailin is built natively with SwiftUI for a fast, fluid Mac experience. Whether you're a journalist investigating a story, a lawyer reviewing evidence, a researcher analyzing communications, or just someone who wants to understand their email history — mailin gives you the tools to do it privately.
```

## Keywords (100 characters max, comma-separated)

```
mbox,eml,email,archive,analyzer,gmail,takeout,parser,forensic,nlp,sentiment,export,privacy,search
```

## Promotional Text (170 characters max, can be updated without new version)

```
Analyze your email archives privately on your Mac. Import Gmail Takeout, Thunderbird, or Apple Mail — with AI-powered insights, forensic tools, and powerful search.
```

---

## Support URL
```
https://sasmalgiri.github.io/mailin/
```

## Marketing URL (optional)
```
https://sasmalgiri.github.io/mailin/
```

## Privacy Policy URL
```
https://sasmalgiri.github.io/mailin/privacy
```

---

## Age Rating Questionnaire Answers

| Question | Answer |
|----------|--------|
| Cartoon or Fantasy Violence | None |
| Realistic Violence | None |
| Prolonged Graphic or Sadistic Realistic Violence | None |
| Profanity or Crude Humor | None |
| Mature/Suggestive Themes | None |
| Horror/Fear Themes | None |
| Medical/Treatment Information | None |
| Alcohol, Tobacco, or Drug Use or References | None |
| Simulated Gambling | None |
| Sexual Content or Nudity | None |
| Unrestricted Web Access | No |
| Gambling and Contests | No |

**Result: Rated 4+**

---

## App Privacy — Privacy Nutrition Label

In App Store Connect → App Privacy:

**1. Do you or your third-party partners collect data from this app?**
→ Select: **No, we do not collect data from this app.**

That's it. Since mailin collects zero user data, no further questions apply.

---

## App Review Notes (for the reviewer)

```
mailin is an email archive analyzer that parses .mbox and .eml files locally on the user's Mac.

TESTING:
- A demo file (demo_emails.mbox) is included in the app bundle for testing. On launch, click "Select Files" and choose any .mbox or .eml file, or use the demo data.
- Free tier allows up to 50 emails. Pro features (analytics, AI, exports) require a subscription.

ON-DEVICE AI:
- The on-device NLP engine uses Apple's NaturalLanguage framework and works entirely offline.
- Apple Intelligence features require macOS 26 or later with a supported device.
- No cloud AI services are used. All AI processing happens on-device.

SUBSCRIPTIONS:
- Monthly ($2.99/month), Yearly ($19.99/year), Lifetime ($49.99 one-time)
- All subscriptions unlock the same Pro features.

NETWORK ACCESS:
- The app requires network access only for StoreKit (in-app purchases) and optional iCloud sync of forensic metadata. All email processing is offline.

No special demo account is needed. The app works with any .mbox or .eml file.
```

---

## What's New (Version 1.0)

```
Initial release of mailin — your private email archive analyzer for Mac.
```
