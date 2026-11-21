# Changelog

本文件记录 LIWENJSON 的所有重要变更。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

第三轮审计（`marks/1120优化.md`）以「让真实宿主按文档使用 CLI、serve/MCP、包装层」为问题：
上一轮修的是执行语义与 provider 终态，这一轮发现的是**协议帧、参数显式性、资源算术与
公开 API 边界**上的错误放行。每一条都有定向回归（`test/1120/`、`code/tests/`），且在旧
实现上会失败。当前树：四个后端 `358/358`、CLI 冒烟 169 项、npm 21 个 Node 测试、
Python 66 个测试、协议一致性 19 组、MCP 契约 13/13。

### Schema 约束顺序审计（1121 追加）

验收指出的核心问题——只调整声明里 `const`/`enum` 的书写顺序，就能让不满足 `const` 的
`mode=write` 变成可执行——已由 1.5.1 的 `c1168b1` 修复并按 TC-GATE-01..27 钉住。本轮
按同一类错误（合取被覆盖、判定依赖书写顺序）重做一次变形审计，覆盖 16 组声明 × 全部键序、
输入对象键序、原子约束合取、一次性/流式终态，共 6650 项检查。审计发现三类缺陷：

- **文本骨架的重复约束关键字仍然后者覆盖前者**：`string(enum:["read"],enum:["read",
  "write"])` 放行 `"write"`，`number(minimum:5,minimum:1)` 放行 `1`，
  `{}(additionalProperties:false,additionalProperties:true)` 放行任意多余成员；反向书写
  则拒绝。现在重复约束名（九种名字，大小写不敏感）在建模阶段报 `E070`（TC-GATE-28），
  两种顺序都拒绝。
- **文本骨架接受矛盾边界**：`string(minLength:4,maxLength:1)` 与
  `number(minimum:5,maximum:1)` 解析成功、运行期拒绝一切值，而 JSON Schema 桥对同样的
  声明报 `E070`。两个声明面现在共用 `Constraints::bound_problem()`，矛盾边界在建模期即
  `E070`（TC-GATE-29），错误文本按各自的来源前缀（` schema:` / `json schema:`）区分。
- **流式终态缺判定字段**：`watch.finish` 只返回解析结果，宿主无法知道已发布的
  `root_ready` 是否仍然成立，也无法区分「稳定拒绝」与「重复键让早先事件成为临时」。
  现在返回 `verdict`、`conflict`、`ready_standing` 三个字段（`PROTOCOL.md` 已写明），
  重复键合并的两种结局都有回归。

### 真实 Claude Code 会话（1121）

用 `claude --dangerously-skip-permission` 跑真实模型会话，把 19 个真实 tool_use
（含一个 2857 字符的 `edit_file` 流）喂给 `llm`、`serve` 与 MCP。引擎与 adapter 的
分块/前缀/变异回放全部一致；会话暴露的是**接入配方与终态**上的四处错误放行：

- **没有参数的 tool call 变成 `null` 或让整条流失败。** `push_arguments` 现在忽略空
  片段，`close_call` 在 `Complete` 且从未收到参数字节时合成 `{}`（`exact` 且可执行）；
  中断/超预算仍不可执行。OpenAI 的 `finish_reason` 分片即使没有 `delta` 也会关闭调用。
  新增 `llm/noarg_wbtest.mbt` 五个用例。P1-1。
- **`explain` / `readiness` / `llm --sse` 把非法 UTF-8 替换成 U+FFFD 后当成 `exact`。**
  一次性读取改为严格 `@utf8.decode`，`E040` 带偏移、exit 3，与 `repair`/`serve`/`MCP`
  一致；合法 U+FFFD 仍放行。CLI 冒烟加四条回归。P1-2。
- **Claude Code hook 在带空格的工程路径上 fail-open。** 安装器与文档示例给
  `${CLAUDE_PROJECT_DIR}/...` 加引号，因为 Claude Code 把 command 交给 `/bin/sh`；
  路径含空格时旧写法 127 退出，工具照常执行。重复安装改为替换而不是追加。P0-1、P2-2。
- **hook 的两个 fail-open。** 缺 `jq` 或缺声明文件时旧脚本直接 exit 0；现在都打印原因
  并 exit 2。`hook_replay.py` 用录制下来的 settings 命令覆盖这些分支。P1-3、P2-1。

### 协议与参数（CLI / serve / MCP）

- **`--policy` 与显式安全参数同时出现时被接受。** 两者语义冲突时旧实现静默取其一。
  现在按「参数是否在命令行上显式给出」置位（不是按取值是否非默认），与顺序无关；
  两种顺序、显式默认值都拒绝（exit 2），非冲突正例保留。P0-04。
- **`--batch` 在 stdin 未关闭时不输出。** 旧实现块读取等到 EOF。重写为严格 UTF-8 的
  逐行 reader：读一行、处理一行、逐行 flush，超长行整体丢弃并报错；每一行都走
  `--schema` 判定（`E070` / 行内 rc 5），写失败 exit 70。P0-01、P0-02、P0-08。
- **`llm` 的 `--strict` / `--policy` / 资源上限被静默丢掉。** 三条路径现在共享同一份
  `Options` 与错误分类；`--provider openai --strict` 的尾逗号 rc=5（`E010`）。P0-03。
- **长驻模式接受一次性参数。** `serve`/`mcp` 拒绝 `--check` 与文件路径（exit 2，固定
  stderr），不再启动一个「什么也没检查」的服务器。P1-01。
- **帧错误被当成连接错误。** `mcp` 对坏 JSON / 超长行 / 非法 UTF-8 回 `-32700` 后继续
  读下一帧；`serve` 对非法 UTF-8 回 `E040`（exit 3）且连接继续；合法 U+FFFD 照常放行，
  不再被替换成 U+FFFD 后冒充 `exact`。P0-08、P1-02。
- **`inputSchema` 声明了却不校验。** `liwenjson_gate.with_text`（boolean）与
  `liwenjson_readiness.step`（integer，`0`..`8388608`，`0` = 自动）进入工具声明；服务端
  在 walk 之前拒绝小数 / 越界 / 错类型 / 未声明字段（`E050`）。P1-03。
- **stdout 不可写时仍返回成功。** 打开失败、短写、`fflush` 失败一律诊断并非零退出（70）；
  POSIX 平台忽略 `SIGPIPE`，读端关闭变成写错误而不是信号。P1-04。

### 引擎

- **缺失成员被伪装成 `null` 并标成就绪。** 新增 `field_missing` 事件（`FieldMissing`，
  verdict 事件）；`value_at()` 返回 `Json?`，`ready_count()` 只在成员存在且类型被接受时
  计数：显式 `null` 是正例、缺失是负例、类型错是第三种。P0-05。
- **根路径与空成员名共用空串。** 新路径层：根是 `""`、空键是 `/`、含 `.`/`/`/`~` 的键
  走 RFC 6901（`/a.b`、`/a~1b`），数组下标拒绝前导零（`01` 是键不是槽位）；
  `at_path`/`lookup_path`/`required_paths`/walk 与 watcher 事件路径统一。P1-09。
- **输出没有预算。** 新增 `Options.max_output_len`（默认 64 MiB，单位 UTF-8 字节）与
  `MAX_INDENT = 64`；渲染按字节增量记账（缩进用 `Int64` 相乘、转义按 JSON 形式计费），
  越界立刻 `E023`，不会先分配 GB 级文本再检查。P2-01。
- **permille 用 Int32 相乘。** `3_000_000/6_000_000` 现在稳定为 `500`，不钳位、不截断、
  不靠缩小 step 掩盖。P2-02。
- **公开 Schema 遍历会 SIGSEGV。** `stringify()` 与 `required_paths()` 改为显式工作栈，
  加深度/节点预算与祖先链环检测（`E070`）；合法共享子结构不误判为环。P2-03。

