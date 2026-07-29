# Embedded caller example

A paper-reading or thesis-writing skill may require Zotero maintenance before its own content task:

```markdown
1. Resolve the paper to an existing Zotero key or managed PDF path.
2. Run `zotero-paper-updater/scripts/maintain-library.ps1` with that one selector.
3. Parse the stable JSON result and stop if `ok` is false.
4. Return to this skill's own workflow for reading, summarizing, comparing, or note-taking.
```

Ownership stays explicit:

- `zotero-paper-updater` owns bibliographic and file maintenance.
- The calling skill owns content reading and downstream deliverables.
- The stable JSON boundary is the only shared source of truth.

