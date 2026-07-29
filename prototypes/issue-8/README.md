# PROTOTYPE — migration compatibility and validation

This throwaway logic prototype answers one question:

> Which legacy interfaces should survive, and which validation cases prove that the simplified `zotero-paper-updater` preserves its core maintenance capability?

It does not access Zotero, `E:\paper`, MinerU caches, or the network. The portable module contains the proposed policy and scenario oracle; `run.ps1` is only an interactive shell for reviewing that model.

## Run

From the repository root:

```powershell
pwsh -NoProfile -File .\prototypes\issue-8\run.ps1
```

Use `n` and `p` to review the nine cases, `i` to inspect the interface decisions, and `j` to inspect the complete JSON state.

For a non-interactive smoke check:

```powershell
pwsh -NoProfile -File .\prototypes\issue-8\run.ps1 -Scenario All -Json |
    ConvertFrom-Json |
    Select-Object id, invocation, expected
```

## Proposed compatibility decision

Preserve one public interface only:

```text
scripts/maintain-library.ps1
  no selector       full-library maintenance
  -ItemKey <key>    one managed Zotero item
  -Path <pdf>       one managed local PDF
```

`-PaperRoot` and `-ZoteroDataDir` remain optional environment overrides. The output boundary is the schema-versioned JSON contract already chosen by [定义统一维护入口与结果契约](https://github.com/Woif-sha/zotero-paper-updater/issues/3).

The old scripts retain useful implementation capabilities but not public compatibility:

| Old interface | Decision | Capability retained internally |
| --- | --- | --- |
| `resolve-paper-md.ps1` | Internalize | Unique item, attachment, and cache resolution |
| `audit-paper-links.ps1` | Internalize | Mapping, hashing, collision, and ambiguity checks |
| `check-llm-for-zotero-version.ps1` | Internalize | MinerU-dependent runtime preflight |
| `invoke-llm-for-zotero-mcp.ps1` | Internalize | Authenticated MCP transport |
| Reading, note generation, and metadata-gap bookkeeping | Delete | None; these responsibilities have left the skill |

There are no compatibility shims for old script names, parameters, exit codes, or JSON fields. In particular, `-AllowIncomplete`, `-SkipHash`, `-SkipApi`, `-RequireAllCaches`, and `-ZoteroApiBase` are not options on the new public entry.

## Proposed validation standard

Automated validation should prove these observable behaviors through the one public entry:

| Case | Expected result |
| --- | --- |
| Default call | Resolves `E:\paper`; a no-op is `succeeded`, `changed=false`, exit `0` |
| `-ItemKey` | Touches one uniquely resolved paper and returns typed actions |
| `-Path` | Touches one uniquely hash-mapped local PDF and respects Zotero's canonical name |
| First duplicate cleanup | Emits one logical deletion action containing the complete verified asset set |
| Repeated duplicate cleanup | Is idempotent: no repeated deletion, no orphaned asset, `changed=false` |
| Metadata not found | Stops after the one allowed lookup, preserves empty fields and `Extra`, and succeeds without inventing an unresolved error |
| Filename conflict | Does not overwrite, merge, rename, or delete; returns `partial` with both paths and hashes |
| Ambiguous association | Performs no repair or destructive action; returns all candidates as a reportable issue |
| Both selectors supplied | Fails before inventory or mutation but still emits contract-valid JSON |

Every case should additionally assert:

- stdout contains exactly one parseable JSON document and diagnostics stay off stdout;
- all stable top-level and per-target fields are present;
- `status`, `changed`, action categories, issue codes, and process exit code agree;
- fixtures use temporary directories and fake adapters rather than the live Zotero library;
- the old script CLIs and JSON shapes are not included in compatibility tests.

## Review question

Does this boundary match the desired migration policy: **retain old capabilities internally, but provide no compatibility promise for any old script interface or JSON shape**?