### Provider 适配

- **小数 tool index 与同帧多 choice 被静默合并。** 索引必须是 Int32 范围内的整数
  （否则 `E060`；`0.5`、`2^31`、字符串都拒绝），字段缺失仍是默认 0；`TextStream` 在同一
  流里遇到第二个 choice 明确 `E060`，不再只留最后一个。P1-08。
- **retry 恢复的根只喂了一半判定。** `finish()` 与 `snapshot()` 对同一 retry 输入给出
  不同 exactness。重试现在把 exactness / ambiguous / repairs 一并采纳（只升不降），
  retry 路径与直读在 `FinalResult`、finish 后 snapshot、delta 重放、watcher 上一致。P1-07。

### 包装与安装

- **npm `snapshot()` 用 `" | "` 拆分展示串。** 改为扫描 JSON 值边界 + 固定状态词
  （`Empty`/`Partial`/`Complete`），值、键名、根字符串里的分隔符不再抛
  `SyntaxError: Unterminated string in JSON`。P0-06。
- **Python 客户端的超时是每步的、协议错误会退化。** 改为全程单调 deadline（锁、写、读
  共用剩余预算）；非 JSON 行、JSON 标量、非法 UTF-8 粘性成为 `LIWENJSONProtocolError`；
  close 有界、幂等，失败连接 terminate/kill/wait 回收；重复请求在 close 后明确拒绝。
  P0-07、P1-05。
- **HTTP facade 在读完 body 之后才发现长度非法。** 先校验负/非数字/重复
  `Content-Length`、不支持的 framing：400；超上限 413（不读 body）；超时统一 408；
  body 上限独立于 `max_input_len`。P1-06。
- **`--from-local` 把 macOS 二进制装进 linux 路径。** 现在只允许宿主目标（复制前 exit 2），
  每个资产检查 ELF/Mach-O/PE 与架构，打包后真启动宿主二进制。P2-06。
- **安装器平台表与 Release 产物不一致。** `install.sh` 平台表 = `release.yml` 的 `want=`
  = 7 个产物；Windows arm64 / Intel macOS 在下载前 exit 2 并说明原因。P1-10。
- **README 示例照抄会 `KeyError: 'text'`。** 示例改用 `plan["value"]`；
  `code/python/tests/test_readme.py` 原样执行 README 首个 Python 块；`pyproject.toml`
  不再声明 `OS Independent`，README 写明四平台支持与 Alpine/musl 未测。P2-04、P2-05。

### 门

- **`claims.sh` 的 any-of 匹配让陈旧文档通过。** 改为「锚点行 + 值都必须命中」，逐文档
  检查；MCP 计数从整份日志取（脚本以散文结尾，取最后一行会得到空值）。
- **独立报告不再靠手改。** `code/tests/independent_report_check.py` 重新生成并比对
  （归一化时间戳、二进制 sha256、oracle 列）；CI 里原来的 `git diff` 在
  `working-directory: code` 下 pathspec 恒空。
- **examples 只看 stdout。** 改为 exit code + stdout 双条件；缺 `.expected` 失败、空用例
  目录 exit 2。
- **coverage 缺豁免清单**从 warning 改为 exit 2（ratchet 不能运行时不算通过）。
- **Windows CI** 钉 `MOONBIT_INSTALL_VERSION` 并逐条检查 `$LASTEXITCODE`。
- **Release** 逐资产下载 + SHA256 校验（无 token exit 3，`--no-skip` exit 2）；新增
  `release_manifest_check.sh`（release.yml `want=` ↔ 7 个产物 ↔ install.sh 平台表，假
  curl 实跑安装器）与 `run_protocol_contract.py`（长驻模式、严格 UTF-8、inputSchema
  执行）两组门。C-01…C-09。

### 行为变化（升级前请读）

- `Options` 新增字段 `max_output_len`：以结构体字面量构造 `Options` 的代码需补字段
  （`{ ..Options::default(), … }` 写法不受影响）。
- 库层 `indent` 上界与 CLI 对齐为 `64`（超过是 `E050`），不再接受任意非负值。
- 新增错误变体 `OutputLimit` → `E023`；`Schema::stringify()` / `required_paths()` 现在会
  `raise LIWENJSONError`（深层、环、超预算都是 `E070`）。
- `TextStream` 拒绝第二个 choice；畸形 index 是 `E060` 而不是 0 号 call。
- 长驻模式拒绝 `--check`（exit 2）；`serve` 的非法 UTF-8 是 `E040` / exit 3。

## [1.5.2] - 2026-11-08

第二轮审计（`marks/迭代.md`）以「把一个真实模型的后端接到闸门上，看会错在哪」为问题。
上一次审计修的是「声明的语义」，这一次发现的是**执行语义、provider 终态与协议契约**上
的错误放行。每一条都由 `code/tests/live_model_audit_v2.py` 用真实 Responses API 复现或验证。

### 安全：闸门仍会错误放行

- **2^53 以上的数值边界被 `Double` 折叠。** `maximum:9007199254740992` 放过
  `9007199254740993`，`minimum:9007199254740993` 放过 `9007199254740992`——两个相邻
  整数在 `Double` 里是同一个值。约束比较改为在**十进制原值**上做（`decimal.mbt`）：
  引擎本就保留了数字的源文本，比较覆盖符号、小数点、指数与前导零。`integer` 判定
  同样改精确：`2147483648`、`1e3`、`1.0` 是整数（旧版用 `Int32` 往返，`2147483648`
  被截断成非整数）。无法精确归一化的边界在建模阶段是 `E070`，无法归一化的值在声明了
  边界时被拒绝（fail closed），而不是退回 `Double` 猜测。SR-41。
- **`minLength`/`maxLength` 数的是 UTF-16 码元，不是码点。** `"😀"` 是 2，所以
  `minLength:2` 放过一个字，`maxLength:1` 拒绝一个字。改为按码点计数。SR-42。
- **`format` 被当 annotation 静默忽略。** JSON Schema 允许这样做，但一个写了
  `format: "email"` 的宿主以为地址被校验过。现在 `format`、`contentEncoding`、
  `contentMediaType` 是 `E070`，消息说明它们未被检查以及宿主可以怎么处理。SR-44。
- **`additionalProperties: false` 是 `E070`，所以标准 strict 工具声明无法过门。**
  真实模型用最常见的 OpenAI strict 声明生成了完全合法的 `{"query":"MoonBit"}`，闸门
  拒绝；更糟的是本服务自己 `tools/list` 公布的每个 `inputSchema` 都带
  `additionalProperties:false`，把它原样作为 `schema_json` 传回来也会被自己拒绝。
  现在实现封闭对象语义：未声明成员被拒绝并指出成员名，`true` 是开放语义（默认），
  出现在非 `object` 节点上是 `E070`。嵌套对象与数组内对象同样适用。SR-43。

### 流式：最终判定与 `RootReady` 的语义

- **可选字段让最终判定消失。** `{!a:string,?b:integer}` 收到 `{"a":"ok",` 后发布
  `root_ready`，随后 `"b":"bad"}` 没有任何事件，`finish()` 之后仍然没有
  `root_invalid`——而同一完整文档走 `analyze` 是 E070。现在流结束时用最终值重新评价，
  不成立则发布 `RootInvalid` 撤销先前的 `RootReady`；`ready_standing()` 报告该许可
  是否仍然成立，`root_ready` 不会被重复发布。SR-40。
- **裸标量根的 watcher 与 `analyze` 矛盾。** `skip_prose` 重试恢复了值并把它返回，
  却没有把它交给引擎，于是 `watcher_final.value` 是 `42` 而事件是 `root_invalid`。
  重试现在把值也采纳进引擎：一个解析器，一个值。

### Provider：终态、协议与并发

