# Zotero metadata writeback

## Supported route

Use the Zotero local API for reads and post-write verification. Perform writes through the bearer-protected llm-for-zotero MCP endpoint at `/llm-for-zotero/mcp`:

1. Run `scripts/invoke-llm-for-zotero-mcp.ps1 -ListTools` and select the semantic write tool when it covers the operation.
2. Use `zotero_script` only for an exact operation not covered by a semantic tool.
3. Load the parent item by library ID and parentItemKey.
4. Compare its current version with the version observed during the latest read.
5. Call `env.snapshot(item)` before mutation, apply only valid fields, and call `saveTx()`.
6. Verify through the local API.

Never run the block against attachmentKey.

Do not print the bearer token, place it in source control, or invoke Chrome/desktop automation. The helper reads it from the active Zotero profile and sends it only to the loopback endpoint.

## Template

Replace every placeholder from verified evidence. Keep fields absent from the change set out of the fields object.

    const libraryID = env.libraryID;
    const parentItemKey = "PARENT_ITEM_KEY";
    const expectedVersion = 123;
    const itemType = "journalArticle";
    const fields = {
      title: "VERIFIED TITLE",
      date: "VERIFIED DATE",
      publicationTitle: "VERIFIED CONTAINER",
      DOI: "10.xxxx/verified",
      url: "https://doi.org/10.xxxx/verified",
      language: "en"
    };
    const creators = [
      { firstName: "First", lastName: "Author", creatorType: "author" }
    ];
    const extraLine = "Metadata status checked YYYY-MM-DD: DOI, pages unavailable. Source: https://official.example/...";

    const item = await Zotero.Items.getByLibraryAndKeyAsync(
      libraryID,
      parentItemKey
    );
    if (!item) {
      throw new Error("Parent item not found: " + parentItemKey);
    }
    if (item.isAttachment()) {
      throw new Error("Refusing to edit an attachment as a parent item");
    }
    if (item.version !== expectedVersion) {
      throw new Error(
        "Version conflict: expected " + expectedVersion +
        ", current " + item.version
      );
    }

    env.snapshot(item);

    const typeID = Zotero.ItemTypes.getID(itemType);
    if (!typeID) {
      throw new Error("Unknown item type: " + itemType);
    }
    if (item.itemTypeID !== typeID) {
      item.setType(typeID);
    }

    for (const [field, value] of Object.entries(fields)) {
      item.setField(field, value);
    }
    if (creators.length) {
      item.setCreators(creators);
    }

    const oldExtra = item.getField("extra") || "";
    if (extraLine && !oldExtra.includes(extraLine)) {
      item.setField("extra", [oldExtra.trim(), extraLine].filter(Boolean).join("\n"));
    }

    await item.saveTx();
    env.log(JSON.stringify({
      key: item.key,
      version: item.version,
      itemType: Zotero.ItemTypes.getName(item.itemTypeID),
      title: item.getField("title"),
      creators: item.getCreators()
    }));

## Change-set rules

- Omit fields not being changed; do not write empty strings merely because a source lacks them.
- To intentionally clear a known-wrong value, list the field and explain the evidence before the write.
- Rebuild creators only when the complete ordered creator list is verified.
- Preserve creator types such as editor or contributor.
- Preserve tags, collections, relations, abstract, dateAdded, and other untouched fields.
- Changing the item type can invalidate field names. Verify the target field vocabulary for the new type before saving.
- Keep existing Extra content and append only a non-duplicated status line.
- Name every intentionally empty applicable field in the status line. Include the check date and the authoritative URL so the gap can be distinguished from an overlooked field and rechecked later.
- Do not use an Extra status note as a shortcut around research. Search Markdown and authoritative online records first; the note is for fields that remain formally unavailable after that check.

## Post-write verification

Read the parent again through Zotero's local API and compare it with the pre-write snapshot:

- target fields equal the verified values;
- ordered creators equal the verified list;
- untouched fields, tags, collections, and relations are unchanged;
- the item version advanced normally;
- no duplicate parent item was created;
- the PDF attachment still belongs to the same parent.
- every applicable field reported by the audit is now populated or appears by name in a dated, sourced Extra status line.

If the write fails, surface Zotero's error and correct the actual field/type problem. Do not add a broad try/catch that hides the failure.
