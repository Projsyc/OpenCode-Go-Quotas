# OpenCodeGo(macOS SwiftUI 应用)

OpenCode Go 多账号额度查询 + GitHub 多账号管理的原生 macOS 应用(Swift 5.10, macOS 14+)。

## 架构

```
Sources/OpenCodeGo/
├── OpenCodeGoApp.swift        # @main,WindowGroup,注入 AccountStore
├── Models.swift               # UsageWindow/UsageResult/Account/UsageHistoryItem
├── AccountStore.swift         # opencode 账号:元数据 JSON + Cookie 存 Keychain
├── QuotaClient.swift          # opencode.ai 额度/历史抓取(页面解析 + /_server RPC)
├── KeychainHelper.swift       # 轻量 Keychain 封装(service: com.acccan.opencode-go)
├── BrowserCookieService.swift # 从 Chrome/Edge 解密读取 opencode.ai auth Cookie
├── Graphics/                  # SVGPath 解析、Theme 色板、GaugeRing 仪表环、Avatar、渐变标题
└── Views/                     # ContentView / AccountCardView / AddEditAccountView / UsageHistoryView
```

## 数据安全红线(任何改动都不得违反)

1. **`~/Library/Application Support/OpenCodeGo/accounts.json` 是用户真实数据**(现有 10 个
   opencode 账号)。代码只能**向后兼容**地读它:修改 `Account` 模型只能加可选字段,绝不
   改字段名/删除字段/改变解码语义。测试绝不允许读写真实路径。
2. **敏感数据只进 Keychain**(Cookie/密码/TOTP secret),不落盘、不打印、不上传。
3. 元数据 JSON 里不得出现任何密码/Cookie/secret 字段。
4. 测试必须用注入的临时目录 + 内存 Keychain mock,绝不碰真实存储。

## 构建与测试

```bash
swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test   # 需要完整 Xcode
swift run OpenCodeGo --demo                                           # 演示模式(不发真实请求)
swift run OpenCodeGo                                                  # ⚠️ 真实数据模式:读写真实 Keychain,非必要勿跑
```

## 编码约定

- SwiftUI + `@Observable`(Observation 框架);视图用 `@Environment(Store.self)`
- 中文 UI 文案与注释;块注释 `// MARK: - 标题`,少量行注释
- 主题:毛玻璃(ultraThinMaterial)、渐变 `Theme.accent`、连续圆角、`Color(hex:)`
- 结构体 `Codable/Identifiable/Sendable/Equatable` + 显式 init(与现有 Models 一致)
- 单测:URLProtocol mock(网络)、内存 mock(Keychain)、RFC 向量(TOTP)

## Boss 流水线(claude-boss-workflow)

- 本仓库已装 boss-workflow:Boss 编排、worker 在 `.claude/worktrees/dm-wt-<ws>` 写代码、
  merger 合并到 `dev`(本地仓库,无远程,不 push)。`main` 保持基线不动。
- worker 铁律:只在自己的 worktree 提交,绝不 merge/push/切分支;报告写批次目录
  `reports/<ws>.md`,末两行 `门禁: PASSED|FAILED` / `结论: OK|BLOCKED: …`。
- 状态/批次目录在 `.claude/boss/`(gitignore);恢复:`bash .claude/skills/boss-agent/bin/resume-boss.sh <batch-dir>`。