- **`content_filter` / `refusal` 被标成正常结束。** 两个适配器都把任意未知
  `stop_reason` 映射为 `Complete`，于是被撤回的响应是 `done: true, exactness: exact`。
  改为白名单：`stop` / `tool_calls` / `end_turn` / `tool_use` / `stop_sequence` 等才是
  正常结束；过滤与拒绝是新的 `Refused` 终态，无法识别的词是 `Unknown`。`CallEnd`
  新增 `is_normal()` / `is_executable()`，`ToolCallView::is_executable()` 还要求参数
  没有经过有损修复——provider 可以在参数字符串被截断时仍然说 `completed`。
- **真实的 Responses API 流被静默丢弃。** `--provider openai` 只读 Chat Completions 的
  `choices`，而真实事件是 `response.output_item.*` / `response.function_call_arguments.*`
  / `response.completed`：两路命令都退出 0、无输出、无 stderr——一个评测 harness 会把它
  读成「模型没有发起工具调用」。新增 `openai-responses` provider 与完整读取器
  （`item_id` 身份、`delta` 增量而 `done` 是全量），Chat Completions 读取器现在对
  Responses 事件报 `E060` 并点名正确的 provider。未知的 `response.*` 事件被记录，
  而**一个没有任何调用却带着未知事件**的流在 `finish` 时被拒绝。
- **多 choice 混参、丢调用或崩溃。** 调用只用 `tool_calls[].index` 定位，任意 choice
  结束还会关闭全部调用：两个 choice 都用 tool index 0 时参数被并进第一个，choice 1
  先结束时 `E030 cannot feed a finished parser`。改为以 `(choice.index, tool_call.index)`
  为键、按 choice 关闭、`finish_reason` 只作用于本 choice。
- **`data: [DONE]` 让一次成功的流失败。** 终止哨兵不是 JSON，喂给读取器会 `E060` 并
  丢弃已经累积的调用。分帧处丢弃它。
- **`--follow` 在截断流上什么都不打印，provider 错误退出 0。** `finish()` 产生的调用
  现在一定会打印；provider 错误是退出码 4。
- **SSE 的 CRLF 跨 chunk 被读成两个终止符。** 一个事件被派发两次——一次带载荷，
  一次为空。

### MCP：公布的契约与实际响应

- **四个工具的真实 `structuredContent` 全部不能通过自己公布的 `outputSchema`。**
  `liwenjson_gate` 缺 required `text`（默认不发送，是 `value` 的渲染形式）；
  `liwenjson_repair`/`liwenjson_validate` 的修复记录是 `code/threshold` 而 schema 要求
  `rule/name/confidence_class`；`liwenjson_readiness` 返回了未声明的 `events`。
  修复记录现在只有**一份定义**（`repair_record_json()` 写、`repair_record_fields()` 列、
  `outputSchema` 从它生成），四个入口（analyze / repair / validate / 工具）形状一致。
  `code/tests/mcp_contract_check.py` 对真实二进制跑完整矩阵。
- **JSON-RPC 2.0 信封从不校验。** `{"jsonrpc":"1.0","method":"ping"}` 与
  `{"method":"ping"}` 都成功。现在校验 `jsonrpc`/`method`/`id`/`params`，错误是 `-32600`；
  批处理在要求它的修订（`2025-03-26`、`2024-11-05`）上返回数组，在 `2025-06-18`
  上用理由拒绝，而不是用一个 `missing method` 回答整个数组。

### 真实客户端：强制门真的拦住了

把 `PreToolUse` hook 装进真实的 Claude Code 2.1.145 会话（`claude -p ...`），
让模型执行 `touch pwned.txt`：hook 拒绝，模型读到 gate 的 `retry.prompt`，
**文件从未被创建**；同一会话里 `echo read-only-ok`（声明里唯一允许的命令）
通过并执行。另一次会话里模型直接调用 `mcp__interjson__interjson_gate`，
得到 `decision: invalid, executable: false` 并按此回答。

真实会话推翻了配方里的一条结论：**`exit 1` 不阻止调用**。第一版 hook 在
找不到 gate 二进制时 `exit 127`、脚本兜底 `exit 1`，Claude Code 报「hook error」
之后**照常执行**了 `touch`——那是带错误信息的 fail-open。现在一律 `exit 2`
（`permissionDecision: deny` 那条路径 exit 0 也可以，两者都验证过）。
另一个真实条件：hook 进程几乎没有 `PATH`，二进制必须显式命名。

证据在 `code/tests/claude-e2e/`（包含真实的 deny/allow 会话记录与 hook 配置），
`code/tests/hook_replay.py` 把录制的 payload 重放进那个脚本，包含
「gate 二进制缺失必须 exit 2」这一支，所以接线不会在两次录制之间腐坏。
接线本身是可安装的：`code/tests/install_gate_hook.sh [项目目录]` 会装好 hook、
声明文件与 `settings.json`，并把 `LIWENJSON_BIN` 指到二进制（hook 几乎没有
`PATH`，不指名字就是 exit 127，然后工具照常执行）。

被拒的那次会话里模型**只调用了 Bash、从未调用 MCP 工具**——它绕过了 MCP，
仍然被拦住。这正是审计要的「模型绕过 MCP 时仍无法执行」的证据，
`hook_replay.py` 把这条也断言了。

另有一次**交互式**终端会话（Claude Code 2.1.319，`claude
--dangerously-skip-permissions`，经 pty 驱动）：第一轮模型回 `pong`，第二轮让它
`touch pwned.txt`，footer 显示 `1 MCPs | 1 hooks` 与 `✓ Bash ×1`，hook 拒绝，
`pwned.txt` 没有生成，模型自己总结「The command was blocked before it ran」。
原始捕获在 `code/tests/claude-e2e/interactive-turn{1,2}.txt`。

### 真实客户端：握手探测被当成错误

用真实的 Claude Code 2.1.308 连本服务时发现：它在 `initialize` **之前**先发
`server/discover`，而服务器用 `-32002 server not initialized` 回答了这个探测。
它拒绝的是一个不需要会话的问题，而一个没有 Claude Code 这么宽容的客户端会直接
连不上。`server/discover` 现在用握手会报告的身份加工具列表回答。
`code/tests/record_mcp_handshake.sh` 记录客户端逐字节请求，
`code/tests/mcp_client_replay.py` 把它重放成一道门。

### 执行语义：闸门不宣称它没有的保证

- **`SAFE TO EXECUTE` 超出实际保证。** 真实模型把 `../../etc/passwd` 判成 safe；另一次
  真实重试把用户要求的 `write` 改成 `read` 后通过。标签改为
  `JSON/SCHEMA POLICY PASSED`，载荷新增 `business_authorized: false`（恒为 false），
  工具摘要明确说明路径、权限与用户意图策略仍由宿主负责。
- **拒绝现在说明能不能自动重试。** `refusal.kind` 是 `syntax`（可以重试）、
  `schema_or_intent`（**不要**自动重试：重试可能换成一个不同的动作）、
  `host_declaration`（改声明）或 `provider`（无可重试）；只有 `syntax` 有
  `auto_retry: true`。宿主因此不必记住哪些错误值得回灌模型。

### 客户端与命令行

- **npm 的 `repair` 静默忽略 `schema`/`schemaJson`。** 同一份输入在 npm 上被接受，在
  Python 与 MCP 上被拒绝。现在声明被遵守，违反时抛 `E070`。
- **Python 文档示例读 `plan["text"]`。** 默认的 `analyze` 不发送 `text`，示例会
  `KeyError`。示例改用 `value`，客户端新增 `with_text` 参数。
- **`--quote-lookahead` 的空白不受 `--max-token-len` 约束。** 候选引号与其后的空白
  最终会成为 token 内容，上限必须覆盖它们。
- **`--batch` 先读完整个 stdin 才回答第一行。** 改为逐行读取（同一个 `LineReader`），
  并给每行加上限。

### 版本

