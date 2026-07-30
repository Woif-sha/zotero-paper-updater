# Maintain an existing Zotero library

This workflow is the sole source of maintenance procedure and safety rules.
Operate only on papers that already have a live Zotero parent and PDF attachment.

## Public call

Invoke `scripts/maintain-library.ps1` once for the requested scope:

- no selector: all managed PDFs under `PaperRoot`;
- `-ItemKey`: one existing parent or PDF attachment;
- `-Path`: one existing managed local PDF.

`-ItemKey` and `-Path` are mutually exclusive. `-PaperRoot` and
`-ZoteroDataDir` only override environment roots. Do not call internal modules
or adapters from another skill.

## Evidence boundary

Resolve identity from live Zotero parent/attachment relationships. For a path,
require a unique SHA-256 match between the selected local PDF and a live Zotero
storage PDF. Never identify a paper from its filename, a numeric cache
directory, `sourceFilename`, file size, or approximate title.

Freeze only the affected target when evidence is missing, ambiguous, outside
an allowed root, behind a reparse point, or conflicts by hash. Continue
independent targets unless the failure invalidates the run-wide scope or fixed
deletion set.

Do not import a PDF, create a parent item, edit `zotero.sqlite`, overwrite a
different file, or introduce a hidden fallback.

## Per-target maintenance

Perform at most one metadata source query per parent. Query by DOI when present;
otherwise query once by full title and first creator. Write only an exact formal
record match. Apply the complete source-provided bibliographic record and an
explicit item type when supplied, while preserving source-absent fields and all
tags, collections, notes, attachments, annotations, relations, and unrelated
fields. A source miss is a successful no-op and must not create an issue or
write a missing-state marker.

After metadata maintenance, take the canonical local filename from the current
Zotero storage PDF basename. Rename only when the local source and storage PDF
have a unique SHA-256 relationship, the source is inside `PaperRoot`, and the
target is safe. A different-hash target is a blocking collision. Never rename a
file inside Zotero storage directly.

## Strict duplicate cleanup

Treat items as duplicates only when DOI identity is exact, or normalized title,
ordered creators, and publication context all match, and healthy MinerU content
confirms the same work. Incomplete or conflicting identity evidence blocks
cleanup.

Choose the retained parent by the most user state and external relations, then
the earliest `dateAdded`. Choose retained attachment evidence in this order:
annotations that cannot be moved losslessly, formal final status, healthy cache
completeness, and most recent successful parse.

Before any destructive operation:

1. consolidate tags, collections, and relations without loss;
2. prove that notes and annotations remain attached to compatible retained
   objects, otherwise stop;
3. freeze retained/deleted keys, versions, hashes, paths, and the exact asset
   set;
4. verify every path is under its allowed root and no reparse point is crossed;
5. verify the local MCP deletion channel and the exact Zotero Trash set.

Run cleanup as one serialized, resumable transaction. Revalidate live evidence
before each stage. Move only the frozen objects to Trash, require Trash to equal
the deletion set, permanently purge and prove old keys absent, then remove only
the frozen redundant storage directories, MinerU caches, and local PDFs.

Resume from physical proof, not a saved stage flag. New user state, changed
hashes, unexpected Trash content, missing retained assets, or another pending
transaction blocks progress and requires a new preflight. A completed
transaction rerun is a successful no-op. Report a complete cleanup as one
logical `deleted` action whose `before` lists every removed asset and whose
`after` is null.

## Result contract

stdout contains exactly one JSON document. The top level contains
`schemaVersion`, run identity and timestamps, `status`, `changed`, `scope`,
`summary`, `results`, and run-level `issues`. Every target result contains its
status, changed flag, stable target identity, typed `actions`, and `issues`.

Action categories are `modified`, `deleted`, `renamed`, and `repaired`.
Exit `0` for `succeeded`, `2` for `partial`, and `1` for `failed`. Diagnostics
belong on stderr and must not corrupt stdout.

## Ownership boundary

llm-for-zotero owns MinerU provenance, association, parsing, and cache creation.
This workflow may validate the minimum cache facts required to prove duplicate
identity and may delete only a redundant attachment's frozen cache asset.

Paper-content reading, analysis, comparison, citation export, custom filename
schemes, importing new PDFs, provenance repair, reparsing, and note generation
belong to other workflows or skills.
