import SwiftUI
import TipKit

struct ImportEmailsTip: Tip {
    var title: Text {
        Text("Import Your Email Archive")
    }

    var message: Text? {
        Text("Drag and drop .mbox, .eml, .msg, or .pst files to get started. All processing happens on-device.")
    }

    var image: Image? {
        Image(systemName: "envelope.arrow.triangle.branch")
    }
}

struct AIAssistantTip: Tip {
    static let emailsImported = Event(id: "emailsImported")

    var title: Text {
        Text("Ask AI About Your Emails")
    }

    var message: Text? {
        Text("Use the AI Assistant to search, summarize, and analyze your emails using on-device Apple Intelligence.")
    }

    var image: Image? {
        Image(systemName: "brain")
    }

    var rules: [Rule] {
        #Rule(Self.emailsImported) {
            $0.donations.count >= 1
        }
    }
}

struct ForensicModeTip: Tip {
    static let emailsViewed = Event(id: "emailsViewed")

    var title: Text {
        Text("Enable Forensic Mode")
    }

    var message: Text? {
        Text("Tag emails as evidence, verify integrity with SHA-256 hashes, and export audit logs for legal review.")
    }

    var image: Image? {
        Image(systemName: "shield.checkered")
    }

    var rules: [Rule] {
        #Rule(Self.emailsViewed) {
            $0.donations.count >= 5
        }
    }
}

struct SearchTip: Tip {
    static let emailsImported = Event(id: "searchTipEmailsImported")

    var title: Text {
        Text("Powerful Search")
    }

    var message: Text? {
        Text("Use boolean operators (AND, OR, NOT), regex patterns, and proximity search to find exactly what you need.")
    }

    var image: Image? {
        Image(systemName: "magnifyingglass")
    }

    var rules: [Rule] {
        #Rule(Self.emailsImported) {
            $0.donations.count >= 1
        }
    }
}

struct KeyboardShortcutsTip: Tip {
    static let emailsTagged = Event(id: "emailsTagged")

    var title: Text {
        Text("Keyboard Shortcuts")
    }

    var message: Text? {
        Text("Press ⌘1-5 to tag emails, ⌘K for AI Assistant, and ⌘⇧F for Forensic Mode.")
    }

    var image: Image? {
        Image(systemName: "keyboard")
    }

    var rules: [Rule] {
        #Rule(Self.emailsTagged) {
            $0.donations.count >= 3
        }
    }
}

struct TranslationTip: Tip {
    var title: Text {
        Text("Translate Emails")
    }

    var message: Text? {
        Text("Tap the translate button to translate email content using Apple's on-device Translation framework.")
    }

    var image: Image? {
        Image(systemName: "translate")
    }
}

struct TagPickerTip: Tip {
    static let emailsViewed = Event(id: "tagPickerEmailsViewed")

    var title: Text {
        Text("Quick Tag Emails")
    }

    var message: Text? {
        Text("Click the tag icon in the email list to quickly categorize emails by type, sentiment, or evidence status.")
    }

    var image: Image? {
        Image(systemName: "tag")
    }

    var rules: [Rule] {
        #Rule(Self.emailsViewed) {
            $0.donations.count >= 2
        }
    }
}

struct AIToggleTip: Tip {
    static let filtersUsed = Event(id: "aiToggleFiltersUsed")

    var title: Text {
        Text("AI Classification")
    }

    var message: Text? {
        Text("Toggle the AI button to enable sentiment analysis, priority scoring, phishing detection, and topic classification — all processed on-device.")
    }

    var image: Image? {
        Image(systemName: "brain")
    }

    var rules: [Rule] {
        #Rule(Self.filtersUsed) {
            $0.donations.count >= 2
        }
    }
}

struct ProToggleTip: Tip {
    static let filtersUsed = Event(id: "proToggleFiltersUsed")

    var title: Text {
        Text("Advanced Features")
    }

    var message: Text? {
        Text("Toggle Pro to access forensic analysis, evidence tagging, legal hold, Bates numbering, and e-discovery tools.")
    }

    var image: Image? {
        Image(systemName: "gearshape")
    }

    var rules: [Rule] {
        #Rule(Self.filtersUsed) {
            $0.donations.count >= 3
        }
    }
}

struct SearchSyntaxTip: Tip {
    static let searchUsed = Event(id: "searchSyntaxSearchUsed")

    var title: Text {
        Text("Search Syntax")
    }

    var message: Text? {
        Text("Try: budget AND report · from:alice · /regex/ · \"word1\" NEAR/5 \"word2\" · has:attachment")
    }

    var image: Image? {
        Image(systemName: "text.magnifyingglass")
    }

    var rules: [Rule] {
        #Rule(Self.searchUsed) {
            $0.donations.count >= 3
        }
    }
}