引擎 **1.5.2**，mooncakes 对应版本 **0.14.0**（`1.1.x`↔`0.8.x` … `1.5.1`↔`0.13.x`
之后的下一个）。`moon.mod`、`version.mbt`、`npm/package.json`、`python/pyproject.toml`
与所有公开文档同步。**没有覆盖已发布的 1.5.1**：它仍在 npm 与 PyPI 上，是另一个版本号。

### 证据

| 验证 | 结果 |
| --- | --- |
| `moon test`（wasm / wasm-gc / js / native） | 各 323/323 |
| `tests/cli_smoke.sh` | 146 项断言 |
| `tests/conformance/run_conformance.py` | 19/19 组 |
| `tests/json_schema_diff.py` | 52 例，无 gate allow / reference reject |
| `tests/eval/run_eval_paths.py` | 六条路径各 1200/1200（新增 `openai-responses`） |
| `tests/coverage.sh` | 库 91.7%，五个核心文件 ≥ 90% |
| `code/tests/mcp_contract_check.py` | 11/11 响应通过自己的 `outputSchema` |
| `code/tests/live_model_audit_v2.py`（真实 Responses API） | 34/34 |
| `tests/run_llm_loopback.py` | 8 个 fixture（新增真实 Responses 录像） |
| `tests/mcp_client_replay.py`（真实 Claude Code 2.1.308 握手） | 通过 |
| `tests/hook_replay.py`（真实 PreToolUse 拒绝/放行） | 通过 |

文档同步：`docs/SPEC.md` 新增 SR-40…SR-44，`docs/PROTOCOL.md` 写明修复记录的单一形状、
`with_text`、`business_authorized` 与 `refusal.kind`，`docs/MCP.md` 写明输出契约与
JSON-RPC 检查，`docs/LLM_EVENTS.md` 写明 Responses 协议与终态语义。

### 前一轮：Schema 闸门的合取语义（同一版本，`marks/审计.md`）


### 安全：Schema 闸门错误放行（`marks/审计.md`）

这一节记录一次以「门能不能被绕过」为问题的审计，以及修复。每一条都曾经让一个
**不满足声明的值**被判定为可执行；它们不是精度问题，是执行门的问题。

- **`const` 与 `enum` 不是合取，而且结果依赖字段顺序。** 桥接层把两个关键字写进
  同一个槽位，后写的一个覆盖前一个，于是
  `{"type":"string","const":"read","enum":["read","write"]}` 放行 `"write"`，
  把 `const` 和 `enum` 换个位置又拒绝它。现在两者是交集：允许值集合是
  `{const}` ∩ `enum`，交集为空是 `E070`（声明不可满足），判定与书写顺序无关。
- **带值约束的容器跳过内部结构。** `{"type":"array","enum":[[1],["bad"]],"items":{"type":"integer"}}`
  放行 `["bad"]`，`{"type":"object","enum":[…],"required":["mode"]}` 放行缺少
  `mode` 的对象。现在同一节点上的值约束与结构约束是合取；`evaluate`、
  `required_paths`、`at_path`、`member_keys`、`field`、`collect_required` 与流式
  watcher 共用一个「取结构内层」的访问器，不再各自解释一遍。
- **`pattern` 量词整数回绕。** `{4294967296}` 被折成 `{0}`，于是空串通过了
  「恰好 4294967296 个字符」的声明。超出 `Int32` 上界的量词现在是 `E070`。
- **`items` 没有 `type` 时被静默丢弃。** 现在 `items` 只能与 `type:"array"` 同现，
  `properties`/`required` 只能与 `type:"object"` 同现，否则 `E070`。空 `enum`、
  `const` 不在 `enum` 内、`minimum > maximum` 等不可满足的声明同样在建模阶段拒绝。
- **裸标量根类型不参与判定。** `{"type":"string"}` 放行数字 `42`。根声明现在和
  其它节点一样检查；这是公开语义变化：`Schema::evaluate` 对裸标量根的判定在
  1.5.1 及更早版本里恒为真，自本次修复起按声明检查。
- **`liwenjson_repair` 完全不读 `schema` / `schema_json`。** 连不支持的 `$ref` 都不报
  `E070`，修复后的文档违反声明也返回 `ok: true`。现在 `repair` 解析声明（不支持的
  关键字是 `E070`），修复后的值不满足声明时拒绝，与 CLI 的 `--schema` 门一致。
- **`Schema::stringify` 丢失容器约束。** `Constrained(Arr/Obj, c).stringify()` 只写回
  内层容器，`parse(stringify(s))` 因此是一个更弱的声明。现在约束会写出来
  （`{!a:integer}(enum:[{"a":1}])`、`[integer](enum:[[1]])`），文本形式对桥接层
  可构造的声明无损。
- **流式路径的过早判定。** 带容器约束的声明在成员就绪时就会发布 `RootReady` /
  `RootInvalid`，此时容器的值还没闭合，`enum` 无从判断。现在这类声明的 verdict
  等根值闭合；一次 feed、逐码元 feed 与任意分块大小的最终判定一致。

文档同步：`docs/SPEC.md` 新增 SR-34…SR-39，`docs/MCP.md` 写明 JSON Schema 子集的
合取语义与 `repair` 的声明契约。回归测试见 `schema_gate_wbtest.mbt`
（TC-GATE-01…19、TC-GATE-26/27）、`stream_readiness_wbtest.mbt`（TC-GATE-20…23）、
`tests/cli_smoke.sh`（CLI 与 MCP 端到端）、npm 与 Python 包测试。

### 发布记录（2026-11-20）

标签 `v1.5.2` **被移动过一次**：先指向 `8ef74df`，CI 在「LLM fixtures are in
sync」上红（`tests/gen_llm_fixtures.py` 拿未格式化的文本和 `moon fmt` 的输出比，
两者永远不可能同时成立），修好门之后移到 `83307c4`。移动时 Release 不存在、产物
0 个、三个注册表都没有 1.5.2，没有已存在的引用被改写——与 `v1.5.0` 那条例外同型
（`AGENTS.md` 已把它记为第二例）。发布由 `release.yml` 完成：八个 `liwenjson-*`
产物 + `SHA256SUMS`，CI 十二项全绿（四平台 CLI 矩阵、wasm 探针、浏览器 bundle、
差分与基准）。npm `liwenjson@1.5.2`（2026-11-20）与 PyPI `liwenjson-1.5.2`
（wheel + sdist，wheel 内带四平台引擎，装完即可用）已上传；
`curl -fsSL .../releases/latest/download/liwenjson-install.sh | sh` 端到端验证装到
`liwenjson 1.5.2`。**当天未做的一件事**：旧名 `interjson-moonbit` 在 npm 上尚未标
deprecated（发布用的 Automation token 只授权了新包，需要覆盖旧包的 token 或
`npm login` 才能改）。

### mooncakes `0.14.0`（2026-11-20）

第四个渠道补齐：`zhanshishan/liwenjson@0.14.0` 已上传，`moon publish` 返回
`Server status: 200 OK`。三点值得记下：

- **模块名换了，注册表不认改名。** mooncakes 上这个包的历史是三个名字：
  0.3.0–0.8.1 是 `zhanshishan/jsonmend`，0.11.0–0.13.0 是 `zhanshishan/interjson`，
  0.14.0 起是 `zhanshishan/liwenjson`。旧条目留在原名上，不会被新包接管。
- **发布号由平台规则决定，不由我们决定。** `moon.mod` 写 `1.5.2` 时服务器直接
  `403 Publishing versions with a major version greater than 0 is not enabled`，
  所以 1.5.2 的注册表对应号是 `0.14.0`（映射见 `version.mbt`）。发布用的是仓库外
  的一份副本，只把副本 `moon.mod` 的 `version` 改成 `0.14.0`；工作树里的
  `moon.mod` 仍是 `1.5.2`——`tests/cli_smoke.sh`、`python/build_wheel.sh` 和
  `python/tests/version.py` 都把它当引擎版本读。
