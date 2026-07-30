Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot "ZoteroPaperUpdater.Common.psm1") -DisableNameChecking

function ConvertTo-WriterBase64Json {
    param([Parameter(Mandatory = $true)][object]$Value)

    $json = $Value | ConvertTo-Json -Depth 30 -Compress
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
}

function Get-McpBusinessResult {
    param([Parameter(Mandatory = $true)][object]$Response)

    $rpcError = Get-OptionalPropertyValue -Object $Response -Name "error"
    if ($null -ne $rpcError) {
        throw "llm-for-zotero MCP returned an error: $($rpcError | ConvertTo-Json -Depth 10 -Compress)"
    }
    $result = Get-RequiredPropertyValue -Object $Response -Name "result"
    if ([bool](Get-OptionalPropertyValue -Object $result -Name "isError")) {
        throw "llm-for-zotero MCP tool call failed: $($result | ConvertTo-Json -Depth 10 -Compress)"
    }
    $content = @(Get-OptionalPropertyValue -Object $result -Name "content")
    $textBlocks = @(
        $content |
            Where-Object { [string](Get-OptionalPropertyValue -Object $_ -Name "type") -eq "text" } |
            ForEach-Object { [string](Get-OptionalPropertyValue -Object $_ -Name "text") }
    )
    if ($textBlocks.Count -ne 1) {
        throw "llm-for-zotero MCP did not return exactly one text result."
    }
    try {
        $toolResult = $textBlocks[0] | ConvertFrom-Json -Depth 30
    }
    catch {
        throw "llm-for-zotero MCP returned an invalid tool result: $($textBlocks[0])"
    }
    $toolError = [string](Get-OptionalPropertyValue -Object $toolResult -Name "error")
    if (-not [string]::IsNullOrWhiteSpace($toolError)) {
        throw "llm-for-zotero zotero_script failed: $toolError"
    }
    $output = [string](Get-RequiredPropertyValue -Object $toolResult -Name "output")
    try {
        $business = $output | ConvertFrom-Json -Depth 10
    }
    catch {
        throw "llm-for-zotero zotero_script returned invalid business output: $output"
    }
    $status = [string](Get-RequiredPropertyValue -Object $business -Name "status")
    if ($status -notin @("written", "version_conflict")) {
        throw "llm-for-zotero zotero_script returned unsupported status '$status'."
    }
    $business
}

function Assert-WriterFieldsPreserved {
    param(
        [Parameter(Mandatory = $true)][object]$BeforeData,
        [Parameter(Mandatory = $true)][object]$AfterData,
        [Parameter(Mandatory = $true)][string[]]$WrittenFieldNames,
        [Parameter(Mandatory = $true)][bool]$ItemTypeWritten
    )

    foreach ($property in $BeforeData.PSObject.Properties) {
        if ($property.Name -in @("version", "dateModified") -or
            $property.Name -in $WrittenFieldNames -or
            ($ItemTypeWritten -and $property.Name -eq "itemType")) {
            continue
        }
        $afterProperty = $AfterData.PSObject.Properties[$property.Name]
        if ($null -eq $afterProperty -or
            -not (Test-DeepValueEqual -Left $property.Value -Right $afterProperty.Value)) {
            throw "Metadata write changed source-absent field '$($property.Name)'."
        }
    }
}

function Test-ZoteroStringSetEqual {
    param([AllowNull()][object[]]$Left, [AllowNull()][object[]]$Right)

    $normalize = {
        param($Values)
        @(
            @($Values) | ForEach-Object {
                if ($null -eq $_) { return }
                $tag = Get-OptionalPropertyValue -Object $_ -Name "tag"
                $type = Get-OptionalPropertyValue -Object $_ -Name "type"
                if ($null -eq $tag) { $tag = [string]$_ }
                if ($null -eq $type) { $type = 0 }
                "$([string]$tag)`u{001f}$([int]$type)"
            } | Sort-Object -Unique
        )
    }
    Test-DeepValueEqual -Left (& $normalize $Left) -Right (& $normalize $Right)
}

