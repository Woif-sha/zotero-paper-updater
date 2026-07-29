# Maintain Library

This is the single workflow for both full-library and targeted maintenance.

1. Resolve the invocation mode:
   - no selector: full library rooted at `E:\paper`;
   - `-ItemKey`: one existing Zotero parent or attachment;
   - `-Path`: one existing managed PDF.
2. Call `scripts/maintain-library.ps1` once with the resolved selector.
3. Parse the JSON result. Treat invalid JSON, a non-zero process exit, or `ok: false` as an explicit failed run.
4. Report changed, deleted, renamed, repaired, and unresolved items from the returned arrays. Do not reconstruct results from console text or filesystem guesses.
5. For an embedded call, return control to the calling skill after this maintenance result. The caller continues its own content workflow independently.

The public script owns inventory, evidence lookup, writes, cleanup, repair, rollback/partial-failure policy, and post-write verification. This workflow must not duplicate those steps.

