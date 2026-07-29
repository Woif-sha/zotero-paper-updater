Set-StrictMode -Version Latest

$script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:fileRenameModulePath = Join-Path $script:repoRoot "scripts\ZoteroPaperUpdater.FileRename.psm1"
$script:pendingFixtureTargets = [Collections.Generic.Queue[object]]::new()

function New-TestPdf {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Creates isolated test fixtures only under the caller-provided temporary root."
    )]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [System.IO.File]::WriteAllBytes(
        $Path,
        [System.Text.Encoding]::ASCII.GetBytes($Content)
    )
}

function New-TestJunction {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Creates isolated junction fixtures only under the caller-provided temporary root."
    )]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Target
    )

    [System.IO.Directory]::CreateDirectory($Target) | Out-Null
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    $null = New-Item -ItemType Junction -Path $Path -Target $Target -ErrorAction Stop
}

function New-FileRenameTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Creates isolated adapter fixtures and an in-memory target for entry tests."
    )]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Scope,

        [Parameter(Mandatory = $true)]
        [string]$Suffix,

        [Parameter(Mandatory = $true)]
        [string]$LocalName,

        [string]$StorageName = "Canonical Paper.pdf",

        [switch]$SkipLocal
    )

    $storageRoot = Join-Path $Scope.zoteroDataDir "storage"
    $attachmentKey = "ATTACH-$Suffix"
    $storagePdf = Join-Path $storageRoot "$attachmentKey\$StorageName"
    $localPdf = Join-Path $Scope.paperRoot $LocalName
    $localPdfPaths = @()
    New-TestPdf -Path $storagePdf -Content "%PDF-$Suffix"
    if (-not $SkipLocal) {
        New-TestPdf -Path $localPdf -Content "%PDF-$Suffix"
        $localPdfPaths = @($localPdf)
    }

    [pscustomobject][ordered]@{
        parentItemKey = "PARENT-$Suffix"
        attachmentKey = $attachmentKey
        path = $localPdf
        localPdfPaths = $localPdfPaths
        storagePdfPaths = @($storagePdf)
        storageRoot = $storageRoot
    }
}

function Get-FileRenameScenarioConfig {
    $scenario = [ordered]@{
        name = [string]$env:ZPU_FILE_RENAME_SCENARIO
        localName = "download.pdf"
        caseOnlySecondMoveFails = $false
        preMoveDrift = $null
        postMoveFailure = $false
        failRollback = $false
        failPostHash = $false
        mutateAfterRename = $false
        createConcurrentSource = $false
        failStateInspection = $false
    }

    switch ($scenario.name) {
        "noop" {
            $scenario.localName = "Canonical Paper.pdf"
        }
        "case-only" {
            $scenario.localName = "canonical Paper.pdf"
        }
        "case-only-second-move-fails" {
            $scenario.localName = "canonical Paper.pdf"
            $scenario.caseOnlySecondMoveFails = $true
        }
        "pre-move-drift" {
            $scenario.preMoveDrift = "source"
        }
        "pre-move-storage-drift" {
            $scenario.preMoveDrift = "storage"
        }
        "post-move-mismatch" {
            $scenario.postMoveFailure = $true
        }
        "post-move-content-mismatch" {
            $scenario.postMoveFailure = $true
            $scenario.mutateAfterRename = $true
        }
        "post-move-hash-fails" {
            $scenario.postMoveFailure = $true
            $scenario.failPostHash = $true
        }
        "post-move-rollback-fails" {
            $scenario.postMoveFailure = $true
            $scenario.failRollback = $true
        }
        "post-move-both-exist" {
            $scenario.postMoveFailure = $true
            $scenario.createConcurrentSource = $true
        }
        "post-move-inspection-fails" {
            $scenario.postMoveFailure = $true
            $scenario.failRollback = $true
            $scenario.failStateInspection = $true
        }
        "post-move-target-hash-mismatch" {
            $scenario.postMoveFailure = $true
            $scenario.failRollback = $true
            $scenario.mutateAfterRename = $true
        }
    }

    [pscustomobject]$scenario
}

