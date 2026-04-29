//
//  FileUtils.swift
//  mailin/mailboxlib
//  Ultra-Enterprise Grade
//

import Foundation

#if os(macOS) || os(Linux)
import Darwin
#else
import Glibc
#endif

#if canImport(CryptoKit)
import CryptoKit
#endif



    // You can add instance-level wrappers for more methods as needed


// MARK: - Errors & Policy

public enum FileUtilsError: Error, CustomStringConvertible {
    case fileExists, fileNotFound, cannotCreateFile, cannotLockFile, cannotUnlockFile, cannotRemoveFile, cannotRenameFile, backupFailed
    case sandboxViolation(path: String), permissionDenied(path: String)
    case unknownError(err: Int32), hashMismatch

    public var description: String {
        switch self {
        case .fileExists: return "File already exists"
        case .fileNotFound: return "File not found"
        case .cannotCreateFile: return "Cannot create file"
        case .cannotLockFile: return "Cannot lock file"
        case .cannotUnlockFile: return "Cannot unlock file"
        case .cannotRemoveFile: return "Cannot remove file"
        case .cannotRenameFile: return "Cannot rename file"
        case .backupFailed: return "File backup failed"
        case .sandboxViolation(let path): return "Sandbox violation: \(path)"
        case .permissionDenied(let path): return "Permission denied: \(path)"
        case .unknownError(let err): return "Unknown error: \(err)"
        case .hashMismatch: return "File hash mismatch"
            
        }
    }
}

// MARK: - Policy & Security

public struct FileUtilsPolicy {
    public static var sandboxRoot: String? = nil
    public static var allowedSubdirs: [String] = []
    public static var dryRun: Bool = false
    public static var failOnViolation: Bool = true
    public static var violationHandler: ((_ path: String, _ msg: String) -> Void)? = nil
    public static var allowedUser: String? = nil // Only allow access as this user (by name)
    public static var allowedGroup: String? = nil
    public static var warnOnLoosePermissions: Bool = true
}

// MARK: - Logging & Auditing

public enum LogLevel: Int { case none = 0, error, warning, info, debug, verbose }
public class FileUtilsAudit {
    public static var logs: [(Date, String, String)] = []
    public static var level: LogLevel = .info
    public static var plugins: [(_ event: String, _ path: String, _ info: [String: Any]) -> Void] = []
    public static func log(_ msg: String, level: LogLevel = .info, path: String = "") {
        guard level.rawValue <= Self.level.rawValue else { return }
        let timestamp = FileUtils.timeString(Date())
        print("[\(timestamp)][\(level)] \(msg)\(path.isEmpty ? "" : " [\(path)]")")
        logs.append((Date(), msg, path))
        for plugin in plugins { plugin(msg, path, [:]) }
    }
    public static func logError(_ err: Error, context: String, path: String = "") {
        log("[Error] \(context): \(err)", level: .error, path: path)
    }
    public static func auditHistory() -> [(Date, String, String)] { logs }
}

// MARK: - Utility / Path / Callers

private func ensureSandbox(_ path: String) throws -> String {
    let abs = (path as NSString).expandingTildeInPath
    if let root = FileUtilsPolicy.sandboxRoot {
        let std = (root as NSString).standardizingPath
        if !abs.hasPrefix(std) {
            let msg = "Sandbox violation: \(abs) not under \(std)"
            FileUtilsAudit.log(msg, level: .error, path: abs)
            if FileUtilsPolicy.failOnViolation {
                FileUtilsPolicy.violationHandler?(abs, msg)
                fatalError(msg)
            }
            throw FileUtilsError.sandboxViolation(path: abs)
        }
    }
    if !FileUtilsPolicy.allowedSubdirs.isEmpty {
        let isAllowed = FileUtilsPolicy.allowedSubdirs.contains { abs.hasPrefix($0) }
        if !isAllowed {
            let msg = "Denied: \(abs) not in allowedSubdirs"
            FileUtilsAudit.log(msg, level: .error, path: abs)
            if FileUtilsPolicy.failOnViolation {
                FileUtilsPolicy.violationHandler?(abs, msg)
                fatalError(msg)
            }
            throw FileUtilsError.permissionDenied(path: abs)
        }
    }
    return abs
}

// MARK: - Final FileUtils Class

public class FileUtils {
    // MARK: - File/Dir Existence and Creation
    
