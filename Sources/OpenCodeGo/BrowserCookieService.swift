import Foundation
import Security
import CommonCrypto
import CryptoKit
import SQLite3

// MARK: - 只读 SQLite 查询

enum CookieDB {
    /// 只读查询;数据库被浏览器占用打不开时,复制 db(+wal/shm) 到临时目录再查
    static func query(_ sql: String, dbPath: String) -> [[String: Any]]? {
        var handle: OpaquePointer?
        var status = sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READONLY, nil)
        var tempCopy: URL?
        if status != SQLITE_OK {
            sqlite3_close(handle)
            guard let copy = copyDB(dbPath) else { return nil }
            tempCopy = copy
            status = sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READONLY, nil)
        }
        guard status == SQLITE_OK, let handle else { return nil }
        defer {
            sqlite3_close(handle)
            if let tempCopy { try? FileManager.default.removeItem(at: tempCopy) }
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }

        var rows: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_TEXT:
                    row[name] = String(cString: sqlite3_column_text(stmt, i))
                case SQLITE_INTEGER:
                    row[name] = sqlite3_column_int64(stmt, i)
                case SQLITE_BLOB:
                    if let bytes = sqlite3_column_blob(stmt, i) {
                        row[name] = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, i)))
                    }
                default:
                    break
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// 复制数据库及 WAL/SHM 到临时目录(浏览器运行时 WAL 里可能有最新 cookie)
    private static func copyDB(_ path: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocg-cookies-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = (path as NSString).lastPathComponent
        let fm = FileManager.default
        do {
            try fm.copyItem(at: URL(fileURLWithPath: path), to: dir.appendingPathComponent(base))
            for suffix in ["-wal", "-shm"] {
                let src = path + suffix
                if fm.fileExists(atPath: src) {
                    try? fm.copyItem(at: URL(fileURLWithPath: src), to: dir.appendingPathComponent(base + suffix))
                }
            }
            return dir.appendingPathComponent(base)
        } catch {
            return nil
        }
    }
}

// MARK: - Chrome / Edge Cookie 读取与解密

/// 从本机 Chrome / Edge 读取 opencode.ai 的 auth Cookie。
/// 解密后的值只在内存中使用(填入表单),绝不落盘、绝不打印。
struct BrowserCookieService {
    enum Browser: String, CaseIterable, Identifiable {
        case chrome = "Chrome"
        case edge = "Edge"

        var id: String { rawValue }

        var appSupportDirName: String {
            switch self {
            case .chrome: return "Google/Chrome"
            case .edge: return "Microsoft Edge"
            }
        }

        /// Keychain 中存储加密口令的 service 名
        var keychainService: String {
            switch self {
            case .chrome: return "Chrome Safe Storage"
            case .edge: return "Microsoft Edge Safe Storage"
            }
        }
    }

    struct Candidate: Identifiable, Equatable {
        var browser: Browser
        var profileName: String
        var cookieName: String
        var hostKey: String
        var expiresAt: Date?
        var value: String // 解密后的明文,仅存内存

        var id: String { "\(browser.rawValue)/\(profileName)/\(cookieName)" }
    }

    /// 在所有已安装浏览器、所有配置文件里找 opencode.ai 的 auth cookie
    static func findOpenCodeAuthCookies() -> [Candidate] {
        var results: [Candidate] = []
        for browser in Browser.allCases {
            guard let password = keychainPassword(for: browser),
                  let key = deriveKey(password: password)
            else { continue }
            for profile in profiles(of: browser) {
                guard let dbPath = cookieDBPath(browser: browser, profile: profile) else { continue }
                guard let rows = CookieDB.query(
                    "SELECT host_key, name, encrypted_value, expires_utc FROM cookies WHERE host_key LIKE '%opencode.ai' ORDER BY name;",
                    dbPath: dbPath)
                else { continue }
                for row in rows {
                    guard let hostKey = row["host_key"] as? String,
                          let name = row["name"] as? String,
                          let encrypted = row["encrypted_value"] as? Data,
                          let value = decryptCookieValue(encrypted, key: key, hostKey: hostKey)
                    else { continue }
                    var expiresAt: Date?
                    if let us = row["expires_utc"] as? Int64, us > 0 {
                        expiresAt = Date(timeIntervalSince1970: Double(us) / 1_000_000 - 11_644_473_600)
                    }
                    results.append(Candidate(
                        browser: browser, profileName: profile, cookieName: name,
                        hostKey: hostKey, expiresAt: expiresAt, value: value))
                }
            }
        }
        return results
    }

    /// 浏览器所有配置文件目录名(Default、Profile 1…)
    static func profiles(of browser: Browser) -> [String] {
        let root = NSHomeDirectory() + "/Library/Application Support/" + browser.appSupportDirName
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return entries
            .filter { candidate in
                let prefs = root + "/" + candidate + "/Preferences"
                return FileManager.default.fileExists(atPath: prefs)
            }
            .sorted()
    }

    private static func cookieDBPath(browser: Browser, profile: String) -> String? {
        let base = NSHomeDirectory() + "/Library/Application Support/"
            + browser.appSupportDirName + "/" + profile
        for candidate in [base + "/Network/Cookies", base + "/Cookies"] {
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - 解密(Chrome 127+ 的 v10 + 32 字节 host 前缀方案)

    /// 读取 Keychain 中的浏览器加密口令
    static func keychainPassword(for browser: Browser) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: browser.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 经典 macOS 方案:PBKDF2-HMAC-SHA1(salt "saltysalt", 1003 轮, 16 字节)
    static func deriveKey(password: String, iterations: UInt32 = 1003) -> Data? {
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            password, password.utf8.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
            iterations, &key, key.count)
        return status == kCCSuccess ? Data(key) : nil
    }

    /// 解密单个 cookie 值。返回以 Fe26. 开头的明文;失败返回 nil。
    static func decryptCookieValue(_ encrypted: Data, key: Data, hostKey: String) -> String? {
        let header = encrypted.prefix(3)
        guard header.count == 3, header == Data("v10".utf8) || header == Data("v11".utf8) else {
            // 旧版本未加密的明文存储
            return String(data: encrypted, encoding: .utf8)
        }
        let cipher = encrypted.dropFirst(3)
        // 历史上 IV 全零;部分版本用 16 个空格,都试一遍
        let ivs: [[UInt8]] = [
            [UInt8](repeating: 0, count: 16),
            [UInt8](repeating: 0x20, count: 16),
        ]
        for iv in ivs {
            guard let plain = aesCBCDecrypt(cipher, key: key, iv: iv) else { continue }
            var value = plain
            // Chrome 127+ (cookie DB v24+) 在明文前加了 32 字节 SHA-256(host_key)
            if plain.count > 32 {
                let expected = Data(SHA256.hash(data: Data(hostKey.utf8)))
                if plain.prefix(32) == expected {
                    value = plain.dropFirst(32)
                }
            }
            if let s = String(data: value, encoding: .utf8), s.hasPrefix("Fe26.") {
                return s
            }
        }
        return nil
    }

    private static func aesCBCDecrypt(_ cipher: Data, key: Data, iv: [UInt8]) -> Data? {
        var out = [UInt8](repeating: 0, count: cipher.count + 64)
        var outLen = 0
        let keyBytes = [UInt8](key)
        let status = CCCrypt(
            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding),
            keyBytes, keyBytes.count,
            iv, [UInt8](cipher), cipher.count,
            &out, out.count, &outLen)
        guard status == kCCSuccess else { return nil }
        return Data(out.prefix(outLen))
    }
}
