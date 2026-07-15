# zotero-paper-updater

用于维护 Zotero、`llm-for-zotero` MinerU Markdown 缓存与本地论文目录之间一致性的 Codex Skill。

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
- 通过 Zotero 支持的界面与 JavaScript API 做最小化回写，禁止直接修改 `zotero.sqlite`。
- 以 `parentItemKey` 维护单一知识笔记，避免标题变化产生重复笔记。
- 在有效 MinerU Markdown 存在时坚持 Markdown-first，不再次解析 PDF 正文。

## 环境要求

- Windows 与 PowerShell 7。
- Zotero Desktop，且本地 API 已启用。
- 已安装并完成解析的 `llm-for-zotero` MinerU 工作流。
- MinerU 缓存中包含 `_llm_source.json`、`manifest.json` 和 `full.md`。

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

Skill 会根据请求区分只读审计与写入操作。仅说“检查”时不会修改 Zotero 或文件。

审计 JSON 会包含本地绝对路径、论文文件名、Zotero key 和
SHA-256。它用于本地核验，不应提交到公开仓库。

## 只读审计脚本

仓库附带 `scripts/audit-paper-links.ps1`。它输出 JSON，并验证本地 PDF、Zotero storage、父子关系、MinerU provenance、Markdown 健康度和哈希。

```powershell
pwsh -File .\scripts\audit-paper-links.ps1 `
  -PaperRoot "D:\Papers" `
  -ZoteroDataDir "D:\ZoteroData"
```

常用选项：

- `-AllowIncomplete`：初次盘点时保留完整报告，不因阻塞问题返回失败。
- `-SkipHash`：跳过 SHA-256；严格一一对应将无法成立。
- `-SkipApi`：跳过 Zotero 父子关系查询；严格一一对应将无法成立。
- `-ZoteroApiBase`：覆盖默认的 `http://127.0.0.1:23119/api/users/0`。

严格模式发现阻塞错误时返回退出码 `2`。可选图块定位越界会作为警告报告，不会抹去已经证明的附件与 Markdown 映射，但不得用该范围切分正文。

## 更新流程

1. 检查 Zotero 连接并盘点父条目与 PDF 附件。
2. 通过 `_llm_source.json` 的 `attachmentKey` 定位 MinerU 缓存。
3. 先验证缓存，再读取 `manifest.json` 和所需的 `full.md` 章节。
4. 从 Markdown 和权威一手来源补全书目信息，不猜测缺失字段。
5. 在 Zotero 中执行带版本检查的最小化回写，并重新读取验证。
6. 让 Zotero 自己重命名 storage 附件；禁止在文件系统中直接改 storage 文件名。
7. SHA-256 一致且目标无冲突时，才重命名本地论文副本。
8. 更新 `notes/<parentItemKey>.md`，最后运行严格审计。

详细规则见：

- [`SKILL.md`](SKILL.md)
- [`references/workflow.md`](references/workflow.md)
- [`references/zotero-writeback.md`](references/zotero-writeback.md)

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
│   └── zotero-writeback.md
└── scripts/
    └── audit-paper-links.ps1
```

## 安全边界

- 不提交论文 PDF、MinerU 解析产物、Zotero 数据库或本地注册表。
- 不读取或输出 MinerU API 密钥。
- 不直接修改 `zotero.sqlite` 或 Zotero storage 文件名。
- 不用模糊标题、Paper ID、文件时间或参考文献年份猜测元数据。
- `full.md` 缺失、为空或失效时显式报告并等待重解析，不静默回退到 PDF。
