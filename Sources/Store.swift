// ClipShelf · 存储层
//
// 一条历史 = 一次剪贴板快照。用 SHA-256 摘要做去重键：
// 同样的内容重复复制不会长出新行，只会把 used 顶到最新。
// 图片本体落在 blobs/<digest>.png，库里只存路径，避免 SQLite 被撑大。

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - 模型

enum ClipKind: String {
    case text
    case image
    case files

    var label: String {
        switch self {
        case .text: return "文本"
        case .image: return "图片"
        case .files: return "文件"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .files: return "folder"
        }
    }
}

struct ClipItem: Identifiable, Equatable, Hashable {
    var id: Int64
    var kind: ClipKind
    var content: String      // 文本正文 / 图片文件路径 / 换行分隔的文件路径
    var preview: String      // 列表里显示的一行摘要
    var source: String       // 复制时前台 App 的名字
    var bytes: Int
    var pinned: Bool
    var created: Double
    var used: Double
    var digest: String

    /// 搜索用的可比较文本
    var searchBlob: String {
        (preview + "\n" + content + "\n" + source).lowercased()
    }

    var sizeText: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = bytes >= 1024 ? [.useKB, .useMB, .useGB] : [.useBytes]
        return f.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - 存储

final class Store {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()

    let dbURL: URL
    let blobDir: URL

    /// - Parameter path: 传 ":memory:" 用于自检和快照渲染
    init(path: String) throws {
        if path == ":memory:" {
            dbURL = URL(fileURLWithPath: path)
            blobDir = URL(fileURLWithPath: NSTemporaryDirectory())
        } else {
            dbURL = URL(fileURLWithPath: path)
            blobDir = dbURL.deletingLastPathComponent().appendingPathComponent("blobs", isDirectory: true)
            try FileManager.default.createDirectory(
                at: dbURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(at: blobDir, withIntermediateDirectories: true)
        }

        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw StoreError.open(msg)
        }
        sqlite3_busy_timeout(db, 2000)
        try migrate()
    }

    deinit { sqlite3_close(db) }

    enum StoreError: Error, CustomStringConvertible {
        case open(String)
        case sql(String)
        var description: String {
            switch self {
            case .open(let m): return "打开数据库失败：\(m)"
            case .sql(let m): return "SQL 失败：\(m)"
            }
        }
    }

