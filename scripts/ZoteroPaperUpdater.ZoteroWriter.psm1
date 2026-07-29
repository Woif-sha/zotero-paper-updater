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

Export-ModuleMember -Function Invoke-ZoteroMetadataWrite
