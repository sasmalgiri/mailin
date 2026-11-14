//
//  OtherOfficeTextExtractors.swift
//  ArchiveCore
//
//  Plan v4 §13.8 step 4 (COMP-10): the two "other" Microsoft formats that
//  are XML and can be read without a new adapter project:
//
//    Visio drawing (.vsdx / .vsdm / .vstx) — a ZIP; visio/pages/pages.xml
//    names the pages, each page part holds Shapes whose <Text> is the
//    drawing's words. Read as [Page: <name>], one line per shape.
//
//    Project XML (.xml saved by Microsoft Project, MSPDI) — one XML file
//    with the schemas.microsoft.com/project namespace. Read as
//    [Project: <name>], [Tasks] "ID  Name  Start  Finish  Notes",
//    [Resources] names, [Assignments] task/resource ids.
//
//  OneNote, binary Visio (.vsd), Project (.mpp), Publisher and Access stay
//  unread and say so in the registry.
//

import Foundation

enum VisioTextExtractor {

    static func extract(fileURL: URL) throws -> OfficeTextExtractor.Result {
        let members: [ZIPArchiveReader.Member]
        do { members = try ZIPArchiveReader.members(of: fileURL) } catch {
            throw OfficeTextExtractor.ExtractError.notAPackage(String(describing: error))
        }
        let scratch = try DocumentTextExtractor.scratchDirectory("visio")
        defer { try? FileManager.default.removeItem(at: scratch) }
        var parts: [String: ZIPArchiveReader.Member] = [:]
        var notText: [String] = []
        for member in members where !member.isDirectory {
            if member.name.hasPrefix("visio/media/") { notText.append(member.name) } else { parts[member.name] = member }
        }
        var skipped: [String] = []
        func bytes(_ name: String) throws -> Data? {
            guard let member = parts[name] else { return nil }
            let partLimit = ExtractionLimits.effective.partBytes
            guard member.uncompressedSize <= partLimit else {
                skipped.append("\(name) (\(member.uncompressedSize) bytes, over the \(partLimit)-byte guard)")
                return nil
            }
            return try DocumentTextExtractor.memberData(member, from: fileURL, scratch: scratch)
        }
        // Page names and their parts.
        var nameByFile: [String: String] = [:]
        if let pagesData = try bytes("visio/pages/pages.xml") {
            let index = VisioPagesCollector()
            if index.parse(pagesData), let relsData = try bytes("visio/pages/_rels/pages.xml.rels") {
                let rels = OOXMLTextCollector(.raw)
                if rels.parse(relsData) {
                    var targetByID: [String: String] = [:]
                    for rel in rels.relationships { targetByID[rel.id] = OfficeTextExtractor.resolve("visio/pages", rel.target) }
                    for page in index.pages { if let file = targetByID[page.relID] { nameByFile[file] = page.name } }
                }
            }
        }
        let pageFiles = parts.keys.filter { $0.hasPrefix("visio/pages/page") && $0.hasSuffix(".xml") && !$0.hasSuffix("pages.xml") }
            .sorted { OfficeTextExtractor.sheetNumber($0) < OfficeTextExtractor.sheetNumber($1) }
        if pageFiles.isEmpty && skipped.isEmpty { throw OfficeTextExtractor.ExtractError.noTextParts }
        var text = ""
        var components: [String] = []
        for file in pageFiles {
            guard let data = try bytes(file) else { continue }
            let collector = VisioShapeTextCollector()
            guard collector.parse(data) else { skipped.append("\(file) (malformed XML)"); continue }
            let label = "Page: " + (nameByFile[file] ?? "Page \(OfficeTextExtractor.sheetNumber(file))")
            components.append(label)
            text += "[\(label)]\n" + collector.lines.joined(separator: "\n") + "\n"
        }
        return OfficeTextExtractor.Result(text: text, components: components, skipped: skipped, notText: notText.sorted())
    }
}

