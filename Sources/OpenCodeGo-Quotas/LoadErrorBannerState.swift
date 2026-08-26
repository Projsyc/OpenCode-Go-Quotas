import Foundation

/// 主界面加载错误横幅的错误来源。
/// 关闭状态必须按来源记录，不能让一个 Store 的确认掩盖另一个 Store 的新错误。
enum LoadErrorSource: String, CaseIterable, Hashable, Sendable {
    case opencodeAccount
    case githubAccount

    func resetting(in dismissedSources: Set<Self>) -> Set<Self> {
        var updated = dismissedSources
        updated.remove(self)
        return updated
    }
}

/// 横幅中的一条用户可见错误。
struct LoadErrorMessage: Identifiable, Equatable, Sendable {
    let source: LoadErrorSource
    let text: String

    var id: LoadErrorSource { source }
}

/// 将两个 Store 的错误转换为稳定顺序的横幅模型，供纯逻辑测试。
struct LoadErrorBannerModel: Equatable, Sendable {
    private let accountMessage: String?
    private let githubMessage: String?

    init(accountMessage: String?, githubMessage: String?) {
        self.accountMessage = accountMessage
        self.githubMessage = githubMessage
    }

    /// 全部当前存在的错误；账号 Store 固定在前，GitHub Store 在后。
    var allMessages: [LoadErrorMessage] {
        var messages: [LoadErrorMessage] = []
        if let accountMessage {
            messages.append(LoadErrorMessage(source: .opencodeAccount, text: accountMessage))
        }
        if let githubMessage {
            messages.append(LoadErrorMessage(source: .githubAccount, text: githubMessage))
        }
        return messages
    }

    /// 当前应显示的错误：只过滤已确认来源，另一个来源不受影响。
    func visibleMessages(dismissing dismissedSources: Set<LoadErrorSource>) -> [LoadErrorMessage] {
        allMessages.filter { !dismissedSources.contains($0.source) }
    }

    /// 「知道了」只确认当前可见来源。
    static func dismissing(
        _ visibleMessages: [LoadErrorMessage],
        in dismissedSources: Set<LoadErrorSource>
    ) -> Set<LoadErrorSource> {
        dismissedSources.union(visibleMessages.map(\.source))
    }
}
