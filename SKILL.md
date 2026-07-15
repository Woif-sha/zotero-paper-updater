---
name: zotero-paper-updater
description: Maintain a local Zotero paper workspace backed by llm-for-zotero MinerU Markdown. Use when the user asks to update Zotero papers, fill missing bibliographic metadata, map MinerU full.md files to Zotero attachments, rename local PDFs to the current Zotero attachment names, keep paper knowledge notes, validate one-to-one mappings, or says 更新 Zotero paper、论文文件名与 Zotero 一致、以后读 MD 不读 PDF、_llm_source.json、attachmentKey、llm-for-zotero-mineru.
---

# Zotero Paper Updater

Treat this as a synchronization workflow with four distinct sources of truth:

- Zotero parent item: bibliographic identity and metadata.
- Zotero attachment key: stable link between the PDF attachment and MinerU cache.
- Current Zotero storage PDF basename: canonical filename for the user's local paper copy.
- MinerU full.md: paper-content source after cache validation.

Never collapse these roles into the downloaded filename, a numeric MinerU directory, or the Markdown's first heading.

## Resolve the workspace

Resolve and report these paths before acting:

- Paper root: the folder named by the user; otherwise the current working directory.
- Zotero data directory: obtain it from Zotero status/profile information or an explicit user-provided path. Do not hardcode a machine-specific default.
- MinerU root: ZoteroDataDir\llm-for-zotero-mineru.
- Notes root: PaperRoot\notes.

Use the companion Zotero skill for connectivity and read-only library queries. Start with its status --json command. If the API is disabled and the user asked to operate Zotero, enable it and restart Zotero, then probe again.

Use computer-use for supported Zotero UI writes. The local Zotero API is read-only in this setup; do not invent PATCH or PUT routes.

## Choose the action boundary

- For 检查、梳理、能否对应、审计: stay read-only.
- For 更新、补齐、同步、重命名: apply only the requested Zotero metadata and local filename changes, then verify them.
- Never treat a metadata update as permission to replace attachments, delete caches, or remove duplicate files.

A read-only one-to-one audit may inspect Zotero storage filenames, query the local
API, and hash PDF bytes unless the user explicitly forbids those checks. These
operations do not read PDF content and are required to prove identity.

## Run the workflow

1. Inventory Zotero parent items and PDF attachments.
2. Run scripts/audit-paper-links.ps1 with -AllowIncomplete for the initial audit.
3. Map every cache through _llm_source.json:
   - attachmentKey is the primary key.
   - parentItemKey identifies the bibliographic parent.
   - attachmentId and the numeric directory are diagnostic only.
   - sourceFilename is a parse-time snapshot and may be stale after a rename.
4. Validate full.md, manifest.json, and _llm_source.json before reading content.
5. Read manifest.json first, then only the relevant sections of full.md.
6. Audit and enrich the Zotero parent metadata.
7. Write metadata through Zotero's supported UI/JavaScript route, with a version check and a minimal field-level change.
8. Let Zotero rename its own stored attachment, or use Zotero's Rename File from Parent Metadata action. Never rename a file inside ZoteroData\storage from the filesystem.
9. Re-read the actual current storage PDF basename. Rename the local copy only after SHA-256 identity, collision, and path checks pass.
10. Create or update notes\parentItemKey.md from assets/paper-note-template.md.
11. Run the audit script again without -AllowIncomplete. Do not claim completion while blocking errors remain.

Report non-blocking manifest locator warnings separately. A bad optional figure
range does not erase an otherwise proven attachment-to-Markdown mapping, but that
range must not be used to slice full.md.

Read references/workflow.md for the detailed gates and failure handling. Read references/zotero-writeback.md before any Zotero metadata write.

## Metadata evidence policy

Audit title, ordered creators, date, item type, container, conference, volume, issue, pages or article number, DOI, URL, language, publisher, place, and ISSN when applicable.

Use sources in this order:

1. The mapped full.md for facts printed in the paper.
2. DOI registry or publisher record.
3. Official conference site, proceedings, or program.
4. Author or institution page.
5. Official preprint record.

Browse for any field that may have changed or is absent locally. Require an exact identity match by title plus creators and context. Do not infer bibliographic values from:

- downloaded filenames;
- Zotero dateAdded or file timestamps;
- the latest year in references;
- MinerU page count;
- conference Paper ID;
- a title-similar web result with mismatched creators.

Leave an unavailable formal field blank. Preserve existing Extra text and append a dated, sourced status note instead of fabricating a value.

## Markdown-first rule

When valid full.md exists, PDF text extraction, OCR, and PDF converters are forbidden for paper reading. Hashing a PDF to establish file identity is allowed and is not content reading.

If full.md is missing, empty, malformed, or known to represent an older attachment:

- report the exact failed gate;
- wait for or explicitly trigger MinerU reparsing;
- do not silently fall back to the PDF unless the user explicitly authorizes it.

A filename-only change does not invalidate MinerU. A replaced attachment can invalidate it even when the attachment key is unchanged. The plugin normally checks only whether full.md exists, so do not trust a cache hit by itself.

## Filename synchronization

The desired local filename is the exact basename currently present in ZoteroData\storage\attachmentKey after Zotero has finished its own rename.

Before renaming a local file:

- prove it is the same attachment by SHA-256;
- resolve both paths to absolute paths under PaperRoot;
- require one source and no conflicting target;
- stop if a target exists with a different hash;
- do not overwrite, merge, or delete files.

After renaming, recompute SHA-256 and rerun the strict audit. A stale sourceFilename in _llm_source.json is expected and must not break the mapping.

## Knowledge note invariant

Use parentItemKey, not title, as the note filename. Update one note in place rather than creating title-based duplicates. Record locatable Markdown headings or short anchors for claims; do not copy full.md wholesale.

## Completion report

Report:

- Zotero connectivity;
- resolved roots;
- counts of parents, attachments, caches, and local PDFs;
- the attachmentKey to parentItemKey to full.md mapping;
- metadata fields changed and sources used;
- local renames with pre/post hashes;
- note files created or updated;
- unresolved metadata and cache problems;
- final strict-audit result.

Do not say the workflow is complete unless mappings are unique, Markdown caches are valid, local names equal current Zotero attachment names, and verified hashes match.