- **拉回验证。** 全新模块 `moon add zhanshishan/liwenjson` 解析到 `0.14.0`，native
  编译通过，`analyze("{\"a\":")` 返回 `REJECT (a value was changed)` /
  `executable=no` / `normalized=yes`，与标签上的黄金用例一致；把注册表解出来的源码
  与 `v1.5.2` 逐文件比，`.mbt`/`.mbti`/C/JS/JSON 全部一致，`moon.mod` 只差那一行版本，
  其余差异只有 `.md`。附带一条既有行为：`moon publish` 会打包 `docs/` 里的本地文档
  （0.13.0 同样如此），发布前值得确认这些文档没有不该外传的内容。

注册表不能改名，能做的只有把旧名指过去：同一天用 `moon deprecate` 把两个旧模块
标为废弃，理由文本写明新名（`moon deprecate <模块> --undo` 可撤销，模块级生效）：

```
Deprecated zhanshishan/interjson (existing versions: 3).
Deprecated zhanshishan/jsonmend (existing versions: 8).
```

之后 `moon add zhanshishan/interjson` 会打印
`Warning: Dependency zhanshishan/interjson@0.13.0 is deprecated: Renamed: use
zhanshishan/liwenjson (LIWENJSON) - this module name is the pre-rename brand`；
新模块 `zhanshishan/liwenjson` 无此警告。已发布版本本身不变，选择版本的行为也不变，
只有在依赖被解析出来时提示。

## [1.5.1] - 2026-10-29

1.5.0 的 tag 打出去之后，深度与内存上的工作才做完。两者不能混在一个版本里：
**tag 是发布物，分支是后来者**，而 1.5.0 的二进制与 1.5.0 的文档说的不是同一件事。
这一节把 tag 之后进默认分支的引擎工作单独记下来，并重新发布——
**"README 说的"和"你装到的"必须是同一个东西**，否则发布这件事就没有意义。

版本对应 **1.5.1**（GitHub）↔ **0.13.0**（mooncakes）。

### 深度：`max_depth` 不再只能收紧

值上的四个遍历——`copy_json`、`json_equal`、`Schema::evaluate`、渲染——原本都是递归的，
所以"能处理多深"是原生栈的属性而不是机器的属性：wasm 后端在 896–1024 帧之间爆栈。
1.5.0 把 `max_depth` 卡在 512，正是为了让"拒绝而不是崩溃"成立，代价是调用方只能收紧、
不能放宽。四者都改成显式工作列表（渲染器同时替掉 core 里递归的 `Json::stringify`，
包括 plan 的 `value` 字段），上限因此变成防笔误的理智上界 `MAX_VALUE_DEPTH = 1048576`：
**10 万层的文档四个后端都能解析、渲染、判等、拷贝**。

声明（JSON Schema 与骨架 DSL）仍由两个递归解析器读，`MAX_SCHEMA_DEPTH = 256` 保留——
这是目前唯一还受栈限制的地方，`SECURITY.md` 如实这么写。

### 内存：三处真实浪费

- **数值**：每个数字都把源文本存成 `repr`，于是整数文档为每个整数分配一个 `String`，
  而那个文本对 `Double` 是可往返的、白存。现在只在文本确实承载信息时才存
  （`1.0`、`1e2`、`-0`、`9007199254740993` 仍然存；`12345` 不存），
  与核心序列化器的一致性由 `TC-R-24` 钉住。
- **容器**：`Map([])` 一次开八个槽、`Array` 同理，单键对象为另外七个空槽付费，
  且每一帧无论种类都同时分配数组和映射。现在容器按实际内容定尺寸（关闭时一次），
  帧只为自己的种类分配。
- **渲染器**：原本把容器的全部子节点一次性压进工作列表，对百万元素数组来说那就是峰值
  分配；改成游标逐个走。

实测（20 万元素，边际峰值 ÷ 输入）：整数 9.7 → **5.2 倍**、嵌套数组 47 → **24 倍**、
对象 29 → **24 倍**。标量进入 4 倍预算；容器没有，且在值是 core 的 `Json` 时不可能进入。

### 门：内存从"被打印"变成"被守住"

新增 `code/tests/memory_gate.py` 并接入 CI：同一组形状、每个形状一条记录的天花板，
涨过就失败。此前 `docs/MEMORY.md` 的数字只是被打印，漂了没人发现。已验证它能抓住真实
回退——把 `shrink_array` 关掉后 `[[1]]` 从 26.8 倍涨到 46.5 倍，门 exit 1。

### 文档

- 发布面 **478 KB → 346 KB**：删除 `PITCH.md`、`ONEPAGE.md`，三份 README 去重，
  1.2.0 及更早的更新日志移出发布面（旧条目在本地 `marks/CHANGELOG-history.md`，
  也仍在 git 历史与 GitHub Release 里）。
- 新增 `code/docs/NOTREE.md`：无树模式的完整设计——要解决的问题、四个真正需要值的点、
  验收判据、实施顺序。**它是设计，不是已实现的功能。**
- 已发布文档不再引用未发布文档（此前有 33 处死链，其中 `code/README.md` 是 mooncakes 包页）。

### 语言包：npm 与 PyPI 都发布了（2026-10-30）

`interjson-moonbit@1.5.1` 于 2026-10-30 发布到 npm 与 PyPI（当时的发布名；本仓库现名 LIWENJSON，包已改名 `liwenjson`）。两个渠道的安装形态不同，
这不是疏漏：

- **npm**：包内带引擎的 JavaScript 编译产物（`vendor/liwenjson.js`），装完在 Node 里
  直接可调；`liwenjson-mcp` 启动器仍需要原生二进制。
- **PyPI**：wheel 内带**四个平台的 native 二进制**（`linux-x86_64`、`linux-arm64`、
  `macos-arm64`、`windows-x86_64`，共约 3.4 MB 未压缩），`find_binary()` 按
  `sys.platform` + `platform.machine()` 选当前平台那一份。`pip install interjson-moonbit`
  是完整安装，不需要 `LIWENJSON_BIN`、不需要 PATH 上有 `liwenjson`、不需要 MoonBit
  工具链。

  在此之前 Python 包是个"壳"：`pip install` 之后第一次调用会
  `FileNotFoundError: the liwenjson engine was not found`。把二进制放进 wheel 是唯一
  能消掉这一步的做法——装的时候不编译，跑的时候不下载。`code/python/build_wheel.sh`
  从 Release 取四个二进制并逐个核对 Release 自带的 `SHA256SUMS`，构建后断言 wheel 里
  确实有它们；`code/tests/package_dist.sh` 在空 venv 里装这个 wheel 并断言
  `find_binary()` 落到 `site-packages` 内、`repair`/`analyze`/`interjson-mcp` 都能用。

  轮到不支持的平台（Intel macOS）时，报错会说明"本包带的是哪些平台"，而不是让人
  反复重装一个不可能有产物的包。

### 未做的事（如实记录）

- **PyPI 上只有 wheel，没有可用的 sdist 安装路径之外的额外渠道**：sdist 里也带二进制，
  所以从 sdist 装同样自包含；但 `pip install` 默认取 wheel，这是被测试覆盖的那条。
- 「不建树、只出文本」的模式仍未实现：标量已在 4 倍预算内，**容器不在**（24–27 倍），
  而容器倍数在值是 core 的 `Json` 时不可能降下来。设计与验收判据见 `docs/NOTREE.md`。
