import Foundation
import GRDB

/// GRDB transactions keep a full event snapshot and its annotations consistent.
final class DatabaseJournal {
    private let queue: DatabaseQueue

    private struct Record: Codable {
        var event: SenseEvent
        var annotation: EventAnnotation?
    }

    init(url: URL) throws {
        var configuration = Configuration()
        configuration.busyMode = .timeout(3)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }
        queue = try DatabaseQueue(path: url.path, configuration: configuration)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("event-snapshot-v1") { db in
            try db.create(table: "eventRecord") { table in
                table.column("id", .text).primaryKey()
                table.column("seenAt", .double).notNull().indexed()
                table.column("payload", .blob).notNull()
            }
            try db.create(table: "journalMetadata") { table in
                table.column("key", .text).primaryKey()
                table.column("value", .text).notNull()
            }
        }
        try migrator.migrate(queue)
    }

    func hasSnapshot() throws -> Bool {
        try queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM journalMetadata WHERE key = 'snapshot'") == "1"
        }
    }

    func load() throws -> JournalArchive {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT payload FROM eventRecord ORDER BY seenAt DESC LIMIT 41")
            guard rows.count <= 40 else { throw JournalError.invalid }
            var events: [SenseEvent] = []
            var annotations: [UUID: EventAnnotation] = [:]
            for row in rows {
                let data: Data = row["payload"]
                let item = try JSONDecoder().decode(Record.self, from: data)
                events.append(item.event)
                annotations[item.event.id] = item.annotation
            }
            let raw = try String.fetchOne(db, sql: "SELECT value FROM journalMetadata WHERE key = 'association-splits-v1'")
            guard (raw?.utf8.count ?? 0) <= 200_000 else { throw JournalError.oversized }
            let links = try raw.map { try JSONDecoder().decode([EventPair].self, from: Data($0.utf8)) } ?? []
            return JournalArchive(events: events, annotations: annotations, suppressedLinks: links)
        }
    }

    func save(_ archive: JournalArchive) throws {
        let validated = try archive.validated(since: .distantPast)
        let items = try validated.events.map { event in
            (event, try JSONEncoder().encode(Record(event: event, annotation: validated.annotations[event.id])))
        }
        let links = String(decoding: try JSONEncoder().encode(validated.suppressedLinks), as: UTF8.self)
        try queue.write { db in
            try db.execute(sql: "DELETE FROM eventRecord")
            for (event, payload) in items {
                try db.execute(sql: "INSERT INTO eventRecord (id, seenAt, payload) VALUES (?, ?, ?)",
                               arguments: [event.id.uuidString, event.lastSeen.timeIntervalSince1970, payload])
            }
            try db.execute(sql: "INSERT OR REPLACE INTO journalMetadata (key, value) VALUES ('snapshot', '1')")
            try db.execute(sql: "INSERT OR REPLACE INTO journalMetadata (key, value) VALUES ('association-splits-v1', ?)", arguments: [links])
        }
    }

    func close() throws { try queue.close() }
}
