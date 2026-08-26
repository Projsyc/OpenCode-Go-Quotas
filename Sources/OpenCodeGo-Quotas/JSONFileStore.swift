import Foundation
import OSLog

/// 通用 JSON 文件存储：负责原子落盘、写前快照、损坏文件留证与快照恢复。
///
/// 业务 Store 只需要提供模型、文件位置和用户可读的数据名称；Keychain 与领域规则
/// 仍由业务 Store 负责。所有路径操作都应通过注入的 `fileURL` 隔离，默认构造器
/// 才会使用 Application Support。
@MainActor
struct JSONFileStore<Model: Codable & Sendable> {
    /// 加载结果。`model == nil` 表示文件不存在或已按既有约定备份后重置；
    /// `recoveryMessage != nil` 时必须展示给用户，避免静默丢失或替换数据。
    struct LoadResult {
        let model: Model?
        let recoveryMessage: String?

        static func unchanged(_ model: Model?) -> LoadResult {
            LoadResult(model: model, recoveryMessage: nil)
        }
    }

    enum PersistenceError: LocalizedError {
        case directoryCreationFailed(subject: String, reason: String)
        case encodingFailed(subject: String, reason: String)
        case writeFailed(subject: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .directoryCreationFailed(let subject, let reason):
                return "无法创建\(subject)数据目录:\(reason)"
            case .encodingFailed(let subject, let reason):
                return "\(subject)数据编码失败:\(reason)"
            case .writeFailed(let subject, let reason):
                return "\(subject)数据写入失败:\(reason)"
            }
        }
    }

    private let fileURL: URL
    private let snapshotURL: URL
    private let subject: String
    private let sourceName: String
    private let logger: Logger

    /// - Parameters:
    ///   - fileURL: 主 JSON 文件；快照固定为主文件名追加 `.bak`
    ///   - subject: 用户可读的数据主体，例如「账号」或「GitHub 账号」
    ///   - sourceName: 日志中使用的源文件名（不含时间戳备份后缀）
    ///   - logger: 业务 Store 的 OSLog category，保持日志归属不变
    init(
        fileURL: URL,
        subject: String,
        sourceName: String,
        logger: Logger
    ) {
        self.fileURL = fileURL
        self.subject = subject
        self.sourceName = sourceName
        self.logger = logger
        self.snapshotURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(fileURL.lastPathComponent + ".bak")
    }

    /// 读取并解码主文件。主文件损坏时优先恢复 `.bak`；若备份也不可用，
    /// 则把损坏原件移动为带时间戳的证据文件后返回空模型。
    func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .unchanged(nil)
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let model = try JSONDecoder().decode(Model.self, from: data)
            return .unchanged(model)
        } catch {
            guard let snapshotData = try? Data(contentsOf: snapshotURL),
                  let recovered = try? JSONDecoder().decode(Model.self, from: snapshotData) else {
                // 快照缺失或同样损坏 → 移动损坏原件留证，避免下一次原子保存永久覆盖。
                let backupName = stashCorruptedFile(move: true)
                if let backupName {
                    return LoadResult(
                        model: nil,
                        recoveryMessage: "\(subject)数据文件损坏，已备份为 \(backupName)，请检查后重新添加")
                }
                return LoadResult(
                    model: nil,
                    recoveryMessage: "\(subject)数据文件损坏，且备份失败，请检查后重新添加")
            }

            // 先复制损坏原件留证，再用快照修复主文件；任一保险动作失败都不阻断内存恢复。
            let evidenceName = stashCorruptedFile(move: false)
            restoreMainFileFromSnapshot()
            if let evidenceName {
                return LoadResult(
                    model: recovered,
                    recoveryMessage: "\(subject)数据文件损坏，已从备份恢复数据（原文件已备份为 \(evidenceName)）")
            }
            logger.error("\(self.sourceName, privacy: .public) 解码失败，已从快照恢复数据")
            return LoadResult(model: recovered, recoveryMessage: "\(subject)数据文件损坏，已从备份恢复数据")
        }
    }

    /// 原子保存模型。写前会滚动更新单份 `.bak` 快照；快照失败只记日志，不阻断保存。
    func save(_ model: Model) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
        } catch {
            throw PersistenceError.directoryCreationFailed(subject: subject, reason: error.localizedDescription)
        }

        snapshotBeforeWrite()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(model)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 编码和写入使用不同用户文案；底层错误在此处已经能区分，不需要额外二次包装。
            if error is EncodingError {
                throw PersistenceError.encodingFailed(subject: subject, reason: error.localizedDescription)
            }
            throw PersistenceError.writeFailed(subject: subject, reason: error.localizedDescription)
        }
    }

    /// 把损坏的主文件移动/复制为 `<主文件>.bak-<时间戳>`；同秒冲突自动递增序号。
    @discardableResult
    private func stashCorruptedFile(move: Bool) -> String? {
        let stamp = JSONFileTimestampFormatter.value.string(from: Date())
        let directory = fileURL.deletingLastPathComponent()
        let evidencePrefix = snapshotURL.lastPathComponent + "-"
        var backupName = evidencePrefix + stamp
        var backupURL = directory.appendingPathComponent(backupName)
        var suffix = 2

        while FileManager.default.fileExists(atPath: backupURL.path) {
            backupName = "\(evidencePrefix)\(stamp)-\(suffix)"
            backupURL = directory.appendingPathComponent(backupName)
            suffix += 1
        }

        do {
            if move {
                try FileManager.default.moveItem(at: fileURL, to: backupURL)
            } else {
                try FileManager.default.copyItem(at: fileURL, to: backupURL)
            }
            return backupName
        } catch {
            return nil
        }
    }

    /// 用字节级快照覆盖损坏主文件。失败仅记日志：调用方仍持有内存中的恢复结果。
    private func restoreMainFileFromSnapshot() {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            try FileManager.default.copyItem(at: snapshotURL, to: fileURL)
        } catch {
            logger.error("从快照写回 \(self.sourceName, privacy: .public) 失败: \(error.localizedDescription)")
        }
    }

    /// 写盘前复制当前主文件到 `.bak`。首次写入没有旧文件时跳过；备份是保险而非依赖。
    private func snapshotBeforeWrite() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            if FileManager.default.fileExists(atPath: snapshotURL.path) {
                try FileManager.default.removeItem(at: snapshotURL)
            }
            try FileManager.default.copyItem(at: fileURL, to: snapshotURL)
        } catch {
            logger.error("写前快照 \(self.sourceName, privacy: .public).bak 失败: \(error.localizedDescription)")
        }
    }

}

/// 泛型类型不能保存静态属性；时间戳格式化器集中放在非泛型辅助类型中复用。
@MainActor
private enum JSONFileTimestampFormatter {
    static let value: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
