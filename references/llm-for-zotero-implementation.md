# llm-for-zotero MinerU implementation notes

## Verified baseline

These notes were verified against llm-for-zotero v3.8.26, commit `770a9ec65cdca0bc6e07b5eb8ae6eef3444aad81`, and the locally installed Zotero add-on with the same version on 2026-07-15. This is a reproducible baseline, not a frozen claim that v3.8.26 will remain latest.

Primary source:

- Repository: https://github.com/yilewang/llm-for-zotero
- Cache implementation: https://github.com/yilewang/llm-for-zotero/blob/v3.8.26/src/modules/contextPanel/mineruCache.ts
- Automatic parsing: https://github.com/yilewang/llm-for-zotero/blob/v3.8.26/src/modules/mineruAutoWatch.ts
- Batch parsing: https://github.com/yilewang/llm-for-zotero/blob/v3.8.26/src/modules/mineruBatchProcessor.ts
- Cache sync and repair: https://github.com/yilewang/llm-for-zotero/blob/v3.8.26/src/modules/contextPanel/mineruSync.ts

Re-check these files when the installed plugin version changes. Treat the implementation below as versioned evidence, not an eternal API contract.

Before each workflow, run `scripts/check-llm-for-zotero-version.ps1 -RequireLatest`. The installed production XPI declares the official update manifest at `https://github.com/yilewang/llm-for-zotero/releases/download/release/update.json`; the checker verifies that channel as well as the installed and latest stable versions. Zotero's built-in add-on updater uses the same channel.

## Cache path and identity

`getBaseDir()` uses Zotero's data directory and falls back to the Zotero profile directory only if the data directory is unavailable. `getMineruCacheDir()` appends `llm-for-zotero-mineru`, and `getMineruItemDir(id)` appends the numeric Zotero attachment ID.

Therefore a current cache normally has this layout:

```text
E:\ZoteroData\llm-for-zotero-mineru\<attachmentId>\
├── _llm_source.json
├── full.md
├── manifest.json
├── content_list.json
└── images\...
```

The numeric directory is a local locator. `_llm_source.json` supplies the stable Zotero keys needed to relate it to library records.

## Provenance v2

The plugin writes `_llm_source.json` after a successful parse. Version 2 contains:

- `kind`: `llm-for-zotero/mineru-cache-source`;
- `version`: `2`;
- `attachmentId`;
- `attachmentKey`;
- `parentItemKey`;
- `sourceFilename`;
- `origin`: `parsed` or `restored`;
- `recordedAt`, plus parse/restore timestamps;
- optional sync-package fields and `cacheContentHash`.

`sourceFilename` is read from the attachment when provenance is written. It is not refreshed merely because Zotero later renames the stored PDF, so it is evidence of the parse-time name rather than a current-name invariant.

The provenance schema does not store a hash of the source PDF. `cacheContentHash`, when present, describes cache-package content for synchronization; it does not prove that the current PDF bytes are the bytes MinerU parsed.

## Parse and write sequence

Both automatic and batch parsing follow the same core sequence:

1. Resolve the current Zotero attachment file path.
2. Call MinerU.
3. Normalize returned files and write the canonical `full.md` plus `manifest.json` under the numeric attachment directory.
4. Write `_llm_source.json` from the live Zotero attachment and parent.
5. Mark the item cached, optionally publish a sync package, and invalidate in-memory text/embedding caches.

The plugin writes the provenance after cache files. A process interruption can therefore leave a partially written directory; readers must validate all required files rather than assuming directory presence means success.

## Cache availability is weaker than cache validity

`hasCachedMineruMd(id)` returns true when the current `full.md`, a legacy `_content.md`, or a legacy single-file Markdown path exists. It does not check that Markdown is non-empty, that `_llm_source.json` matches the live attachment, that `manifest.json` parses, or that the current PDF bytes match the parsed source.

Automatic parsing skips an attachment whenever the availability layer reports something other than `missing`. A normal Zotero `modify` event is also ignored unless the item is already in a failed/processing retry state. Consequently, replacing PDF content under an existing attachment can leave an apparently available but stale cache.

Skill implication: perform independent health/provenance checks. Require explicit reparse or repair after known attachment replacement; do not invalidate for a filename-only rename.

## Markdown and manifest behavior

`full.md` is the canonical current Markdown path. The plugin normalizes MinerU archives, writes `content_list.json`, and builds `manifest.json` from the Markdown plus content-list metadata.

The manifest's character offsets are JavaScript string offsets, which are UTF-16 code-unit indices. Use the same indexing model when checking or slicing text. When no useful headings are detected, the manifest can have no sections; this is not by itself cache corruption. Read the whole validated `full.md` in that case.

The plugin treats manifest-writing failure as non-critical during a fresh cache write because the manifest can be rebuilt. This skill is stricter for efficient external reading: repair or rebuild a missing/invalid manifest before section-targeted reads.

## Sync and repair behavior

When MinerU cache sync is enabled, the plugin can publish companion ZIP attachments containing Markdown, manifest, content list, and selected assets. Repair can restore a missing local cache from such a package, finalize existing caches, remove numeric cache directories whose attachment IDs no longer exist, and clean orphan sync packages.

Use the plugin's Manage Files repair controls for plugin-owned repair. Do not emulate repair by editing `zotero.sqlite` or manually renaming files under Zotero storage.

## Operational conclusions

- Resolve identity with `attachmentKey` and `parentItemKey`; use numeric IDs only to locate a local cache.
- Read `manifest.json` and `full.md`, not the PDF, after health checks pass.
- Treat `sourceFilename` drift as normal after a Zotero rename.
- Treat a known attachment replacement as a freshness failure because provenance cannot prove the parsed PDF hash.
- Keep Zotero bibliographic metadata separate from MinerU's extracted content and synchronize verified fields back to the parent item.
