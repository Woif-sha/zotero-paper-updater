[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) `
    "scripts\ZoteroPaperUpdater.CrossrefSource.psm1"
Import-Module $modulePath -Force -DisableNameChecking
$passed = 0

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
    $script:passed++
}

function New-CrossrefWork {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Constructs an in-memory Crossref test record."
    )]
    param(
        [string]$Title = "Exact Paper",
        [string]$Given = "Ada",
        [string]$Family = "Lovelace",
        [string]$Doi = "10.1000/exact",
        [string]$Type = "journal-article",
        [string]$Container = "Formal Journal"
    )

    [pscustomobject][ordered]@{
        type = $Type
        title = @($Title)
        subtitle = @("A Subtitle")
        author = @([pscustomobject][ordered]@{ given = $Given; family = $Family })
        editor = @([pscustomobject][ordered]@{ given = "Grace"; family = "Hopper" })
        translator = @([pscustomobject][ordered]@{ given = "Katherine"; family = "Johnson" })
        abstract = "<jats:p>Verified &amp; complete abstract.</jats:p>"
        DOI = $Doi
        "container-title" = @($Container)
        "short-title" = @("Exact")
        "short-container-title" = @("Form. J.")
        "published-print" = [pscustomobject][ordered]@{ "date-parts" = @(@(2025, 7, 1)) }
        volume = "12"
        issue = "3"
        page = "10-20"
        publisher = "Formal Publisher"
        "publisher-location" = "London"
        "series-title" = @("Formal Series")
        "edition-number" = "2"
        number = "R-42"
        degree = @("PhD")
        subtype = "preprint"
        "group-title" = "Formal Repository"
        event = [pscustomobject]@{
            name = "Formal Conference"
            location = "Paris"
        }
        institution = @([pscustomobject]@{ name = "Formal Institute" })
        archive = @("Formal Archive", "Preservation Archive")
        license = @(
            [pscustomobject]@{ URL = "https://license.example/formal" },
            [pscustomobject]@{ URL = "https://license.example/secondary" }
        )
        ISSN = @("1234-5678", "9876-5432")
        ISBN = @("978-1-234", "978-9-876")
        URL = "https://doi.org/$Doi"
    }
}

function Invoke-CrossrefWorkMapping {
    param([Parameter(Mandatory = $true)][object]$Work)

    Invoke-CrossrefMetadataQuery `
        -Query ([pscustomobject]@{ kind = "doi"; value = $Work.DOI }) `
        -HttpAdapter {
            param($Uri)
            $null = $Uri
            [pscustomobject]@{
                statusCode = 200
                body = [pscustomobject]@{ message = $Work }
            }
        }
}

$doiCalls = [Collections.Generic.List[string]]::new()
$doiHttp = {
    param($Uri)
    $doiCalls.Add($Uri)
    [pscustomobject]@{
        statusCode = 200
        body = [pscustomobject]@{ message = New-CrossrefWork }
    }
}
$doiResult = Invoke-CrossrefMetadataQuery `
    -Query ([pscustomobject]@{ kind = "doi"; value = "https://doi.org/10.1000/EXACT" }) `
    -HttpAdapter $doiHttp
Assert-True ($doiCalls.Count -eq 1) "DOI lookup should make one HTTP request"
Assert-True ($doiCalls[0] -match "/works/10\.1000%2Fexact$") "DOI lookup should use the DOI endpoint"
Assert-True $doiResult.matched "an identical DOI should be exact"
Assert-True ($doiResult.record.fields.publicationTitle -eq "Formal Journal") "journal mapping should use publicationTitle"
Assert-True ($doiResult.record.fields.publisher -eq "Formal Publisher") "journal mapping should retain a schema-valid publisher"
Assert-True ($doiResult.record.fields.place -eq "London") "journal mapping should retain publisher location"
Assert-True ($doiResult.record.fields.abstractNote -eq "Verified & complete abstract.") "Crossref JATS abstract should map to plain Zotero abstractNote"
Assert-True ($doiResult.record.fields.shortTitle -eq "Exact") "Crossref short title should map to shortTitle"
Assert-True ($doiResult.record.fields.journalAbbreviation -eq "Form. J.") "short container title should map to journalAbbreviation"
Assert-True ($doiResult.record.fields.title -eq "Exact Paper: A Subtitle") "source subtitle should complete the Zotero title"
Assert-True ($doiResult.record.fields.creators.Count -eq 3) "all schema-valid source creators should be retained"
Assert-True ($doiResult.record.fields.creators[1].creatorType -eq "editor") "Crossref editors should map to Zotero editor creators"
Assert-True ($doiResult.record.fields.creators[1].lastName -eq "Hopper") "editor identity should be preserved"
Assert-True ($doiResult.record.fields.creators[2].creatorType -eq "translator") "Crossref translators should map to Zotero translator creators"
Assert-True ($doiResult.record.fields.archive -eq "Formal Archive; Preservation Archive") "all Crossref archives should map to Zotero archive"
Assert-True ($doiResult.record.fields.rights -eq "https://license.example/formal; https://license.example/secondary") "all Crossref licenses should map to Zotero rights"

$titleCalls = [Collections.Generic.List[string]]::new()
$titleHttp = {
    param($Uri)
    $titleCalls.Add($Uri)
    [pscustomobject]@{
        statusCode = 200
        body = [pscustomobject]@{
            message = [pscustomobject]@{
                items = @(
                    (New-CrossrefWork -Title "Similar Paper"),
                    (New-CrossrefWork -Type "book-chapter" -Container "Collected Works")
                )
            }
        }
    }
}
$titleResult = Invoke-CrossrefMetadataQuery `
    -Query ([pscustomobject]@{
        kind = "title_first_author"
        title = "Exact Paper: A Subtitle"
        firstAuthor = "Ada Lovelace"
    }) `
    -HttpAdapter $titleHttp
Assert-True ($titleCalls.Count -eq 1) "title lookup should make one HTTP request"
Assert-True ($titleCalls[0] -match "query\.title=Exact%20Paper%3A%20A%20Subtitle") "title lookup URI should contain the full title and subtitle"
Assert-True ($titleCalls[0] -match "query\.author=Ada%20Lovelace") "title lookup URI should contain the first author"
Assert-True ($titleCalls[0] -match "rows=5$") "title lookup should inspect a bounded candidate set in one response"
Assert-True $titleResult.matched "one exact candidate among bounded results should match"
Assert-True ($titleResult.record.itemType -eq "bookSection") "book chapter should map to bookSection"
Assert-True ($titleResult.record.fields.bookTitle -eq "Collected Works") "bookSection mapping should use bookTitle"
Assert-True ($titleResult.record.fields.PSObject.Properties.Name -notcontains "publicationTitle") "bookSection mapping should exclude journal fields"

$differentSubtitle = Invoke-CrossrefMetadataQuery `
    -Query ([pscustomobject]@{
        kind = "title_first_author"
        title = "Exact Paper"
        firstAuthor = "Ada Lovelace"
    }) `
    -HttpAdapter {
        param($Uri)
        $null = $Uri
        $work = New-CrossrefWork
        $work.subtitle = @("Different Subtitle")
        [pscustomobject]@{
            statusCode = 200
            body = [pscustomobject]@{
                message = [pscustomobject]@{ items = @($work) }
            }
        }
    }
Assert-True (-not $differentSubtitle.matched) "a source record with a different complete subtitle must not match the queried title"

$conferenceFields = (Invoke-CrossrefWorkMapping `
    (New-CrossrefWork -Type "proceedings-article" -Container "Proceedings")).record.fields