/// visio/pages/pages.xml: `<Page Name="…"><Rel r:id="rIdN"/></Page>`.
final class VisioPagesCollector: NSObject, XMLParserDelegate {
    struct Page { let name: String; let relID: String }
    private(set) var pages: [Page] = []
    private var currentName: String?
    private var failed = false

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        return parser.parse() && !failed
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "Page" { currentName = attributes["Name"] ?? attributes["NameU"] ?? "Page" }
        if name == "Rel", let page = currentName {
            let rid = attributes["r:id"] ?? attributes.first { $0.key.hasSuffix(":id") }?.value ?? ""
            pages.append(Page(name: page, relID: rid))
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.hasSuffix("Page") { currentName = nil }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { failed = true }
}

/// A Visio page part: every shape's `<Text>` as one line (field and
/// paragraph markers inside it carry no words of their own).
final class VisioShapeTextCollector: NSObject, XMLParserDelegate {
    private(set) var lines: [String] = []
    private var current = ""
    private var textDepth = 0
    private var failed = false

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        return parser.parse() && !failed
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "Text" { textDepth += 1; if textDepth == 1 { current = "" } }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if textDepth > 0 { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "Text" {
            textDepth -= 1
            if textDepth == 0 {
                let line = current.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty { lines.append(line) }
            }
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { failed = true }
}

enum ProjectXMLTextExtractor {

    static let namespaceMarker = "schemas.microsoft.com/project"

    /// True when the first bytes name the Project XML namespace.
    static func looksLikeProjectXML(_ head: Data) -> Bool {
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else { return false }
        return text.contains("<Project") && text.contains(namespaceMarker)
    }

    static func extract(fileURL: URL) throws -> OfficeTextExtractor.Result {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard Int64(data.count) <= ExtractionLimits.effective.partBytes else {
            return OfficeTextExtractor.Result(text: "", components: [], skipped: ["\(fileURL.lastPathComponent) (\(data.count) bytes, over the \(ExtractionLimits.effective.partBytes)-byte guard)"], notText: [])
        }
        let collector = ProjectXMLCollector()
        guard collector.parse(data) else { throw OfficeTextExtractor.ExtractError.notAPackage("malformed Project XML") }
        guard !collector.tasks.isEmpty || !collector.resources.isEmpty || !collector.projectName.isEmpty else {
            throw OfficeTextExtractor.ExtractError.noTextParts
        }
        var text = ""
        var components: [String] = []
        if !collector.projectName.isEmpty {
            components.append("Project: " + collector.projectName)
            text += "[Project: \(collector.projectName)]\n\n"
        }
        if !collector.tasks.isEmpty {
            components.append("Tasks")
            text += "[Tasks]\n" + collector.tasks.joined(separator: "\n") + "\n\n"
        }
        if !collector.resources.isEmpty {
            components.append("Resources")
            text += "[Resources]\n" + collector.resources.joined(separator: "\n") + "\n\n"
        }
        if !collector.assignments.isEmpty {
            components.append("Assignments")
            text += "[Assignments]\n" + collector.assignments.joined(separator: "\n") + "\n"
        }
        return OfficeTextExtractor.Result(text: text, components: components, skipped: [], notText: [])
    }
}

/// MSPDI: Project/Name, Tasks/Task (ID, Name, Start, Finish, Notes),
/// Resources/Resource (Name), Assignments/Assignment (TaskUID, ResourceUID).
final class ProjectXMLCollector: NSObject, XMLParserDelegate {
    private(set) var projectName = ""
    private(set) var tasks: [String] = []
    private(set) var resources: [String] = []
    private(set) var assignments: [String] = []
    private var path: [String] = []
    private var current = ""
    private var fields: [String: String] = [:]
    private var failed = false

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        return parser.parse() && !failed
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        path.append(name)
        current = ""
        if name == "Task" || name == "Resource" || name == "Assignment" { fields = [:] }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { current += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.count == 2, path[0] == "Project", name == "Name" { projectName = value }
        if path.count == 4, ["Task", "Resource", "Assignment"].contains(path[2]) { fields[name] = value }
        if path.count == 3 {
            switch name {
            case "Task":
                let line = [fields["ID"] ?? fields["UID"] ?? "", fields["Name"] ?? "", fields["Start"] ?? "", fields["Finish"] ?? "", fields["Notes"] ?? ""]
                    .map { $0.replacingOccurrences(of: "\n", with: " ") }
                if !(fields["Name"] ?? "").isEmpty { tasks.append(line.joined(separator: "\t").trimmingCharacters(in: .whitespaces)) }
            case "Resource":
                if let resource = fields["Name"], !resource.isEmpty { resources.append(resource) }
            case "Assignment":
                if let task = fields["TaskUID"], let resource = fields["ResourceUID"] { assignments.append("task \(task) → resource \(resource)") }
            default: break
            }
        }
        path.removeLast()
        current = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { failed = true }
}
