# zotero-paper-updater

用于维护 Zotero、`llm-for-zotero` MinerU Markdown 缓存与本地论文目录之间一致性的 Codex Skill。它也负责论文研读入口：缓存健康时只读对应的 Markdown，不重复读取 PDF 正文。

MinerU 缓存由官方开源插件 [yilewang/llm-for-zotero](https://github.com/yilewang/llm-for-zotero) 生成。本仓库不复制插件实现，也不使用第三方镜像；版本判断、更新清单和 XPI 下载地址都以该官方仓库为准。

它解决的不是单次文件重命名，而是一条可重复验证的论文维护流程：建立稳定映射、补全书目信息、安全回写 Zotero、同步本地文件名，并在后续研读时优先使用 MinerU Markdown。

## 核心约定

| 数据 | 作用 |
| --- | --- |
| Zotero 父条目 | 论文书目身份与元数据 |
| PDF 附件的 `attachmentKey` | Zotero 附件、storage 和 MinerU 缓存之间的稳定主键 |
| Zotero storage 中当前 PDF 文件名 | 本地论文副本的规范文件名 |
| MinerU `full.md` | 缓存通过健康检查后的论文正文来源 |
| `parentItemKey` | Zotero 父条目与知识笔记的稳定标识 |

数字缓存目录、下载文件名、`sourceFilename` 和 Markdown 首标题都不能单独作为论文身份。

## 主要能力

- 递归解析 `_llm_source.json`，按 `attachmentKey` 建立一一对应关系。
- 验证 `full.md`、`manifest.json`、Zotero 父子关系和 storage 附件。
- 使用 SHA-256 证明本地 PDF 与 Zotero 附件相同，而不读取 PDF 正文。
- 将本地 PDF 同步为 Zotero 当前附件名，遇到重复或哈希冲突时停止。
- 审计题名、作者顺序、年份、文献类型、期刊或会议、卷期、页码、DOI、URL、语言、出版社和地点。
- 对适用但为空的元数据字段给出可执行缺口：能核实的写回 Zotero，暂未公开的在 `Extra` 中记录字段名、日期和权威来源，不让缺失悄悄留空。
- 通过 Zotero 支持的界面与 JavaScript API 做最小化回写，禁止直接修改 `zotero.sqlite`。
- 以 `parentItemKey` 维护单一知识笔记，避免标题变化产生重复笔记。
- 在有效 MinerU Markdown 存在时坚持 Markdown-first，不再次解析 PDF 正文。

## 环境要求

- Windows 与 PowerShell 7。
- Zotero Desktop，且本地 API 已启用。
- 已安装并完成解析的 `llm-for-zotero` MinerU 工作流；当前实现依据 v3.8.26 核验。
- MinerU 缓存中包含 `_llm_source.json`、`manifest.json` 和 `full.md`。

本机默认数据目录是 `E:\ZoteroData`，默认受管论文目录是 `E:\paper`。Skill 解析论文目录时依次使用用户显式路径、存在的 `E:\paper`、当前工作目录；解析 Zotero 数据目录时依次使用显式 `-ZoteroDataDir`、环境变量 `ZOTERO_DATA_DIR`、存在的 `E:\ZoteroData`。因此“有新论文，更新”会先审计 `E:\paper`，不会误扫 Skill 仓库。

## 上游版本实时检查

llm-for-zotero 自带 Zotero 更新通道，正式版 XPI 的 `update_url` 指向官方仓库的 `update.json`。本 Skill 额外提供显式检查，避免把文档核验过的版本误当成永远最新：

```powershell
pwsh -File .\scripts\check-llm-for-zotero-version.ps1 -RequireLatest
```

脚本会同时检查：插件是否启用、本机版本、官方稳定版、XPI 地址与哈希、以及安装包是否仍配置官方自动更新通道。技能每次开始涉及 MinerU 的工作流时都应运行它；无法联网时不得宣称“已是最新”，检测到落后版本时先通过 Zotero 的附加组件更新功能升级，再重新核验。这里的“实时”是“每次技能调用时在线核验 + Zotero 自带自动更新”，不是常驻后台轮询。

## 安装

推荐通过 `skills-updater` 安装，这样会同时写入来源元数据并刷新 Skill 清单：

```powershell
python "$HOME\.agents\skills\skills-updater\scripts\install_agent_skill.py" `
  --repo Woif-sha/zotero-paper-updater `
  --path . `
  --name zotero-paper-updater
```

也可以直接克隆，但直接克隆不会自动生成 `.openskills.json`，因此不会自动成为 `skills-updater` 的托管条目。

在 PowerShell 中执行：

```powershell
Set-Location "$HOME\.agents\skills"
git clone https://github.com/Woif-sha/zotero-paper-updater.git
```

安装后的入口文件是：

```text
~/.agents/skills/zotero-paper-updater/SKILL.md
```

## 使用方式

可以直接提出这类请求：

```text
用 zotero-paper-updater 检查这个论文目录能否与 MinerU Markdown 一一对应。
补全这些 Zotero 条目的出版信息，并同步本地 PDF 文件名。
研读这篇论文，只使用对应的 MinerU Markdown，不读取 PDF 正文。
```

Skill 会根据请求区分只读审计与写入操作。整个流程禁止使用 Chrome、浏览器或桌面自动化：Zotero 通过本地 API 读取，本地 PDF、storage 和 MinerU 缓存通过 PowerShell 直接处理。若 Zotero 数据库写入没有可调用的非 UI 接口，会单独报告待处理 key，不会为了操作界面浪费 token。仅说“检查”时不会修改 Zotero 或文件。

对 DOI 或完整书目信息一致、且 MinerU Markdown 表示同一正文的重复版本，默认保留最新且健康的一套，永久删除旧本地 PDF和旧 MinerU 缓存。旧 storage 目录必须在对应 Zotero 附件记录删除后清理，否则同步会自动恢复。PDF 哈希不同但仅由下载版本、批注或 MinerU/OCR 细节造成时，不保留多个副本；不建立备份或隔离目录。

审计 JSON 会包含本地绝对路径、论文文件名、Zotero key 和
SHA-256。它用于本地核验，不应提交到公开仓库。

## 只读解析与审计脚本

已知 Zotero `parentItemKey`、`attachmentKey` 或数字附件 ID 时，可先解析到唯一 Markdown：

```powershell
pwsh -File .\scripts\resolve-paper-md.ps1 -ItemKey Z2SQADYZ
```

脚本会校验 provenance v2、`full.md`、manifest 字符数与区间、storage 附件，并输出可直接读取的 `fullMdPath`。若父条目有多个 PDF，会要求改用具体 `attachmentKey`，不会模糊选择。

仓库附带 `scripts/audit-paper-links.ps1`。它输出 JSON，并验证本地 PDF、Zotero storage、父子关系、MinerU provenance、Markdown 健康度和哈希。

```powershell
pwsh -File .\scripts\audit-paper-links.ps1 `
  -PaperRoot "D:\Papers"
```

常用选项：

- `-AllowIncomplete`：初次盘点时保留完整报告，不因阻塞问题返回失败。
- `-SkipHash`：跳过 SHA-256；严格一一对应将无法成立。
- `-SkipApi`：跳过 Zotero 父子关系查询；严格一一对应将无法成立。
- `-RequireAllCaches`：要求 MinerU 根目录中的每个缓存都在 `PaperRoot` 有唯一 PDF；适合全库镜像审计，普通论文子目录不要开启。
- `-ZoteroApiBase`：覆盖默认的 `http://127.0.0.1:23119/api/users/0`。

启用 Zotero API 时，审计还会按文献类型报告核心字段、建议字段、已在 `Extra` 说明的正式缺失，以及仍需联网核实的字段。严格模式发现阻塞错误或未说明的元数据缺口时返回退出码 `2`。可选图块定位越界会作为警告报告，不会抹去已经证明的附件与 Markdown 映射，但不得用该范围切分正文。

## 更新流程

1. 检查 Zotero 连接并盘点父条目与 PDF 附件。
2. 通过 `_llm_source.json` 的 `attachmentKey` 定位 MinerU 缓存。
3. 先验证缓存，再读取 `manifest.json` 和所需的 `full.md` 章节。
4. 从 Markdown 和权威一手来源补全书目信息；适用字段要么填入，要么在 `Extra` 中留下带日期、字段名和来源的未公开状态。
5. 在 Zotero 中执行带版本检查的最小化回写，并重新读取验证。
6. 让 Zotero 自己重命名 storage 附件；禁止在文件系统中直接改 storage 文件名。
7. SHA-256 一致且目标无冲突时，才重命名本地论文副本。
8. 更新 `notes/<parentItemKey>.md`，最后运行严格审计。

详细规则见：

- [`SKILL.md`](SKILL.md)
- [`references/workflow.md`](references/workflow.md)
- [`references/zotero-writeback.md`](references/zotero-writeback.md)
- [`references/llm-for-zotero-implementation.md`](references/llm-for-zotero-implementation.md)

## 目录结构

```text
zotero-paper-updater/
├── SKILL.md
├── README.md
├── assets/
│   └── paper-note-template.md
├── evals/
│   └── evals.json
├── references/
│   ├── workflow.md
│   ├── zotero-writeback.md
│   └── llm-for-zotero-implementation.md
├── scripts/
│   ├── audit-paper-links.ps1
│   ├── check-llm-for-zotero-version.ps1
│   ├── resolve-paper-md.ps1
│   └── ZoteroPaperUpdater.Common.psm1
└── tests/
    └── run-tests.ps1
```

## 安全边界

- 不提交论文 PDF、MinerU 解析产物、Zotero 数据库或本地注册表。
- 不读取或输出 MinerU API 密钥。
- 不直接修改 `zotero.sqlite` 或 Zotero storage 文件名。
- 不用模糊标题、Paper ID、文件时间或参考文献年份猜测元数据。
- `full.md` 缺失、为空或失效时显式报告并等待重解析，不静默回退到 PDF。
