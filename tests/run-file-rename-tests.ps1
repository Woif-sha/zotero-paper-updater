[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$adapterPath = Join-Path $PSScriptRoot "fixtures\FakeFileRenameAdapter.psm1"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("zotero-file-rename-test-" + [guid]::NewGuid().ToString("N"))
$harnessModulePath = Join-Path $PSScriptRoot "TestMaintenanceHarness.psm1"
Import-Module -Name $harnessModulePath -Force
$entryPath = New-MaintenanceTestHarness `
    -RepoRoot $repoRoot `
    -TempRoot $tempRoot `
    -AdapterPath $adapterPath
$passed = 0
$scenarioRuns = @{}

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

function Start-FileRenameScenario {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Starts an isolated child process that writes only beneath the per-run test directory."
    )]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Scenario
    )

    $scenarioRoot = Join-Path $tempRoot $Scenario
    $paperRoot = Join-Path $scenarioRoot "papers"
    $zoteroDataDir = Join-Path $scenarioRoot "ZoteroData"
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment["ZPU_FILE_RENAME_SCENARIO"] = $Scenario
    foreach ($argument in @(
        "-NoProfile",
        "-File",
        $entryPath,
        "-PaperRoot",
        $paperRoot,
        "-ZoteroDataDir",
        $zoteroDataDir
    )) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "Failed to start file rename test process."
    }
    $script:scenarioRuns[$Scenario] = [pscustomobject]@{
        process = $process
        stdout = $process.StandardOutput.ReadToEndAsync()
        stderr = $process.StandardError.ReadToEndAsync()
        deadline = [DateTime]::UtcNow.AddSeconds(60)
        paperRoot = $paperRoot
    }
}

function Invoke-FileRenameScenario {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Scenario
    )

    $run = $script:scenarioRuns[$Scenario]
    if ($null -eq $run) {
        throw "File rename scenario '$Scenario' was not scheduled."
    }
    $remaining = [int][Math]::Max(0, ($run.deadline - [DateTime]::UtcNow).TotalMilliseconds)
    if (-not $run.process.HasExited -and
        ($remaining -eq 0 -or -not $run.process.WaitForExit($remaining))) {
        $run.process.Kill($true)
        $run.process.WaitForExit()
        throw "File rename test process exceeded the 60-second timeout."
    }
    $run.process.WaitForExit()
    $exitCode = $run.process.ExitCode
    $stdout = $run.stdout.GetAwaiter().GetResult().Trim()
    $stderr = $run.stderr.GetAwaiter().GetResult().Trim()
    $run.process.Dispose()
    $script:scenarioRuns.Remove($Scenario)
    if ([string]::IsNullOrWhiteSpace($stdout)) {
        throw "File rename scenario '$Scenario' returned no JSON. stderr: $stderr"
    }

    [pscustomobject]@{
        exitCode = $exitCode
        stderr = $stderr
        json = $stdout | ConvertFrom-Json
        paperRoot = $run.paperRoot
    }
}

function Assert-FrozenScenario {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Scenario,

        [Parameter(Mandatory = $true)]
        [string]$IssueCode
    )

    $result = Invoke-FileRenameScenario -Scenario $Scenario
    Assert-True -Condition ($result.exitCode -eq 2) -Message "$Scenario should freeze only its target"
    Assert-True -Condition ($result.json.results[0].status -eq "failed") -Message "$Scenario should fail the unsafe target"
    Assert-True -Condition ($result.json.results[0].issues[0].code -eq $IssueCode) -Message "$Scenario should report $IssueCode"
    Assert-True -Condition (-not $result.json.changed) -Message "$Scenario should not emit an action"
    $result
}

try {
    [System.IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    foreach ($scenario in @(
        "case-only", "case-only-second-move-fails", "hash-conflict",
        "local-ambiguous", "local-one-match", "local-parent-junction",
        "local-path-invalid", "local-path-outside", "missing-continues", "noop",
        "paper-root-junction", "post-move-both-exist", "post-move-content-mismatch",
        "post-move-hash-fails", "post-move-inspection-fails", "post-move-mismatch",
        "post-move-rollback-fails", "post-move-target-hash-mismatch", "pre-move-drift",
        "pre-move-storage-drift", "rename", "storage-ambiguous", "storage-missing",
        "storage-parent-junction", "storage-path-outside", "storage-root-junction",
        "target-conflict", "target-duplicate"
    )) {
        Start-FileRenameScenario -Scenario $scenario
    }

    $renamed = Invoke-FileRenameScenario -Scenario "rename"
    Assert-True -Condition ($renamed.exitCode -eq 0) -Message "a unique SHA-256 match should succeed"
    $renamedAction = $renamed.json.results[0].actions[0]
    $canonicalPath = Join-Path $renamed.paperRoot "Canonical Paper.pdf"
    Assert-True -Condition ($renamedAction.category -eq "renamed") -Message "rename should use the renamed category"
    Assert-True -Condition ($renamedAction.kind -eq "local_pdf_renamed") -Message "rename should have a typed action"
    Assert-True -Condition ($renamedAction.before.path -eq (Join-Path $renamed.paperRoot "download.pdf")) -Message "action should preserve the source path"
    Assert-True -Condition ($renamedAction.after.path -eq $canonicalPath) -Message "storage basename should become the canonical local path"
    Assert-True -Condition ($renamedAction.before.sha256 -eq $renamedAction.after.sha256) -Message "pre/post SHA-256 should prove unchanged content"
    Assert-True -Condition ($renamedAction.before.sha256 -eq "CF5C318101420BBA9F21824FD787D99E21E081E30B1FF3C0F338334783F28F30") -Message "action should report the independently known PDF SHA-256"
    Assert-True -Condition ($renamedAction.evidence -contains "storageSha256=$($renamedAction.before.sha256)") -Message "evidence should name the verified storage SHA-256"
    Assert-True -Condition ($renamedAction.evidence -contains "postRenameSha256=$($renamedAction.after.sha256)") -Message "evidence should name the verified post-rename SHA-256"
    Assert-True -Condition (Test-Path -LiteralPath $canonicalPath -PathType Leaf) -Message "canonical local PDF should exist"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $renamed.paperRoot "download.pdf"))) -Message "old local PDF path should be gone"

    $noOp = Invoke-FileRenameScenario -Scenario "noop"
    Assert-True -Condition ($noOp.exitCode -eq 0) -Message "an already canonical same-hash PDF should succeed"
    Assert-True -Condition (-not $noOp.json.changed) -Message "an already canonical same-hash PDF should be a no-op"
    Assert-True -Condition ($noOp.json.summary.actionCount -eq 0) -Message "a no-op should emit no rename action"

    $caseOnly = Invoke-FileRenameScenario -Scenario "case-only"
    $caseOnlyPath = Join-Path $caseOnly.paperRoot "Canonical Paper.pdf"
    $caseOnlyLeaf = @(
        [System.IO.Directory]::GetFiles($caseOnly.paperRoot) |
            ForEach-Object { [System.IO.Path]::GetFileName($_) }
    )
    Assert-True -Condition ($caseOnly.exitCode -eq 0) -Message "a case-only basename change should succeed"
    Assert-True -Condition ($caseOnly.json.changed) -Message "a case-only basename change should emit a rename action"
    Assert-True -Condition ($caseOnly.json.results[0].actions[0].after.path -ceq $caseOnlyPath) -Message "the action should preserve the exact storage basename"
    Assert-True -Condition ($caseOnly.json.results[0].actions[0].before.sha256 -eq $caseOnly.json.results[0].actions[0].after.sha256) -Message "a case-only rename should preserve SHA-256"
    Assert-True -Condition ($caseOnlyLeaf.Count -eq 1) -Message "a case-only rename must not create a second local PDF"
    Assert-True -Condition ($caseOnlyLeaf[0] -ceq "Canonical Paper.pdf") -Message "the on-disk basename should exactly match storage casing"

    $caseOnlyFailure = Assert-FrozenScenario -Scenario "case-only-second-move-fails" -IssueCode "rename_move_failed"
    $caseOnlyFailureLeaf = @(
        [System.IO.Directory]::GetFiles($caseOnlyFailure.paperRoot) |
            ForEach-Object { [System.IO.Path]::GetFileName($_) }
    )
    Assert-True -Condition ($caseOnlyFailureLeaf.Count -eq 1) -Message "a failed case-only rename must not leave a temporary file or copy"
    Assert-True -Condition ($caseOnlyFailureLeaf[0] -ceq "canonical Paper.pdf") -Message "a failed case-only rename should restore the exact source basename"
    Assert-True -Condition ((Get-FileHash -LiteralPath (Join-Path $caseOnlyFailure.paperRoot $caseOnlyFailureLeaf[0]) -Algorithm SHA256).Hash -eq "CF5C318101420BBA9F21824FD787D99E21E081E30B1FF3C0F338334783F28F30") -Message "a failed case-only rename should restore the original SHA-256"

    $missingContinues = Invoke-FileRenameScenario -Scenario "missing-continues"
    Assert-True -Condition ($missingContinues.exitCode -eq 2) -Message "a missing local copy should make the run partial"
    Assert-True -Condition ($missingContinues.json.summary.targetCount -eq 2) -Message "an independent target should continue"
    Assert-True -Condition ($missingContinues.json.results[0].status -eq "partial") -Message "the missing-copy target should be partial"
    Assert-True -Condition ($missingContinues.json.results[0].issues[0].code -eq "local_pdf_missing") -Message "missing local copy should have a distinct issue code"
    Assert-True -Condition ($missingContinues.json.results[1].actions[0].kind -eq "local_pdf_renamed") -Message "the independent target should still rename"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $missingContinues.paperRoot "Continued Paper.pdf")) -Message "the independent rename should reach disk"

    $oneMatch = Invoke-FileRenameScenario -Scenario "local-one-match"
    Assert-True -Condition ($oneMatch.exitCode -eq 0) -Message "one hash match among unrelated local PDFs should be unique"
    Assert-True -Condition ($oneMatch.json.summary.actionCount -eq 1) -Message "the unique matching local PDF should rename"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $oneMatch.paperRoot "Canonical Paper.pdf")) -Message "the uniquely matching PDF should reach the storage basename"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $oneMatch.paperRoot "unrelated.pdf")) -Message "an unrelated local PDF should remain untouched"

    $null = Assert-FrozenScenario -Scenario "storage-missing" -IssueCode "storage_pdf_missing"
    $null = Assert-FrozenScenario -Scenario "storage-ambiguous" -IssueCode "storage_pdf_ambiguous"
    $null = Assert-FrozenScenario -Scenario "local-ambiguous" -IssueCode "local_pdf_ambiguous"
    $null = Assert-FrozenScenario -Scenario "hash-conflict" -IssueCode "local_storage_hash_conflict"
    $targetConflict = Assert-FrozenScenario -Scenario "target-conflict" -IssueCode "rename_target_conflict"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $targetConflict.paperRoot "download.pdf")) -Message "a conflicting source should remain"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $targetConflict.paperRoot "Canonical Paper.pdf")) -Message "a different-hash target must not be overwritten"
    $null = Assert-FrozenScenario -Scenario "target-duplicate" -IssueCode "rename_target_duplicate"
    $null = Assert-FrozenScenario -Scenario "local-path-outside" -IssueCode "path_outside_allowed_root"
    $invalidPath = Assert-FrozenScenario -Scenario "local-path-invalid" -IssueCode "path_validation_failed"
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($invalidPath.json.results[0].issues[0].message)) -Message "an unknown path failure should retain the original error message"
    Assert-True -Condition ($invalidPath.json.results[0].issues[0].evidence.Count -gt 0) -Message "an unknown path failure should retain path evidence"
    $null = Assert-FrozenScenario -Scenario "storage-path-outside" -IssueCode "path_outside_allowed_root"
    $null = Assert-FrozenScenario -Scenario "paper-root-junction" -IssueCode "path_contains_reparse_point"
    $null = Assert-FrozenScenario -Scenario "storage-root-junction" -IssueCode "path_contains_reparse_point"
    $null = Assert-FrozenScenario -Scenario "local-parent-junction" -IssueCode "path_contains_reparse_point"
    $null = Assert-FrozenScenario -Scenario "storage-parent-junction" -IssueCode "path_contains_reparse_point"
    $preMoveDrift = Assert-FrozenScenario -Scenario "pre-move-drift" -IssueCode "rename_source_drift"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $preMoveDrift.paperRoot "download.pdf")) -Message "pre-move drift should leave the source in place"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $preMoveDrift.paperRoot "Canonical Paper.pdf"))) -Message "pre-move drift should prevent the move"
    $preMoveStorageDrift = Assert-FrozenScenario -Scenario "pre-move-storage-drift" -IssueCode "storage_pdf_drift"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $preMoveStorageDrift.paperRoot "download.pdf")) -Message "storage drift should leave the local source in place"
    $postMoveMismatch = Assert-FrozenScenario -Scenario "post-move-mismatch" -IssueCode "rename_postcondition_failed"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $postMoveMismatch.paperRoot "download.pdf")) -Message "a verified rollback should restore the source path"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $postMoveMismatch.paperRoot "Canonical Paper.pdf"))) -Message "a verified rollback should remove the destination path"
    $postMoveHashFailure = Assert-FrozenScenario -Scenario "post-move-hash-fails" -IssueCode "rename_postcondition_failed"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $postMoveHashFailure.paperRoot "download.pdf")) -Message "a post-rename hash failure should restore the source path"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $postMoveHashFailure.paperRoot "Canonical Paper.pdf"))) -Message "a post-rename hash failure should remove the destination path"
    $contentMismatch = Invoke-FileRenameScenario -Scenario "post-move-content-mismatch"
    Assert-True -Condition ($contentMismatch.exitCode -eq 2) -Message "a content mismatch that cannot be restored should be partial"
    Assert-True -Condition (-not $contentMismatch.json.changed) -Message "a hash-mismatched source is not evidence of a persisted rename"
    Assert-True -Condition ($contentMismatch.json.results[0].actions.Count -eq 0) -Message "an uncertain rollback must not fabricate a renamed action"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $contentMismatch.paperRoot "download.pdf")) -Message "the mismatched file should remain at the source path"
    $rollbackFailed = Invoke-FileRenameScenario -Scenario "post-move-rollback-fails"
    Assert-True -Condition ($rollbackFailed.exitCode -eq 2) -Message "an unrolled-back postcondition failure should be partial"
    Assert-True -Condition ($rollbackFailed.json.results[0].status -eq "failed") -Message "an unrolled-back postcondition failure should fail its target"
    Assert-True -Condition ($rollbackFailed.json.results[0].issues[0].code -eq "rename_postcondition_failed") -Message "an unrolled-back postcondition failure should retain the issue"
    Assert-True -Condition $rollbackFailed.json.changed -Message "a persisted rename must report changed=true"
    Assert-True -Condition ($rollbackFailed.json.results[0].actions[0].kind -eq "local_pdf_renamed") -Message "a persisted rename must emit a typed action"
    Assert-True -Condition ($rollbackFailed.json.results[0].actions[0].after.path -eq (Join-Path $rollbackFailed.paperRoot "Canonical Paper.pdf")) -Message "the action should report the actual destination path"
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $rollbackFailed.paperRoot "Canonical Paper.pdf")) -Message "the persisted destination should exist"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $rollbackFailed.paperRoot "download.pdf"))) -Message "the persisted rename should leave the source absent"

    $bothExist = Invoke-FileRenameScenario -Scenario "post-move-both-exist"
    Assert-True -Condition ($bothExist.exitCode -eq 2) -Message "an ambiguous two-path rollback state should be partial"
    Assert-True -Condition (-not $bothExist.json.changed) -Message "two existing paths must not be reported as one persisted rename"
    Assert-True -Condition ($bothExist.json.results[0].actions.Count -eq 0) -Message "a two-path state must not fabricate a renamed action"

    $inspectionFails = Invoke-FileRenameScenario -Scenario "post-move-inspection-fails"
    Assert-True -Condition ($inspectionFails.exitCode -eq 2) -Message "an unreadable rollback state should be partial"
    Assert-True -Condition (-not $inspectionFails.json.changed) -Message "an unreadable state must preserve uncertainty"
    Assert-True -Condition ($inspectionFails.json.results[0].actions.Count -eq 0) -Message "an unreadable state must not fabricate a renamed action"

    $targetHashMismatch = Invoke-FileRenameScenario -Scenario "post-move-target-hash-mismatch"
    Assert-True -Condition ($targetHashMismatch.exitCode -eq 2) -Message "a persisted target with the wrong hash should be partial"
    Assert-True -Condition (-not $targetHashMismatch.json.changed) -Message "a wrong-hash target must not prove a rename"
    Assert-True -Condition ($targetHashMismatch.json.results[0].actions.Count -eq 0) -Message "a wrong-hash target must not fabricate a renamed action"
    $targetHashMismatchPath = Join-Path $targetHashMismatch.paperRoot "Canonical Paper.pdf"
    Assert-True -Condition (Test-Path -LiteralPath $targetHashMismatchPath) -Message "the issue evidence should correspond to the persisted target"
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $targetHashMismatch.paperRoot "download.pdf"))) -Message "the source should remain absent in the wrong-hash persisted state"
    $targetHashMismatchRollback = @(
        $targetHashMismatch.json.results[0].issues[0].evidence |
            Where-Object { $_.phase -eq "rollback" }
    )[0]
    $targetHashMismatchActualHash = (Get-FileHash -LiteralPath $targetHashMismatchPath -Algorithm SHA256).Hash
    Assert-True -Condition ($targetHashMismatchRollback.state.destinationHash -eq $targetHashMismatchActualHash) -Message "the issue should retain the observed destination SHA-256"
    Assert-True -Condition ($targetHashMismatchRollback.state.destinationHash -ne "CF5C318101420BBA9F21824FD787D99E21E081E30B1FF3C0F338334783F28F30") -Message "the issue should make the SHA-256 mismatch explicit"

    Write-Output "All $passed file rename assertions passed."
}
finally {
    foreach ($run in @($scenarioRuns.Values)) {
        if (-not $run.process.HasExited) {
            $run.process.Kill($true)
            $run.process.WaitForExit()
        }
        $run.process.Dispose()
    }
    $resolvedTempRoot = [System.IO.Path]::GetFullPath($tempRoot)
    $resolvedSystemTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolvedTempRoot.StartsWith($resolvedSystemTemp, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