- `PreToolUse` hook 配方是手工验证的草图，不是本仓库测试套件覆盖的配置。
- **文档体量仍高于评审给的 ≤ 120 KB 目标。** 随仓库发布的 markdown 从 **478 KB 降到
  337 KB**（−30%）。本轮删掉 `PITCH.md` 与 `ONEPAGE.md`，把三份 README 去重
  （根 README 62→37 KB、`code/README.md` 52→34 KB、`code/README.zh.md` 54→13 KB），
  并把 1.2.0 及更早的全部更新日志移出发布面（`CHANGELOG.md` 83→24.5 KB；旧条目在本地
  `marks/CHANGELOG-history.md`，也仍在 git 历史与 GitHub Release 里）。
  剩下的 337 KB 里，**83 KB 是生成的证据**（`DIVERGENCES.md` 40 KB、`EVAL_*` 43 KB，
  由流水线写、不由人写），96 KB 是三份 README，其余 158 KB 是接入文档与规范。
  再往下压只能压证据或压 API 参考——那是删内容，不是删重复，所以没做。

## [1.5.0] - 2026-10-28

修**两处「错误放行」**、一处**拒绝契约**、一处**档位定义漂移**，以及 CLI / MCP 协议 /
编码边界上的一组缺陷。这些缺陷都不是靠跑测试发现的，是读代码读出来的——它们全都在
「测试绿」的状态下发布过，这本身就是这一节要记下来的事实。

版本对应 **1.5.0**（GitHub）↔ **0.12.0**（mooncakes）。发布状态：
**`0.12.0` 已于 2026-10-28 上传 mooncakes**（当时以 `zhanshishan/interjson` 上传，`moon search interjson` 可见，
重复上传返回 409）；GitHub 侧 tag `v1.5.0` 已推送，Release 随该 tag 构建。
语言包当时还没有发布；npm 与 PyPI 的 `interjson-moonbit@1.5.1` 于 2026-10-30 补齐。

第一次打 tag 时 Release 失败了：`macos-15-intel` 这个矩阵项装不上 MoonBit 工具链
（`cli.moonbitlang.com/install/unix.sh` 只认 `Darwin arm64`、`Linux x86_64`、
`Linux aarch64`）。**平台矩阵不是选择题，是工具链给什么就是什么**；该矩阵项已删除，
安装脚本在 Intel Mac 上直接说明原因。

**`v1.5.0` 的 tag 被重新指向过一次**，需要记下来，因为它与本项目的发布规则相悖。
规则是「标签一旦推送不再移动」，理由是 tag 是任何引用的锚点，移动它等于改写历史。
那次移动的条件是：**Release 工作流失败、一个产物都没有对外发布、Release 记录不存在**，
所以移动没有改写任何已存在的引用。移动之后的正确做法是**不再移动**——1.5.0 之后每一处
引擎或文档的变化都进新版本，1.5.1 就是这么来的。规则没有变，只是首次破例的理由被记下来
而不是被忘掉。

### 两处「错误放行」（P0）

- **`json_equal` 按 `Double` 比较数字**：`9007199254740993` 与 `9007199254740992` 是
  2^53 之后相邻的两个整数，作为 `Double` 是同一个数。重复键合并因此被判定为「无损」、
  记为 `Info`，门对**一个已经被悄悄改过的值**回答 `executable: true`。现在按数字的
  精确十进制值比较：这一例记为 `R018` + `Warning`（有损、拒绝）。另一个方向也钉住了：
  `1` 与 `1.0`、`100` 与 `1e2`、`0.5` 与 `5e-1`、`-0` 与 `0` 仍是同一个数，合并仍为
  `Info` / `Cosmetic`，不会因为收紧比较而误报。
- **`RuleSet` 写死 22 个槽位**：`RepairCode::number()` 从 1 开始，所以 22 个槽只覆盖
  `R001` … `R021`，把同一轮新增的 `R022 NormalizeLiteral` 落在表外；`is_enabled` 的
  越界分支返回 `true`，于是 `R022` 看起来是开的，`disable(R022)` 却是**静默 no-op**——
  调用方以为自己关掉了一条规则，其实没有。现在表由 `RepairCode::count()` 定尺寸，
  越界一律 **fail-closed**（返回 `false`），`disable` / `enable` 对表外的码直接 abort
  而不是假装成功。这一条修的是**一类**缺陷（表与枚举可能不同步），不是那一个实例。

### 拒绝契约

- **不可执行的结果必带 `retry.prompt`，且 `value` 为 `null`**。1.4.x 里
  `plan_of_final` 对「被接受的结果」设 `retry_hint: None`，于是**被接受但不可执行**的
  计划（`permissive` 下的有损修复；骨架不符的值）序列化成 `"retry": null`，而工具描述
  却让调用方去读 `retry.prompt`——拒绝没有句子，同时对象里还带着一个活的 `value`。
  这正是宿主最不该看到的一种组合。现在：`executable == false` ⇒ `value: null`、
  `text: ""`、`retry.prompt` 非空；`executable == true` ⇒ `value` 存在、`retry: null`。
  两种拒绝路径（`plan_of_error` 与 `plan_of_final`）都覆盖到了。

### 档位定义漂移

- **MCP `agent` 档现在等于 `Options::for_agent()`**。按名字选档（MCP 工具、`--policy`、
  `serve`）此前只应用了 `SafetyPolicy` 的**安全字段**，丢掉了该档的**协议字段**——
  对 `agent` 就是 `skip_prose`。结果是旗舰工具 `liwenjson_gate` 拒绝最常见的模型输出
  形状 `Here are the args:\n{"a":1}`（`E002`）。现在新增 `Options::with_profile(policy)`
  与 `Options::for_profile(name)`，「一个档是什么意思」只有一处定义，库预设与按名选档
  走同一条路径。`execution` / `strict` / `interactive` / `permissive` 行为不变，仍然
  不跳前言（TC-R-12 钉住这一点）。

### 递归深度加界

- **`Options::max_depth` 有了上限**：新增公开常量 `MAX_VALUE_DEPTH = 512`（值）与
  `MAX_SCHEMA_DEPTH = 256`（声明）。`max_depth` 超过 512 报 `E050`；声明超过 256 报
  `E070`；值超过 `max_depth` 报 `E020`。上限不是策略选择：`copy_json`、`json_equal`、
  `walk_schema` 三个递归遍历与引擎自身的栈帧都以它为界，wasm 后端在 896–1024 帧之间
  会爆栈——上限高于此就把 `E020` 变回它本要防的崩溃。因为 512 也是默认值，实际效果是
  「只能收紧，不能放宽」。
- 新增公开 API：`Options::with_profile(policy)`、`Options::for_profile(name)`、
  `RepairCode::count()`。

### CLI

- **`--max-repairs 10000` 不再报错**：解析复用了上限为 64 的 `parse_uint`，于是
  `--help` 推荐的 10000 是个错误值。现在用 `parse_uint_up_to`，上限 1000000。
- **`--max-prose-buffer=65536` 现在真的是 65536**：等号形式少切了一位，`=65536` 静默
  变成 `5536`——在「缓冲区多大」这个开关上小十二倍。
- **`--print-config claude`（空格形式）可用**，未知客户端名**报错**（退出码 2）而不是
  静默回落成 JSON 配置。此前空格形式下客户端名根本没被读，typo 会打印一份看起来
  正常的配置。
- 版本字符串统一到 `code/version.mbt` 的 `VERSION` / `REGISTRY_VERSION`，`--version`
  与 `serve` 的 `engine` / `registry` 字段都从那里读，不再各写一份字面量。

### 编码与健壮性

- **stdin 只解码一次**：`--batch` / `explain` / `readiness` / `llm` 此前按 64 KiB 分块
  各自 `decode_lossy`，跨块边界的一个多字节字符在**两块里都是非法序列**，于是被解码成
  两个 U+FFFD。中文与 emoji 会静默变成错误结果——命令报告成功，读到的文档却不是写下的
  文档。现在先读字节、最后解码一次，边界不复存在。
- 新增字节级模糊测试套件（`code/fuzz_wbtest.mbt`，TC-F-01…05），把「任何字节序列不得
  panic」从一句文档断言变成被测的断言。

### MCP 协议

