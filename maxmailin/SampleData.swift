//
//  SampleData.swift
//  mailin
//
//  Bundled fictional emails used by the "Try with Sample Data" button on the
//  empty home screen. Lets App Store reviewers and first-time users experience
//  the full app without needing an external email archive.
//
//  All addresses use the reserved .example TLD (RFC 6761) — they cannot
//  resolve to a real domain. Content is entirely fictional.
//

import Foundation

enum SampleData {

    /// Marker tag added to every sample email so they can be filtered out or
    /// removed later from Settings.
    static let sampleTag = "sample"

    static func emails() -> [MBOXParser.RawEmail] {
        let now = Date()
        let calendar = Calendar.current

        func dateBack(_ days: Int, hour: Int = 9, minute: Int = 0) -> Date {
            var comps = calendar.dateComponents([.year, .month, .day], from: calendar.date(byAdding: .day, value: -days, to: now) ?? now)
            comps.hour = hour
            comps.minute = minute
            return calendar.date(from: comps) ?? now
        }

        var emails: [MBOXParser.RawEmail] = []

        // Thread 1: project planning (3 messages)
        let thread1ID = "<thread-project-kickoff@sample.example>"
        emails.append(make(
            id: thread1ID,
            from: "Alex Morgan <alex@acme.example>",
            to: "you@personal.example",
            subject: "Project Aurora kickoff — agenda for Monday",
            date: dateBack(75, hour: 10),
            body: "Hi,\n\nAttaching the kickoff agenda for the Aurora project. We'll cover:\n\n1. Scope and timeline\n2. Team roles\n3. Initial milestones\n4. Risk review\n\nLet me know if you'd like to add anything before Monday at 10am.\n\nThanks,\nAlex",
            threadID: thread1ID,
            tags: ["work"]
        ))
        emails.append(make(
            id: "<re-kickoff-1@sample.example>",
            from: "you@personal.example",
            to: "Alex Morgan <alex@acme.example>",
            subject: "Re: Project Aurora kickoff — agenda for Monday",
            date: dateBack(74, hour: 14),
            body: "Hi Alex,\n\nAgenda looks great. Can we add a 10-minute slot for compliance review at the end? I want to make sure we have the privacy policy items lined up before we start.\n\nSee you Monday.\n\n— Me",
            threadID: thread1ID,
            inReplyTo: thread1ID,
            tags: ["work"]
        ))
        emails.append(make(
            id: "<re-kickoff-2@sample.example>",
            from: "Alex Morgan <alex@acme.example>",
            to: "you@personal.example",
            subject: "Re: Project Aurora kickoff — agenda for Monday",
            date: dateBack(74, hour: 16),
            body: "Good idea — added. Final agenda attached. Looking forward to it.\n\nAlex",
            threadID: thread1ID,
            inReplyTo: "<re-kickoff-1@sample.example>",
            attachments: [att("Aurora-Kickoff-Agenda.pdf", "application/pdf", 142_336)],
            tags: ["work", "important"]
        ))

        // Thread 2: family travel planning (2 messages)
        let thread2ID = "<thread-vacation@sample.example>"
        emails.append(make(
            id: thread2ID,
            from: "Jamie Chen <jamie@bookclub.example>",
            to: "you@personal.example",
            subject: "Cabin weekend — dates?",
            date: dateBack(60, hour: 19),
            body: "Hey! Are you still up for the cabin weekend in October? We have two date options:\n\n- Oct 11–13\n- Oct 18–20\n\nLet me know which one works better and I'll book.",
            threadID: thread2ID,
            tags: ["personal", "family"]
        ))
        emails.append(make(
            id: "<re-cabin-1@sample.example>",
            from: "you@personal.example",
            to: "Jamie Chen <jamie@bookclub.example>",
            subject: "Re: Cabin weekend — dates?",
            date: dateBack(59, hour: 8),
            body: "The 18th works better for me. Can you send the address once you book?\n\nCan't wait!",
            threadID: thread2ID,
            inReplyTo: thread2ID,
            tags: ["personal", "family"]
        ))

        // Receipts and notifications
        emails.append(make(
            id: "<receipt-coffee-1@sample.example>",
            from: "Receipts <receipts@cafe.example>",
            to: "you@personal.example",
            subject: "Your receipt from Bluebird Café",
            date: dateBack(2, hour: 8, minute: 12),
            body: "Thanks for visiting Bluebird Café.\n\n1x Flat White — $4.50\n1x Almond croissant — $3.75\n\nTotal: $8.25\nCard ending 4242\n\nSee you again soon.",
            tags: ["receipts"]
        ))
        emails.append(make(
            id: "<receipt-bookstore@sample.example>",
            from: "Pages Bookshop <noreply@pages.example>",
            to: "you@personal.example",
            subject: "Order confirmed — #PB-99381",
            date: dateBack(11, hour: 21),
            body: "Your order is on the way.\n\n• \"The Lighthouse Garden\" — paperback — $14.99\n• \"Quiet Algorithms\" — paperback — $19.99\n\nSubtotal: $34.98\nShipping: $0.00\nTotal: $34.98\n\nExpected delivery: 3–5 business days.",
            tags: ["receipts"]
        ))

        // Newsletter
        emails.append(make(
            id: "<newsletter-design-12@sample.example>",
            from: "Design Weekly <hello@designweekly.example>",
            to: "you@personal.example",
            subject: "🎨 5 fresh icon sets, a free typeface, and a great podcast",
            date: dateBack(4, hour: 7),
            body: "Here's what caught our eye this week:\n\n1. Outline Mini — a free set of 320 outlined icons\n2. Serif Revival 12 — a free open-source typeface\n3. The Type podcast: Episode 88 with Sara K.\n4. New tutorial: building accessible color palettes\n5. Designer interview: how Maya redesigned her studio\n\nForward to a friend who'd enjoy this!",
            tags: ["newsletters"]
        ))
        emails.append(make(
            id: "<newsletter-news@sample.example>",
            from: "Local Brief <briefing@localbrief.example>",
            to: "you@personal.example",
            subject: "Local Brief — Tuesday morning roundup",
            date: dateBack(8, hour: 6),
            body: "Top stories this morning:\n\n• City council approves new bike lane along Mill Street\n• Spring market returns to Riverside Park this weekend\n• Library extends Sunday hours starting May 1\n• Weather: mild and sunny through Thursday\n\nHave a great day.",
            tags: ["newsletters"]
        ))

        // Work emails
        emails.append(make(
            id: "<work-onboarding-1@sample.example>",
            from: "Priya Anand <priya.anand@acme.example>",
            to: "you@personal.example",
            subject: "Welcome to the team — first-week checklist",
            date: dateBack(45, hour: 11),
            body: "Welcome aboard!\n\nA few things for your first week:\n\n1. Pick up your laptop from reception\n2. Complete the security training (link below)\n3. Schedule a 1:1 with each direct teammate\n4. Read the team handbook (attached)\n\nPing me anytime if anything is unclear.\n\nPriya",
            attachments: [att("Team-Handbook-v3.pdf", "application/pdf", 894_112)],
            tags: ["work", "important"]
        ))
        emails.append(make(
            id: "<work-q3-results@sample.example>",
            from: "Finance <finance@acme.example>",
            to: "all-staff@acme.example",
            subject: "Q3 results and outlook",
            date: dateBack(30, hour: 17),
            body: "Q3 closed ahead of plan. Highlights:\n\n• Revenue: +14% YoY\n• Operating margin: 22%\n• Customer churn: 1.6%\n• New product launches: 3\n\nFull deck attached. We'll discuss at the all-hands on Friday.",
            attachments: [att("Q3-Review.pdf", "application/pdf", 2_134_004)],
            tags: ["work"]
        ))

        // Travel
        emails.append(make(
            id: "<flight-confirm@sample.example>",
            from: "TripWise <reservations@tripwise.example>",
            to: "you@personal.example",
            subject: "Booking confirmed — TW-A7Q9R2 — May 18",
            date: dateBack(20, hour: 15),
            body: "Your booking is confirmed.\n\nReservation: TW-A7Q9R2\nDeparture: May 18, 7:40 AM — Gate B12\nReturn: May 22, 6:15 PM\nSeat: 14A (window)\n\nCheck-in opens 24 hours before departure.\nManage your booking from the TripWise app.",
            tags: ["travel"]
        ))

        // Reminder / personal
        emails.append(make(
            id: "<dentist-reminder@sample.example>",
            from: "Northbrook Dental <reminder@northbrookdental.example>",
            to: "you@personal.example",
            subject: "Reminder: Cleaning appointment on Tuesday",
            date: dateBack(5, hour: 16),
            body: "Just a friendly reminder of your upcoming cleaning appointment:\n\nTuesday, 10:30 AM\nDr. Patel\nNorthbrook Dental, 14 Aspen Lane\n\nPlease arrive 10 minutes early. Reply STOP to unsubscribe from reminders.",
            tags: ["personal"]
        ))

        // Friend chatter
        emails.append(make(
            id: "<friend-1@sample.example>",
            from: "Sam Riley <sam@personal.example>",
            to: "you@personal.example",
            subject: "Saturday plans?",
            date: dateBack(3, hour: 22),
            body: "Hey,\n\nA few of us are getting together at the park Saturday afternoon. Want to come? Bringing a picnic. Should be relaxed.\n\nLet me know!\n\n— Sam",
            tags: ["personal"]
        ))

        // Newsletter (cooking)
        emails.append(make(
            id: "<newsletter-cooking@sample.example>",
            from: "Quiet Kitchen <hello@quietkitchen.example>",
            to: "you@personal.example",
            subject: "3 sheet-pan dinners + this week's pantry sale",
            date: dateBack(6, hour: 12),
            body: "This week's quick recipes:\n\n• Lemon & oregano chicken with potatoes\n• Maple-glazed salmon with broccoli\n• Halloumi, chickpea, and pepper bake\n\nAll three are under 35 minutes start-to-finish. Recipes inside.",
            tags: ["newsletters"]
        ))

        // Suspicious-looking (anomaly detection demo)
        emails.append(make(
            id: "<suspicious-1@sample.example>",
            from: "Acccount Security <secure-noreply@accounts-helper.example>",
            to: "you@personal.example",
            subject: "Action required: verify your account",
            date: dateBack(7, hour: 3, minute: 14),
            body: "Dear customer,\n\nWe have detected unusual activity on your account. Please click the link below within 24 hours to verify your identity or your account will be suspended.\n\nhttps://accounts-helper.example/verify?token=A8sZ\n\nThank you,\nAccount Security",
            tags: ["suspicious"]
        ))

        // Bills
        emails.append(make(
            id: "<bill-electricity@sample.example>",
            from: "PowerCo <billing@powerco.example>",
            to: "you@personal.example",
            subject: "Your March statement is ready",
            date: dateBack(28, hour: 6),
            body: "Your March statement is now available.\n\nAccount: 4421-8821\nBilling period: Mar 1 – Mar 31\nBalance due: $84.62\nDue date: April 15\n\nView and pay online anytime.",
            tags: ["receipts"]
        ))

        // Personal long message
        emails.append(make(
            id: "<personal-long@sample.example>",
            from: "Mom <mom@personal.example>",
            to: "you@personal.example",
            subject: "Garden update + photos",
            date: dateBack(12, hour: 18),
            body: "Hi sweetheart,\n\nThe garden is finally taking shape. The tomatoes are doing better than last year — I think the new compost made a difference. The basil is going wild as usual, so come pick some when you visit. Dad finally finished the deck stain, which was a bigger project than he expected (you know how he is). The neighbors got a new puppy — a little brown thing who keeps escaping under the fence. We met up with the Williamses last Sunday for coffee, they say hi. Let me know when you'd like to come up for a weekend, we'd love to see you.\n\nLove,\nMom",
            attachments: [att("garden-may.jpg", "image/jpeg", 1_523_004), att("deck-finished.jpg", "image/jpeg", 982_004)],
            tags: ["personal", "family", "important"]
        ))

        // Calendar invite-style
        emails.append(make(
            id: "<calendar-1@sample.example>",
            from: "Calendar <noreply@calendar.example>",
            to: "you@personal.example",
            subject: "Invitation: Coffee with Priya — Thursday 3:00 PM",
            date: dateBack(1, hour: 9),
            body: "You are invited to: Coffee with Priya\n\nWhen: Thursday, 3:00 PM – 3:45 PM\nWhere: Bluebird Café, 22 Aspen Lane\nOrganizer: Priya Anand\n\nReply with Accept / Decline / Maybe.",
            tags: ["work"]
        ))

        // Subscription receipt
        emails.append(make(
            id: "<sub-receipt-1@sample.example>",
            from: "StreamCo <receipts@streamco.example>",
            to: "you@personal.example",
            subject: "Your subscription has renewed",
            date: dateBack(16, hour: 4),
            body: "Hi,\n\nYour StreamCo subscription has renewed for the next billing cycle.\n\nPlan: Standard (Monthly)\nAmount: $9.99\nNext renewal: June 14\n\nYou can change or cancel anytime from your account settings.",
            tags: ["receipts"]
        ))

        // Survey
        emails.append(make(
            id: "<survey-1@sample.example>",
            from: "Pages Bookshop <feedback@pages.example>",
            to: "you@personal.example",
            subject: "How was your recent order? 30-second survey",
            date: dateBack(9, hour: 13),
            body: "Hi,\n\nThanks for your recent purchase. Could you take 30 seconds to let us know how it went? Your feedback helps us improve.\n\nReply STOP to unsubscribe.",
            tags: ["newsletters"]
        ))

        // Confirmation
        emails.append(make(
            id: "<library-hold@sample.example>",
            from: "Riverside Library <holds@riversidelibrary.example>",
            to: "you@personal.example",
            subject: "Your hold is ready: \"Quiet Algorithms\"",
            date: dateBack(14, hour: 10),
            body: "Hi,\n\nThe item you placed on hold is now available:\n\nTitle: Quiet Algorithms\nAuthor: Patel, A.\n\nPlease pick up within 7 days at the Riverside Library main desk.",
            tags: ["personal"]
        ))

        // Workshop registration
        emails.append(make(
            id: "<workshop-1@sample.example>",
            from: "Creative Workshops <workshops@creative.example>",
            to: "you@personal.example",
            subject: "Confirmed: Watercolor basics — May 25",
            date: dateBack(19, hour: 14),
            body: "Your registration is confirmed.\n\nClass: Watercolor Basics\nDate: May 25, 10:00 AM – 12:30 PM\nLocation: Studio 14, 5 Birch Avenue\n\nMaterials provided. Wear something you don't mind getting paint on.",
            tags: ["personal"]
        ))

        // Reply chain — 1-1 colleague
        let thread3ID = "<thread-budget@sample.example>"
        emails.append(make(
            id: thread3ID,
            from: "Lee Park <lee@acme.example>",
            to: "you@personal.example",
            subject: "Budget review — quick question",
            date: dateBack(22, hour: 15),
            body: "Hi,\n\nDo you have 10 minutes today to walk through the Q4 budget? I want to confirm we're aligned on the headcount line before I send it up.\n\nLee",
            threadID: thread3ID,
            tags: ["work"]
        ))
        emails.append(make(
            id: "<re-budget-1@sample.example>",
            from: "you@personal.example",
            to: "Lee Park <lee@acme.example>",
            subject: "Re: Budget review — quick question",
            date: dateBack(22, hour: 15, minute: 30),
            body: "Yes — I'm free at 4. Send me a meet link?",
            threadID: thread3ID,
            inReplyTo: thread3ID,
            tags: ["work"]
        ))

        return emails
    }

