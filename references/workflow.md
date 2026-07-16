# Detailed workflow and invariants

## 1. Connectivity and inventory

Use the installed Zotero skill's helper and begin with status --json. Confirm:

- Zotero Desktop is running;
- the local API is enabled and reachable at 127.0.0.1:23119;
- the user library route works;
- the discovered data directory matches the directory used for storage and MinerU.

Before relying on plugin-specific behavior, run `scripts/check-llm-for-zotero-version.ps1 -RequireLatest`. It reads the installed add-on record and XPI manifest, then compares them with the stable update manifest published by [yilewang/llm-for-zotero](https://github.com/yilewang/llm-for-zotero). Do not claim the plugin is current when this online check fails. If an authorized update is installed through Zotero, rerun both the version check and Zotero status probe.

Resolve the data directory in this order: an explicit user path, `ZOTERO_DATA_DIR`, the existing local default `E:\ZoteroData`, and finally Zotero status/profile discovery. Report the resolved path rather than assuming the fallback was used.

Use the local API for reads and verification and llm-for-zotero's local MCP for writes. Never initialize `computer-use`, Chrome, or browser automation for this workflow. Probe `http://127.0.0.1:23119/llm-for-zotero/mcp` with `scripts/invoke-llm-for-zotero-mcp.ps1`; never edit zotero.sqlite directly, even while Zotero is closed.

Resolve the managed paper root before inventory. Use an explicit user path first, then the existing machine default `E:\paper`, and only then the current working directory. This prevents a generic update request from accidentally auditing the skill repository.

Inventory parent items and their PDF children. Keep these identifiers distinct:

- parent item key: bibliographic record;
- attachment key: PDF record and storage folder name;
- BibTeX citation key: export identifier, not a Zotero item key;
- numeric attachment id: local implementation detail used by the MinerU directory.

## 2. MinerU provenance mapping

Recursively enumerate _llm_source.json under the MinerU root. For each record:

1. Parse JSON and require current provenance kind `llm-for-zotero/mineru-cache-source`, version 2, attachmentId, attachmentKey, parentItemKey, origin, and recordedAt.
2. Treat the containing numeric folder as a cache location, not identity.
3. Resolve ZoteroData\storage\attachmentKey.
4. Require exactly one current PDF in that storage directory.
5. Resolve the parent item through parentItemKey and confirm the attachment is its child.
6. Detect duplicate attachment keys and orphaned cache records.

sourceFilename records the name at parse time. It is useful as evidence but is not an invariant after renaming.

For a single-paper reading request, use `scripts/resolve-paper-md.ps1` with a parent or attachment key. If a parent has multiple PDF caches, stop and select the attachment explicitly rather than guessing.

## 3. Cache health

For each mapped cache require:

- full.md exists and is not empty;
- _llm_source.json parses;
- manifest.json parses;
- manifest totalChars, when present, equals the .NET/JavaScript UTF-16 string length of full.md;
- section character ranges stay within full.md;
- paths named in the manifest are interpreted relative to that cache directory.

The manifest's charStart and charEnd values are JavaScript UTF-16 code-unit indices. Do not interpret them as UTF-8 byte offsets, especially around Chinese or non-BMP characters.

Treat an out-of-bounds section range as a blocking cache error. Treat an
out-of-bounds optional figureBlocks locator as a quality warning when full.md,
totalChars, and section ranges remain valid; do not use that locator for
slicing, and report it for reparsing/plugin repair.

The plugin's availability check accepts an existing current or legacy Markdown path and may accept an empty or stale file. Automatic parsing skips an attachment that is already reported as available, and ordinary modify events are not a general freshness check. Replacing the content of an existing attachment may therefore leave a stale cache.

See `llm-for-zotero-implementation.md` for the versioned source evidence behind these rules.

## 4. Reading a paper

Locate by attachmentKey first. Read manifest.json to identify sections, figures, tables, and character ranges, then read only the necessary sections of full.md.

MinerU can omit a title, OCR a heading incorrectly, or damage symbols. Keep paper identity anchored to provenance and Zotero. Correct bibliography from Zotero and authoritative sources, not from a fuzzy Markdown heading match.

When valid Markdown is unavailable, mark the paper unreadable in MD-first mode and trigger or await MinerU. Do not invoke PDF extraction as a hidden fallback.

## 5. Metadata audit and evidence

Read the current parent record immediately before preparing changes. Compare it field by field with evidence. Prefer exact, first-party records and record URLs or identifiers in the work log.

Do not let empty applicable fields disappear from the report. Classify every gap as one of:

- verified and ready to write;
- already documented as formally unavailable;
- unresolved and requiring an online source check.

The audit script treats missing title, creators, or date as core errors. It also reports item-type-specific fields such as venue, volume, issue, pages, DOI, URL, language, publisher, place, and ISSN/ISBN. A recommended field can remain formally empty only when `Extra` names that field and records when and where its availability was checked.

Common traps:

- A DOI deposit date is not necessarily the publication date.
- Early-access year and volume/issue year may both be real; represent them according to the publisher record and explain the status in Extra.
- An IEEE Xplore document ID is not automatically an article number.
- A conference Paper ID is not pagination.
- A manifest page count is the PDF length, not bibliographic pages.
- Organization of a conference is not necessarily the proceedings publisher.

If a formal record is pending, leave DOI, pages, volume, issue, or publisher empty as appropriate. Append a field-specific line such as:

    Metadata status checked YYYY-MM-DD: DOI, pages unavailable. Source: official conference program URL.

Preserve existing Extra content and avoid duplicate status lines.

## 6. Safe writeback

Before editing:

1. Save a JSON snapshot of the parent key, version, type, fields being changed, ordered creators, tags, collections, relations, and Extra.
2. Ensure the target is the parent item, not the attachment.
3. Prepare the smallest change set.
4. Recheck the live item version in the Zotero JavaScript context.
5. Abort on a version mismatch and re-read rather than forcing a save.

After editing, query the record again through the local API and deep-compare untouched fields. Creators must preserve order and creatorType.

See zotero-writeback.md for the execution template.

## 7. Zotero attachment naming

Changing parent metadata may cause Zotero to auto-rename stored attachments. If it does not, invoke Zotero's own Rename File from Parent Metadata command. Do not rename the storage file in PowerShell or Explorer because Zotero's attachment metadata can become inconsistent.

Wait for Zotero to finish, then enumerate the PDF currently in ZoteroData\storage\attachmentKey. Its basename is the only canonical filename for the local paper copy.

## 8. Local filename synchronization

Run the audit with hashing enabled. A rename candidate is safe only when:

- the local candidate hash equals the Zotero storage PDF hash;
- the candidate is uniquely identified;
- the source is within PaperRoot;
- the target is within PaperRoot;
- the target does not exist.

Use native PowerShell Rename-Item with -LiteralPath. Never send paths through cmd.exe or construct a deletion pipeline.

If the target already exists:

- different hash: stop and report a collision;
- same hash: report a duplicate and request explicit cleanup authority; do not delete either copy.

After rename, verify the hash is unchanged and the basename exactly matches Zotero, including punctuation, year, and creator string.

## 9. Cache invalidation

Do not invalidate a cache merely because sourceFilename differs from the current attachment name.

Invalidate when attachment content was replaced or the Markdown is empty/corrupt. Because provenance version 2 does not store the original PDF hash, a changed attachment cannot always be proven from the cache alone. Use known replacement history, Zotero modification evidence, or explicit user confirmation.

For a required reparse, prefer a reversible quarantine of the numeric cache directory with a timestamp before invoking the plugin. Confirm the new _llm_source.json points to the same attachmentKey and the new full.md is non-empty before removing any backup. Deletion is a separate destructive action and requires explicit authority.

For a proven duplicate paper, the user's standing policy is different: keep the newest healthy parse and permanently delete older duplicate local PDFs and MinerU caches. Delete Zotero-managed storage only after the corresponding attachment record is removed through llm-for-zotero MCP; otherwise sync restores it. Empty trash only after a read script proves it contains exactly the verified duplicate set. Do not quarantine or back up duplicate versions. PDF byte differences alone do not require retention when DOI or full bibliographic identity matches and the Markdown represents the same paper with only MinerU/OCR-level differences.

## 10. Knowledge notes

Maintain PaperRoot\notes\parentItemKey.md. Use the bundled template and update the same file. Include:

- bibliographic identity and evidence;
- research question;
- method;
- experiments or data;
- key results;
- equations and variables;
- limitations;
- relation to the user's topic;
- reusable knowledge;
- open questions.

Add the mapped attachmentKey, full.md path, and source headings so every claim can be found again.

## 11. Strict completion gates

The final audit must show:

- one unique cache record per included attachment;
- one unique parent relation;
- valid non-empty full.md and parseable manifest/provenance;
- exactly one Zotero storage PDF;
- exactly one matching local PDF;
- identical local and Zotero basenames;
- identical SHA-256 hashes;
- no unaccounted PDF in the managed paper root.
- no missing core bibliographic field;
- no applicable empty field that lacks either verified data or a dated, sourced status note in Extra.

If any gate fails, report the record and the corrective action still needed. Do not reduce the error to a generic “not synced” message.