function Test-ConsolidationInboundRelationApplied {
    param(
        [Parameter(Mandatory = $true)][object]$LiveItems,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$RelationWrites
    )

    foreach ($rewrite in $RelationWrites) {
        $item = Get-RequiredPropertyValue -Object $LiveItems -Name ([string]$rewrite.sourceKey)
        $data = Get-RequiredPropertyValue -Object $item -Name "data"
        $relations = Get-RequiredPropertyValue -Object $data -Name "relations"
        $values = @(
            Get-OptionalPropertyValue -Object $relations -Name ([string]$rewrite.predicate)
        )
        if ([string]$rewrite.oldTargetKey -cin $values -or
            [string]$rewrite.newTargetKey -cnotin $values) {
            return $false
        }
    }
    $true
}

function Invoke-DefaultZoteroMcp {
    param([Parameter(Mandatory = $true)][object]$Arguments)

    $helperPath = Join-Path $PSScriptRoot "invoke-llm-for-zotero-mcp.ps1"
    $responseJson = & $helperPath `
        -ToolName "zotero_script" `
        -ArgumentsJson ($Arguments | ConvertTo-Json -Depth 30 -Compress)
    $responseJson | ConvertFrom-Json -Depth 100
}

function Invoke-ZoteroMetadataWrite {
    param(
        [Parameter(Mandatory = $true)][object]$WriteRequest,
        [Parameter(Mandatory = $true)][object]$BeforeLiveItem,
        [Parameter(Mandatory = $true)][scriptblock]$ReadAdapter,
        [scriptblock]$McpAdapter
    )

    if ($null -eq $McpAdapter) {
        $McpAdapter = { param($Arguments) Invoke-DefaultZoteroMcp -Arguments $Arguments }
    }
    $payload = [pscustomobject][ordered]@{
        parentItemKey = Get-RequiredPropertyValue -Object $WriteRequest -Name "parentItemKey"
        expectedVersion = Get-RequiredPropertyValue -Object $WriteRequest -Name "expectedVersion"
        fields = Get-RequiredPropertyValue -Object $WriteRequest -Name "fields"
        itemType = Get-OptionalPropertyValue -Object $WriteRequest -Name "itemType"
    }
    $payloadBase64 = ConvertTo-WriterBase64Json -Value $payload
    $script = @"
const bytes = Uint8Array.from(atob("$payloadBase64"), c => c.charCodeAt(0));
const request = JSON.parse(new TextDecoder().decode(bytes));
const item = await Zotero.Items.getByLibraryAndKeyAsync(env.libraryID, request.parentItemKey);
if (!item || !item.isRegularItem()) {
  throw new Error("Parent item not found or not regular: " + request.parentItemKey);
}
if (item.version !== request.expectedVersion) {
  env.log(JSON.stringify({status:"version_conflict", actualVersion:item.version}));
} else {
  let targetTypeID = item.itemTypeID;
  if (request.itemType) {
    targetTypeID = Zotero.ItemTypes.getID(request.itemType);
    if (!targetTypeID) throw new Error("Unknown item type: " + request.itemType);
    if (item.itemTypeID !== targetTypeID) {
      for (const fieldID of item.getUsedFields()) {
        const fieldName = Zotero.ItemFields.getName(fieldID);
        if (!(fieldName in request.fields) &&
            !Zotero.ItemFields.isValidForType(fieldID, targetTypeID)) {
          throw new Error("Item type change would drop source-absent field: " + fieldName);
        }
      }
    }
  }
  for (const field of Object.keys(request.fields)) {
    if (field === "creators") continue;
    const fieldID = Zotero.ItemFields.getID(field);
    if (!fieldID || !Zotero.ItemFields.isValidForType(fieldID, targetTypeID)) {
      throw new Error("Field is invalid for target item type: " + field);
    }
  }
  env.snapshot(item);
  if (item.itemTypeID !== targetTypeID) item.setType(targetTypeID);
  const creators = request.fields.creators;
  for (const [field, value] of Object.entries(request.fields)) {
    if (field === "creators") continue;
    item.setField(field, value);
  }
  if (creators) item.setCreators(creators);
  await item.saveTx();
  env.log(JSON.stringify({status:"written", version:item.version}));
}
"@
    $mcpResponse = & $McpAdapter ([pscustomobject][ordered]@{
        mode = "write"
        script = $script
        description = "Complete exact-match bibliographic metadata with optimistic versioning"
    })
    $business = Get-McpBusinessResult -Response $mcpResponse
    $parentKey = [string](Get-RequiredPropertyValue -Object $WriteRequest -Name "parentItemKey")
    $afterLiveItem = & $ReadAdapter $parentKey
    $actualVersion = Get-RequiredPropertyValue -Object $afterLiveItem -Name "version"
    if ([string]$business.status -eq "version_conflict") {
        $conflictVersion = Get-RequiredPropertyValue -Object $business -Name "actualVersion"
        if ([long]$conflictVersion -ne [long]$actualVersion) {
            throw "Version-conflict verification disagreed with the live Zotero reread."
        }
        return [pscustomobject][ordered]@{
            status = "version_conflict"
            actualVersion = $conflictVersion
        }
    }
    if ([long]$actualVersion -ne [long](Get-RequiredPropertyValue -Object $business -Name "version")) {
        throw "Post-write verification found a different Zotero version than the MCP write result."
    }

    $beforeData = Get-RequiredPropertyValue -Object $BeforeLiveItem -Name "data"
    $afterData = Get-RequiredPropertyValue -Object $afterLiveItem -Name "data"
    $writeFields = Get-RequiredPropertyValue -Object $WriteRequest -Name "fields"
    $writtenNames = @($writeFields.PSObject.Properties.Name)
    $itemTypeWritten = $WriteRequest.PSObject.Properties.Name -contains "itemType"
    foreach ($name in $writtenNames) {
        if (-not (Test-DeepValueEqual `
                -Left (Get-OptionalPropertyValue -Object $writeFields -Name $name) `
                -Right (Get-OptionalPropertyValue -Object $afterData -Name $name))) {
            throw "Post-write verification failed for field '$name'."
        }
    }
    if ($itemTypeWritten -and
        [string](Get-OptionalPropertyValue -Object $afterData -Name "itemType") -cne
            [string](Get-OptionalPropertyValue -Object $WriteRequest -Name "itemType")) {
        throw "Post-write verification failed for itemType."
    }
    Assert-WriterFieldsPreserved `
        -BeforeData $beforeData `
        -AfterData $afterData `
        -WrittenFieldNames $writtenNames `
        -ItemTypeWritten $itemTypeWritten

    [pscustomobject][ordered]@{
        status = "written"
        version = $actualVersion
        fields = $afterData
        itemType = [string](Get-RequiredPropertyValue -Object $afterData -Name "itemType")
    }
}

