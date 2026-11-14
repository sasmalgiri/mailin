//
//  FeatureTutorials+3_0.swift
//  maxmailin
//
//  Help ▸ Feature Guide entries for the 3.0 features (audit 2026-10-17: the guide had none, so a
//  search for "deleted", "script" or "PST" found nothing). Same convention as FeatureTutorials:
//  titles and one-line "what" summaries are localized; longer how-to text is English.
//

import SwiftUI

extension FeatureTutorial {

    static let deletedMailRecovery = FeatureTutorial(
        title: String(localized: "How to Find Deleted Mail"),
        icon: "arrow.counterclockwise.circle",
        overview: "Mail clients often keep deleted messages inside the mailbox file until it is compacted. mailin marks those messages when you import, and says how each one was found. Deep recovery also searches the free space of Outlook files for messages that no folder lists any more.",
        quickStart: "Import the mailbox as usual, then open the Recovered folder in the sidebar or search is:recovered. Settings ▸ Recovery shows the counts and the deep-recovery tools.",
        steps: [
            TutorialStep(title: String(localized: "See What Was Recovered"), icon: "tray.full", color: .orange,
                what: String(localized: "List every deleted message found in your files."),
                how: "Open the Recovered folder in the sidebar, or type is:recovered in the search field. Each recovered email shows an orange banner saying how it was found (a deletion flag, a message not yet purged, and so on).",
                tip: "Recovered mail is evidence of what the files still hold — mailin cannot bring back mail that was purged and overwritten."),
            TutorialStep(title: String(localized: "Check the Counts"), icon: "number", color: .blue,
                what: String(localized: "See how many messages were recovered and how."),
                how: "Settings ▸ Recovery lists the totals by how each message was found, and how many recovered emails are on legal hold.",
                tip: "Save recovery report (CSV) records the list for a case file."),
            TutorialStep(title: String(localized: "Search Free Space (Deep Recovery)"), icon: "scissors", color: .purple,
                what: String(localized: "Look for messages no folder lists any more."),
                how: "In Settings ▸ Recovery choose Carve a file for emails… and pick the Outlook file. mailin reads its unallocated space and adds what it can rebuild, marked as carved.",
                tip: "Deep recovery is part of Professional; finding deleted mail in folders is part of Personal.")
        ],
        tips: [
            TutorialTip(icon: "switch.2", text: "Settings ▸ Modules has a switch for recovery if you do not want deleted mail marked at import."),
            TutorialTip(icon: "lock.shield", text: "Nothing is changed in your original mailbox files; recovery only reads them.")
        ]
    )

    static let scriptsAndShortcuts = FeatureTutorial(
        title: String(localized: "How to Use Scripts and Shortcuts"),
        icon: "curlybraces",
        overview: "Scripts tag, set aside, note and number your own emails automatically. They run on this device with no network access, and every run starts with a dry run that shows each change before anything is written. Shortcuts can call the same actions from the Shortcuts app.",
        quickStart: "Open Settings ▸ Scripts, write a script or build a rule from the menus, run the dry run, then apply.",
        steps: [
            TutorialStep(title: String(localized: "Write or Build a Rule"), icon: "hammer", color: .blue,
                what: String(localized: "Describe which emails to change and how."),
                how: "In Settings ▸ Scripts write a short script, or use the rule builder to pick the conditions and the action from menus — no code needed.",
                tip: "Change one thing at a time and check the dry run after each change."),
            TutorialStep(title: String(localized: "Dry Run First"), icon: "eye", color: .orange,
                what: String(localized: "See every change before it happens."),
                how: "The dry run lists each email the script would change and what it would do. Nothing is written until you apply it.",
                tip: "If the dry run touches more emails than you expect, narrow the conditions."),
            TutorialStep(title: String(localized: "Use It from Shortcuts"), icon: "square.on.square", color: .purple,
                what: String(localized: "Find, tag, hold, number and export emails from the Shortcuts app."),
                how: "Open the Shortcuts app and search for mailin. Its actions work on the archive on this device.",
                tip: "Scripts and Shortcuts actions are part of Professional.")
        ],
        tips: [
            TutorialTip(icon: "wifi.slash", text: "Scripts cannot reach the network; they only see your archive."),
            TutorialTip(icon: "arrow.uturn.backward", text: "Scripts only tag, hold, note and number emails; they never delete mail.")
        ]
    )

    static let reviewTogether = FeatureTutorial(
        title: String(localized: "How to Review Together"),
        icon: "shippingbox",
        overview: "Send a set of emails to someone else for review as a Review Pack and merge their answers back, or run a team case in a shared folder with signed logs, roles and second-level review. Reviewers need no purchase.",
        quickStart: "Select the emails, open Settings ▸ Review Pack and create a pack. Send the file to the reviewer; when their response file comes back, open it to merge.",
        steps: [
            TutorialStep(title: String(localized: "Create a Review Pack"), icon: "shippingbox", color: .blue,
                what: String(localized: "Package a set of emails for a reviewer."),
                how: "In Settings ▸ Review Pack choose the emails to include, then save the .mailinpack file and send it any way you like.",
                tip: "The pack holds only the emails you chose."),
            TutorialStep(title: String(localized: "Merge the Answers"), icon: "arrow.triangle.merge", color: .green,
                what: String(localized: "Bring the reviewer's decisions back into your archive."),
                how: "Open the .mailinresponse file the reviewer returns. mailin checks it belongs to your pack, shows each decision, and merges what you accept.",
                tip: "A response for a pack you did not create is refused."),
            TutorialStep(title: String(localized: "Run a Team Case"), icon: "person.3", color: .purple,
                what: String(localized: "Review with several people in one shared folder."),
                how: "Settings ▸ Team starts a case in a shared folder (for example on a network drive). Each member joins it, works on their batch, and a second reviewer checks the decisions. Every step is written to a signed log.",
                tip: "Leading a case is part of Professional; joining one is free.")
        ],
        tips: [
            TutorialTip(icon: "lock.shield", text: "Packs and case folders stay wherever you put them; mailin never uploads them."),
            TutorialTip(icon: "checkmark.seal", text: "The case log can be verified later to show no entry was changed.")
        ]
    )