function Get-MaintenanceZoteroItem {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Scope
    )

    $script:pendingFixtureTargets.Clear()
    $count = if ([string]$env:ZPU_FILE_RENAME_SCENARIO -eq "missing-continues") { 2 } else { 1 }
    $items = [Collections.Generic.List[object]]::new()
    foreach ($ordinal in 2..($count + 1)) {
        $parentKey = "PAR$ordinal$ordinal$ordinal$ordinal$ordinal"
        $attachmentKey = "ATT$ordinal$ordinal$ordinal$ordinal$ordinal"
        $storagePath = Join-Path $Scope.zoteroDataDir "storage\$attachmentKey\route-$ordinal.pdf"
        $localPath = Join-Path $Scope.paperRoot "route-$ordinal.pdf"
        New-TestPdf -Path $storagePath -Content "%PDF-route-$ordinal"
        New-TestPdf -Path $localPath -Content "%PDF-route-$ordinal"
        $items.Add([pscustomobject][ordered]@{
            key = $parentKey
            data = [pscustomobject][ordered]@{
                key = $parentKey
                itemType = "journalArticle"
                title = "Route $ordinal"
            }
        })
        $items.Add([pscustomobject][ordered]@{
            key = $attachmentKey
            data = [pscustomobject][ordered]@{
                key = $attachmentKey
                itemType = "attachment"
                parentItem = $parentKey
                contentType = "application/pdf"
                filename = "route-$ordinal.pdf"
            }
        })
    }
    $items.ToArray()
}

