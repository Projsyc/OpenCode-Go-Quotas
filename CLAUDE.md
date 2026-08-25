# OpenCode-Go-Quotas(macOS SwiftUI 应用)

OpenCode Go 多账号额度查询 + GitHub 多账号管理的原生 macOS 应用(Swift 5.10, macOS 14+)。

## 架构

```
Sources/OpenCodeGo-Quotas/
├── OpenCodeGoQuotasApp.swift        # @main,WindowGroup,注入 AccountStore + GitHubAccountStore
├── Models.swift               # UsageWindow/UsageResult/Account/UsageHistoryItem + GitHubAccount/GitHubCredentialKind
├── AccountStore.swift         # opencode 账号:元数据 JSON + Cookie 存 Keychain
├── GitHubAccountStore.swift   # GitHub 账号:元数据 JSON(github-accounts.json)+ 密码/凭据存 Keychain
├── QuotaClient.swift          # opencode.ai 额度/历史抓取(页面解析 + /_server RPC)
├── TOTPGenerator.swift        # RFC 6238 TOTP 验证码生成(base32 解码 + HMAC-SHA1 + 倒计时)
├── GitHubImportParser.swift   # 批量导入解析:Tab/逗号/分号/空格,CSV 引号,凭据类型推断
├── KeychainHelper.swift       # 轻量 Keychain 封装(service: com.acccan.opencode-go / -github)
├── BrowserCookieService.swift # 从 Chrome/Edge 解密读取 opencode.ai auth Cookie
├── Graphics/                  # SVGPath 解析、Theme 色板、GaugeRing 仪表环、Avatar、渐变标题
└── Views/                     # ContentView / AccountCardView / AddEditAccountView / UsageHistoryView
                               # + GitHubAccountCardView / GitHubEditView / GitHubImportView
```

## 数据安全红线(任何改动都不得违反)

1. **`~/Library/Application Support/OpenCode-Go-Quotas/accounts.json` 是用户真实数据**(现有 10 个
   opencode 账号)。代码只能**向后兼容**地读它:修改 `Account` 模型只能加可选字段,绝不
   改字段名/删除字段/改变解码语义。测试绝不允许读写真实路径。
2. **敏感数据只进 Keychain**(Cookie/密码/TOTP secret),不落盘、不打印、不上传。GitHub 的
   密码 / TOTP secret / 一次性验证码同样只进 Keychain(service `com.acccan.opencode-go.github`),
   **`github-accounts.json` 不得含任何敏感字段**。
3. 元数据 JSON 里不得出现任何密码/Cookie/secret 字段。
4. 测试必须用注入的临时目录 + 内存 Keychain mock,绝不碰真实存储。

## 构建与测试

```bash
swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test   # 需要完整 Xcode
swift run OpenCode-Go-Quotas --demo                                           # 演示模式(不发真实请求)
swift run OpenCode-Go-Quotas                                                  # ⚠️ 真实数据模式:读写真实 Keychain,非必要勿跑
```

## 编码约定

- SwiftUI + `@Observable`(Observation 框架);视图用 `@Environment(Store.self)`
- 中文 UI 文案与注释;块注释 `// MARK: - 标题`,少量行注释
- 主题:毛玻璃(ultraThinMaterial)、渐变 `Theme.accent`、连续圆角、`Color(hex:)`
- 结构体 `Codable/Identifiable/Sendable/Equatable` + 显式 init(与现有 Models 一致)
- 单测:URLProtocol mock(网络)、内存 mock(Keychain)、RFC 向量(TOTP)

## 签名约定(钥匙串免提示的前提,勿违反)

- **分发/交付构建必须用「OpenCodeGo Dev」证书身份签名**(`codesign --force --deep -s "OpenCodeGo Dev"`;身份在登录钥匙串,p12 备份在 `~/Desktop/OpenCodeGo-Dev.p12`,密码不落仓库)。
- 原因:钥匙串 ACL 的可信应用需求取自二进制签名(ad-hoc 时即 CDHash,**每次重签名都会失效**);
  证书身份的需求稳定跨版本,ACL 不会随更新失效 → 免弹窗。
- `tools/build-dmg.sh` 已内置「有身份用身份,无身份退回 ad-hoc」;手动交付时遵循同一逻辑。
- b17 曾假设路径匹配与签名无关,已被实测推翻(见 KeychainHelper.swift 注释)。

## Boss 流水线(claude-boss-workflow)

- 本仓库已装 boss-workflow:Boss 编排、worker 在 `.claude/worktrees/dm-wt-<ws>` 写代码、
  merger 合并到 `dev`(本地仓库,无远程,不 push)。`main` 保持基线不动。
- worker 铁律:只在自己的 worktree 提交,绝不 merge/push/切分支;报告写批次目录
  `reports/<ws>.md`,末两行 `门禁: PASSED|FAILED` / `结论: OK|BLOCKED: …`。
- 状态/批次目录在 `.claude/boss/`(gitignore);恢复:`bash .claude/skills/boss-agent/bin/resume-boss.sh <batch-dir>`。
