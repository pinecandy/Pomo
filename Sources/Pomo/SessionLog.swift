import Foundation

/// One completed/interrupted work-or-break interval, serialized as a single
/// JSONL line so an AI can later answer "what did I spend time on today".
///
/// `reason` says how the interval ended — see `SessionEndReason`, which owns
/// the vocabulary. The values the current app writes are "completed", "pause",
/// "reset" and "note".
struct SessionRecord: Codable, Equatable {
    let start: String
    let end: String
    let seconds: Int
    let phase: String
    let task: String
    let reason: String
    // v2 fields. Optional so the pre-v2 lines already on disk still decode;
    // every write from the current app populates all four.
    let kind: String?
    let timerID: String?
    let sessionID: String?
    let schemaVersion: Int?
    /// A break-time reflection note, logged as its own independent record
    /// (`reason == "note"`). nil on every normal work/break interval.
    let note: String?
}

/// One interval to log, in domain types.
///
/// `SessionRecord` above is the serialization shape — strings and optionals,
/// kept that way so historical lines still decode. This is what callers build,
/// and it is a value object rather than a long parameter list because these
/// fields are one concept that always changes together.
struct SessionEntry {
    let start: Date
    let end: Date
    let seconds: Int
    let phase: Phase
    let task: String
    let reason: SessionEndReason
    let timerID: TimerInstanceID
    let sessionID: TimerInstanceID?
    let kind: TimerKind
    /// Only set on a `.note` record. Optional `var` members get an implicit
    /// `nil` default in the synthesized memberwise init, so interval call
    /// sites simply omit it.
    var note: String?
}

/// Appends session records to `<directory>/sessions.jsonl` — one JSON object
/// per line, append-only. Every operation is best-effort: logging must never
/// crash or block the timer, so failures are logged and swallowed.
///
/// `directory` is a stored property, not a hardcoded path, so a test can point
/// an instance at a temp directory. `applicationSupportDirectory` resolves
/// from the user record and ignores $HOME, so there is no environment-level
/// way to redirect it — injection is the only safe way to exercise the write
/// path without touching the user's real log.
struct SessionLog {
    /// nil when Application Support is unavailable; every operation no-ops.
    let directory: URL?

    static let shared = SessionLog(directory: applicationSupportDirectory)

    /// Intervals shorter than this are dropped as noise.
    static let minimumLoggedSeconds = 5
    /// Schema version stamped on every record this binary writes.
    static let schemaVersion = 2

    static var applicationSupportDirectory: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        return appSupport.appendingPathComponent("Pomo", isDirectory: true)
    }

    var fileURL: URL? {
        directory?.appendingPathComponent("sessions.jsonl")
    }

    // MARK: - Decisions (pure)

    /// Whether an entry is worth a line at all. Note records mark a moment
    /// rather than a duration, so they carry `seconds: 0` and bypass the
    /// noise floor.
    static func shouldLog(_ entry: SessionEntry) -> Bool {
        entry.seconds >= minimumLoggedSeconds || entry.note != nil
    }

    /// The exact record that will be serialized. Separated from the write so
    /// the on-disk shape can be asserted without touching a filesystem.
    static func record(for entry: SessionEntry) -> SessionRecord {
        SessionRecord(
            start: isoFormatter.string(from: entry.start),
            end: isoFormatter.string(from: entry.end),
            seconds: entry.seconds,
            phase: entry.phase.logName,
            task: entry.task,
            reason: entry.reason.rawValue,
            kind: entry.kind.rawValue,
            timerID: entry.timerID.uuidString,
            sessionID: entry.sessionID?.uuidString,
            schemaVersion: schemaVersion,
            note: entry.note
        )
    }

    /// The bytes one entry adds to the file, or nil if it is not logged.
    static func line(for entry: SessionEntry) -> Data? {
        guard shouldLog(entry) else { return nil }
        guard let encoded = try? JSONEncoder().encode(record(for: entry)) else { return nil }
        return encoded + Data("\n".utf8)
    }

    // MARK: - I/O

    /// Keeps file I/O off the main thread, and guarantees two appends can
    /// never interleave mid-line.
    private static let ioQueue = DispatchQueue(label: "pomo.sessionlog")

    /// ISO8601 with a LOCAL timezone offset (e.g. "+09:00"), not UTC "Z" —
    /// matches the schema in the task spec.
    ///
    /// `autoupdatingCurrent`, not `current`: this is a `static let` in a
    /// long-lived menu-bar app, so `TimeZone.current` would snapshot one
    /// concrete zone at first use and keep stamping that offset into
    /// sessions.jsonl after the user travels or changes their Mac's timezone,
    /// until the app is relaunched, with nothing reporting it.
    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        f.timeZone = TimeZone.autoupdatingCurrent
        return f
    }()

    /// Appends one interval. Never throws, never crashes the app.
    func append(_ entry: SessionEntry) {
        guard let lineData = Self.line(for: entry) else { return }
        guard let fileURL = fileURL, let dirURL = directory else {
            NSLog("Pomo: no log directory — session not logged")
            return
        }

        Self.ioQueue.async {
            do {
                try FileManager.default.createDirectory(
                    at: dirURL, withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    defer { try? handle.close() }
                    // `seekToEnd`/`write(contentsOf:)`, NOT the legacy
                    // `seekToEndOfFile`/`write`: those signal failure by
                    // raising an NSFileHandleOperationException, which is not
                    // a Swift error — it unwinds straight past this `catch`
                    // and terminates the process. A full or unmounted volume
                    // would then kill the app mid-session, which is exactly
                    // what this type's never-crash contract forbids.
                    try handle.seekToEnd()
                    try handle.write(contentsOf: lineData)
                } else {
                    try lineData.write(to: fileURL, options: .atomic)
                }
            } catch {
                NSLog("Pomo: failed to write session log — %@", String(describing: error))
            }
        }
    }

    /// Blocks until every queued append has been written. For tests — the app
    /// must never call this, since blocking the main thread is exactly what
    /// `ioQueue` exists to avoid.
    func waitForPendingWrites() {
        Self.ioQueue.sync { }
    }

    /// Ensures the log directory exists (creating it if needed, even if no
    /// session has ever been logged yet) so "Open Logs Folder" always has
    /// somewhere to point Finder at. Returns nil only if the directory is
    /// unavailable.
    @discardableResult
    func ensureDirectoryExists() -> URL? {
        guard let dirURL = directory else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: dirURL, withIntermediateDirectories: true
            )
        } catch {
            // Previously `try?`, which returned the URL of a directory that
            // does not exist. The only caller beeps on nil but otherwise hands
            // the path straight to NSWorkspace, so "Open Logs Folder" did
            // nothing at all instead of reporting the problem.
            NSLog("Pomo: could not create log directory — %@", String(describing: error))
            return nil
        }
        return dirURL
    }
}