function Resolve-MaintenanceTarget {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Scope
    )

    $config = Get-FileRenameScenarioConfig
    $scenario = $config.name
    if ($scenario -eq "missing-continues") {
        return @(
            New-FileRenameTarget -Scope $Scope -Suffix "MISSING" -LocalName "missing.pdf" -SkipLocal
            New-FileRenameTarget -Scope $Scope -Suffix "CONTINUE" -LocalName "continue.pdf" -StorageName "Continued Paper.pdf"
        )
    }

    if ($scenario -eq "storage-missing") {
        $target = New-FileRenameTarget -Scope $Scope -Suffix "STORAGE-MISSING" -LocalName "download.pdf"
        Remove-Item -LiteralPath $target.storagePdfPaths[0] -Force
        $target.storagePdfPaths = @()
        return $target
    }
    if ($scenario -eq "storage-ambiguous") {
        $target = New-FileRenameTarget -Scope $Scope -Suffix "STORAGE-AMBIGUOUS" -LocalName "download.pdf"
        $secondStorage = Join-Path $target.storageRoot "ATTACH-STORAGE-AMBIGUOUS\Second.pdf"
        New-TestPdf -Path $secondStorage -Content "%PDF-STORAGE-AMBIGUOUS"
        $target.storagePdfPaths = @($target.storagePdfPaths[0], $secondStorage)
        return $target
    }
    if ($scenario -eq "local-ambiguous") {
        $target = New-FileRenameTarget -Scope $Scope -Suffix "LOCAL-AMBIGUOUS" -LocalName "first.pdf"
        $secondLocal = Join-Path $Scope.paperRoot "second.pdf"
        New-TestPdf -Path $secondLocal -Content "%PDF-LOCAL-AMBIGUOUS"
        $target.localPdfPaths = @($target.localPdfPaths[0], $secondLocal)
        return $target
    }
    if ($scenario -eq "local-one-match") {
        $target = New-FileRenameTarget -Scope $Scope -Suffix "LOCAL-ONE-MATCH" -LocalName "matching.pdf"
        $unrelatedLocal = Join-Path $Scope.paperRoot "unrelated.pdf"
        New-TestPdf -Path $unrelatedLocal -Content "%PDF-unrelated"
        $target.localPdfPaths = @($target.localPdfPaths[0], $unrelatedLocal)
        return $target
    }
    if ($scenario -eq "hash-conflict") {
        $target = New-FileRenameTarget -Scope $Scope -Suffix "HASH-CONFLICT" -LocalName "download.pdf"
        New-TestPdf -Path $target.localPdfPaths[0] -Content "%PDF-different"
        return $target
    }
    if ($scenario -in @("target-conflict", "target-duplicate")) {
        $target = New-FileRenameTarget -Scope $Scope -Suffix "TARGET" -LocalName "download.pdf"
        $targetPath = Join-Path $Scope.paperRoot "Canonical Paper.pdf"
        $targetContent = if ($scenario -eq "target-duplicate") { "%PDF-TARGET" } else { "%PDF-different" }
        New-TestPdf -Path $targetPath -Content $targetContent
        return $target
    }
    if ($scenario -eq "local-path-outside") {
        $target = New-FileRenameTarget -Scope $Scope -Suffix "LOCAL-OUTSIDE" -LocalName "inside.pdf"
        $outsidePath = Join-Path (Split-Path -Parent $Scope.paperRoot) "outside.pdf"
        New-TestPdf -Path $outsidePath -Content "%PDF-LOCAL-OUTSIDE"
        $target.path = $outsidePath
        $target.localPdfPaths = @($outsidePath)
        return $target
    }
    if ($scenario -eq "local-path-invalid") {
        $target = New-FileRenameTarget -Scope $Scope -Suffix "LOCAL-INVALID" -LocalName "inside.pdf"
        $invalidPath = "$($Scope.paperRoot)\invalid`0.pdf"
        $target.path = $invalidPath
        $target.localPdfPaths = @($invalidPath)
        return $target
    }
    if ($scenario -eq "storage-path-outside") {
        $target = New-FileRenameTarget -Scope $Scope -Suffix "STORAGE-OUTSIDE" -LocalName "download.pdf"
        $outsideStorage = Join-Path $Scope.zoteroDataDir "outside.pdf"
        New-TestPdf -Path $outsideStorage -Content "%PDF-STORAGE-OUTSIDE"
        $target.storagePdfPaths = @($outsideStorage)
        return $target
    }
    if ($scenario -eq "paper-root-junction") {
        $paperBacking = Join-Path (Split-Path -Parent $Scope.paperRoot) "paper-backing"
        New-TestJunction -Path $Scope.paperRoot -Target $paperBacking
        return New-FileRenameTarget -Scope $Scope -Suffix "PAPER-ROOT-JUNCTION" -LocalName "download.pdf"
    }
    if ($scenario -eq "storage-root-junction") {
        $storageRoot = Join-Path $Scope.zoteroDataDir "storage"
        $storageBacking = Join-Path $Scope.zoteroDataDir "storage-backing"
        New-TestJunction -Path $storageRoot -Target $storageBacking
        return New-FileRenameTarget -Scope $Scope -Suffix "STORAGE-ROOT-JUNCTION" -LocalName "download.pdf"
    }
    if ($scenario -eq "local-parent-junction") {
        $localBacking = Join-Path (Split-Path -Parent $Scope.paperRoot) "local-backing"
        New-TestJunction -Path (Join-Path $Scope.paperRoot "linked") -Target $localBacking
        return New-FileRenameTarget -Scope $Scope -Suffix "LOCAL-PARENT-JUNCTION" -LocalName "linked\download.pdf"
    }
    if ($scenario -eq "storage-parent-junction") {
        $storageRoot = Join-Path $Scope.zoteroDataDir "storage"
        $attachmentPath = Join-Path $storageRoot "ATTACH-STORAGE-PARENT-JUNCTION"
        $attachmentBacking = Join-Path $Scope.zoteroDataDir "attachment-backing"
        New-TestJunction -Path $attachmentPath -Target $attachmentBacking
        return New-FileRenameTarget -Scope $Scope -Suffix "STORAGE-PARENT-JUNCTION" -LocalName "download.pdf"
    }

    New-FileRenameTarget -Scope $Scope -Suffix "RENAME" -LocalName $config.localName
}