    // MARK: - Builders

    private static func make(
        id: String,
        from: String,
        to: String,
        subject: String,
        date: Date,
        body: String,
        threadID: String? = nil,
        inReplyTo: String? = nil,
        attachments: [AttachmentMetadata] = [],
        tags: [String] = []
    ) -> MBOXParser.RawEmail {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let dateString = df.string(from: date)

        var headers: [String: String] = [
            "From": from,
            "To": to,
            "Subject": subject,
            "Date": dateString,
            "Message-ID": id
        ]
        if let inReplyTo { headers["In-Reply-To"] = inReplyTo }

        let raw = """
        From: \(from)
        To: \(to)
        Subject: \(subject)
        Date: \(dateString)
        Message-ID: \(id)
        \(inReplyTo.map { "In-Reply-To: \($0)\n" } ?? "")
        \(body)
        """

        let preview = String(body.prefix(120)).replacingOccurrences(of: "\n", with: " ")

        let allTags = Array(Set(tags + [sampleTag]))

        var email = MBOXParser.RawEmail(
            headers: headers,
            rawSource: raw,
            messageType: "mbox",
            attachments: attachments,
            timestamp: dateString,
            domains: extractDomains(from: [from, to]),
            plainBody: body,
            htmlBody: "",
            mimeDiagnostics: [],
            threadID: threadID,
            inReplyTo: inReplyTo,
            references: nil,
            tags: allTags,
            anomalies: []
        )
        email.bodyPreview = preview
        return email
    }

    private static func att(_ filename: String, _ mime: String, _ size: Int) -> AttachmentMetadata {
        AttachmentMetadata(filename: filename, mimeType: mime, size: size)
    }

    private static func extractDomains(from addresses: [String]) -> [String] {
        let pattern = #"@([\w.-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var domains = Set<String>()
        for address in addresses {
            let range = NSRange(address.startIndex..., in: address)
            regex.enumerateMatches(in: address, range: range) { match, _, _ in
                if let m = match, let r = Range(m.range(at: 1), in: address) {
                    domains.insert(String(address[r]).lowercased())
                }
            }
        }
        return Array(domains).sorted()
    }
}