- **新增接受 `2025-03-26`**（此前只接受 `2025-06-18` 与 `2024-11-05`）。未知的
  `protocolVersion` 一律回 `2025-06-18`，**绝不回显**客户端给的字符串——回显一个不存在
  的版本会让客户端以为自己谈成了。
- **握手前先报错**：`initialize` 之外的请求在握手前返回 `-32002`。此前 `tools/list`
  在握手前会成功，客户端跳过 `initialize` 后拿到工具列表，却在几步之后才发现
  `instructions` 与协商版本是空的——故障离原因很远。
- **未知工具与非法 `arguments` 返回 `-32602`**：此前未知工具返回工具级 `isError: true`，
  宿主无法区分「工具跑了并拒绝」与「工具名打错了」；非对象的 `arguments` 被当成
  「没有参数」，于是一个格式错误的调用变成「缺少 text」的费解错误。
- **`outputSchema` 改成真正的逐工具 schema**（封闭、列出必需字段），不再是
  `{type: object, additionalProperties: true}`。
- **`content[0].text` 改成摘要**：决策、`executable`、`exactness`、错误与 `retry` 提示；
  载荷只在 `structuredContent` 里出现一次。此前两条通道携带同一份完整对象，一次门调用
  在线路上是两个完整副本（每个副本里还各含一份修复后文本）。

### 打包与安装

- **`code/install.sh`**：一条命令的安装脚本，判断平台 → 下载 Release 产物 → 用 Release
  自带的 `SHA256SUMS` 核对 SHA-256 → 装到 `~/.local/bin` 并打印 `PATH` 提示。校验失败
  是硬失败：删除文件，什么都不装。覆盖三个操作系统上的四个二进制
  （linux-x86_64、linux-arm64、macos-arm64、windows-x86_64）。
  **没有 Intel macOS 产物**：MoonBit 工具链只发布 `darwin-aarch64`、
  `linux-x86_64`、`linux-aarch64`，那个平台连工具链都装不上（2026-10-28 的发布
  尝试就是因此失败的）。安装脚本在 Intel Mac 上直接报错说明原因，而不是下载一个
  不存在的产物。
- `code/npm/package.json` 与 `code/python/pyproject.toml` 补齐发布元数据
  （`repository` / `homepage` / `bugs` / `author` / `engines.node >= 20`、`[project.urls]`、
  `py.typed`），版本改为 `1.5.0`。两个包在 registry 上仍是**待发布**状态。

### 测试

- **243 个测试 × 4 个后端**（wasm-gc / native / JS / wasm；1.4.0 为 217）。新增
  `code/regression_1_5_wbtest.mbt`（TC-R-01…21，本节每一处缺陷都有一条断言）与
  `code/fuzz_wbtest.mbt`（TC-F-01…05，字节级模糊）。
- **122 条 CLI 断言**（1.4.0 为 106）：新增 `--chunk N` 走一次性路径（此前只影响 `--batch`，于是这个用来压流式路径的开关从没碰过它），以及冲突选项报错（`--strict --policy permissive` 此前静默丢弃 `--strict`；`--max-depth` 与 `--policy` 同理），退出码 2。
- **19 组一致性用例**（数量不变，用例变多：MCP 半侧新增 `2025-03-26` 回显、`-32002`、
  `-32602` 与摘要通道检查）。
- 库代码行覆盖率 **4113/4431 = 92.8%**（`tests/coverage.sh` 的 `library` 行口径；
  根包 3851/4115、`llm` 包 337/391）。

## [1.4.0] - 2026-10-27

更名 **InterJSON**（项目现名 LIWENJSON），把「LLM 输出的执行门」作为产品定位，对外主入口改为**本地部署的
MCP server**。引擎、修复语义与全部不变量不变；版本对应 **1.4.0**（GitHub）↔
**0.11.0**（mooncakes）。这是模块路径与 MCP 工具名的破坏性重命名；1.3.0 的 registry
对应号 0.10.0 尚未上传 mooncakes，因此 registry 上的已发布历史（0.3.0 … 0.8.1）不构成
升级路径变更。registry 对应号 **0.11.0 已于 2026-10-27 上传 mooncakes**。

### 更名与 MCP

- **产品与模块统一更名**：产品、MoonBit 模块（`zhanshishan/interjson`）、CLI、
  npm/Python 包装层与浏览器 bundle（`interjson.js`）全部使用 InterJSON 命名。
  引擎与修复语义不变；公共 API 的**形状**不变，两处名字随之更改：
  `MendError` → `InterJSONError`，Python 侧 `JsonMendError` → `InterJSONError`。
  这是破坏性的导入变更，因此本轮直接按 minor 发布：版本 1.4.0 ↔ 0.11.0。
- **MCP 主工具改名**：`interjson_analyze` → `interjson_gate`，其余三个工具为
  `interjson_repair` / `interjson_validate` / `interjson_readiness`。`interjson_gate`
  不带 `profile` 时默认走 **`agent`** 档：lossy 或 ambiguous 的修复一律拒绝，
  不替模型猜；结果仍是 `decision` / `executable` / `exactness` / `value` /
  `retry.prompt`。
- **MCP 面补齐协议细节**：`initialize` 返回服务端 instructions；四个工具都声明
  `readOnlyHint` 与 `outputSchema`；协议协商首选 `2025-06-18`、接受 `2024-11-05`，不支持的版本回落到
  `2025-06-18`。stdout 只写 JSON-RPC；没有 `id` 的请求（通知）一律不回答。
  成功结果同时带 `content` 文本与 `structuredContent`，错误结果只带可读文本。
- **配置生成**：`liwenjson mcp --print-config[=claude|cursor|vscode|codex|windsurf|zed|json]`
  打印对应客户端配置；`--print-config=claude` 输出
  `claude mcp add liwenjson -- liwenjson mcp`。
- **同一入口的别名**：`liwenjson-mcp` 等价于 `liwenjson mcp`；npm 包
  `interjson-moonbit` 的 bin 为 `interjson-mcp`（需本机原生二进制），Python 包
  同时提供 `liwenjson-mcp` 控制台入口。
- **文档**：新增 `docs/MCP.md` 作为本地部署指南；`docs/PROTOCOL.md` 补充
  `serve` 与 MCP 的分工（宿主侧传输 vs 模型侧传输）；演示页、CHANGELOG 与
  其余接入文档同步新工具名。更早的版本记录、`static/demo/mcp-claude-session.txt`
  与 `产品文档.md` 是录制/历史证据，保留当时的旧名原文。
- **历史记录的处理**：更早的版本记录、`static/demo/mcp-claude-session.txt` 与
  `产品文档.md` 中出现的 `jsonmend` 与本次改名后的 `interjson` 指代同一对象；
  录制证据保持逐字节原文。已经发布的 Release（`v1.3.0` 及更早）资产文件名仍带
  旧前缀（`jsonmend-*`），下载链接以对应 Release 页面为准；下一次发布起资产改用
  `interjson-*`，命名规则见 `docs/MCP.md`。
- **不变量与数字均未变**：输出必合法 JSON、修复幂等、流式分块不变、快照是稳定
  前缀、任何字节序列不得 panic；README 与文档中的全部数字保持原值。版本统一为
  **1.4.0**（`code/moon.mod`、`--version`、npm/Python 清单与 `serve` 的
  `engine` 字段一致），mooncakes 对应号 **0.11.0**。
- **演示媒体随版本刷新**：`static/demo/` 下的截图、GIF 与录屏由
  `bash code/tests/media/refresh.sh` 在当前构建上重新生成（生成器移入
  `code/tests/media/`），不再保留更名前的旧画面；旧版派生素材
  （`mcp-claude-demo.gif`、`mcp-claude-poster.png`）已删除，
  `static/demo/mcp-claude-session.txt` 作为真实会话的逐字节文字证据保留原文。
