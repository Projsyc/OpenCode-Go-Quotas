import Foundation

/// 添加/编辑 GitHub 账号的凭据参数组:add/update 的调用点不再零散传参。
///
/// 校验(trim、非空、凭据类型推断)由调用方在构造 input 前完成,与现状一致;
/// store 内只做重复校验(空用户名 / 密码过短 / 凭据缺类型 / 重名)。
struct GitHubAccountInput: Equatable {
    var username: String
    var notes: String = ""
    /// 密码。add 必填(至少 6 字符);update 时由 `passwordChanged` 决定是否应用
    var password: String
    /// 凭据(TOTP secret / 一次性验证码)。update 语义:传 nil 表示不修改
    var credential: String? = nil
    /// 凭据类型。update 语义:传 nil 表示不修改(credential 更新时沿用现有类型)
    var kind: GitHubCredentialKind? = nil
}