    private func migrate() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS items (
            id      INTEGER PRIMARY KEY AUTOINCREMENT,
            kind    TEXT    NOT NULL,
            content TEXT    NOT NULL,
            preview TEXT    NOT NULL,
            source  TEXT    NOT NULL DEFAULT '',
            bytes   INTEGER NOT NULL DEFAULT 0,
            pin     INTEGER NOT NULL DEFAULT 0,
            created REAL    NOT NULL,
            used    REAL    NOT NULL,
            digest  TEXT    NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_digest ON items(digest);
        CREATE INDEX IF NOT EXISTS idx_order ON items(pin DESC, used DESC);
        """
        try exec(sql)
    }

    // MARK: 低阶封装

    private func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.sql(msg)
        }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        return stmt
    }

    private func bindText(_ stmt: OpaquePointer?, _ i: Int32, _ v: String) {
        sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT)
    }

    private func bindInt(_ stmt: OpaquePointer?, _ i: Int32, _ v: Int64) {
        sqlite3_bind_int64(stmt, i, v)
    }

    private func bindDouble(_ stmt: OpaquePointer?, _ i: Int32, _ v: Double) {
        sqlite3_bind_double(stmt, i, v)
    }

    private func text(_ stmt: OpaquePointer?, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }

    private func readRows(_ stmt: OpaquePointer?) -> [ClipItem] {
        var out: [ClipItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let kind = ClipKind(rawValue: text(stmt, 1)) ?? .text
            out.append(ClipItem(
                id: sqlite3_column_int64(stmt, 0),
                kind: kind,
                content: text(stmt, 2),
                preview: text(stmt, 3),
                source: text(stmt, 4),
                bytes: Int(sqlite3_column_int64(stmt, 5)),
                pinned: sqlite3_column_int64(stmt, 6) != 0,
                created: sqlite3_column_double(stmt, 7),
                used: sqlite3_column_double(stmt, 8),
                digest: text(stmt, 9)
            ))
        }
        sqlite3_finalize(stmt)
        return out
    }

    // MARK: 写入

    /// 收入一条记录。返回 true 表示是新记录，false 表示只是把旧记录顶上去。
    @discardableResult
    func add(kind: ClipKind, content: String, preview: String,
             bytes: Int, source: String, digest: String,
             used: Double? = nil) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = used ?? Date().timeIntervalSince1970

        // 已存在：只更新 used（置顶状态保持不变）
        if let stmt = prepare("SELECT id FROM items WHERE digest = ? LIMIT 1;") {
            bindText(stmt, 1, digest)
            let exists = sqlite3_step(stmt) == SQLITE_ROW
            sqlite3_finalize(stmt)
            if exists {
                let upd = prepare("UPDATE items SET used = ? WHERE digest = ?;")
                bindDouble(upd, 1, now)
                bindText(upd, 2, digest)
                sqlite3_step(upd)
                sqlite3_finalize(upd)
                return false
            }
        }

        let stmt = prepare("""
        INSERT INTO items (kind, content, preview, source, bytes, pin, created, used, digest)
        VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?);
        """)
        bindText(stmt, 1, kind.rawValue)
        bindText(stmt, 2, content)
        bindText(stmt, 3, preview)
        bindText(stmt, 4, source)
        bindInt(stmt, 5, Int64(bytes))
        bindDouble(stmt, 6, now)
        bindDouble(stmt, 7, now)
        bindText(stmt, 8, digest)
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        if rc != SQLITE_DONE { throw StoreError.sql("insert rc=\(rc)") }
        return true
    }

    @discardableResult
    func touch(id: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = prepare("UPDATE items SET used = ? WHERE id = ?;") else { return false }
        bindDouble(stmt, 1, Date().timeIntervalSince1970)
        bindInt(stmt, 2, id)
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        return ok
    }

    func setPin(id: Int64, pinned: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = prepare("UPDATE items SET pin = ? WHERE id = ?;") else { return }
        bindInt(stmt, 1, pinned ? 1 : 0)
        bindInt(stmt, 2, id)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func delete(id: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = prepare("DELETE FROM items WHERE id = ?;") else { return }
        bindInt(stmt, 1, id)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        gcBlobs()
    }

    func clear(keepPinned: Bool) throws {
        try exec(keepPinned ? "DELETE FROM items WHERE pin = 0;" : "DELETE FROM items;")
        gcBlobs()
    }

    // MARK: 读取

    /// 按「置顶优先、最近使用优先」取一批记录（搜索在内存里做，足够快）
    func fetch(limit: Int = 800) -> [ClipItem] {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = prepare("""
        SELECT id, kind, content, preview, source, bytes, pin, created, used, digest
        FROM items ORDER BY pin DESC, used DESC LIMIT ?;
        """) else { return [] }
        bindInt(stmt, 1, Int64(limit))
        return readRows(stmt)
    }

    func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let stmt = prepare("SELECT COUNT(*) FROM items;") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// 超过上限的旧记录（不含置顶）直接淘汰，图片额外收紧额度
    func prune(maxItems: Int = 600, maxImages: Int = 120) {
        lock.lock(); defer { lock.unlock() }
        try? exec("""
        DELETE FROM items WHERE pin = 0 AND id NOT IN (
            SELECT id FROM items WHERE pin = 0 ORDER BY used DESC LIMIT \(maxItems)
        );
        """)
        try? exec("""
        DELETE FROM items WHERE pin = 0 AND kind = 'image' AND id NOT IN (
            SELECT id FROM items WHERE pin = 0 AND kind = 'image' ORDER BY used DESC LIMIT \(maxImages)
        );
        """)
        gcBlobs()
    }

    /// 清掉没有被数据库引用的图片文件
    func gcBlobs() {
        guard blobDir.path != NSTemporaryDirectory() else { return }
        lock.lock(); defer { lock.unlock() }

        var alive = Set<String>()
        if let stmt = prepare("SELECT digest FROM items WHERE kind = 'image';") {
            while sqlite3_step(stmt) == SQLITE_ROW {
                alive.insert(text(stmt, 0))
            }
            sqlite3_finalize(stmt)
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: blobDir.path)) ?? []
        for f in files where f.hasSuffix(".png") {
            let key = String(f.dropLast(4))
            if !alive.contains(key) {
                try? FileManager.default.removeItem(at: blobDir.appendingPathComponent(f))
            }
        }
    }

    // MARK: 图片落盘

    func blobPath(for digest: String) -> URL {
        blobDir.appendingPathComponent("\(digest).png")
    }
}