    // Reads a text file as String (UTF-8 by default)
    public static func readTextFile(at path: String, encoding: String.Encoding = .utf8) throws -> String {
        // Do not enforce sandbox here — assume external file was authorized by fileImporter
        return try String(contentsOfFile: path, encoding: encoding)
    }

    public static func readTextFile(url: URL, encoding: String.Encoding = .utf8) throws -> String {
        // Do not enforce sandbox here — assume security-scoped resource is active
        return try String(contentsOf: url, encoding: encoding)
    }


    public static func copyFile(from srcURL: URL, to destURL: URL) throws {
        let spath = srcURL.path
        let dpath = destURL.path
        let fm = FileManager.default
        if fm.fileExists(atPath: dpath) {
            try fm.removeItem(at: destURL)
        }
        try fm.copyItem(at: srcURL, to: destURL)
        FileUtilsAudit.log("Copied file", level: .info, path: "\(spath) → \(dpath)")
    }

    public static func writeString(_ string: String, to url: URL) throws {
        let spath = url.path
        if FileUtilsPolicy.dryRun { return }
        try string.write(to: url, atomically: true, encoding: .utf8)
        FileUtilsAudit.log("Wrote string to file", level: .info, path: spath)
    }

    
    public static func fileExists(at path: String) -> Bool {
        let spath = (try? ensureSandbox(path)) ?? path
        let exists = FileManager.default.fileExists(atPath: spath)
        FileUtilsAudit.log("Checked existence", level: .debug, path: spath)
        return exists
    }
    public static func directoryExists(at path: String) -> Bool {
        var isDir: ObjCBool = false
        let spath = (try? ensureSandbox(path)) ?? path
        let exists = FileManager.default.fileExists(atPath: spath, isDirectory: &isDir)
        FileUtilsAudit.log("Checked dir existence", level: .debug, path: spath)
        return exists && isDir.boolValue
    }
    public static func createDirectory(at path: String, mode: Int = 0o700) throws {
        let spath = try ensureSandbox(path)
        FileUtilsAudit.log("Creating directory", level: .info, path: spath)
        if FileUtilsPolicy.dryRun { return }
        if !directoryExists(at: spath) {
            try FileManager.default.createDirectory(atPath: spath, withIntermediateDirectories: true)
            try setPermissions(path: spath, mode: mode)
        }
        checkPermissions(path: spath)
    }
    public static func removeFile(at path: String) throws {
        let spath = try ensureSandbox(path)
        FileUtilsAudit.log("Removing file", level: .info, path: spath)
        if FileUtilsPolicy.dryRun { return }
        guard fileExists(at: spath) else { throw FileUtilsError.fileNotFound }
        try FileManager.default.removeItem(atPath: spath)
    }
    public static func renameFile(from oldPath: String, to newPath: String) throws {
        let sOld = try ensureSandbox(oldPath), sNew = try ensureSandbox(newPath)
        FileUtilsAudit.log("Renaming file", level: .info, path: sOld)
        if FileUtilsPolicy.dryRun { return }
        try FileManager.default.moveItem(atPath: sOld, toPath: sNew)
    }
    public static func setPermissions(path: String, mode: Int) throws {
        let spath = try ensureSandbox(path)
        let result = chmod(spath, mode_t(mode))
        if result != 0 { throw FileUtilsError.unknownError(err: errno) }
        checkPermissions(path: spath)
    }

    // MARK: - .lock Dotlock Files (with expiry)

    public static var dotLockMaxAge: TimeInterval = 300 // seconds (5 min)
    public static func createDotLock(for path: String) throws -> URL {
        let lockPath = try ensureSandbox(path) + ".lock"
        FileUtilsAudit.log("Creating dotlock", level: .debug, path: lockPath)
        if FileUtilsPolicy.dryRun { return URL(fileURLWithPath: lockPath) }
        if fileExists(at: lockPath) {
            let age = getAge(path: lockPath)
            if age > dotLockMaxAge { try? removeFile(at: lockPath) }
            else { throw FileUtilsError.fileExists }
        }
        try "".write(toFile: lockPath, atomically: true, encoding: .utf8)
        return URL(fileURLWithPath: lockPath)
    }
    public static func removeDotLock(for path: String) throws {
        let lockPath = try ensureSandbox(path) + ".lock"
        FileUtilsAudit.log("Removing dotlock", level: .debug, path: lockPath)
        if FileUtilsPolicy.dryRun { return }
        if fileExists(at: lockPath) {
            try FileManager.default.removeItem(atPath: lockPath)
        }
    }
    public static func cleanupDotLocks(in dir: String) {
        let spath = (try? ensureSandbox(dir)) ?? dir
        let files = try? FileManager.default.contentsOfDirectory(atPath: spath)
        let now = Date()
        files?.filter { $0.hasSuffix(".lock") }.forEach { fname in
            let fpath = (spath as NSString).appendingPathComponent(fname)
            if let modTime = getModificationTime(path: fpath), now.timeIntervalSince1970 - modTime > dotLockMaxAge {
                try? removeFile(at: fpath)
                FileUtilsAudit.log("Orphaned dotlock removed", level: .warning, path: fpath)
            }
        }
    }