    static let hiddenTimestamps = FeatureTutorial(
        title: String(localized: "How to Read Hidden Timestamps"),
        icon: "clock.badge.checkmark",
        overview: "Mail systems record times in places the Date line does not show: Gmail and other services leave time values in message IDs and headers, and DKIM and ARC signatures carry their own signing times. mailin reads them and checks the signatures, so you can see when a message really passed through.",
        quickStart: "Open an email and choose Timestamps & signals.",
        steps: [
            TutorialStep(title: String(localized: "Open Timestamps & Signals"), icon: "clock", color: .blue,
                what: String(localized: "See every time value the message carries."),
                how: "In an open email, tap or click Timestamps & signals. Each value shows where it was found and what it means.",
                tip: "A Date line far from the other times is worth a closer look."),
            TutorialStep(title: String(localized: "Check the Signatures"), icon: "checkmark.seal", color: .green,
                what: String(localized: "See whether DKIM and ARC signatures hold."),
                how: "The same view lists each DKIM and ARC signature, its signing time and whether it verifies. Import the domain's DKIM keys as a text file to check them; mailin never looks keys up online.",
                tip: "A signature that no longer verifies means the signed part of the message changed after it was sent.")
        ],
        tips: [
            TutorialTip(icon: "exclamationmark.triangle", text: "These values show what the headers contain; they do not prove who sent a message."),
            TutorialTip(icon: "briefcase", text: "Hidden timestamps and signature checks are part of Professional.")
        ]
    )

    static let scannedAttachments = FeatureTutorial(
        title: String(localized: "How to Search Scanned Attachments"),
        icon: "doc.text.viewfinder",
        overview: "Scanned PDFs and photos attached to your emails are read on this device by Apple's Vision framework, so attachment search finds the words inside them. Mail already in your archive is read once in the background, and the pass resumes after an interruption.",
        quickStart: "Search with in:attachments followed by a word, for example in:attachments invoice.",
        steps: [
            TutorialStep(title: String(localized: "Search Inside Attachments"), icon: "magnifyingglass", color: .blue,
                what: String(localized: "Find words in PDFs, documents and scans."),
                how: "Type in:attachments and the words you are looking for. Results say they matched in an attachment.",
                tip: "Scans are read once; a new import's scans are read after its text is indexed."),
            TutorialStep(title: String(localized: "Watch the Progress"), icon: "chart.bar", color: .orange,
                what: String(localized: "See how much has been read."),
                how: "While the first pass runs, Running now shows \"scanned text: X of Y emails\". You can keep working; it pauses and resumes by itself.",
                tip: "Settings ▸ Modules has a switch for this if you do not want scans read.")
        ],
        tips: [
            TutorialTip(icon: "wifi.slash", text: "Recognition runs on this device; nothing is sent anywhere."),
            TutorialTip(icon: "exclamationmark.triangle", text: "Text read from a scan can contain recognition errors — check the attachment itself.")
        ]
    )

    static let otherApps = FeatureTutorial(
        title: String(localized: "How to Use mailin with Other Apps"),
        icon: "square.and.arrow.up.on.square",
        overview: "Hand emails to the apps you already use: an Outlook data file (.pst) for anyone who works in Outlook, standard .eml files for DEVONthink, and links that reopen an email in mailin from your notes.",
        quickStart: "Open the Export menu and choose Outlook Archive (.pst), or on the Mac, Send to DEVONthink.",
        steps: [
            TutorialStep(title: String(localized: "Export to Outlook"), icon: "archivebox", color: .blue,
                what: String(localized: "Write emails as one Outlook .pst file."),
                how: "Export ▸ Outlook Archive (.pst) writes the current list — folders, recipients and attachments — into a file that opens in Microsoft Outlook. On the Mac it is also in File ▸ Export as PST.",
                tip: "Very large exports are split into several files, each below the size Outlook accepts."),
            TutorialStep(title: String(localized: "Send to DEVONthink (Mac)"), icon: "tray.and.arrow.up", color: .purple,
                what: String(localized: "Put emails into DEVONthink as standard .eml files."),
                how: "Export ▸ Send to DEVONthink writes the emails as .eml files and opens them in DEVONthink, which imports them into your Global Inbox or chosen group. Without DEVONthink the files open in Finder.",
                tip: "The receipt says whether DEVONthink or Finder received the files."),
            TutorialStep(title: String(localized: "Link to an Email"), icon: "link", color: .green,
                what: String(localized: "Reopen any email from your notes."),
                how: "In an open email choose Copy Link to Email. Paste the mailin:// link into DEVONthink, Notes or any app; clicking it opens that email in mailin.",
                tip: "A link to an email that is no longer in this archive says so.")
        ],
        tips: [
            TutorialTip(icon: "c.circle", text: "Outlook is a trademark of Microsoft Corporation and DEVONthink of DEVONtechnologies; mailin is not affiliated with either.")
        ]
    )
}
