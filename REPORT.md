# ws-costscale 汇报(2026-08-25)

## 背景结论
平台把 history 记录的 `cost` 字段从「美元」改为 **×10⁸ 定点单位**(cost × 10⁻⁸ = 美元)。
取证:真实 $0.0019 ↔ 记录 194958(=0.00194958);合计 $0.99 ↔ 98,711,933;各条 10⁴~10⁶
量级 ×10⁻⁸ = $0.002~0.005,量级自洽。b30 词边界修复保留未动。

## 实际改动
- `Sources/OpenCodeGo-Quotas/QuotaClient.swift`
  - 新增常量 `historyCostScale = 1e-8`(命名常量 + 注释:平台 ×10⁸ 定点单位语义,背景取自取证)。
  - `parseHistoryBody`:cost 提取改为 `costRaw = historyDouble("cost")` → `cost = costRaw * historyCostScale`,
    缩放在**解析层一次到位**;token 计数字段(inputTokens/outputTokens/reasoningTokens/cache*)不缩放;
    UI 层(今日/周/月/合计、表格、fmtCost)零改动。
  - 诊断旁路(b29 HistoryDiagSink):阈值判定用**缩放后美元值**(> $5),日志记录**平台原始未缩放值**
    并标注 `costRaw=`(诊断目的 = 取证原始数据,避免与 UI 显示混淆);`historyDiagMatch` 仍返回
    原始匹配串(未缩放)。
- `Tests/OpenCodeGo-QuotasTests/QuotaClientTests.swift`
  - b29 集成 fixture(原样保留 `total_cost:98711933, cost:0.0123`):断言改为
    `cost == 0.0123 * QuotaClient.historyCostScale`(词边界 + 缩放双回归)。
  - 诊断测试改写为双记录:9871193300 → $98.71(超阈值 → 写日志,断言 `costRaw=9871193300.0`)、
    98711933 → $0.98711933(低于阈值 → 不写日志)。
  - 合成 fixture 的 cost 值统一改为平台定点原始值(如 190000 → $0.0019、4500000 → $0.045),
    美元断言保留并收紧 accuracy(1e-9~1e-12,防错误缩放系数漏检)。
  - 新增 1 条缩放回归:`cost:0 → 0`、`323852 → 0.00323852`、`%.8f` 8 位小数精度无丢失。

## 缩放语义
- 平台字段值 × 10⁻⁸ = 美元;仅作用于 `cost`,与 UI 显示同源,合计/表格自动正确。
- 诊断日志:保留原始定点值(标注 costRaw),不记录缩放值 —— 取证原始数据,避免与显示混淆。
- 词边界守卫(historyFieldBoundary)逻辑零改动。

## 门禁结果
- swift build: 通过
- swift test: **254 通过 / 0 失败**(原有 253 + 新增缩放回归 1)
- git diff --check: 通过

## 遇到的问题
- 无。注:多行 commit message 首次提交失败(外层 hook),已改用多个 `-m` 参数提交成功。

## 证据
- `git log`:d24bb69(fix)+ 1e4f38e(test),分支 `ws-costscale`,未 merge/未 push。
- 测试输出:`Executed 254 tests, with 0 failures`。
- 改动物料仅边界内两文件(`git diff --stat`:QuotaClient.swift 28 行 / QuotaClientTests.swift 86 行)。

门禁: PASSED
结论: OK
