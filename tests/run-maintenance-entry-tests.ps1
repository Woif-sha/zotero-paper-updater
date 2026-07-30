[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$adapterPath = Join-Path $PSScriptRoot "fixtures\FakeMaintenanceAdapter.psm1"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("zotero-maintenance-entry-test-" + [guid]::NewGuid().ToString("N"))
$harnessModulePath = Join-Path $PSScriptRoot "TestMaintenanceHarness.psm1"
Import-Module -Name $harnessModulePath -Force
$entryPath = New-MaintenanceTestHarness `
    -RepoRoot $repoRoot `
    -TempRoot $tempRoot `
    -AdapterPath $adapterPath
$paperRoot = Join-Path $tempRoot "papers"
$zoteroDataDir = Join-Path $tempRoot "ZoteroData"
$passed = 0

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
    $script:passed++
}

function Invoke-MaintenanceEntry {
    param(
        [string[]]$Arguments,
        [string]$Scenario = "unchanged",
        [string]$ScriptPath = $entryPath
    )

    $previousScenario = $env:ZPU_FAKE_SCENARIO
    $process = $null
    $env:ZPU_FAKE_SCENARIO = $Scenario
    try {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in @("-NoProfile", "-File", $ScriptPath) + $Arguments) {
            $startInfo.ArgumentList.Add($argument)
        }

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw "Failed to start maintenance entry process."
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "Maintenance entry process exceeded the 60-second test timeout."
        }
        $exitCode = $process.ExitCode
        $stdout = $stdoutTask.GetAwaiter().GetResult().Trim()
        $stderr = $stderrTask.GetAwaiter().GetResult().Trim()
    }
    finally {
        $env:ZPU_FAKE_SCENARIO = $previousScenario
        if ($null -ne $process) {
            $process.Dispose()
        }
    }

    [pscustomobject]@{
        exitCode = $exitCode
        stdout = $stdout
        stderr = $stderr
        json = $stdout | ConvertFrom-Json
    }
}

function Add-FakeManagedPaper {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AttachmentKey,

        [Parameter(Mandatory = $true)]
        [string]$LocalName
    )

    $bytes = [System.Text.Encoding]::ASCII.GetBytes("%PDF-$AttachmentKey")
    $storageDirectory = Join-Path $zoteroDataDir (Join-Path "storage" $AttachmentKey)
    $localPath = Join-Path $paperRoot $LocalName
    [System.IO.Directory]::CreateDirectory($storageDirectory) | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $storageDirectory "$AttachmentKey.pdf"), $bytes)
    [System.IO.File]::WriteAllBytes($localPath, $bytes)
    [pscustomobject]@{
        storageDirectory = $storageDirectory
        localPath = $localPath
    }
}

function Remove-FakeManagedPaper {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Removes only the temporary fixture paths created by this test."
    )]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Fixture
    )

    Remove-Item -LiteralPath $Fixture.localPath -Force
    Remove-Item -LiteralPath $Fixture.storageDirectory -Recurse -Force
}

try {
    [System.IO.Directory]::CreateDirectory($paperRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($zoteroDataDir) | Out-Null
    $attachment1Storage = Join-Path $zoteroDataDir "storage\ABCDEFGH"
    [System.IO.Directory]::CreateDirectory($attachment1Storage) | Out-Null
    $attachment1Bytes = [System.Text.Encoding]::ASCII.GetBytes("%PDF-fake-attachment-1")
    [System.IO.File]::WriteAllBytes((Join-Path $attachment1Storage "paper.pdf"), $attachment1Bytes)
    [System.IO.File]::WriteAllBytes((Join-Path $paperRoot "paper.pdf"), $attachment1Bytes)

    $commonArguments = @(
        "-PaperRoot", $paperRoot,
        "-ZoteroDataDir", $zoteroDataDir
    )

    $all = Invoke-MaintenanceEntry -Arguments $commonArguments
    Assert-True -Condition ($all.exitCode -eq 0) -Message "unchanged all-library maintenance should exit 0"
    Assert-True -Condition ($all.json.schemaVersion -eq 1) -Message "result should use schema version 1"
    Assert-True -Condition ($all.json.scope.mode -eq "all") -Message "no selector should use all-library scope"
    Assert-True -Condition (-not $all.json.changed) -Message "successful no-op should report changed=false"
    Assert-True -Condition ($all.json.status -eq "succeeded") -Message "successful no-op should report succeeded"
    Assert-True -Condition ([string]::IsNullOrEmpty($all.stderr)) -Message "successful diagnostics should not pollute stderr"
    Assert-True -Condition ($all.json.summary.targetCount -eq 1) -Message "summary should count resolved targets"
    Assert-True -Condition ($all.json.results[0].status -eq "succeeded") -Message "target result should carry a stable status"
    Assert-True -Condition ($all.json.results[0].PSObject.Properties.Name -contains "actions") -Message "target result should always include actions"
    Assert-True -Condition ($all.json.results[0].PSObject.Properties.Name -contains "issues") -Message "target result should always include issues"

    $attachment9Storage = Join-Path $zoteroDataDir "storage\JKLMNPQR"
    [System.IO.Directory]::CreateDirectory($attachment9Storage) | Out-Null
    $attachment9Bytes = [System.Text.Encoding]::ASCII.GetBytes("%PDF-fake-attachment-9")
    [System.IO.File]::WriteAllBytes((Join-Path $attachment9Storage "paper-9.pdf"), $attachment9Bytes)
    $attachment9Local = Join-Path $paperRoot "managed-paper.pdf"
    [System.IO.File]::WriteAllBytes($attachment9Local, $attachment9Bytes)
    $byItem = Invoke-MaintenanceEntry -Arguments ($commonArguments + @("-ItemKey", "PARENT9"))
    Assert-True -Condition ($byItem.json.scope.mode -eq "itemKey") -Message "ItemKey should select item scope"
    Assert-True -Condition ($byItem.json.scope.selector -eq "PARENT9") -Message "ItemKey scope should preserve the selector"
    Assert-True -Condition ($byItem.json.results[0].target.parentItemKey -eq "PARENT9") -Message "fake adapter should receive item scope"
    Assert-True -Condition ($byItem.json.results[0].target.attachmentKey -eq "JKLMNPQR") -Message "a parent key should resolve through its live PDF attachment relation"

    $byAttachment = Invoke-MaintenanceEntry -Arguments ($commonArguments + @("-ItemKey", "JKLMNPQR"))
    Assert-True -Condition ($byAttachment.exitCode -eq 0) -Message "an attachment key should resolve successfully"
    Assert-True -Condition ($byAttachment.json.results[0].target.parentItemKey -eq "PARENT9") -Message "an attachment key should resolve through its live parent relation"
    Assert-True -Condition ($byAttachment.json.results[0].target.attachmentKey -eq "JKLMNPQR") -Message "an attachment key should remain the selected attachment"
    Remove-Item -LiteralPath $attachment9Local -Force
    Remove-Item -LiteralPath $attachment9Storage -Recurse -Force

    $paperPath = Join-Path $paperRoot "paper.pdf"
    $byPath = Invoke-MaintenanceEntry -Arguments ($commonArguments + @("-Path", $paperPath))
    Assert-True -Condition ($byPath.json.scope.mode -eq "path") -Message "Path should select path scope"
    Assert-True -Condition ($byPath.json.scope.selector -eq $paperPath) -Message "Path scope should preserve the selector"
    Assert-True -Condition ($byPath.json.results[0].target.attachmentKey -eq "ABCDEFGH") -Message "Path should resolve to the unique storage PDF with the same SHA-256"

    $duplicateLocalPath = Join-Path $paperRoot "paper-copy.pdf"
    [System.IO.File]::WriteAllBytes($duplicateLocalPath, $attachment1Bytes)
    $ambiguousLocalByPath = Invoke-MaintenanceEntry `
        -Arguments ($commonArguments + @("-Path", $paperPath)) `
        -Scenario "partial"
    Assert-True -Condition ($ambiguousLocalByPath.exitCode -eq 2) -Message "a path sharing its SHA-256 with another managed local PDF should be partial"
    Assert-True -Condition ($ambiguousLocalByPath.json.summary.targetCount -eq 1) -Message "an ambiguous local path should return one blocked target"
    Assert-True -Condition ($ambiguousLocalByPath.json.results[0].issues[0].code -eq "association_ambiguous") -Message "non-unique local SHA-256 mappings should be ambiguous"
    Assert-True -Condition ($ambiguousLocalByPath.json.results[0].issues[0].message -match "exactly one managed local PDF") -Message "local hash ambiguity should be detected before maintenance"
    Assert-True -Condition ($ambiguousLocalByPath.json.summary.actionCount -eq 0) -Message "an ambiguous local path must not invoke maintenance"
    Remove-Item -LiteralPath $duplicateLocalPath -Force

    $textPath = Join-Path $paperRoot "paper.txt"
    [System.IO.File]::WriteAllBytes($textPath, $attachment1Bytes)
    $textSelection = Invoke-MaintenanceEntry -Arguments ($commonArguments + @("-Path", $textPath))
    Assert-True -Condition ($textSelection.exitCode -eq 2) -Message "a non-PDF path should be rejected even when its bytes match storage"
    Assert-True -Condition ($textSelection.json.results[0].issues[0].code -eq "association_not_found") -Message "a non-PDF selector must not establish paper identity"
    Assert-True -Condition ($textSelection.json.summary.actionCount -eq 0) -Message "a non-PDF selector must not trigger maintenance"
    Remove-Item -LiteralPath $textPath -Force

    $junctionTarget = Join-Path $tempRoot "junction-target"
    $junctionPath = Join-Path $paperRoot "linked-directory"
    [System.IO.Directory]::CreateDirectory($junctionTarget) | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $junctionTarget "linked.pdf"), $attachment1Bytes)
    $null = New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget
    $junctionSelection = Invoke-MaintenanceEntry `
        -Arguments ($commonArguments + @("-Path", (Join-Path $junctionPath "linked.pdf")))
    Assert-True -Condition ($junctionSelection.exitCode -eq 2) -Message "a selector path through a junction should be rejected"
    Assert-True -Condition ($junctionSelection.json.results[0].issues[0].code -eq "path_reparse_point") -Message "a selector junction should be reported explicitly"
    Remove-Item -LiteralPath $junctionPath -Force
    Remove-Item -LiteralPath $junctionTarget -Recurse -Force

    $paperRootTarget = Join-Path $tempRoot "paper-root-target"
    $paperRootJunction = Join-Path $tempRoot "paper-root-junction"
    [System.IO.Directory]::CreateDirectory($paperRootTarget) | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $paperRootTarget "paper.pdf"), $attachment1Bytes)
    $null = New-Item -ItemType Junction -Path $paperRootJunction -Target $paperRootTarget
    $junctionRootArguments = @(
        "-PaperRoot", $paperRootJunction,
        "-ZoteroDataDir", $zoteroDataDir
    )
    $junctionRoot = Invoke-MaintenanceEntry -Arguments $junctionRootArguments
    Assert-True -Condition ($junctionRoot.exitCode -eq 2) -Message "a PaperRoot junction should reject all-library resolution"
    Assert-True -Condition ($junctionRoot.json.results[0].issues[0].code -eq "path_reparse_point") -Message "a PaperRoot junction should be reported explicitly"
    Remove-Item -LiteralPath $paperRootJunction -Force
    Remove-Item -LiteralPath $paperRootTarget -Recurse -Force

    Remove-Item -LiteralPath $attachment1Storage -Recurse -Force
    $storageJunctionTarget = Join-Path $tempRoot "storage-junction-target"
    [System.IO.Directory]::CreateDirectory($storageJunctionTarget) | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $storageJunctionTarget "paper.pdf"), $attachment1Bytes)
    $null = New-Item -ItemType Junction -Path $attachment1Storage -Target $storageJunctionTarget
    $storageJunction = Invoke-MaintenanceEntry -Arguments ($commonArguments + @("-ItemKey", "PARENT1"))
    Assert-True -Condition ($storageJunction.exitCode -eq 2) -Message "a storage path through a junction should freeze the target"
    Assert-True -Condition ($storageJunction.json.results[0].issues[0].code -eq "path_reparse_point") -Message "a storage junction should be reported explicitly"
    Remove-Item -LiteralPath $attachment1Storage -Force
    Remove-Item -LiteralPath $storageJunctionTarget -Recurse -Force
    [System.IO.Directory]::CreateDirectory($attachment1Storage) | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $attachment1Storage "paper.pdf"), $attachment1Bytes)

    $unmatchedPath = Join-Path $paperRoot "unmatched.pdf"
    [System.IO.File]::WriteAllBytes($unmatchedPath, [System.Text.Encoding]::ASCII.GetBytes("%PDF-not-in-zotero"))
    $unmatchedByPath = Invoke-MaintenanceEntry -Arguments ($commonArguments + @("-Path", $unmatchedPath))
    Assert-True -Condition ($unmatchedByPath.exitCode -eq 2) -Message "a path without byte-identical Zotero storage should be partial"
    Assert-True -Condition ($unmatchedByPath.json.results[0].issues[0].code -eq "association_not_found") -Message "Path must not guess identity from its filename"
    Remove-Item -LiteralPath $unmatchedPath -Force

    $ambiguousPath = Join-Path $paperRoot "ambiguous.pdf"
    $ambiguousBytes = [System.Text.Encoding]::ASCII.GetBytes("%PDF-shared-by-two-attachments")
    [System.IO.File]::WriteAllBytes($ambiguousPath, $ambiguousBytes)
    foreach ($attachmentKey in @("STUVWXYZ", "23456789")) {
        $storageDirectory = Join-Path $zoteroDataDir (Join-Path "storage" $attachmentKey)
        [System.IO.Directory]::CreateDirectory($storageDirectory) | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $storageDirectory "$attachmentKey.pdf"), $ambiguousBytes)
    }
    $ambiguousByPath = Invoke-MaintenanceEntry `
        -Arguments ($commonArguments + @("-Path", $ambiguousPath)) `
        -Scenario "ambiguous-path"
    Assert-True -Condition ($ambiguousByPath.exitCode -eq 2) -Message "a path matching multiple live attachments should be partial"
    Assert-True -Condition ($ambiguousByPath.json.results[0].issues[0].code -eq "association_ambiguous") -Message "non-unique SHA-256 mappings should use a distinct issue code"
    Assert-True -Condition ($ambiguousByPath.json.summary.actionCount -eq 0) -Message "an ambiguous path must not trigger maintenance actions"
    Remove-Item -LiteralPath $ambiguousPath -Force
    foreach ($attachmentKey in @("STUVWXYZ", "23456789")) {
        Remove-Item -LiteralPath (Join-Path $zoteroDataDir (Join-Path "storage" $attachmentKey)) -Recurse -Force
    }

    Remove-Item -LiteralPath $paperPath -Force
    $missingLocal = Invoke-MaintenanceEntry -Arguments ($commonArguments + @("-ItemKey", "PARENT1"))
    Assert-True -Condition ($missingLocal.exitCode -eq 2) -Message "a Zotero target without a local byte match should be partial"
    Assert-True -Condition ($missingLocal.json.results[0].issues[0].code -eq "missing_local_copy") -Message "a missing local copy should use its own issue code"
    Assert-True -Condition ($missingLocal.json.summary.actionCount -eq 0) -Message "a missing local copy must not trigger repair or deletion"

    [System.IO.File]::WriteAllBytes($paperPath, [System.Text.Encoding]::ASCII.GetBytes("%PDF-conflicting-local"))
    $hashConflict = Invoke-MaintenanceEntry -Arguments ($commonArguments + @("-ItemKey", "PARENT1"))
    Assert-True -Condition ($hashConflict.exitCode -eq 2) -Message "different bytes at the canonical path should be partial"
    Assert-True -Condition ($hashConflict.json.results[0].issues[0].code -eq "hash_conflict") -Message "different canonical-path bytes should use the hash-conflict issue code"
    Assert-True -Condition ($hashConflict.json.summary.actionCount -eq 0) -Message "a hash conflict must not trigger repair or deletion"
    [System.IO.File]::WriteAllBytes($paperPath, $attachment1Bytes)

    $unknownItem = Invoke-MaintenanceEntry -Arguments ($commonArguments + @("-ItemKey", "UNKNOWN"))
    Assert-True -Condition ($unknownItem.exitCode -eq 2) -Message "an unknown ItemKey should freeze only that target"
    Assert-True -Condition ($unknownItem.json.results[0].issues[0].code -eq "association_not_found") -Message "an unknown ItemKey should report a missing live association"

    $nonPdfAttachment = Invoke-MaintenanceEntry `
        -Arguments ($commonArguments + @("-ItemKey", "Z2Y3X4W5")) `
        -Scenario "non-pdf-attachment"
    Assert-True -Condition ($nonPdfAttachment.exitCode -eq 2) -Message "a non-PDF attachment selector should be rejected"
    Assert-True -Condition ($nonPdfAttachment.json.results[0].issues[0].code -eq "association_not_found") -Message "a non-PDF attachment is not a paper target"

    $orphanAttachment = Invoke-MaintenanceEntry `
        -Arguments ($commonArguments + @("-ItemKey", "Z3X5V7T9")) `
        -Scenario "orphan-attachment"
    Assert-True -Condition ($orphanAttachment.exitCode -eq 2) -Message "an attachment without a live parent should freeze only that target"
    Assert-True -Condition ($orphanAttachment.json.results[0].issues[0].code -eq "association_not_found") -Message "an orphan attachment should not establish paper identity"

    $unsafeStorageDirectory = Join-Path $zoteroDataDir "BAD"
    [System.IO.Directory]::CreateDirectory($unsafeStorageDirectory) | Out-Null
    $unsafeKeyBytes = [System.Text.Encoding]::ASCII.GetBytes("%PDF-unsafe-key")
    [System.IO.File]::WriteAllBytes((Join-Path $unsafeStorageDirectory "unsafe.pdf"), $unsafeKeyBytes)
    $unsafeKeyLocal = Join-Path $paperRoot "unsafe-key.pdf"
    [System.IO.File]::WriteAllBytes($unsafeKeyLocal, $unsafeKeyBytes)
    $unsafeAttachmentKey = Invoke-MaintenanceEntry `
        -Arguments ($commonArguments + @("-ItemKey", "PARENT-BADKEY")) `
        -Scenario "invalid-attachment-key"
    Assert-True -Condition ($unsafeAttachmentKey.exitCode -eq 2) -Message "an invalid attachment key must be rejected before storage lookup"
    Assert-True -Condition ($unsafeAttachmentKey.json.results[0].issues[0].code -eq "association_ambiguous") -Message "an invalid attachment key should freeze the association"
    Assert-True -Condition ($unsafeAttachmentKey.json.summary.actionCount -eq 0) -Message "an invalid attachment key must not trigger maintenance"
    Remove-Item -LiteralPath $unsafeKeyLocal -Force
    Remove-Item -LiteralPath $unsafeStorageDirectory -Recurse -Force

    $multipleParentPdfs = Invoke-MaintenanceEntry `
        -Arguments ($commonArguments + @("-ItemKey", "PARENT-MULTI")) `
        -Scenario "multiple-parent-pdfs"
    Assert-True -Condition ($multipleParentPdfs.exitCode -eq 2) -Message "a parent with multiple PDF children should be partial"
    Assert-True -Condition ($multipleParentPdfs.json.results[0].issues[0].code -eq "association_ambiguous") -Message "multiple live PDF children should be reported as ambiguous"

    Remove-Item -LiteralPath $paperPath -Force
    $multiFirst = Add-FakeManagedPaper -AttachmentKey "R2T4V6X8" -LocalName "multi-a.pdf"
    $multiSecond = Add-FakeManagedPaper -AttachmentKey "S3U5W7Y9" -LocalName "multi-b.pdf"
    $allMultipleParentPdfs = Invoke-MaintenanceEntry -Arguments $commonArguments -Scenario "multiple-parent-pdfs"
    Assert-True -Condition ($allMultipleParentPdfs.exitCode -eq 2) -Message "all-library mode should freeze a parent with multiple PDF children"
    Assert-True -Condition ($allMultipleParentPdfs.json.summary.targetCount -eq 1) -Message "all-library mode should emit one result for an ambiguous parent"
    Assert-True -Condition ($allMultipleParentPdfs.json.results[0].issues[0].code -eq "association_ambiguous") -Message "the grouped parent should carry one ambiguity issue"
    Assert-True -Condition ($allMultipleParentPdfs.json.summary.actionCount -eq 0) -Message "an ambiguous parent must not be invoked twice"
    Remove-FakeManagedPaper -Fixture $multiFirst
    Remove-FakeManagedPaper -Fixture $multiSecond
    [System.IO.File]::WriteAllBytes($paperPath, $attachment1Bytes)

    $outsidePath = Join-Path $tempRoot "outside.pdf"
    [System.IO.File]::WriteAllBytes($outsidePath, $attachment1Bytes)
    $outsideSelection = Invoke-MaintenanceEntry -Arguments ($commonArguments + @("-Path", $outsidePath))
    Assert-True -Condition ($outsideSelection.exitCode -eq 2) -Message "a selected path outside PaperRoot should be partial"
    Assert-True -Condition ($outsideSelection.json.results[0].issues[0].code -eq "path_outside_paper_root") -Message "the selected path must stay within PaperRoot"
    Remove-Item -LiteralPath $outsidePath -Force

    Remove-Item -LiteralPath $paperPath -Force
    $goodFixture = Add-FakeManagedPaper -AttachmentKey "A3C5E7G9" -LocalName "good-local.pdf"
    $missingStorage = Join-Path $zoteroDataDir "storage\B2D4F6H8"
    [System.IO.Directory]::CreateDirectory($missingStorage) | Out-Null
    [System.IO.File]::WriteAllBytes(
        (Join-Path $missingStorage "B2D4F6H8.pdf"),
        [System.Text.Encoding]::ASCII.GetBytes("%PDF-B2D4F6H8")
    )
    $conflictStorage = Join-Path $zoteroDataDir "storage\J3L5N7Q9"
    [System.IO.Directory]::CreateDirectory($conflictStorage) | Out-Null
    [System.IO.File]::WriteAllBytes(
        (Join-Path $conflictStorage "conflict.pdf"),
        [System.Text.Encoding]::ASCII.GetBytes("%PDF-J3L5N7Q9")
    )
    $conflictLocal = Join-Path $paperRoot "conflict.pdf"
    [System.IO.File]::WriteAllBytes(
        $conflictLocal,
        [System.Text.Encoding]::ASCII.GetBytes("%PDF-different-conflict")
    )
    $allMixed = Invoke-MaintenanceEntry -Arguments $commonArguments -Scenario "all-mixed"
    Assert-True -Condition ($allMixed.exitCode -eq 2) -Message "blocked all-library targets should make the run partial"
    Assert-True -Condition ($allMixed.json.summary.targetCount -eq 3) -Message "all-library mode should enumerate every live paper relation"
    Assert-True -Condition ($allMixed.json.summary.succeededCount -eq 1) -Message "an independent all-library target should continue"
    Assert-True -Condition ($allMixed.json.summary.failedCount -eq 2) -Message "missing and conflicting targets should be frozen independently"
    $allMixedCodes = @($allMixed.json.results.issues.code)
    Assert-True -Condition ($allMixedCodes -contains "missing_local_copy") -Message "all-library mode should report a missing local copy"
    Assert-True -Condition ($allMixedCodes -contains "hash_conflict") -Message "all-library mode should report a hash conflict separately"
    Assert-True -Condition ($allMixed.json.summary.actionCount -eq 0) -Message "resolution issues must not trigger repair or deletion"
    Remove-FakeManagedPaper -Fixture $goodFixture
    Remove-Item -LiteralPath $missingStorage, $conflictStorage -Recurse -Force
    Remove-Item -LiteralPath $conflictLocal -Force
    [System.IO.File]::WriteAllBytes($paperPath, $attachment1Bytes)

    $orphanPath = Join-Path $paperRoot "orphan.pdf"
    [System.IO.File]::WriteAllBytes($orphanPath, [System.Text.Encoding]::ASCII.GetBytes("%PDF-orphan"))
    $allWithOrphan = Invoke-MaintenanceEntry -Arguments $commonArguments
    Assert-True -Condition ($allWithOrphan.exitCode -eq 2) -Message "an orphan managed PDF should make all-library maintenance partial"
    Assert-True -Condition ($allWithOrphan.json.summary.targetCount -eq 2) -Message "all-library mode should enumerate the orphan without hiding the valid target"
    Assert-True -Condition (@($allWithOrphan.json.results.issues.code) -contains "association_not_found") -Message "an orphan managed PDF should not be identified by filename or cache hints"
    Remove-Item -LiteralPath $orphanPath -Force

    $partial = Invoke-MaintenanceEntry -Arguments $commonArguments -Scenario "partial"
    Assert-True -Condition ($partial.exitCode -eq 2) -Message "partial maintenance should exit 2"
    Assert-True -Condition ($partial.json.status -eq "partial") -Message "partial maintenance should report partial"
    Assert-True -Condition $partial.json.changed -Message "actions should make changed=true"
    Assert-True -Condition ($partial.json.summary.actionsByCategory.modified -eq 1) -Message "summary should count action categories"
    Assert-True -Condition ($partial.json.results[0].actions[0].PSObject.Properties.Name.Count -eq 6) -Message "actions should expose the stable six-field contract"
    Assert-True -Condition ($partial.json.results[0].issues[0].PSObject.Properties.Name.Count -eq 5) -Message "issues should expose the stable five-field contract"

    $targetFailure = Invoke-MaintenanceEntry -Arguments $commonArguments -Scenario "target-failure"
    Assert-True -Condition ($targetFailure.exitCode -eq 1) -Message "an unexpected adapter exception should fail the run"
    Assert-True -Condition ($targetFailure.json.status -eq "failed") -Message "an unexpected adapter exception should not be downgraded to partial"
    Assert-True -Condition ($targetFailure.json.issues[0].evidence.Count -ge 1) -Message "unexpected failures should preserve exception evidence"

    Remove-Item -LiteralPath $paperPath -Force
    $blockedFixture = Add-FakeManagedPaper -AttachmentKey "A2B3C4D5" -LocalName "blocked.pdf"
    $continuedFixture = Add-FakeManagedPaper -AttachmentKey "E6F7G8H9" -LocalName "continued.pdf"
    $targetBlocked = Invoke-MaintenanceEntry -Arguments $commonArguments -Scenario "target-blocked"
    Assert-True -Condition ($targetBlocked.exitCode -eq 2) -Message "one blocked target should make the run partial"
    Assert-True -Condition ($targetBlocked.json.summary.targetCount -eq 2) -Message "independent targets should both be processed"
    Assert-True -Condition ($targetBlocked.json.summary.failedCount -eq 1) -Message "blocked target should be counted as failed"
    Assert-True -Condition ($targetBlocked.json.summary.succeededCount -eq 1) -Message "independent target should continue to success"
    Remove-FakeManagedPaper -Fixture $blockedFixture
    Remove-FakeManagedPaper -Fixture $continuedFixture

    $changedFixture = Add-FakeManagedPaper -AttachmentKey "J2K3L4M5" -LocalName "changed.pdf"
    $crashedFixture = Add-FakeManagedPaper -AttachmentKey "N6P7Q8R9" -LocalName "crashed.pdf"
    $progressThenCrash = Invoke-MaintenanceEntry -Arguments $commonArguments -Scenario "progress-then-crash"
    Assert-True -Condition ($progressThenCrash.exitCode -eq 1) -Message "an unexpected later crash should fail the run"
    Assert-True -Condition $progressThenCrash.json.changed -Message "completed actions should survive a later crash"
    Assert-True -Condition ($progressThenCrash.json.summary.targetCount -eq 1) -Message "completed targets should survive a later crash"
    Assert-True -Condition ($progressThenCrash.json.summary.actionCount -eq 1) -Message "completed actions should remain in the summary"
    Assert-True -Condition ($progressThenCrash.json.issues[0].code -eq "maintenance_run_failed") -Message "later crash should remain a run-level failure"
    Remove-FakeManagedPaper -Fixture $changedFixture
    Remove-FakeManagedPaper -Fixture $crashedFixture

    $validFixture = Add-FakeManagedPaper -AttachmentKey "S2T3U4V5" -LocalName "valid.pdf"
    $invalidFixture = Add-FakeManagedPaper -AttachmentKey "W6X7Y8Z9" -LocalName "invalid.pdf"
    $progressThenInvalid = Invoke-MaintenanceEntry -Arguments $commonArguments -Scenario "progress-then-invalid-result"
    Assert-True -Condition ($progressThenInvalid.exitCode -eq 1) -Message "an invalid later record should fail the run"
    Assert-True -Condition $progressThenInvalid.json.changed -Message "completed actions should survive a later contract error"
    Assert-True -Condition ($progressThenInvalid.json.summary.targetCount -eq 1) -Message "completed targets should survive a later contract error"
    Assert-True -Condition ($progressThenInvalid.json.summary.actionCount -eq 1) -Message "completed action summary should survive a later contract error"
    Remove-FakeManagedPaper -Fixture $validFixture
    Remove-FakeManagedPaper -Fixture $invalidFixture
    [System.IO.File]::WriteAllBytes($paperPath, $attachment1Bytes)

    $inconsistent = Invoke-MaintenanceEntry -Arguments $commonArguments -Scenario "inconsistent"
    Assert-True -Condition ($inconsistent.exitCode -eq 1) -Message "an inconsistent adapter result should fail the run"
    Assert-True -Condition ($inconsistent.json.status -eq "failed") -Message "succeeded plus unresolved issues should be rejected"
    Assert-True -Condition ($inconsistent.json.issues[0].message -match "succeeded target") -Message "inconsistent result should explain the violated invariant"

    $invalid = Invoke-MaintenanceEntry -Arguments ($commonArguments + @("-ItemKey", "PARENT9", "-Path", $paperPath))
    Assert-True -Condition ($invalid.exitCode -eq 1) -Message "dual selectors should exit 1"
    Assert-True -Condition ($invalid.json.status -eq "failed") -Message "dual selectors should return failed JSON"
    Assert-True -Condition ($invalid.json.issues[0].code -eq "selectors_mutually_exclusive") -Message "dual selectors should have a stable issue code"
    Assert-True -Condition ($invalid.stdout.StartsWith("{") -and $invalid.stdout.EndsWith("}")) -Message "stdout should contain one JSON document"

    $failed = Invoke-MaintenanceEntry -Arguments $commonArguments -Scenario "run-failure"
    Assert-True -Condition ($failed.exitCode -eq 1) -Message "run-level adapter failure should exit 1"
    Assert-True -Condition ($failed.json.status -eq "failed") -Message "run-level adapter failure should report failed"
    Assert-True -Condition ($failed.json.issues[0].code -eq "maintenance_run_failed") -Message "run-level failure should have a stable issue code"
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($failed.stderr)) -Message "run-level failure diagnostics should be written to stderr"

    $isolatedEntryRoot = Join-Path $tempRoot "isolated-entry"
    [System.IO.Directory]::CreateDirectory($isolatedEntryRoot) | Out-Null
    $isolatedEntryPath = Join-Path $isolatedEntryRoot "maintain-library.ps1"
    [System.IO.File]::Copy($entryPath, $isolatedEntryPath)
    [System.IO.File]::Copy(
        (Join-Path $repoRoot "scripts\ZoteroPaperUpdater.Common.psm1"),
        (Join-Path $isolatedEntryRoot "ZoteroPaperUpdater.Common.psm1")
    )
    $bootstrapFailure = Invoke-MaintenanceEntry -Arguments @() -ScriptPath $isolatedEntryPath
    Assert-True -Condition ($bootstrapFailure.exitCode -eq 1) -Message "missing workflow module should exit 1"
    Assert-True -Condition ($bootstrapFailure.json.status -eq "failed") -Message "missing workflow module should still emit failed JSON"
    Assert-True -Condition ($bootstrapFailure.json.issues[0].code -eq "maintenance_run_failed") -Message "bootstrap failure should preserve the stable run issue code"

    $isolatedWithoutCommonRoot = Join-Path $tempRoot "isolated-without-common"
    [System.IO.Directory]::CreateDirectory($isolatedWithoutCommonRoot) | Out-Null
    $isolatedWithoutCommonPath = Join-Path $isolatedWithoutCommonRoot "maintain-library.ps1"
    [System.IO.File]::Copy($entryPath, $isolatedWithoutCommonPath)
    $commonBootstrapFailure = Invoke-MaintenanceEntry -Arguments @() -ScriptPath $isolatedWithoutCommonPath
    Assert-True -Condition ($commonBootstrapFailure.exitCode -eq 1) -Message "missing common module should exit 1"
    Assert-True -Condition ($commonBootstrapFailure.json.status -eq "failed") -Message "missing common module should still emit failed JSON"
    Assert-True -Condition ($commonBootstrapFailure.json.issues[0].code -eq "maintenance_run_failed") -Message "missing common module should preserve the stable run issue code"

    $unknownArgument = Invoke-MaintenanceEntry -Arguments ($commonArguments + @("-UnknownOption", "value"))
    Assert-True -Condition ($unknownArgument.exitCode -eq 1) -Message "unsupported arguments should exit 1"
    Assert-True -Condition ($unknownArgument.json.issues[0].code -eq "invalid_arguments") -Message "unsupported arguments should return JSON with a stable issue code"

    $missingValue = Invoke-MaintenanceEntry -Arguments @("-ItemKey")
    Assert-True -Condition ($missingValue.exitCode -eq 1) -Message "a known argument without a value should exit 1"
    Assert-True -Condition ($missingValue.json.issues[0].code -eq "invalid_arguments") -Message "a missing argument value should return JSON"

    Write-Output "All $passed maintenance-entry assertions passed."
}
finally {
    $resolvedTempRoot = [System.IO.Path]::GetFullPath($tempRoot)
    $resolvedSystemTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolvedTempRoot.StartsWith($resolvedSystemTemp, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
