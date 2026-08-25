# OpenCode-Go-Quotas — OpenCode Go 多账号额度查询 (macOS)

把 [Ruinique/opencode-go-dashboard](https://github.com/Ruinique/opencode-go-dashboard) 改造成的原生 Swift 应用。
现代化 SwiftUI 界面(SVG 装饰 + 渐变仪表环):每个账号展示 **Rolling / Weekly / Monthly** 三档用量与重置倒计时,附逐请求用量历史(今日 / 本周 / 本月 / 全部)。

数据获取逻辑与原项目 **1:1 移植**(`Sources/OpenCodeGo-Quotas/QuotaClient.swift` 对应原 `src/worker/quota.ts`):
- 额度:GET `https://opencode.ai/workspace/{ws}/go`,解析页面内嵌的 `rollingUsage/weeklyUsage/monthlyUsage/plan`
- 历史:POST `https://opencode.ai/_server`(SolidStart RPC),按 `id:"usg_xxx"` 锚点切块解析逐请求用量与费用

## Cookie 获取:一键导入 or 手动

- **自动导入**:添加账号时一键从本机 **Chrome / Edge** 读取 opencode.ai 的 `auth` Cookie(自动遍历所有配置文件,支持 Chrome 127+ 的新版加密:Keychain 口令 → PBKDF2 → AES-128-CBC → 剥离 32 字节 host 前缀)
- **手动填写**:浏览器 F12 → Application → Cookies → 复制 `auth` 值(`Fe26.` 开头)
- 首次读取浏览器 Keychain 口令时系统会弹一次授权提示

## 安全设计

- **Cookie 存 Keychain**,不落盘、不打印、不上传
- 账号元数据 + 上次额度快照存 `~/Library/Application Support/OpenCode-Go-Quotas/accounts.json`
- 所有请求只读,不消耗配额

## 构建与运行

```bash
# 开发模式直接跑(无界面验证 UI 用 --demo)
swift run OpenCode-Go-Quotas --demo

# 打包成 .app(双击运行)
bash scripts/bundle-app.sh
open dist/OpenCode-Go-Quotas.app
```

> 注意:`swift test` 需要完整 Xcode(本机 dev 目录指向 CommandLineTools):
> `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`

## 使用

1. 「添加账号」→ 在「从浏览器自动获取」区选择 Chrome/Edge → 检测到 auth Cookie → 点「填入」
2. 填账号名称 + Workspace ID(`wrk_xxx`,工作区 URL 里可见)
3. 点「刷新」看三档额度仪表环;点卡片「用量历史」按日/周/月查看消耗与费用

## 测试

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

21 个单测覆盖:额度/历史解析(URLProtocol mock)、cookie 解密 round-trip(本地构造 Chrome 127+ 加密样本)、
PBKDF2 RFC 6070 向量、Chrome 时间戳换算、SVG 路径解析。

## 与原项目的差异

| | 原项目 | 本应用 |
|---|---|---|
| 形态 | Cloudflare Worker + React 自托管面板 | 原生 macOS SwiftUI app |
| Cookie 来源 | 手动复制粘贴 | Chrome/Edge 一键导入或手动 |
| Cookie 存放 | 服务器 D1 数据库 | 本机 Keychain |
| 部署 | 需 Cloudflare 账号 | 免部署 |

## 已知限制

- opencode.ai 页面结构变更后解析逻辑需同步更新(与原项目相同)
- Cookie 过期需重新导入或复制更新(应用会明确提示)
- 仅 macOS 14+
- 浏览器 Cookie 需为持久化 Cookie 才会落盘;若在隐私模式下登录则可能读不到
