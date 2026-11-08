import Foundation

/// RFC 4180 CSV reader/writer (quoted fields, `""` escapes, embedded CR/LF, CRLF or LF records,
/// optional UTF-8 BOM). Lenient: a stray quote inside an unquoted field is kept literally.
public enum CSV {
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var fieldStarted = false // distinguishes `""` (empty quoted field) from end-of-input
        var chars = Array(text.unicodeScalars)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        func endField() { row.append(field); field = ""; fieldStarted = false }
        func endRow() { endField(); rows.append(row); row = [] }
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.unicodeScalars.append("\""); i += 1 }
                    else { inQuotes = false }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else {
                switch c {
                case "\"" where field.isEmpty && !fieldStarted:
                    inQuotes = true; fieldStarted = true
                case ",":
                    endField()
                case "\r":
                    if i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                    endRow()
                case "\n":
                    endRow()
                default:
                    field.unicodeScalars.append(c); fieldStarted = true
                }
            }
            i += 1
        }
        if !field.isEmpty || fieldStarted || !row.isEmpty { endRow() }
        // Drop fully blank lines.
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    public static func escape(_ field: String) -> String {
        let needsQuotes = field.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
            || field.hasPrefix(" ") || field.hasSuffix(" ")
        guard needsQuotes else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func serialize(_ rows: [[String]], lineEnding: String = "\r\n") -> String {
        rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: lineEnding) + lineEnding
    }
}

/// One login parsed from an export. Contains a plaintext password: do not log.
public struct ImportedPassword: Sendable, Hashable, CustomStringConvertible {
    public var title: String
    public var url: String
    public var host: String
    public var username: String
    public var password: String
    public var notes: String?
    /// `otpauth://` URI from Apple Passwords. Preserved on import/export but not used for filling
    /// (TOTP generation is out of scope; Security Code AutoFill covers SMS/email codes).
    public var otpAuth: String?
    /// 1-based line number of the record's first line in the source file (header = 1).
    public var line: Int

    public var description: String { "ImportedPassword(line: \(line), host: \(host))" }

    public var credential: Credential {
        Credential(host: host, username: username, password: password, note: notes)
    }
}

public struct CSVImportError: Error, Sendable, Hashable, CustomStringConvertible {
    public enum Reason: Sendable, Hashable {
        case missingHeader
        case missingRequiredColumn(String)
        case wrongFieldCount(expected: Int, found: Int)
        case invalidURL(String)
        case emptyPassword
    }
    public var line: Int
    public var reason: Reason
    public var description: String { "line \(line): \(reason)" }
}

public struct CSVParseResult: Sendable {
    public enum Format: String, Sendable { case applePasswords, chrome, unknownCompatible }
    public var format: Format
    public var items: [ImportedPassword]
    public var errors: [CSVImportError]
}

public struct ImportSummary: Sendable, Equatable {
    public var imported = 0
    /// Same host, username and password already saved.
    public var skippedDuplicates = 0
    /// Same host + username but a different password; skipped unless `overwriteConflicts`.
    public var conflicts = 0
    public var overwritten = 0
    public var failed = 0
    public init() {}
}

/// Parses password CSVs exported by Apple Passwords / Safari
/// (`Title,URL,Username,Password,Notes,OTPAuth`) and Chrome / Chromium browsers
/// (`name,url,username,password,note`). Header names are matched case-insensitively,
/// so column order does not matter and Firefox/Bitwarden-style headers with the same
/// names also work.
public enum PasswordCSVImporter {
    static let aliases: [String: [String]] = [
        "title": ["title", "name"],
        "url": ["url", "website", "login_uri", "login url"],
        "username": ["username", "login", "login_username", "user name", "email"],
        "password": ["password", "login_password"],
        "notes": ["notes", "note", "comments", "extra"],
        "otp": ["otpauth", "otp", "totp", "login_totp"],
    ]

    public static func parse(_ text: String) -> CSVParseResult {
        let records = recordsWithLineNumbers(text)
        guard let (headerLine, header) = records.first else {
            return CSVParseResult(format: .unknownCompatible, items: [], errors: [CSVImportError(line: 1, reason: .missingHeader)])
        }
        let normalized = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func column(_ key: String) -> Int? {
            for alias in aliases[key] ?? [] { if let i = normalized.firstIndex(of: alias) { return i } }
            return nil
        }
        let cURL = column("url"), cUser = column("username"), cPass = column("password")
        let cTitle = column("title"), cNotes = column("notes"), cOTP = column("otp")

        var errors: [CSVImportError] = []
        for (name, idx) in [("URL", cURL), ("Username", cUser), ("Password", cPass)] where idx == nil {
            errors.append(CSVImportError(line: headerLine, reason: .missingRequiredColumn(name)))
        }
        guard let cURL, let cUser, let cPass else {
            return CSVParseResult(format: .unknownCompatible, items: [], errors: errors)
        }

        let format: CSVParseResult.Format =
            normalized.contains("otpauth") && normalized.contains("title") ? .applePasswords
            : normalized.contains("name") && normalized.contains("note") ? .chrome
            : .unknownCompatible

        var items: [ImportedPassword] = []
        for (line, fields) in records.dropFirst() {
            let maxIdx = [cURL, cUser, cPass].max()!
            guard fields.count > maxIdx else {
                errors.append(CSVImportError(line: line, reason: .wrongFieldCount(expected: header.count, found: fields.count)))
                continue
            }
            func value(_ i: Int?) -> String? {
                guard let i, i < fields.count else { return nil }
                let v = fields[i]
                return v.isEmpty ? nil : v
            }
            let urlString = fields[cURL].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let host = host(fromURLString: urlString) else {
                errors.append(CSVImportError(line: line, reason: .invalidURL(urlString)))
                continue
            }
            let password = fields[cPass]
            guard !password.isEmpty else {
                errors.append(CSVImportError(line: line, reason: .emptyPassword))
                continue
            }
            items.append(ImportedPassword(
                title: value(cTitle) ?? host,
                url: urlString,
                host: host,
                username: fields[cUser],
                password: password,
                notes: value(cNotes),
                otpAuth: value(cOTP),
                line: line
            ))
        }
        return CSVParseResult(format: format, items: items, errors: errors)
    }

