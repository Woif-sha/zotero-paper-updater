# PROTOTYPE — unified maintenance contract

This throwaway prototype asks one question:

> Does one stable JSON envelope remain clear when a full-library or single-paper run performs several mutation types while also leaving some work unresolved?

Run it from the repository root:

```powershell
pwsh -NoProfile -File .\prototypes\maintenance-contract\run.ps1
```

For a non-interactive snapshot:

```powershell
pwsh -NoProfile -File .\prototypes\maintenance-contract\run.ps1 -Scenario mixed -Scope itemKey
```

## Proposed public invocation

The eventual public script would expose three mutually exclusive scopes:

```powershell
# Full library: E:\paper and the associated existing Zotero items
pwsh -File .\scripts\maintain-library.ps1

# One Zotero parent or attachment
pwsh -File .\scripts\maintain-library.ps1 -ItemKey PARENT1

# One managed local PDF
pwsh -File .\scripts\maintain-library.ps1 -Path 'E:\paper\Example Paper.pdf'
```

`-PaperRoot` and `-ZoteroDataDir` remain optional environment overrides. They do not create additional operation modes. `-ItemKey` and `-Path` are mutually exclusive.

## Proposed contract

- `schemaVersion` is the compatibility boundary.
- `status` reports execution completeness only: `succeeded`, `partial`, or `failed`.
- `changed` answers whether any mutation occurred; an unchanged healthy run is `status=succeeded, changed=false`.
- `actions[]` records facts that occurred. Its stable `category` is one of `modified`, `deleted`, `renamed`, or `repaired`; `kind` provides the narrower operation.
- `issues[]` records unresolved work. A target can therefore be modified and still be `partial` without inventing a combined status.
- Every action carries `target`, `before`, `after`, and `evidence`. Every issue carries `severity`, `code`, `target`, `message`, and `evidence`.
- Run-level failures live in top-level `issues`; target-specific unresolved work lives beside that target in `results[].issues`.

Suggested process exit codes:

| Exit code | Meaning |
|---:|---|
| `0` | `succeeded`, whether changed or unchanged |
| `2` | `partial`; the JSON explains unresolved work |
| `1` | `failed`; no trustworthy maintenance result was produced |

## Questions for the decision

1. Should `-PaperRoot` and `-ZoteroDataDir` stay public overrides, or should the entry resolve them entirely from the environment?
2. Is `partial` the right status when safe mutations succeeded but some metadata or associations remain unresolved?
3. Should deletion be represented as one logical `duplicate_paper_deleted` action containing all removed artifacts, or as one action per deleted Zotero/file/cache artifact?
