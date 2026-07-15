---
name: zotero-paper-updater
description: Maintain and read a local Zotero library backed by llm-for-zotero MinerU Markdown. Use whenever the user asks to read, summarize, compare, or analyze a Zotero paper; fill missing dates, authors, venues, DOI, pages, or other bibliographic metadata; map MinerU full.md files to Zotero attachments; repair cache provenance; rename local paper copies; or says 更新 Zotero paper、论文信息不要留空、以后读 MD 不读 PDF、E:\ZoteroData、_llm_source.json、attachmentKey、llm-for-zotero-mineru. Prefer a validated full.md over PDF text extraction and sync verified metadata back to the Zotero parent item.
---

# Zotero Paper Updater

Treat the task as synchronization among four distinct sources of truth:

- Zotero parent item: bibliographic identity and metadata.
- Zotero attachment key: stable link between the PDF attachment and MinerU provenance.
- Current Zotero storage PDF basename: canonical filename for the user's local paper copy.
- Validated MinerU `full.md`: default paper-content source.

Do not collapse these roles into the downloaded filename, numeric MinerU directory, `sourceFilename`, or the Markdown's first heading.

## Resolve this environment

Resolve and report these paths before acting:

- Paper root: the folder named by the user; otherwise the current working directory.
- Zotero data directory: an explicit user path, then `ZOTERO_DATA_DIR`, then `E:\ZoteroData` when it exists; otherwise obtain it from Zotero status/profile information.
- MinerU root: `ZoteroDataDir\llm-for-zotero-mineru`.
- Zotero storage root: `ZoteroDataDir\storage`.
- Notes root: `PaperRoot\notes`.

Use the companion Zotero skill for connectivity and read-only library queries. Start with its `status --json` command. If the API is disabled and the user asked to operate Zotero, enable it and restart Zotero, then probe again.