Assert-True ($conferenceFields.conferenceName -eq "Formal Conference") "conference event name should map to conferenceName"
Assert-True ($conferenceFields.eventPlace -eq "Paris") "conference event location should map to eventPlace"
Assert-True ($conferenceFields.issue -eq "3") "conference issue should be retained when schema-valid"
Assert-True ($conferenceFields.ISSN -eq "1234-5678; 9876-5432") "all conference ISSNs should be retained when schema-valid"

$bookSectionFields = (Invoke-CrossrefWorkMapping `
    (New-CrossrefWork -Type "book-chapter" -Container "Collected Works")).record.fields
Assert-True ($bookSectionFields.series -eq "Formal Series") "book section series should map to series"
Assert-True ($bookSectionFields.edition -eq "2") "book section edition should map to edition"
Assert-True ($bookSectionFields.ISSN -eq "1234-5678; 9876-5432") "all book section ISSNs should be retained"

$bookFields = (Invoke-CrossrefWorkMapping (New-CrossrefWork -Type "book")).record.fields
Assert-True ($bookFields.series -eq "Formal Series") "book series should map to series"
Assert-True ($bookFields.edition -eq "2") "book edition should map to edition"
Assert-True ($bookFields.ISSN -eq "1234-5678; 9876-5432") "all book ISSNs should be retained"

$reportFields = (Invoke-CrossrefWorkMapping (New-CrossrefWork -Type "report")).record.fields
Assert-True ($reportFields.institution -eq "Formal Institute") "report institution should prefer the formal institution record"
Assert-True ($reportFields.seriesTitle -eq "Formal Series") "report series should map to seriesTitle"
Assert-True ($reportFields.pages -eq "10-20") "report pages should be retained"
Assert-True ($reportFields.ISBN -eq "978-1-234; 978-9-876") "all report ISBNs should be retained"
Assert-True ($reportFields.ISSN -eq "1234-5678; 9876-5432") "all report ISSNs should be retained"

$thesisWork = New-CrossrefWork -Type "dissertation"
$thesisWork.page = "150"
$thesisFields = (Invoke-CrossrefWorkMapping $thesisWork).record.fields
Assert-True ($thesisFields.university -eq "Formal Institute") "thesis institution should map to university"
Assert-True ($thesisFields.thesisType -eq "PhD") "Crossref degree should map to thesisType"
Assert-True ($thesisFields.numPages -eq "150") "a numeric thesis page count should map to numPages"
Assert-True ($thesisFields.creators.Count -eq 1) "schema-invalid thesis editors should be omitted"

$preprintFields = (Invoke-CrossrefWorkMapping (New-CrossrefWork -Type "posted-content")).record.fields
Assert-True ($preprintFields.genre -eq "preprint") "Crossref posted-content subtype should map to preprint genre"
Assert-True ($preprintFields.repository -eq "Formal Repository") "Crossref group title should identify the preprint repository"
Assert-True ($preprintFields.PSObject.Properties.Name -notcontains "ISBN") "schema-invalid preprint ISBN should be omitted"

$locatorWork = New-CrossrefWork
$locatorWork.page = $null
$locatorWork | Add-Member -NotePropertyName "article-number" -NotePropertyValue "e12345"
$locatorFields = (Invoke-CrossrefWorkMapping $locatorWork).record.fields
Assert-True ($locatorFields.pages -eq "e12345") "article number should fill pages when Crossref supplies no page range"

$notFoundCalls = 0
$notFound = Invoke-CrossrefMetadataQuery `
    -Query ([pscustomobject]@{ kind = "doi"; value = "10.1000/missing" }) `
    -HttpAdapter {
        param($Uri)
        $null = $Uri
        $script:notFoundCalls++
        [pscustomobject]@{ statusCode = 404; body = $null }
    }
Assert-True ($notFoundCalls -eq 1) "a 404 should not retry or switch sources"
Assert-True (-not $notFound.matched) "a 404 should be a successful no-match"

$ambiguous = Invoke-CrossrefMetadataQuery `
    -Query ([pscustomobject]@{
        kind = "title_first_author"
        title = "Exact Paper"
        firstAuthor = "Ada Lovelace"
    }) `
    -HttpAdapter {
        param($Uri)
        $null = $Uri
        [pscustomobject]@{
            statusCode = 200
            body = [pscustomobject]@{
                message = [pscustomobject]@{
                    items = @((New-CrossrefWork), (New-CrossrefWork -Doi "10.1000/other"))
                }
            }
        }
    }
Assert-True (-not $ambiguous.matched) "multiple exact identities should not select an arbitrary record"

$sparseWork = [pscustomobject]@{
    type = "journal-article"
    title = @("Sparse Paper")
    DOI = "10.1000/sparse"
    URL = "https://doi.org/10.1000/sparse"
}
$sparseFields = (Invoke-CrossrefWorkMapping $sparseWork).record.fields
Assert-True ($sparseFields.title -eq "Sparse Paper") "a sparse formal record should still map its supplied fields"
Assert-True ($sparseFields.PSObject.Properties.Name -notcontains "creators") "an absent source creator list should leave Zotero creators unchanged"
Assert-True ($sparseFields.PSObject.Properties.Name -notcontains "abstractNote") "an absent source abstract should leave Zotero abstract unchanged"

Write-Output "All $passed Crossref-source assertions passed."
