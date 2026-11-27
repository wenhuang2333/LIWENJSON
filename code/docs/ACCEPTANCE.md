# 验收对照：赛事九项要求

本文件逐条对照赛事验收指南，说明 **LIWENJSON（原项目，不是 `dsh` 插件）** 如何满足九项要求。
文中测试数字与 `README.md` 的「验收证据」表一致，并由 `code/tests/claims.sh` 从当前构建重新推导：
文档里的数字与构建不符，门会失败。

| # | 验收要求 | 结论 | 证据 |
| --- | --- | --- | --- |
| 1 | 项目以 MoonBit 为主要实现语言，`moonc` 版本不低于 `1.0.0-rc1` | 满足 | 引擎（`code/*.mbt`）、native CLI（`code/cmd/liwenjson/`）、provider 适配（`code/llm/`）与示例全部是 MoonBit；工具链 `moon 0.1.20261126` / `moonc v1.0.0-rc1+3c0520448`，CI 用 `MOONBIT_INSTALL_VERSION` 钉住 |
| 2 | GitHub 仓库公开可访问，提交记录清晰 | 满足 | <https://github.com/wenhuang2333/LIWENJSON> 公开（visibility `public`，Apache-2.0）；提交按主题拆分，`git log --oneline` 可直接审阅 |
| 3 | 源代码结构清晰，能够完成声明的核心功能 | 满足 | `code/` 单扁平包是引擎，`cmd/` 是 CLI，`llm/` 是 provider 适配，`npm/`、`python/` 是同引擎包装；目录表见 README「目录结构」。修复、流式部分解析、执行档、JSON Schema 桥与 MCP server 都由此实现 |
| 4 | 提供 README，说明项目目标、安装方式、使用方法和示例，并可复现 | 满足 | README 的「功能亮点 / 快速上手 / 使用说明 / 技术栈」覆盖目标、四种安装方式、MCP 与 Node/MoonBit 用法；复现命令见本文件「复现」与 `code/CONTRIBUTING.md` |
| 5 | 使用持续集成，覆盖检查、构建、测试流程 | 满足 | [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) 的三组 job：MoonBit（`check --deny-warn`、`fmt --check`、四后端测试、CLI/MCP/差分/覆盖率/打包）、Windows（native 构建与 I/O 不变量）、Differential（外部 oracle 与基准）；提交 `ea96d92` 的 `main` 运行结论 `success`，本次升级由同一工作流在推送后验证 |
| 6 | 至少一个可运行示例或最小使用样例 | 满足 | 两个端到端示例 `examples/agent_gate`、`examples/agent_loop`，以及下文「样例」中的 CLI 与 MoonBit 最小调用；浏览器演示控制台由同一引擎的 JS 产物驱动 |
| 7 | 完整测试，覆盖核心功能路径 | 满足 | 白盒测试 `*_wbtest.mbt` 覆盖修复规则、黄金用例、性质、流式分块、字节级 fuzz 与错误码；四个后端各 `384/384`；CLI 冒烟、协议一致性、MCP 契约、npm 与 Python 包各有独立测试，数字见下表 |
| 8 | 发布到 mooncakes.io | 满足 | `zhanshishan/liwenjson@0.15.0`（对应 GitHub `v1.5.3`）。`moon search liwenjson` 命中 0.15.0，`moon add zhanshishan/liwenjson` 可直接安装 |
| 9 | 采用 OSI 认可的开源许可证；参考或移植其他项目时符合原许可证 | 满足 | Apache-2.0：根目录 `LICENSE` 与 `NOTICE`；测试仅把 `jsonrepair`（ISC）与 `json-repair`（MIT）作为进程外 oracle，未复制其源码；vendored 的 nst/JSONTestSuite 语料保留原许可证与出处（`code/tests/eval/third_party/jsontestsuite/PROVENANCE.md`） |

## 测试证据（当前构建）

| 证据 | 结果 |
| --- | --- |
| 四个后端 wasm-gc / native / JS / wasm | 每个后端 `384/384` 通过 |
| CLI 冒烟 | `183 项断言` |
| 协议 / MCP 一致性 | `19 组` |
| npm 包 | `33 个 Node 测试` |
| Python 包 | `89 个测试` |
| 根包行覆盖率 | `4697/4931` |
| `llm` 包行覆盖率 | `529/696` |
| 覆盖率门（有未覆盖行的文件口径） | `5151/5552` |
| wasm-gc 产物体积 | `121.0 KiB` |
| MCP 契约：真实二进制对真实 `outputSchema` | `13/13 响应通过` |
| 真值评测（协议先冻结） | `1200` 条，恢复率 `100.00%` |
| 差分测试（对 `jsonrepair` / `json-repair`） | `402` 条，未解释 0 处分歧 |
| 骨架就绪表 | `10 个场景` |

## 复现

```bash
# 1. 工具链（与 CI 同一版本）
curl -fsSL https://cli.moonbitlang.com/install/unix.sh \
  | MOONBIT_INSTALL_VERSION=1.0.0-rc1+3c0520448 bash
export PATH="$HOME/.moon/bin:$PATH"

# 2. 检查、格式化与四后端测试
cd code
moon check --deny-warn
moon fmt --check
moon test
moon test --target native
moon test --target js
moon test --target wasm

# 3. 构建 CLI，跑冒烟与示例
moon build cmd/liwenjson --target native --release
bash tests/cli_smoke.sh
bash tests/examples.sh

# 4. 差分测试（必须 exit 0）
python3 tests/diff/run_diff.py \
  --cli ./_build/native/release/build/cmd/liwenjson/liwenjson.exe

# 5. 重新推导文档中的数字（README 与本文件的数字都由它检查）
bash tests/claims.sh
```

CI 执行同一组命令并额外覆盖 Windows、独立 JSON Schema oracle、覆盖率门与浏览器 smoke：
<https://github.com/wenhuang2333/LIWENJSON/actions/workflows/ci.yml>。

## 样例

命令行最小调用：

```bash
printf '{"amount":100,"currency":"USD"' | liwenjson explain --policy agent --json
```

MoonBit 库最小调用（流式部分解析 + 执行档）：

```moonbit
let options = @liwenjson.Options::for_execution()
let p = @liwenjson.PartialParser::new(options=options)
p.feed("{\"name\":\"Mo")
let s = p.snapshot()          // 稳定前缀：{"name":"Mo"} | Partial
p.feed("onBit\",\"tags\":[\"json\"]}")
let done = p.finish()         // Complete，text 是合法 JSON
```

两个端到端示例（CI 每次运行）：

```bash
cd code
moon run examples/agent_gate --target native --release
moon run examples/agent_loop --target native --release
```

浏览器演示控制台：<https://wenhuang2333.github.io/LIWENJSON/>
