# histdiag 汇报(2026-08-25)

## 实际改动

- `Sources/OpenCodeGo/HistoryDiagSink.swift`(新增)→ 与 `LoginLogSink` 同风格的诊断输出器:
  directory 可注入(默认 `~/Library/Logs/OpenCodeGo/history.log`),追加写、自动建目录、失败静默。
- `Sources/OpenCodeGo/QuotaClient.swift` →
  - `RX.firstFullMatch`:新增正则「完整匹配串 + Range」助手(诊断取原始匹配串用);
  - 常量 `historyDiagCostThreshold = 5.0`、`historyDiagContextRadius = 60`;
  - 纯函数 `diagContext(in:around:radius:)`:匹配串两侧各 60 字符,`\n`/`\r` 转义为字面 `\n`/`\r`;
  - `historyDiagMatch(in:)`:返回 `cost:` 正则首个**完整匹配串**与上下文;
  - `parseHistoryBody(_:diag:)`:新增默认参数 `diag`(测试注入;生产默认写真实路径)。
    cost > 5 时旁路追加一行诊断,解析结果与错误路径零变化。
- `Tests/OpenCodeGoTests/HistoryDiagSinkTests.swift`(新增):5 条(建文件/追加/深层目录/静默失败/文件名隔离)。
- `Tests/OpenCodeGoTests/QuotaClientTests.swift`:新增 6 条(上下文截取、边界收敛、换行转义、
  跨字段抢匹配、超阈值集成写日志、低于阈值不写)。

## 诊断格式(history.log 每行一条)

```
[ISO8601] id=<usg_xxx> model=<model> cost=<解析后数值> match=<原始匹配串> ctx=<两侧各60字符,换行转义>
```

示例(集成测试真实产出,复现 98M 机制 —— `cost` 正则从 `total_cost` 字段抢到 98711933):

```
[2026-08-25T06:59:43Z] id=usg_Cross1 model=gpt-test cost=98711933.0 match=cost:98711933 ctx=...total_cost:98711933...
```

- `match` = `cost:\s*(\d+(?:\.\d+)?)` 的**完整匹配串**(从 `cost:` 起,含数字),比只记数字更能定位来源;
- `ctx` = match 左侧 60 + 右侧 60 字符;原始换行/回车转义为字面 `\n` / `\r`(两字符文本)防串行;
- 仅含 id/model/cost/上下文,无任何凭据(红线)。

## 门禁结果

- `swift build`:通过(Build complete!,8.32s)
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`:**247 通过 / 0 失败**(原 236 + 新增 11)
- `git diff --check`:通过

## 遇到的问题

- 无阻塞项。两点说明:
  1. 提交 commit message 中 `$5` 触发沙箱 simple_expansion 保护 → 改写为「5 美元」后提交成功;
  2. match 的取法界定:prompt 未明示 match 是「捕获组数字」还是「正则整体」,实现取**正则整体**
     (如 `cost:98711933`),因为它在诊断时严格更有信息量(能看出匹配起点是否位于 `_cost:` 等
     其它键内),与 `cost=<解析后数值>` 不重复。
- 若后续拿到真实响应样本,直接查看 `~/Library/Logs/OpenCodeGo/history.log` 中
  `match`/`ctx` 即可定位 98M 数值来自哪个字段;用户无需任何额外操作(打开一次用量历史即触发)。

## 证据

- `swift test` 输出摘要:`Executed 247 tests, with 0 failures`
- 集成测试断言:超阈值记录写 `history.log` 且含 `match=cost:98711933`/`total_cost`;
  低于阈值(0.0123/0.045)不创建日志文件;现有 236 条测试全部保持通过。

门禁: PASSED
结论: OK
