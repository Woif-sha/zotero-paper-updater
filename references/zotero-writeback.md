# Zotero metadata writeback

## Supported route

In this setup the local API is used for reads and post-write verification. Perform metadata edits in Zotero Desktop:

1. Open Tools → Developer → Run JavaScript.
2. Use an async JavaScript block.
3. Load the parent item by library ID and parentItemKey.
4. Compare its current version with the version observed during the latest read.
5. Apply only valid fields and creators.
6. Call saveTx().
7. Verify through the local API.

Never run the block against attachmentKey.

## Template

Replace every placeholder from verified evidence. Keep fields absent from the change set out of the fields object.

    const libraryID = Zotero.Libraries.userLibraryID;
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
    const extraLine = "Metadata status checked YYYY-MM-DD: ... Source: ...";

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
    return {
      key: item.key,
      version: item.version,
      itemType: Zotero.ItemTypes.getName(item.itemTypeID),
      title: item.getField("title"),
      creators: item.getCreators()
    };

## Change-set rules

- Omit fields not being changed; do not write empty strings merely because a source lacks them.
- To intentionally clear a known-wrong value, list the field and explain the evidence before the write.
- Rebuild creators only when the complete ordered creator list is verified.
- Preserve creator types such as editor or contributor.
- Preserve tags, collections, relations, abstract, dateAdded, and other untouched fields.
- Changing the item type can invalidate field names. Verify the target field vocabulary for the new type before saving.
- Keep existing Extra content and append only a non-duplicated status line.

## Post-write verification

Read the parent again through Zotero's local API and compare it with the pre-write snapshot:

- target fields equal the verified values;
- ordered creators equal the verified list;
- untouched fields, tags, collections, and relations are unchanged;
- the item version advanced normally;
- no duplicate parent item was created;
- the PDF attachment still belongs to the same parent.

If the write fails, surface Zotero's error and correct the actual field/type problem. Do not add a broad try/catch that hides the failure.