    /// Extracts a normalized host. Accepts bare hosts (`example.com/login`) and
    /// Chrome's `android://…@com.app/` entries are rejected (no web host).
    public static func host(fromURLString s: String) -> String? {
        guard !s.isEmpty else { return nil }
        var candidate = s
        if !candidate.contains("://") { candidate = "https://" + candidate }
        guard let comps = URLComponents(string: candidate),
              let scheme = comps.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = comps.host, !host.isEmpty
        else { return nil }
        let normalized = RegistrableDomain.normalize(host)
        return normalized.isEmpty ? nil : normalized
    }

    /// Records paired with the 1-based physical line on which each starts.
    static func recordsWithLineNumbers(_ text: String) -> [(Int, [String])] {
        // Re-parse to compute line numbers: count newlines consumed per record.
        let rows = CSV.parse(text)
        var result: [(Int, [String])] = []
        var line = 1
        // Leading blank lines are dropped by CSV.parse; account for them.
        var scalars = Substring(text)
        if scalars.first == "\u{FEFF}" { scalars = scalars.dropFirst() }
        for ch in scalars { if ch == "\n" || ch == "\r\n" { line += 1 } else { break } }
        for row in rows {
            result.append((line, row))
            let embedded = row.reduce(0) { $0 + $1.reduce(0) { $0 + (($1 == "\n" || $1 == "\r\n" || $1 == "\r") ? 1 : 0) } }
            line += 1 + embedded
        }
        return result
    }

    /// Saves parsed items into `store`, skipping exact duplicates (host + username + password,
    /// also duplicates within the file itself). Same host + username with a different password
    /// counts as a conflict and is skipped unless `overwriteConflicts` is true.
    public static func importItems(
        _ items: [ImportedPassword],
        into store: PasswordStore,
        overwriteConflicts: Bool = false
    ) async -> ImportSummary {
        await store.bulkImport(items, overwriteConflicts: overwriteConflicts)
    }

    /// Convenience: parse + import.
    public static func importCSV(
        _ text: String,
        into store: PasswordStore,
        overwriteConflicts: Bool = false
    ) async -> (summary: ImportSummary, errors: [CSVImportError]) {
        let parsed = parse(text)
        var summary = await importItems(parsed.items, into: store, overwriteConflicts: overwriteConflicts)
        summary.failed += parsed.errors.filter {
            switch $0.reason {
            case .missingHeader, .missingRequiredColumn: false
            default: true
            }
        }.count
        return (summary, parsed.errors)
    }
}

extension PasswordStore {
    func bulkImport(_ items: [ImportedPassword], overwriteConflicts: Bool) -> ImportSummary {
        var summary = ImportSummary()
        let existing = (try? allCredentials()) ?? []
        var byKey: [String: Credential] = [:]
        for c in existing { byKey[c.host + "\u{0}" + c.username] = c }
        for item in items {
            let key = item.host + "\u{0}" + item.username
            if let current = byKey[key] {
                let currentPassword = try? rawPassword(for: current)
                if currentPassword == item.password {
                    summary.skippedDuplicates += 1
                    continue
                }
                guard overwriteConflicts else { summary.conflicts += 1; continue }
                var updated = current
                updated.password = item.password
                if let notes = item.notes { updated.note = notes }
                do { try update(updated); summary.overwritten += 1 } catch { summary.failed += 1 }
                continue
            }
            do {
                let saved = try save(item.credential)
                byKey[key] = saved
                summary.imported += 1
            } catch {
                summary.failed += 1
            }
        }
        return summary
    }
}

/// Writes the Apple Passwords CSV format (`Title,URL,Username,Password,Notes,OTPAuth`),
/// which Apple Passwords, Safari, Chrome and Firefox can all import.
public enum PasswordCSVExporter {
    public static let header = ["Title", "URL", "Username", "Password", "Notes", "OTPAuth"]

    /// Credentials must have `password` populated.
    public static func csv(for credentials: [Credential]) -> String {
        var rows = [header]
        for c in credentials {
            rows.append([c.host, "https://\(c.host)/", c.username, c.password ?? "", c.note ?? "", ""])
        }
        return CSV.serialize(rows)
    }

    /// Exports every saved password after a single user-presence check.
    /// The returned string contains plaintext passwords; write it with 0600 permissions.
    public static func exportAll(from store: PasswordStore, reason: String = "export your saved passwords") async throws -> String {
        guard await store.authenticateUser(reason: reason) else { throw PasswordStoreError.userPresenceRequired }
        return csv(for: try await store.allCredentialsWithPasswords())
    }
}

extension PasswordStore {
    func allCredentialsWithPasswords() throws -> [Credential] {
        try allCredentials().map { c in
            var c = c
            c.password = try rawPassword(for: c)
            return c
        }
    }
}