function Invoke-ZoteroConsolidationWrite {
    param(
        [Parameter(Mandatory = $true)][object]$Decision,
        [Parameter(Mandatory = $true)][scriptblock]$ReadAdapter,
        [scriptblock]$McpAdapter
    )

    if ([string](Get-RequiredPropertyValue -Object $Decision -Name "status") -cne "eligible") {
        throw "Only an eligible duplicate consolidation decision can be written."
    }
    if ($null -eq $McpAdapter) {
        $McpAdapter = { param($Arguments) Invoke-DefaultZoteroMcp -Arguments $Arguments }
    }
    $parentWrite = Get-RequiredPropertyValue -Object $Decision -Name "parentWriteRequest"
    $attachmentWrite = Get-OptionalPropertyValue -Object $Decision -Name "attachmentWriteRequest"
    $relationWrites = @(
        Get-OptionalPropertyValue -Object $Decision -Name "inboundRelationWrites"
    )
    $versionEntries = [Collections.Generic.List[object]]::new()
    $versionEntries.Add([pscustomobject]@{
        key = [string]$parentWrite.parentItemKey
        version = [long]$parentWrite.expectedVersion
    })
    if ($null -ne $attachmentWrite) {
        $versionEntries.Add([pscustomobject]@{
            key = [string]$attachmentWrite.attachmentKey
            version = [long]$attachmentWrite.expectedVersion
        })
    }
    foreach ($rewrite in $relationWrites) {
        $versionEntries.Add([pscustomobject]@{
            key = [string]$rewrite.sourceKey
            version = [long]$rewrite.expectedVersion
        })
    }
    $versionsByKey = [ordered]@{}
    foreach ($entry in $versionEntries) {
        if ($versionsByKey.Contains($entry.key) -and
            [long]$versionsByKey[$entry.key] -ne [long]$entry.version) {
            throw "Consolidation decision contains conflicting expected versions for '$($entry.key)'."
        }
        $versionsByKey[$entry.key] = [long]$entry.version
    }
    $expectedVersions = @(
        foreach ($key in @($versionsByKey.Keys | Sort-Object)) {
            [pscustomobject]@{ key = $key; version = $versionsByKey[$key] }
        }
    )
    $payload = [pscustomobject][ordered]@{
        retainedParentKey = [string]$parentWrite.parentItemKey
        expectedVersions = $expectedVersions
        tags = @($parentWrite.tags)
        collections = @($parentWrite.collections)
        relations = $parentWrite.relations
        attachment = $attachmentWrite
        inboundRelationWrites = $relationWrites
    }
    $beforeRead = [ordered]@{}
    foreach ($entry in $payload.expectedVersions) {
        $beforeRead[$entry.key] = & $ReadAdapter $entry.key
    }
    $parentBeforeData = Get-RequiredPropertyValue `
        -Object $beforeRead[[string]$parentWrite.parentItemKey] `
        -Name "data"
    $alreadyApplied = $true
    foreach ($property in @("tags", "collections", "relations")) {
        $left = Get-RequiredPropertyValue -Object $parentWrite -Name $property
        $right = Get-RequiredPropertyValue -Object $parentBeforeData -Name $property
        $equal = if ($property -in @("tags", "collections")) {
            Test-ZoteroStringSetEqual -Left @($left) -Right @($right)
        }
        else { Test-DeepValueEqual -Left $left -Right $right }
        if (-not $equal) {
            $alreadyApplied = $false
        }
    }
    if ($null -ne $attachmentWrite) {
        $attachmentBefore = $beforeRead[[string]$attachmentWrite.attachmentKey]
        if ([string]$attachmentBefore.data.parentItem -cne [string]$attachmentWrite.parentItemKey) {
            $alreadyApplied = $false
        }
    }
    if (-not (Test-ConsolidationInboundRelationApplied `
            -LiveItems ([pscustomobject]$beforeRead) `
            -RelationWrites $relationWrites)) {
        $alreadyApplied = $false
    }
    if ($alreadyApplied) {
        return [pscustomobject][ordered]@{
            status = "already_applied"
            retainedParentKey = [string]$parentWrite.parentItemKey
            retainedAttachmentKey = [string]$Decision.retainedAttachment.key
            liveItems = [pscustomobject]$beforeRead
        }
    }
    $versionDrift = @(
        $payload.expectedVersions | Where-Object {
            [long]$beforeRead[$_.key].version -ne [long]$_.version
        }
    )
    if ($versionDrift.Count -gt 0) {
        return [pscustomobject][ordered]@{
            status = "version_conflict"
            key = [string]$versionDrift[0].key
            actualVersion = [long]$beforeRead[$versionDrift[0].key].version
        }
    }
    $payloadBase64 = ConvertTo-WriterBase64Json -Value $payload
    $script = @"
const bytes = Uint8Array.from(atob("$payloadBase64"), c => c.charCodeAt(0));
const request = JSON.parse(new TextDecoder().decode(bytes));
const items = new Map();
const conflicts = [];
for (const expected of request.expectedVersions) {
  const item = await Zotero.Items.getByLibraryAndKeyAsync(env.libraryID, expected.key);
  if (!item) throw new Error("Consolidation item not found: " + expected.key);
  items.set(expected.key, item);
  if (item.version !== expected.version) {
    conflicts.push({key:expected.key, expectedVersion:expected.version, actualVersion:item.version});
  }
}
if (conflicts.length) {
  env.log(JSON.stringify({status:"version_conflict", key:conflicts[0].key, actualVersion:conflicts[0].actualVersion}));
} else {
  await Zotero.DB.executeTransaction(async () => {
    for (const item of items.values()) env.snapshot(item);
    const parent = items.get(request.retainedParentKey);
    parent.setTags(request.tags.map(tag =>
      typeof tag === "string" ? {tag, type:0} : {tag:tag.tag, type:tag.type ?? 0}
    ));
    parent.setCollections(request.collections);
    parent.setRelations(request.relations);
    await parent.save();
    if (request.attachment) {
      const attachment = items.get(request.attachment.attachmentKey);
      attachment.parentItemID = parent.id;
      await attachment.save();
    }
    for (const rewrite of request.inboundRelationWrites) {
      const source = items.get(rewrite.sourceKey);
      const relations = source.getRelations();
      const values = (relations[rewrite.predicate] || []).map(value =>
        value === rewrite.oldTargetKey ? rewrite.newTargetKey : value
      );
      source.setRelations({...relations, [rewrite.predicate]: [...new Set(values)]});
      await source.save();
    }
  });
  env.log(JSON.stringify({status:"written", version:items.get(request.retainedParentKey).version}));
}
"@
    $mcpResponse = & $McpAdapter ([pscustomobject][ordered]@{
        mode = "write"
        script = $script
        description = "Consolidate strict duplicate user state with optimistic versioning"
    })
    $business = Get-McpBusinessResult -Response $mcpResponse
    $reread = [ordered]@{}
    foreach ($entry in $payload.expectedVersions) {
        $reread[$entry.key] = & $ReadAdapter $entry.key
    }
    if ([string]$business.status -eq "version_conflict") {
        $conflictKey = [string](Get-OptionalPropertyValue -Object $business -Name "key")
        $actualVersion = [long](Get-RequiredPropertyValue -Object $business -Name "actualVersion")
        if ([string]::IsNullOrWhiteSpace($conflictKey)) {
            $conflictKey = @(
                $payload.expectedVersions |
                    Where-Object { [long]$reread[$_.key].version -ne [long]$_.version }
            )[0].key
        }
        if ([long]$reread[$conflictKey].version -ne $actualVersion) {
            throw "Consolidation version-conflict proof disagreed with the live reread."
        }
        return [pscustomobject][ordered]@{
            status = "version_conflict"
            key = $conflictKey
            actualVersion = $actualVersion
        }
    }
    $parentAfter = $reread[[string]$parentWrite.parentItemKey]
    $parentData = Get-RequiredPropertyValue -Object $parentAfter -Name "data"
    foreach ($property in @("tags", "collections", "relations")) {
        $left = Get-RequiredPropertyValue -Object $parentWrite -Name $property
        $right = Get-RequiredPropertyValue -Object $parentData -Name $property
        $equal = if ($property -in @("tags", "collections")) {
            Test-ZoteroStringSetEqual -Left @($left) -Right @($right)
        }
        else { Test-DeepValueEqual -Left $left -Right $right }
        if (-not $equal) {
            throw "Post-consolidation verification failed for retained parent '$property'."
        }
    }
    if ($null -ne $attachmentWrite) {
        $attachmentAfter = $reread[[string]$attachmentWrite.attachmentKey]
        if ([string](Get-RequiredPropertyValue -Object $attachmentAfter.data -Name "parentItem") -cne
            [string]$attachmentWrite.parentItemKey) {
            throw "Post-consolidation attachment ownership verification failed."
        }
    }
    if (-not (Test-ConsolidationInboundRelationApplied `
            -LiveItems ([pscustomobject]$reread) `
            -RelationWrites $relationWrites)) {
        throw "Post-consolidation inbound relation verification failed."
    }
    [pscustomobject][ordered]@{
        status = "written"
        retainedParentKey = [string]$parentWrite.parentItemKey
        retainedAttachmentKey = [string](Get-RequiredPropertyValue -Object $Decision -Name "retainedAttachment").key
        liveItems = [pscustomobject]$reread
    }
}

Export-ModuleMember -Function `
    Invoke-ZoteroMetadataWrite, `
    Invoke-ZoteroConsolidationWrite
