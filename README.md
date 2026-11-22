**版本**：1.5.3

# LIWENJSON — LLM 输出的执行门

[![CI](https://github.com/wenhuang2333/LIWENJSON/actions/workflows/ci.yml/badge.svg)](https://github.com/wenhuang2333/LIWENJSON/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![演示控制台](https://img.shields.io/badge/demo-console-2ea44f.svg)](https://wenhuang2333.github.io/LIWENJSON/)
[![npm](https://img.shields.io/npm/v/liwenjson.svg?label=npm)](https://www.npmjs.com/package/liwenjson) [![PyPI](https://img.shields.io/pypi/v/liwenjson.svg?label=PyPI)](https://pypi.org/project/liwenjson/)

**LIWENJSON 是 LLM 输出的执行门：它在模型的工具参数被执行之前判定这些参数能不能安全执行，并在拒绝时把要发回给模型的那句提示一并返回。**

判定的底层是一份纯 MoonBit 的流式 JSON 修复与部分解析引擎（`zhanshishan/liwenjson`）。同一份引擎既回答「这些字节是不是合法 JSON、能不能边生成边读」，也回答「它能不能被执行」——对外主入口是本地 MCP server `liwenjson mcp`，另外提供 native CLI、长驻 stdio 协议以及 npm / Python 语言包。

**版本与渠道**

| GitHub tag | mooncakes.io | npm | PyPI | 状态 |
| --- | --- | --- | --- | --- |
| `v1.5.3` | `0.15.0` | `liwenjson@1.5.3` | `liwenjson@1.5.3` | **本轮发布**（2026-11-23）：标签触发 CI 与 GitHub Release，npm / PyPI / mooncakes 依次跟进 |
| `v1.5.2` | `0.14.0` | `liwenjson@1.5.2` | `liwenjson@1.5.2` | 上一版（GitHub Release / npm / PyPI 2026-11-20，mooncakes 同日） |
| `v1.5.1` | `0.13.0` | `interjson-moonbit@1.5.1` | `interjson-moonbit@1.5.1` | 更早（mooncakes 2026-10-29，npm / PyPI 2026-10-30，重命名前） |

改名前后是三个不同的模块名：mooncakes 上 0.11.0–0.13.0 是 `zhanshishan/interjson`，更早是 `zhanshishan/jsonmend`，`zhanshishan/liwenjson` 是 0.14.0 才出现的新模块（注册表不支持改名，只能新增包名；两个旧模块 `zhanshishan/interjson`、`zhanshishan/jsonmend` 已于 2026-11-20 `moon deprecate` 标为废弃并把新名写进理由）。已发布的是 mooncakes `zhanshishan/interjson@0.13.0`（2026-10-29）与 npm / PyPI 的 `interjson-moonbit@1.5.1`（2026-10-30）、以及 `1.5.2` 的四个渠道（GitHub Release、npm、PyPI、mooncakes `zhanshishan/liwenjson@0.14.0` 都在 2026-11-20，拉回后 `VERSION=1.5.2` / `REGISTRY_VERSION=0.14.0`）。**本轮的 `1.5.3` ↔ mooncakes `0.15.0`** 装的是同一份引擎的第三轮审计修复，发布顺序仍是 标签 → GitHub Release → wheel → PyPI → npm → mooncakes；发布记录与历史见 `code/CHANGELOG.md`。两个语言包的 wheel 与 tarball 里都带着引擎，装完即可调用。

本文的自动化验收数字对应当前构建（`v1.5.3`）；每个版本的内容见 [CHANGELOG](code/CHANGELOG.md)。

## 功能亮点

- **执行门（默认入口）**。每个结果都带精确度标签——`Exact`（没修）、`Cosmetic`（只改记法）、`Lossy`（发明或丢弃了信息）——以及歧义类别。执行档（`execution` / `agent`）下，有损或有两种读法的结果被拒绝，而不是先执行再后悔。执行档的拒绝结果带非空的 `retry.prompt` 且 `value: null`；只有 `refusal.auto_retry: true` 时才可按提示自动重试，宿主声明或数值表示问题须由调用方修正。
- **本地 MCP server**。`liwenjson mcp` 通过 stdio 讲 JSON-RPC 2.0（协议 `2025-06-18`），不监听端口、不发网络请求、不需要 API key，模型输出不离开本机。四个只读工具：`liwenjson_gate`（执行门，不传 `profile` 时默认 `agent`，等价于 `Options::for_agent()`）、`liwenjson_repair`、`liwenjson_validate`、`liwenjson_readiness`。`--print-config=claude|cursor|vscode|codex|windsurf|zed|json` 打印可直接粘贴的客户端配置。**MCP 是建议性的**：模型可以不调它，要变成强制闸门得由宿主接入（见下节「接入面」）。
- **流式部分解析**。`PartialParser` 的 `feed` / `feed_bytes` / `snapshot` / `finish`：任意切分任何 token（含转义序列与代理对）都成立，`snapshot` 给出的是稳定前缀——同一个输入前缀永远得到同一个快照。增量视图是 `Set` / `AppendText` / `Close` 三种 delta，路径用 RFC 6901 JSON Pointer。
- **五种安全档位**。`permissive` / `interactive` / `execution` / `agent` / `strict`，库侧对应 `Options::for_execution()`、`Options::for_agent()` 等预设；`with_policy` 只换安全字段、保留协议字段，`with_profile` 连协议一起给，可按名字反查。库默认 `permissive`，**任何执行路径必须显式选执行档**。
- **JSON Schema 桥**。两条声明通道：库内声明 DSL（如 `{!query:string,!limit:integer}`）与工具声明里已有的 JSON Schema 子集（`type` / `properties` / `required` / `items` / `enum` / `const` / 数值与长度约束 / `pattern`）。不支持的键报 `E070`，而不是静默忽略。同一节点上的关键字按 **合取** 解释、与书写顺序无关（`const` 与 `enum` 取交集，容器上的约束与内部 `required`/`items` 同时生效），根节点的类型也参与判定；无法满足的声明在建模阶段就是 `E070`。语义与验收用例见 `code/docs/SPEC.md` §7a 与 `code/schema_gate_wbtest.mbt`。
- **CLI 与资源上限**。`liwenjson` 有六个子命令：`repair`、`explain`、`readiness`、`serve`、`mcp`、`llm`。资源上限可收紧也可放宽：`--max-input-len`（`E021`）、`--max-depth`（`E020`）、`--max-token-len`（`E022`），三个上限的默认值与库一致。退出码 0 / 1 / 2 / 3 / 4 / 5 / 70 逐条固定。
- **多后端一致性**。wasm-gc / native / JS / wasm 四个后端跑**同一套**测试，结果一致；CLI 是 native 后端。
- **LLM provider 适配**。`liwenjson/llm` 吃 Anthropic 的细粒度工具流与 OpenAI 兼容的工具调用流，自带 SSE 分帧，支持多路并发；一次调用结束被报成 `Complete` / `MaxTokens` / `Interrupted` / `ProviderError`，并保留 provider 自己的 `stop_reason`。
- **修复面与硬不变量**。22 条修复规则（R001–R022）逐条可关，12 个错误码（E001–E070）都带位置与上下文片段。五条不变量不可回退：**输出永远是合法 JSON**、**修复幂等**、**任意分块与一次性输入等价**、**快照是稳定前缀**、**任何字节序列都不会 panic**。

验收证据（自动化结果由当前构建重新推导；真实模型和会话行是历史实测记录，本轮未发起外部模型调用）：

| 证据 | 结果 |
| --- | --- |
| 四个后端（wasm-gc / native / JS / wasm） | 每个后端 `384/384` 通过 |
| CLI 冒烟 | `183 项断言` |
| 协议 / MCP 一致性 | `19 组` |
| npm 包 | `33 个 Node 测试` |
| Python 包 | `89 个测试` |
| 根包行覆盖率 | `4697/4932` |
| `llm` 包行覆盖率 | `529/696` |
| 覆盖率门（有未覆盖行的文件口径） | `5151/5553` |
| wasm-gc 产物体积 | `116.2 KiB` |
| MCP 契约（真实二进制 × 真实 `outputSchema`） | `13/13 响应通过` |
| 真实模型端到端（Responses API，`code/tests/live_model_audit_v2.py`） | `34/34 检查通过` |
| 真实 Claude Code 会话：强制 `PreToolUse` 门 | 拒绝 `touch pwned.txt`（文件未创建）、放行 `echo read-only-ok` |
| 真实 Claude Code **交互式**会话（pty，2.1.319） | 回答 `pong`；`touch pwned.txt` 被 hook 拦下、文件未创建 |
| 真实 Claude Code 会话：MCP 工具调用 | `interjson_gate` 返回 `invalid` / `executable: false`（录像保留改名前的字节；同一会话在当前构建上是 `liwenjson_gate`） |
| `code/tests/hook_replay.py`（录制的 hook 接线重放，`code/tests/claude-e2e/`） | 通过 |
| 真值评测（协议先冻结） | `1200` 条，恢复率 `100.00%` |
| 差分测试（对 `jsonrepair` / `json-repair`） | `402` 条，未解释 0 处分歧 |
| 骨架就绪表 | `10 个场景` |

## 快速上手

### 环境依赖

- **原生 CLI**：不需要运行时。支持 macOS（Apple Silicon）、Linux（x86_64 / arm64）、Windows（x86_64）。**没有 Intel macOS 产物**：MoonBit 工具链不发布 `darwin-x86_64` 目标，该平台只能从源码构建。
- **npm 包**：Node.js **>= 20**。
- **pip 包**：Python **>= 3.10**，无需其他依赖；wheel 内已带原生引擎。
- **从源码构建**：需要 MoonBit 工具链 `moon 0.1.20261016`（仓库与 CI 都钉在这个版本上，其他版本未验证）。

### 安装

原生 CLI，一条命令装到 `~/.local/bin`（可用 `LIWENJSON_DIR` 改目录；安装脚本会拿 Release 自带的 `SHA256SUMS` 核对 SHA-256，校验不通过就什么都不装）：

```bash
curl -fsSL https://github.com/wenhuang2333/LIWENJSON/releases/latest/download/liwenjson-install.sh | sh
```

Node 包（纯 JS 引擎 + MCP 启动器 `liwenjson-mcp`）：

```bash
npm install liwenjson
```

Python 包（同一引擎的原生二进制随 wheel 一起装，四个平台各一份，按当前平台自动选）：

```bash
pip install liwenjson
```

MoonBit 库（同一份引擎在宿主进程内直接用；注册表对应号是 `0.15.0`，因为平台只接受 `0.x.y`）：

```bash
moon add zhanshishan/liwenjson
```

### 运行命令

```bash
# 版本
liwenjson --version                                  # liwenjson 1.5.3

# 打印 Claude Code 的 MCP 配置，然后注册
liwenjson mcp --print-config=claude                  # claude mcp add liwenjson -- liwenjson mcp
claude mcp add liwenjson -- liwenjson mcp

# 同一个判定在命令行上直接看
printf '{"amount":100,"currency":"USD"' | liwenjson explain --policy agent --json

# 语言包自带的启动器起同一个 MCP server（npm 与 pip 都提供 liwenjson-mcp）
npm install -g liwenjson                     # 或：pip install liwenjson
liwenjson-mcp --version                              # liwenjson 1.5.3
```

`liwenjson-mcp` 只负责找到原生引擎（`LIWENJSON_BIN` → PATH 上的 `liwenjson` → 语言包自带的二进制 → 仓库内的开发构建）并把 stdio 交过去；找不到二进制时以退出码 127 结束并打印安装方式，不会起一个半可用的 server。

## 目录结构

```text
.
├── code/                纯 MoonBit 引擎（单扁平包，*_wbtest.mbt 同包白盒测试）
│   ├── cmd/liwenjson/   native CLI：repair / explain / readiness / serve / mcp / llm
│   ├── llm/             provider 适配：Anthropic、OpenAI 兼容、SSE 分帧
│   ├── npm/             liwenjson 的 Node 包装（ESM + CJS + 类型声明）
│   ├── python/          liwenjson 的 Python 包装（含 liwenjson-mcp / liwenjson-http）
│   ├── examples/        示例：浏览器后端驱动、agent 自愈闭环
│   └── tests/           正式测试设施：一致性、差分、真值评测、覆盖率、产物
├── static/demo/         演示控制台与逐帧重放页（由 JS 后端产物驱动，无第二份解析器）
├── README.md
├── LICENSE
└── NOTICE
```

## 使用说明

### MCP：一次被拒绝的执行

宿主在执行工具参数前调用 `liwenjson_gate`，把参数原文与该工具的 `inputSchema` 一起传进去。下面是被 `max_tokens` 截断的参数（少一个右花括号）的结果，取自真实进程的 `structuredContent`（节选，省略了 `repairs` 等字段）：

```json
{
  "decision": "lossy_repair",
  "executable": false,
  "exactness": "lossy",
  "execution": "blocked",
  "valid_json": false,
  "error": {
    "code": "E010",
    "message": "E010 StrictViolation at 1:31 (offset 30): R009 CloseContainer: exactness lossy exceeds max_loss cosmetic"
  },
  "retry": {
    "code": "E010",
    "prompt": "LIWENJSON refused the arguments: E010 R009 CloseContainer at line 1 column 31 (offset 30).\nReason: exactness lossy exceeds max_loss cosmetic\nContext: nt\":100,\"currency\":\"USD\"\n                                 ^\nRe-emit the arguments as valid JSON with exactly one reading."
  },
  "value": null
}
```

`executable: false` 时不要执行：把 `retry.prompt` 原样发回模型，模型重发 `{"amount":100,"currency":"USD"}` 后再过一次门，`executable` 为 `true`、`value` 是解析好的对象。

### Node / npm：宿主侧过门

```js
import { analyze } from "liwenjson";

const plan = analyze(modelOutput, {
  profile: "agent",           // 执行前的档位；库默认是 permissive
  schemaJson: tool.inputSchema, // 工具声明里已有的 JSON Schema 子集
});

if (!plan.executable) {
  // 拒绝一定是：value === null 且 retry.prompt 非空
  return retryModel(plan.retry.prompt);
}
execute(plan.value);
```

除 `analyze`（永不抛错）外，包还导出 `repair`、`repairResult`、`report`、`snapshot`、`live`。`options.schema` 收库内声明 DSL（如 `{!query:string,!limit:integer}`），`options.schemaJson` 收 JSON Schema 子集；子集之外的键（`$ref`、`oneOf` 等）报 `E070`，不会静默降级。

### MoonBit 库：流式部分解析与执行档

```moonbit
// 执行档：max_loss = Cosmetic、reject_ambiguous = true
let options = @liwenjson.Options::for_execution()
let p = @liwenjson.PartialParser::new(options=options)
p.feed("{\"name\":\"Mo")
let s = p.snapshot()                                   // 稳定前缀：{"name":"Mo"} | Partial
p.feed("onBit\",\"tags\":[\"json\"]}")
let done = p.finish()                                  // Complete，text 是合法 JSON

// 截断到字符串中间：补引号会发明内容，超出 Cosmetic，拒绝
let q = @liwenjson.PartialParser::new(options=@liwenjson.Options::for_execution())
q.feed("{\"path\":\"/tmp/x")
q.finish()                                             // 抛 E010
```

### 接入面

| 接入面 | 入口 | 谁调用 |
| --- | --- | --- |
| **MCP** | `liwenjson mcp` | 模型主动调用（**建议性**，不是强制点） |
| **Claude Code hook** | `PreToolUse` | 宿主在工具执行前强制过门 |
| **长驻协议** | `liwenjson serve` | 任何能起子进程的宿主；和高频 / 流式场景 |
| **npm** | `liwenjson` | Node 宿主进程内调用 |
| **pip** | `pip install liwenjson` | Python 宿主进程内调用 |
| **MoonBit 库** | `moon add zhanshishan/liwenjson` | MoonBit 宿主进程内调用（注册表号 `0.15.0` = 引擎 1.5.3） |
| **HTTP** | `liwenjson-http --port 8080` | n8n、Dify、Coze、网关等只讲 HTTP 的宿主 |

**MCP 是建议性的，这是产品边界而不是实现疏漏。** `liwenjson_gate` 是模型可以选择调用的一个工具，协议层没有任何强制点；「接了 MCP」等于多了一个检查点，不等于参数一定过了门。真正把它变成强制闸门的是宿主侧的三条路径：Claude Code 的 `PreToolUse` hook、宿主 SDK 里一行 `gate(args) -> execute | retry`、或 `liwenjson serve`——它们在执行之前运行，不依赖模型自觉。

## 技术栈

- **引擎**：纯 MoonBit，无第三方运行时依赖；工具链钉在 `moon 0.1.20261016`（CI 同样钉住）。
- **后端**：wasm-gc / native / JS / wasm 四个后端跑同一套测试（每个后端 `384/384`）；CLI 与 MCP server 是 native 后端，浏览器里跑的是 JS 后端产物。
- **协议**：MCP 用 stdio + JSON-RPC 2.0，协议版本 `2025-06-18`；`liwenjson serve` 用版本化 JSONL（每行一个请求、一行一个响应，stdout 只走协议）。
- **语言包**：npm 包提供 ESM + CJS + TypeScript 类型（Node >= 20）；Python 包是同一引擎的薄客户端，无第三方依赖，wheel 内自带四个平台的 native 二进制。
- **构建与 CI**：GitHub Actions；同一组命令在 CI 与本地执行，失败即失败。

## 许可证

Apache-2.0。仓库根目录的 [LICENSE](LICENSE) 与 [NOTICE](NOTICE) 是完整的许可与归属声明；分发时按 Apache-2.0 第 4(d) 条一并传递 NOTICE。
