# zotero-paper-updater

维护现有 Zotero 论文条目及其受管本地 PDF 的 Codex Skill。

## 安装

```powershell
python "$HOME\.agents\skills\skills-updater\scripts\install_agent_skill.py" `
  --repo Woif-sha/zotero-paper-updater `
  --path . `
  --name zotero-paper-updater
```

## 唯一公开命令

```powershell
# 默认维护整个受管库
pwsh -File .\scripts\maintain-library.ps1

# -ItemKey：按现有父条目或 PDF 附件 key 维护
pwsh -File .\scripts\maintain-library.ps1 -ItemKey 8KJ4M2QX

# -Path：按已受管本地 PDF 定位并维护
pwsh -File .\scripts\maintain-library.ps1 -Path "D:\papers\paper.pdf"

# -PaperRoot / -ZoteroDataDir：覆盖两个环境目录
pwsh -File .\scripts\maintain-library.ps1 `
  -PaperRoot "D:\papers" `
  -ZoteroDataDir "D:\ZoteroData"
```

`-ItemKey` 与 `-Path` 互斥。公开参数仅为 `-ItemKey`、`-Path`、
`-PaperRoot` 和 `-ZoteroDataDir`。

## JSON 与退出码

stdout 始终只有一个 schema-versioned JSON 文档，包含运行状态、作用域、
汇总、逐目标 actions/issues 和运行级 issues。`changed=false` 表示成功
no-op。

| 退出码 | 状态 |
| --- | --- |
| `0` | `succeeded` |
| `2` | `partial` |
| `1` | `failed` |

完整维护规则见
[`workflows/maintain-library.md`](workflows/maintain-library.md)。
