# costfix 汇报(2026-08-25)

## 实际改动

- `Sources/OpenCodeGo/QuotaClient.swift` →
  - 新增常量 `historyFieldBoundary = "(?<![A-Za-z0-9_])"`(ICU 定长 lookbehind),注释说明
    「字段名子串抢匹配」这一病根(b29 98M 实锤)及大小写/下划线变体,防止回归;
  - **所有 history 字段正则加词边界前缀**:anchor 切块正则 `id:`、`idRaw`、`timeCreated`、
    `model`、`provider`、`keyID`、`sessionID`、`plan` 的直接 RX.capture 调用点,以及
    `historyInt`/`historyNullableInt`/`historyDouble` 助手内部拼串
    (inputTokens/outputTokens/reasoningTokens/cacheReadTokens/cacheWrite5mTokens/
    cacheWrite1hTokens/cost),统一收口到 `historyFieldBoundary`;
  - 诊断旁路 `historyDiagMatch` 同步加前缀(**与 `historyDouble("cost")` 同一正则**,
    保证 match 与解析结果一致,未来异常仍可取证);阈值 5 / 上下文半径 60 / 格式不变;
  - `parseUsageObject` 走 JSON key 值匹配(非正则),未动;行为仅收紧匹配,字段语义零变化。
- `Tests/OpenCodeGoTests/QuotaClientTests.swift` →
  - **改写 2 条** b29 断言为修复后语义,原 98M fixture 保留为回归证据:
    `testHistoryDiagMatchSkipsSubstringCostField`(原 `...FindsFirstCostMatch`)、
    `testParseHistoryBodyReproductionFixtureParsesTrueCost`(原 `...WritesDiagForAnomalousCost`);
  - **新增 6 条**:total_cost/totalCost/totalcost 三变体(cost 分别取 0.0019/0.0027/0.0035)、
    apikeyID→keyID 抢匹配、uid 伪锚点、无 cost 默认 0、4000 字符截断不破坏早段字段、
    真实独立 cost 超阈值仍写诊断日志(保留旁路覆盖);
  - 现有 247 条测试全部保持通过。

## 词边界机制

- 模式:`cost:\s*(\d+(?:\.\d+)?)` → `(?<![A-Za-z0-9_])cost:\s*(\d+(?:\.\d+)?)`,即断言
  字段名前一字符不是字母/数字/下划线 → 字段名必须**独立成词**;
- `total_cost:`→ 前一字符 `_` 被拦截;`totalcost:`→ 前一字符 `l` 被拦截;
  `apikeyID:`→ `keyID:` 前是 `i` 被拦截;`uid:"usg_..."` 内的 `id:"usg_..."` 前是 `u`
  被拦截(anchor 防护);`totalCost:`(大写 C)→ 大小写敏感本就不匹配 `cost:`,实测确认零影响;
- `{`/`,`/空格/`"` 等合法前置符不受影响,既有记录格式照常解析;
- 坑中坑:Swift 原始字符串 `#"..."#` 中 `\(...)` 是**字面量**,插值必须用 `\#(...)`(本次实现时实测验证)。

## 门禁结果

- `swift build`:通过(Build complete!,8.09s)
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`:**253 通过 / 0 失败**(原 247 + 新增 6;改写 2 条)
- `git diff --check`:通过

## 遇到的问题

- 无阻塞项。两点说明:
  1. 原始字符串插值坑:初版将 `\(Self.historyFieldBoundary)` 写入 `#"..."#`(字面量,不插值)→
     改为 `\#(...)` 并用 `swift -e` 实测两种写法后修正;若未发现,词边界前缀会变成纯字面量,
     全部字段正则失效——已由 253 条测试全绿确认修复到位;
  2. prompt 提到的「>4000 字符截断、无 cost 字段(默认 0)」边界在现有测试文件中并无既有单测,
     为守住边界各自补充 1 条守卫测试(截断点前字段正常解析且不崩溃、无 cost → 0)。
- 若后续仍见到 cost 异常,`~/Library/Logs/OpenCodeGo/history.log` 的 match/ctx 机制不变,
  但 match 现在只会来自独立 `cost:` 字段(子串字段已被排除)。

## 证据

- `swift test` 输出摘要:`Executed 253 tests, with 0 failures`
- 核心回归:fixture `total_cost:98711933, cost:0.0019` → cost 解析为 **0.0019**(修复前 98,711,933)
- b29 原 98M fixture(`total_cost:98711933, cost:0.0123`)→ cost = 0.0123 且不写诊断日志;
  真实独立 `cost:98711933` → 照常写日志,`match=cost:98711933` 格式不变

门禁: PASSED
结论: OK
