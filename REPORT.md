# 自动登录流程健壮性审计报告(ws-loginaudit,2026-08-25)

审计对象:`Sources/OpenCodeGo/GitHubLoginService.swift`(decide 状态机、JS 构造、cookie 提取)
+ `Sources/OpenCodeGo/Views/GitHubLoginView.swift`(WKWebView I/O、轮询、超时、注入执行)。
审计日期:2026-08-25;基线:dev 合并点 `a20b357`;198 条既有测试全绿。

## 审计清单(按严重度排序)

| # | 问题 | 触发路径 | 影响 | 是否修复 |
|---|------|----------|------|----------|
| 1 | 取消/超时后残留的 in-flight 轮询回调仍可触发成功 | 轮询每 500ms 一次,`cancel()`/超时判定与 `getAllCookies` 回调并发(取消瞬间命中在途回调概率高) | `cancel()` 不置终止标记 → 在途回调 `guard !succeeded` 通过 → `succeed()` 在用户取消后调用 `onAuthCookie`(父视图被回填);超时后残留回调可把 `.failed` 覆盖为 `.waitingOAuthRedirect` 并重启轮询 | ✔ commit `9cfabfc`:`succeeded` 兼作「流程已终止」标记,cancel()/超时路径置位;cancel 在 `.done` 期间保持 no-op、`.failed` 后仍收尾关闭 |
| 2 | 用户手动登录期间被上一次导航起的 300s 计时器打断 | 凭据注入重试耗尽(约 2.8s)→ 转手动;用户在窗口中手动输码耗时超过「距上次导航步骤变化」的 300s 窗口 | 手动进行中状态被置 `.failed`;随后导航被 `guard !succeeded` 拦截 → 用户已完成登录但 cookie 不再轮询,流程假失败 | ✔ commit `9cfabfc`:任何步骤变化(注入结果/OTP 探测结果推进)都 `restartTimeout()`;规则收敛为 service `shouldRestartTimeout`(终态不重启) |
| 3 | 一次性注入(授权点击/OTP 填码/读 cookie)不受取消管理 | didFinish 后 300ms 窗口内页面继续导航/成功/取消 | 旧页面上下文的 JS 在已离场页面执行(多数无害,如 `no-otp`;可能误点页面按钮);成功后仍执行造成噪音 | ✔ commit `9cfabfc`:`injectOneShot` 改由 `injectionTask` 承载(新决策到达即取消),执行前校验 `!succeeded` 且 `webView` 未替换 |
| 4 | OTP 探测结果可覆盖已推进的新状态 | 探测(300ms)期间页面继续导航(2FA 页 → 用户手动 → 转 manual;或回跳 opencode) | 过期结果把新状态覆盖回 `.twoFactor`,或按旧 URL 误判「登录未成功」转手动 | ✔ commit `9cfabfc`:`handleOTPProbeResult` 仅当仍处于凭据已提交阶段(`isCredentialSubmittedState`)才应用结果 |
| 5 | `start()` 未显式复位关键状态(重开 sheet 残留) | 同一视图实例被再次呈现(SwiftUI 容器保留 @State 的场景) | 携带上次流程的 `succeeded`/`reachedGitHubOAuth`/`currentStep`/`lastDecision`/`lastExecutedJS`/轮询/时间线重新开始 → 占位 cookie 门槛被跳过、决策去重误伤、时间线混流 | ✔ commit `9cfabfc`:`start()` 幂等复位全部瞬态(含 `flowLog.clear()`、`stopPolling`/`stopTimeout`/`cancelPendingInjection`) |
| 6 | decide 对终态无守卫(视图 guard 之外的纵深缺口) | 成功/超时后残留 didFinish 回调 | decide 会把 `.failed` 决策为 `.waitingOAuthRedirect` 且 `pollCookie = true`(视图 guard 正常时不暴露;属于纵深防御缺口) | ✔ commit `4a69c16`:decide 顶部终态硬守卫——原样返回、不注入、不轮询;单测 `testDecideNeverOverridesTerminalStates` |
| 7 | 视图与 decide 的 `isGitHubHost` 判定两份 | 未来改动只改一处 | 判定漂移(OAuth 门槛与 decide 行为不一致) | ✔ commit `4a69c16`:收敛为 service `isGitHubHost(url:)`,视图复用;单测 `testIsGitHubHost` |
| 8 | 一次性注入结果不解释(`no-authorize-btn`/`no-otp` 不重试) | OAuth 授权页/2FA 页按钮或输入框在 +300ms 时仍未渲染(慢渲染) | 点击/填码落空且无后续 didFinish(SPA 页面)→ 停留至 300s 超时;概率低(GitHub 服务端渲染,300ms 已覆盖多数情形) | ✘ 未修(重试属行为增强);建议后续:为一次性注入加 2~3 次受控重试(复用 `injectionTask` 机制,约 20 行) |
| 9 | 各阶段无独立守护超时,依赖 300s 全局超时 | 某阶段静默卡住(didFinish 不再到来、轮询持续空转) | 最长 5 分钟后才提示失败;整体有兜底,可接受 | ✘ 未修;建议后续:启动加载阶段加 15s 级阶段超时(需引入新状态,属扩展) |
| 10 | 2FA/一次性码过期路径与 b16 一致性核查 | — | 核查通过:2FA 页无码 → 手动「请输入两步验证码」;登录页凭据已提交无码 → 手动「请输入当前两步验证码」;内联探测未命中登录页 → 手动「登录未成功」;`decide`/`totpCodeNow` 双重把关,过期码不会被自动填入 | ✔ 无需改动(核查结论) |

## decide 分支遍历(死分支/重复核查)

通读 `decide` 全部 return 分支:无 URL 分支、two-factor、webauthn、device、oauth/authorize、
login/session(state switch 三分支 + default)、其他 github 页(探测/延续)、opencode 域、
其他域(idle → loading,其余延续)——共 9 类,无一不可达。
rule 4 的 `default` 与 rule 5 的「按当前状态延续」是合并语义而非重复分支
(前者覆盖 login/session 路径的延续,后者覆盖非登录 github 路径)。
「登录页重复注入」由视图 `lastExecutedJS` 去重(同 step+js 只注入一次)与 decide 决策去重配合,
无无限重填死循环;本轮新增终态守卫补齐唯一缺口(见 #6)。

## 轮询终止条件核查

- 成功:`succeed()` → `stopPolling()` ✔;取消:`cancel()` → `stopPolling()` ✔;
  超时:超时任务 → `stopPolling()` ✔;任务本身 `guard !Task.isCancelled, !succeeded`。
- 取消后轮询残留:定时器已 invalidate;in-flight `getAllCookies` 回调由 #1 的终止标记拦截 ✔。
- `startPolling` 有 `pollTimer == nil` 去重,不会叠加多个定时器 ✔。

## 实际修复清单(commit)

| commit | 内容 |
|--------|------|
| `4a69c16` feat(loginaudit) | decide 终态硬守卫 + isGitHubHost / isCredentialSubmittedState / shouldRestartTimeout 判定收敛 |
| `9cfabfc` fix(loginaudit) | 视图:终止标记、取消/超时残留回调拦截、一次性注入取消管理、OTP 探测竞态守卫、步骤变化重启超时、start() 幂等复位 |
| `b079baf` test(loginaudit) | 新增 6 条单测(终态守卫 / 域名判定 / 阶段判定 / 超时重启×3) |

门禁:204 测试全绿(198 基线 + 6 新增);`swift build`、`git diff --check` 通过。
