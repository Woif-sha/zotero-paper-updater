# Result Contract Sketch

The exact field set belongs to “定义统一维护入口与结果契约”. This ticket only fixes where that contract lives and how callers depend on it.

```json
{
  "schemaVersion": 1,
  "runId": "opaque-id",
  "mode": "library | itemKey | path",
  "target": null,
  "ok": true,
  "changed": [],
  "deleted": [],
  "renamed": [],
  "repaired": [],
  "unresolved": [],
  "errors": []
}
```

Compatibility rules proposed by this prototype:

- stdout contains exactly one JSON document;
- stderr may contain human-readable progress;
- array entries carry stable codes and identities, not prose-only messages;
- `schemaVersion` changes only for breaking field semantics;
- internal script names and intermediate artifacts are not part of the contract.

