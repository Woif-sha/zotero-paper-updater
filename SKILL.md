---
name: zotero-paper-updater
description: >
  Maintain existing Zotero paper records and managed local PDF copies. Use for
  requests such as "更新 Zotero 论文库", "补全已管理论文信息", "同步 Zotero 附件名",
  "清理重复 Zotero 论文", or maintaining an existing paper by Zotero key or local
  PDF path. Activate only when the request audits or changes existing library
  state; do not use for paper content reading, analysis, comparison, or note authoring.
---

# Zotero Paper Updater

## Responsibility

Maintain papers that already exist in Zotero and their managed local PDF copies.
The skill may complete exact-match metadata, synchronize local filenames, and
clean strictly proven duplicates while preserving user state.

Do not import PDFs, create Zotero parent items, edit `zotero.sqlite`, invent
identity from filenames, or take ownership of llm-for-zotero parsing.

## Route

For every in-scope request, read and follow
[`workflows/maintain-library.md`](workflows/maintain-library.md).

Use only `scripts/maintain-library.ps1` as the executable interface. Other
skills call that command and consume its JSON; they do not copy this workflow.