    // MARK: - File Locking (fcntl/flock)

    public static func lockFile(_ handle: FileHandle) throws {
        #if os(macOS) || os(Linux)
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)    // Fixed: Use Int16 not UInt8
        lock.l_start = 0
        lock.l_len = 0
        let result = fcntl(handle.fileDescriptor, F_SETLK, &lock)
        if result != 0 { throw FileUtilsError.cannotLockFile }
        #endif
        FileUtilsAudit.log("File locked", level: .debug)
    }
    public static func unlockFile(_ handle: FileHandle) throws {
        #if os(macOS) || os(Linux)
        var lock = flock()
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        let result = fcntl(handle.fileDescriptor, F_SETLK, &lock)
        if result != 0 { throw FileUtilsError.cannotUnlockFile }
        #endif
        FileUtilsAudit.log("File unlocked", level: .debug)
    }
    public static func syncFile(_ handle: FileHandle) {
        fsync(handle.fileDescriptor)
        FileUtilsAudit.log("File fsync", level: .debug)
    }

    // MARK: - Timed Temp File Expiry & Background Cleanup

    public static var tempFileLifetime: TimeInterval = 86400 // 1 day
    private static var cleanupTask: DispatchSourceTimer?
    public static func startTempFileCleanup() {
        cleanupTask?.cancel()
        cleanupTask = DispatchSource.makeTimerSource(queue: .global())
        cleanupTask?.schedule(deadline: .now(), repeating: 3600)
        cleanupTask?.setEventHandler {
            cleanupExpiredTempFiles()
        }
        cleanupTask?.resume()
    }
    @discardableResult
    public static func createTemporaryFile(prefix: String = "mbox") throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
        let template = tmpDir.appendingPathComponent("\(prefix)_XXXXXXXX").path
        let ctemplate = strdup(template)
        let fd = mkstemp(ctemplate)
        guard fd != -1, let ctemplate = ctemplate else {
            throw FileUtilsError.cannotCreateFile
        }
        close(fd)
        let url = URL(fileURLWithPath: String(cString: ctemplate))
        free(ctemplate)
        FileUtilsAudit.log("Temp file created", level: .debug, path: url.path)
        UserDefaults.standard.set(Date().addingTimeInterval(tempFileLifetime), forKey: "tempfile-\(url.lastPathComponent)")
        return url
    }
    public static func cleanupExpiredTempFiles() {
        let tmpDir = FileManager.default.temporaryDirectory
        let files = try? FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
        let now = Date()
        files?.forEach { fname in
            let key = "tempfile-\(fname)"
            if let expires = UserDefaults.standard.object(forKey: key) as? Date, expires < now {
                let fpath = tmpDir.appendingPathComponent(fname).path
                try? FileManager.default.removeItem(atPath: fpath)
                UserDefaults.standard.removeObject(forKey: key)
                FileUtilsAudit.log("Expired temp file removed", level: .info, path: fpath)
            }
        }
    }
    // MARK: - File Versioning
    public static var maxBackupVersions: Int = 10
    public static func backupFile(at path: String, backupDir: String = "Backups") throws {
        let spath = try ensureSandbox(path)
        guard fileExists(at: spath) else { throw FileUtilsError.fileNotFound }
        let base = (spath as NSString).lastPathComponent
        let timestamp = Int(Date().timeIntervalSince1970)
        let backupRoot = try ensureSandbox(backupDir)
        try createDirectory(at: backupRoot)
        let backupPath = (backupRoot as NSString).appendingPathComponent("\(base).\(timestamp)")
        FileUtilsAudit.log("Backing up file", level: .info, path: backupPath)
        if FileUtilsPolicy.dryRun { return }
        try FileManager.default.copyItem(atPath: spath, toPath: backupPath)
        cleanupOldBackups(for: base, in: backupRoot)
    }
    private static func cleanupOldBackups(for base: String, in backupRoot: String) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: backupRoot)) ?? []
        let myBackups = files.filter { $0.hasPrefix(base + ".") }
            .sorted(by: >)
        if myBackups.count > maxBackupVersions {
            myBackups.dropFirst(maxBackupVersions).forEach { fname in
                let fpath = (backupRoot as NSString).appendingPathComponent(fname)
                try? FileManager.default.removeItem(atPath: fpath)
                FileUtilsAudit.log("Old backup pruned", level: .info, path: fpath)
            }
        }
    }

    // MARK: - Security/Permissions

    public static func checkPermissions(path: String) {
        guard FileUtilsPolicy.warnOnLoosePermissions else { return }
        let spath = (try? ensureSandbox(path)) ?? path
        var statbuf = stat()
        if stat(spath, &statbuf) == 0 {
            if (statbuf.st_mode & S_IWOTH) != 0 {
                FileUtilsAudit.log("World-writable file: \(spath)", level: .warning)
            }
            if (statbuf.st_mode & S_IRWXO) != 0 {
                FileUtilsAudit.log("File is world-accessible: \(spath)", level: .warning)
            }
        }
    }

    // MARK: - Hash-based File Integrity

    public static func fileSHA256(at path: String) throws -> String {
        let spath = try ensureSandbox(path)
        let data = try Data(contentsOf: URL(fileURLWithPath: spath))
        return sha256(data: data)
    }
    private static func sha256(data: Data) -> String {
        #if canImport(CryptoKit)
        return Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
        #else
        // Fallback: Not cryptographically secure, but okay for detection
        return String(data.hashValue)
        #endif
    }

    // MARK: - Miscellaneous

    public static func getModificationTime(path: String) -> TimeInterval? {
        let spath = (try? ensureSandbox(path)) ?? path
        let attr = try? FileManager.default.attributesOfItem(atPath: spath)
        return (attr?[.modificationDate] as? Date)?.timeIntervalSince1970
    }
    public static func getAge(path: String) -> TimeInterval {
        let spath = (try? ensureSandbox(path)) ?? path
        guard let mod = getModificationTime(path: spath) else { return .infinity }
        return Date().timeIntervalSince1970 - mod
    }
    public static var hostname: String {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        gethostname(&buffer, buffer.count)
        return String(cString: buffer)
    }
    public static var processID: Int32 { getpid() }
    public static var currentTime: TimeInterval { Date().timeIntervalSince1970 }
    public static func sleep(seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }
    public static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    // MARK: - Atomic Write

    public static func atomicWrite(data: Data, to path: String) throws {
        let spath = try ensureSandbox(path)
        let tmp = spath + ".tmp"
        try data.write(to: URL(fileURLWithPath: tmp), options: .atomic)
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: spath), withItemAt: URL(fileURLWithPath: tmp))
        FileUtilsAudit.log("Atomic write succeeded", level: .info, path: spath)
    }

    // MARK: - Virtual Path Mapping (for demo/test/sandbox)
    public static var pathMapper: ((String) -> String)? = nil
    private static func mapped(_ path: String) -> String {
        if let map = pathMapper { return map(path) }
        return path
    }

    // MARK: - In-memory Streams

    public static func dataFromFile(at path: String) throws -> Data {
        let spath = try ensureSandbox(path)
        FileUtilsAudit.log("Reading data", level: .debug, path: spath)
        return try Data(contentsOf: URL(fileURLWithPath: spath))
    }
    public static func writeData(_ data: Data, to path: String) throws {
        let spath = try ensureSandbox(path)
        FileUtilsAudit.log("Writing data", level: .info, path: spath)
        if FileUtilsPolicy.dryRun { return }
        try atomicWrite(data: data, to: spath)
    }

    // MARK: - File System Watcher (optional)
    // TODO: Add FSEvents/inotify integration for live mailbox update

    // MARK: - Misc Logging
    public static func info(_ message: String) { FileUtilsAudit.log(message, level: .info) }
    public static func debug(_ message: String) { FileUtilsAudit.log(message, level: .debug) }
    public static func warn(_ message: String) { FileUtilsAudit.log("[Warning] \(message)", level: .warning) }
}

// MARK: - Typealiases and Extensions

public typealias AnyStream = InputStream
public typealias AnyFileHandle = FileHandle

public extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
}
public func appSupportDirectory(appFolder: String = "mailin") throws -> URL {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "FileUtils", code: 1, userInfo: [NSLocalizedDescriptionKey: "Application Support directory not found"])
        }
        let folder = dir.appendingPathComponent(appFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