- **发布后本地清理**：提交/发布后本地只保留当前版本——`_build/`、`test/`、
  缓存与旧演示媒体删除，历史版本由 GitHub 的提交历史与 Release 保存；旧文档
  不删除，但开头标注「历史档案」且不进入现行入口。规则见 `AGENTS.md`。

## [1.3.0] - 2026-10-26

结构性重构，目标是把三处「每条变更都付一次代价」的设计换成按 token / 按记录付费，
另修一处只影响成本、不影响结果的字节入口缺陷。默认行为不变：`repair`、`parse`、
`snapshot`、`drain_deltas` 的输出与 1.2.0 逐字节一致，只有新增 API 与一处 CLI 默认值
变化。版本对应 **1.3.0**（GitHub）↔ **0.10.0**（mooncakes）——新增公开 API 属 minor，
不能当 1.2.x 补丁。

### 引擎

- **当前位置与历史位置分离**：`Engine.pos : Position` 改为 `pos_offset/pos_line/
  pos_column` 三个整数，新增 `Engine::position()`（冻结成不可变 `Position`）与
  `Engine::advance(u)`。`step_*` 处理器不再携带 `p : Position`，只在真正要记录
  或报错时冻结一次：token 起点、错误点、逗号位置等历史位置仍是冻结的 `Position`，
  绝不与当前游标共享。改造前每个码元构造一个 `Position`，JS 后端因此每码元分配
  一个对象、代价随活跃堆增长；现在每 token / 每记录才物化一次。
- **增量日志改为紧凑数组 + 路径 arena**：`DeltaLog` 用并行数组（`ops`/`ats`/
  `path_ids`/`values`/`texts`）记录变更，路径是 arena 索引而不是一份
  `Array[PathSegment]` 拷贝。`Frame.path` 改为 `Frame.path_id`。arena 本身也是
  三组并行数组（不是「结构体数组」——带引用字段的结构体逐元素装箱，正是这里要
  避免的分配），并带一个内容寻址的单条缓存：同一个槽位的两三次查询（开标记、
  drain 时的文本刷新、落地）只做几次整数比较，不重复建节点。
- **新增 `DeltaView` 与零路径分配的消费入口**：`PartialParser::drain_views()`、
  `PartialParser::for_each_delta()`、`PartialParser::delta_path()`、
  `PartialParser::delta_pointer()`。视图只带 `op`/`at`/`value`/`text`，路径留在
  arena 里按需解码；不调用 `delta_path` 就没有路径分配。`drain_deltas()` 保留为
  兼容层并如实标注其成本（每条变更物化一个 `Delta` 与一份路径数组），
  `NFR-PERF-05` 的口径改登记到新入口上。
- **`Options::validate` 未变**：`collect_deltas` 仍拒绝 `KeepFirst` 与
  `TrimToValid`——这两条是流本身的语义约束，与记录方式无关。
- **不变量保持**：输出合法 JSON、修复幂等、任意分块与一次性结果一致、任何字节
  序列不 panic，全部由原有 212 条测试 × 4 后端继续强制；新增的两条测试断言
  「视图流与物化流逐字段、逐路径解码一致」。
- **字节入口对多字节 UTF-8 序列批量并入**：`feed_bytes` 的 ASCII 快路径（0.1.0 起）
  只认 `b < 0x80`，非 ASCII 字节一个码元一次 `parts.push(c.to_string())`，
  成本随字符数线性增长。现在第一段仍是原来的纯 ASCII 扫描（不带计数器，合进一个新
  循环会让纯 ASCII 慢 15%），第二段用新增的 `plain_utf8_run` 判断「完整 + 最短形式
  + `step_str` 会原样送入 `push_cu`」的序列并整段并入，码元数按 UTF-8 长度累计
  （四字节算两个码元）。`plain_utf8_run` 复制而不是复用 `feed_byte` 的校验：它只决定
  能不能批量，拒绝时一律退回逐字节路径，`E040` 仍由 `feed_byte` 以原来的绝对偏移报出。
  一行 `{"text": "…"}` 的长文本，native 由 38.5–39.6 → 209.7–220.8 Mu/s、JS 由 10.8–11.0 →
  76.3–79.1 Mu/s（4 Mi 码元，`bench -- longtext`，三次运行的区间），按字节算 CJK 与 ASCII 同价；CLI 读一份
  25.17 MB 的单条 CJK 字符串由 0.22–0.24 s 降到 0.04 s，`--check` 峰值 RSS 由
  228.0 MB（9.5 ×）降到 46–54 MB（1.9–2.2 ×，峰值 RSS 随调用上下文抖动）。
  纯 ASCII 与转义密集文本的读数不变。
  影响面限于喂字节的入口：CLI 的默认路径与 `batch` 子命令，以及直接调用
  `feed_bytes` 的库调用方。`serve` 的 `repair` / `watch`、npm 包与浏览器 bundle 走
  字符串入口 `feed`，本来就在快的那个路径上，本次未受影响。

### CLI

- **资源上限可在命令行设置**：新增 `--max-input-len`、`--max-depth`、
  `--max-token-len`（默认值与库一致：67108864 / 512 / 16777216）。此前只有库
  API 能改这三个上限，命令行用户既收不紧也放不宽。数值解析改为「乘之前先比较」，
  超长数字串不再回绕成负数被当成合法上限。
- **`explain --json` 默认不再带修复后全文**：机器可读的计划里已有 `value`，全文
  是第二份整篇拷贝；需要时用新增的 `--with-text` 取回。文本块的 `Repaired:` 行
  不受影响，`serve`/MCP 的 `analyze` 契约也不变。
- **命令行断言 94 → 102 条**：新增三个上限的「咬得住 / 放得开 / 越界拒绝 /
  回绕拒绝」四条与 `--with-text` 正反两条。

### 基准与门禁

- **`median5_single`**：`median5` 按「一轮里的调用次数」摊时间，一旦单次调用超过
  100 ms 就退化成**一个样本**——正是扩张性检查用的大输入，一次 GC 停顿就能独占
  结果。新增按「五次独立单次调用的中位数」测量，JS `4n/2n` 由在 2.2–2.8 之间跳动
  变为稳定值。
- **长文本 arm 与 arm 过滤器**：`bench/main.mbt` 新增 `longtext` 组（4 Mi 码元的纯
  ASCII、CJK、转义密集三种单字符串文档，同时报 `feed` 与 `feed_bytes` 两个入口，单位是
  UTF-16 码元/秒而不是 MB/s），并给 `main` 加了一个参数过滤器：4 MiB 的 CJK 文档会留下
  足够多的垃圾让紧随其后的 JS 读数偏离 30%，所以文档引用的是单独跑的读数
  （`moon run bench --target native --release -- longtext`）。
- **新增 `tests/scaling.sh`**：把 `NFR-PERF-01`（native `2n/n`、`4n/2n` ≤ 2.3）与
  `NFR-PERF-05`（native `for_each_delta` 开销 ≤ 160% 基线）做成 `best-of-N` 比值
  棘轮，进 CI。比值按「先取各尺寸的最小时间、再求比」归约，而不是取比值的最小值：
  两个被干扰放大的时间算出的比值可以落到 1 以下，取最小值会把这个假象留下来。
  JS 的扩张性只打印、不做硬门禁（共享 runner 的 GC 时序抖动大于要防的回归）。
## Earlier versions

`1.2.0` and everything before it — the JSONMend releases, the 1.0 public-API
freeze and the hackathon rounds — are in **`marks/CHANGELOG-history.md`**
(local only) and in the git history and GitHub releases, which is where a
changelog for a published project belongs. This file carried all of it until
1.5.0; at 82 KB it was the largest document in the repository and was being
downloaded by every reader to find the three versions that still matter.

The version-by-version channel mapping (GitHub `v1.x` ↔ mooncakes `0.x`) stays
in `README.md`, which is where an installer looks for it.