function Invoke-MaintenanceTarget {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Target,

        [Parameter(Mandatory = $true)]
        [object]$Scope
    )

    Remove-Item -LiteralPath ([string]$Target.path) -Force
    $routingStoragePath = [string]$Target.storagePath
    Remove-Item -LiteralPath $routingStoragePath -Force
    Remove-Item -LiteralPath (Split-Path -Parent $routingStoragePath) -Force
    if ($script:pendingFixtureTargets.Count -eq 0) {
        foreach ($fixtureTarget in @(Resolve-MaintenanceTarget -Scope $Scope)) {
            $script:pendingFixtureTargets.Enqueue($fixtureTarget)
        }
    }
    $Target = $script:pendingFixtureTargets.Dequeue()
    Import-Module -Name $script:fileRenameModulePath -Force -DisableNameChecking
    $config = Get-FileRenameScenarioConfig
    $arguments = @{
        Target = $Target
        PaperRoot = $Scope.paperRoot
        StorageRoot = $Target.storageRoot
    }
    if ($config.caseOnlySecondMoveFails) {
        $renameState = [pscustomobject]@{ count = 0 }
        $arguments.FileOperations = @{
            RenameFile = {
                param($SourcePath, $DestinationPath)
                $renameState.count++
                if ($renameState.count -eq 2) {
                    throw "Simulated case-only second move failure."
                }
                Rename-Item -LiteralPath $SourcePath -NewName (Split-Path -Leaf $DestinationPath)
            }.GetNewClosure()
        }
    }
    elseif ($config.preMoveDrift -eq "source") {
        $sourcePath = [string]$Target.localPdfPaths[0]
        $destinationPath = Join-Path (Split-Path -Parent $sourcePath) (Split-Path -Leaf $Target.storagePdfPaths[0])
        $arguments.FileOperations = @{
            TestFile = {
                param($Path)
                if ([string]$Path -eq $destinationPath) {
                    [System.IO.File]::WriteAllBytes(
                        $sourcePath,
                        [System.Text.Encoding]::ASCII.GetBytes("%PDF-drifted-before-move")
                    )
                }
                Test-Path -LiteralPath $Path -PathType Leaf
            }.GetNewClosure()
        }
    }
    elseif ($config.preMoveDrift -eq "storage") {
        $sourcePath = [string]$Target.localPdfPaths[0]
        $storagePath = [string]$Target.storagePdfPaths[0]
        $destinationPath = Join-Path (Split-Path -Parent $sourcePath) (Split-Path -Leaf $storagePath)
        $arguments.FileOperations = @{
            TestFile = {
                param($Path)
                if ([string]$Path -eq $destinationPath) {
                    [System.IO.File]::WriteAllBytes(
                        $storagePath,
                        [System.Text.Encoding]::ASCII.GetBytes("%PDF-storage-drifted-before-move")
                    )
                }
                Test-Path -LiteralPath $Path -PathType Leaf
            }.GetNewClosure()
        }
    }
    elseif ($config.postMoveFailure) {
        $sourcePath = [string]$Target.localPdfPaths[0]
        $destinationPath = Join-Path (Split-Path -Parent $sourcePath) (Split-Path -Leaf $Target.storagePdfPaths[0])
        $renameState = [pscustomobject]@{
            count = 0
            postHashFailureReported = $false
        }
        $failRollback = $config.failRollback
        $failPostHash = $config.failPostHash
        $mutateAfterRename = $config.mutateAfterRename
        $createConcurrentSource = $config.createConcurrentSource
        $failStateInspection = $config.failStateInspection
        $arguments.FileOperations = @{
            RenameFile = {
                param($SourcePath, $DestinationPath)
                $renameState.count++
                if ($createConcurrentSource -and $renameState.count -eq 2) {
                    [System.IO.File]::WriteAllBytes(
                        $DestinationPath,
                        [System.Text.Encoding]::ASCII.GetBytes("%PDF-concurrent-source")
                    )
                    throw "Simulated concurrent source creation."
                }
                if ($failRollback -and $renameState.count -eq 2) {
                    throw "Simulated rollback failure."
                }
                Rename-Item -LiteralPath $SourcePath -NewName (Split-Path -Leaf $DestinationPath)
                if ($mutateAfterRename -and $renameState.count -eq 1) {
                    [System.IO.File]::WriteAllBytes(
                        $DestinationPath,
                        [System.Text.Encoding]::ASCII.GetBytes("%PDF-drifted-after-move")
                    )
                }
            }.GetNewClosure()
            GetSha256 = {
                param($Path)
                if (
                    $failStateInspection -and
                    $renameState.count -ge 2 -and
                    [string]$Path -eq $destinationPath
                ) {
                    throw "Simulated state inspection failure."
                }
                if (
                    -not $mutateAfterRename -and
                    $renameState.count -eq 1 -and
                    [string]$Path -eq $destinationPath
                ) {
                    if ($failPostHash -and -not $renameState.postHashFailureReported) {
                        $renameState.postHashFailureReported = $true
                        throw "Simulated post-rename hash failure."
                    }
                    return "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
                }
                (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
            }.GetNewClosure()
        }
    }

    Invoke-LocalPdfRename @arguments
}

Export-ModuleMember -Function Get-MaintenanceZoteroItem, Invoke-MaintenanceTarget