The upstream plugin is [yilewang/llm-for-zotero](https://github.com/yilewang/llm-for-zotero). The implementation reference was verified against v3.8.26, but that is a baseline rather than a permanent latest-version claim. Run `scripts/check-llm-for-zotero-version.ps1 -RequireLatest` at the start of every MinerU workflow. If the check cannot reach the official update manifest, report that freshness is unverified. If an update is available, update through Zotero's Add-ons UI when the request authorizes it, then rerun the check before relying on version-specific behavior.

Read `references/llm-for-zotero-implementation.md` before diagnosing cache drift, reparsing, restore/sync behavior, or a plugin-version change.

When the user wants global Skills available inside llm-for-zotero, run `scripts/sync-global-skills-to-runtime.ps1`. It reads the `skills-updater` registry as the canonical inventory, preserves plugin-owned Skills, and creates one directory symbolic link per registered Skill. Do not hardcode a `profile-*` suffix: it is derived from the Zotero profile path and can change when profiles move or switch. Rerun the sync after such a change or after an upstream runtime-layout change; use `-RuntimeRoot` if discovery reports that the root moved.

## Choose the action boundary

- For 检查、梳理、能否对应、审计: stay read-only.
- For 研读、总结、比较: read only validated MinerU Markdown and Zotero metadata.
- For 更新、补齐、同步、重命名: apply the requested Zotero metadata and local filename changes, then verify them.
- Never treat a metadata update as permission to replace attachments, delete caches, remove duplicate files, or edit `zotero.sqlite`.

A read-only one-to-one audit may inspect Zotero storage filenames, query the local API, and hash PDF bytes. Hashing proves identity without reading PDF content.

## Run the workflow

1. Run the live upstream version check, then check Zotero status and inventory parent items plus PDF attachments.
2. Resolve a requested paper with `scripts/resolve-paper-md.ps1`. Search Zotero first when the user supplied a title rather than a Zotero key.
3. Run `scripts/audit-paper-links.ps1 -AllowIncomplete` for an initial paper-root audit.
4. Map each cache through `_llm_source.json`:
   - `attachmentKey` links provenance to the Zotero attachment and storage directory.
   - `parentItemKey` identifies the bibliographic parent.
   - `attachmentId` and the numeric directory are local cache locators, not durable identity.
   - `sourceFilename` is a parse-time snapshot and may be stale after a rename.
5. Validate `_llm_source.json`, non-empty `full.md`, and `manifest.json` before reading content.
6. Read `manifest.json` first and then only the relevant `full.md` ranges. If the manifest has `noSections: true` or no sections, read `full.md` directly.
7. Audit every applicable Zotero metadata field. Fill supported values from Markdown and authoritative online sources; explicitly document any field that remains formally unavailable.
8. Write metadata through Zotero's supported UI/JavaScript route with a version check and a minimal field-level change.
9. Let Zotero rename its own stored attachment. Never rename a file inside `ZoteroData\storage` from the filesystem.
10. Re-read the actual storage PDF basename. Rename a local copy only after SHA-256 identity, collision, and path checks pass.
11. Create or update `notes\parentItemKey.md` from `assets/paper-note-template.md`.
12. Run the audit again without `-AllowIncomplete`. Do not claim completion while blocking errors or undocumented metadata gaps remain.

Read `references/workflow.md` for detailed gates and failure handling. Read `references/zotero-writeback.md` before any Zotero metadata write.

## Metadata completeness policy

Audit title, ordered creators, date, item type, container or conference, volume, issue, pages or article number, DOI, URL, language, publisher, place, and ISSN/ISBN when applicable.

Use evidence in this order:

1. The mapped `full.md` for facts printed in the paper.
2. DOI registry or publisher record.
3. Official conference site, proceedings, or program.
4. Author or institution page.
5. Official preprint record.

Browse whenever an applicable field is missing locally or may have changed. Require an exact identity match by title, ordered creators, and publication context. Do not infer values from downloaded filenames, Zotero `dateAdded`, file timestamps, the latest year in references, MinerU page count, conference Paper ID, or a title-similar result with mismatched creators.

Do not silently leave a gap. For each applicable empty field, either:

- populate it from verified evidence; or
- preserve the empty formal field and append a dated status line to `Extra` naming the unavailable fields and the source checked, for example: `Metadata status checked 2026-07-15: DOI, pages unavailable. Source: https://...`.

This rule prevents fabrication while making every remaining gap explicit and re-checkable.

## Markdown-first rule

When valid `full.md` exists, PDF text extraction, OCR, and PDF converters are forbidden for paper reading. Do not open a PDF merely because a title is absent or a manifest has no section headings. Identity comes from Zotero keys and provenance.

If `full.md` is missing, empty, malformed, or known to represent an older attachment:

- report the exact failed gate;
- use llm-for-zotero's Manage Files parse/repair action or await MinerU reparsing;
- do not silently fall back to the PDF unless the user explicitly authorizes it.

The plugin's availability check treats an existing `full.md` as cached. Provenance v2 does not store the source PDF hash, so a cache hit alone cannot prove freshness after attachment replacement. A filename-only change does not invalidate MinerU.

## Filename synchronization

The desired local filename is the exact basename currently present in `ZoteroData\storage\attachmentKey` after Zotero finishes its own rename.

Before renaming a local file:

- prove it is the same attachment by SHA-256;
- resolve source and target under `PaperRoot`;
- require one source and no conflicting target;
- stop if a target exists with a different hash;
- do not overwrite, merge, or delete files.

After renaming, recompute SHA-256 and rerun the strict audit. A stale `sourceFilename` is expected and must not break the mapping.

## Knowledge note invariant

Use `parentItemKey`, not title, as the note filename. Update one note in place. Record locatable Markdown headings or short anchors for claims; do not copy `full.md` wholesale.

## Completion report

Report:

- Zotero and llm-for-zotero connectivity/version;
- resolved paper, Zotero data, MinerU, storage, and notes roots;
- counts of parents, attachments, caches, and local PDFs;
- the `attachmentKey -> parentItemKey -> full.md` mapping;
- cache-health findings and whether PDF content reads remained zero;
- metadata fields changed, sources used, and explicitly documented unavailable fields;
- local renames with pre/post hashes;
- note files created or updated;
- final strict-audit result.

Do not say the workflow is complete unless mappings are unique, Markdown caches are valid, local names equal current Zotero attachment names, verified hashes match, and every applicable metadata gap is either filled or explicitly documented.
