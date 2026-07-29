# PROTOTYPE — Skill 结构与跨 Skill 调用路由

本原型只回答一个问题：`zotero-paper-updater` 的入口、workflow、公开脚本和内部实现怎样分层，才能同时支持人工全库维护与其他论文类 skill 的局部嵌入调用，又不继续承担论文研读、知识笔记和强制 MinerU 正文校验。

它是结构草案，不是实现；所有文件都位于 `prototypes/issue-7/`，不会被正式 skill 路由读取。

## 建议结构

```text
zotero-paper-updater/
├── SKILL.md
├── workflows/
│   └── maintain-library.md
├── references/
│   ├── result-contract.md
│   └── llm-for-zotero-implementation.md
├── scripts/
│   ├── maintain-library.ps1
│   ├── ZoteroPaperUpdater.Common.psm1
│   └── internal/
│       ├── audit-library.ps1
│       ├── resolve-target.ps1
│       └── invoke-llm-for-zotero-mcp.ps1
└── tests/
    └── run-tests.ps1
```

## 结构不变量

1. `SKILL.md` 只定义职责边界、触发条件和到唯一 workflow 的路由，不重复维护步骤。
2. `workflows/maintain-library.md` 是唯一维护流程来源；人工调用和嵌入调用走同一流程。
3. `scripts/maintain-library.ps1` 是唯一公开执行入口；其他脚本和模块只服务该入口。
4. 无参数表示全库维护；`-ItemKey` 与 `-Path` 表示局部维护，二者互斥。
5. 公开入口只向 stdout 输出一个稳定 JSON 文档；进度和诊断信息写 stderr。
6. 论文研读、总结、比较、知识笔记和 `notes\<parentItemKey>.md` 不属于本 skill。
7. `full.md`、`manifest.json` 的正文健康不再是通用维护前置条件；只有实际操作 MinerU 缓存时才检查所需的最小事实。
8. 找不到可靠元数据时保留空值并返回 unresolved 项，不向 `Extra` 写缺失状态。

## 调用形态

人工全库维护：

```powershell
pwsh -NoProfile -File .\scripts\maintain-library.ps1
```

人工局部维护：

```powershell
pwsh -NoProfile -File .\scripts\maintain-library.ps1 -ItemKey Z2SQADYZ
pwsh -NoProfile -File .\scripts\maintain-library.ps1 -Path 'E:\paper\example.pdf'
```

其他论文类 skill 的嵌入调用：

```powershell
$result = & "$updaterRoot\scripts\maintain-library.ps1" -ItemKey $itemKey |
    ConvertFrom-Json -Depth 100

if (-not $result.ok) {
    throw "Zotero paper maintenance failed: $($result.runId)"
}
```

调用方只依赖公开参数与 `references/result-contract.md`；它不读取内部脚本，不复制维护步骤，也不把控制权整体交给 `zotero-paper-updater`。

## 需要人确认的取舍

原型采用“直接嵌入公开脚本”的路由，而不是让其他论文类 skill 先完整读取并执行本 skill 的 workflow。这样可把复用边界固定在稳定参数和 JSON 契约上，也避免两个 skill 同时争夺主流程所有权。

