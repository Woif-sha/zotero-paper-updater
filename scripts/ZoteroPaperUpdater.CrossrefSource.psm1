Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot "ZoteroPaperUpdater.Common.psm1") -DisableNameChecking

$script:CrossrefApiBase = "https://api.crossref.org"
$script:CandidateLimit = 5

function ConvertTo-SourceIdentityText {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }
    $valueText = $Value.Normalize([Text.NormalizationForm]::FormKC).ToLowerInvariant()
    $valueText = [regex]::Replace($valueText, "[^\p{L}\p{Nd}]+", " ")
    [regex]::Replace($valueText.Trim(), "\s+", " ")
}

function ConvertTo-SourceDoi {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }
    $doi = $Value.Trim().ToLowerInvariant()
    $doi = $doi -replace "^https?://(?:dx\.)?doi\.org/", ""
    $doi -replace "^doi:\s*", ""
}

function Get-SourceFirstValue {
    param([AllowNull()][object]$Value)

    $values = @(@($Value) | Where-Object { $null -ne $_ })
    if ($values.Count -eq 0) {
        return $null
    }
    $values[0]
}

function ConvertTo-SourceListText {
    param([AllowNull()][object]$Value)

    $values = @(
        @($Value) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
    if ($values.Count -eq 0) {
        return $null
    }
    $values -join "; "
}

function Get-SourceDate {
    param([Parameter(Mandatory = $true)][object]$Work)

    foreach ($name in @("published-print", "published-online", "published", "issued")) {
        $dateObject = Get-OptionalPropertyValue -Object $Work -Name $name
        if ($null -eq $dateObject) {
            continue
        }
        $parts = Get-OptionalPropertyValue -Object $dateObject -Name "date-parts"
        if ($null -eq $parts) {
            continue
        }
        $values = @(@($parts)[0] | Where-Object { $null -ne $_ })
        if ($values.Count -eq 0) {
            continue
        }
        if ($values.Count -ge 3) {
            return "{0:D4}-{1:D2}-{2:D2}" -f [int]$values[0], [int]$values[1], [int]$values[2]
        }
        if ($values.Count -eq 2) {
            return "{0:D4}-{1:D2}" -f [int]$values[0], [int]$values[1]
        }
        if ($values.Count -eq 1) {
            return [string]$values[0]
        }
    }
    $null
}

function Get-SourceCreator {
    param(
        [Parameter(Mandatory = $true)][object]$Work,
        [AllowNull()][string]$ItemType
    )

    @(
        foreach ($creatorGroup in @(
            [pscustomobject]@{ property = "author"; creatorType = "author" },
            [pscustomobject]@{ property = "editor"; creatorType = "editor" },
            [pscustomobject]@{ property = "translator"; creatorType = "translator" }
        )) {
            if ($creatorGroup.creatorType -in @("editor", "translator") -and $ItemType -eq "thesis") {
                continue
            }
            foreach ($creator in @(Get-OptionalPropertyValue -Object $Work -Name $creatorGroup.property)) {
                if ($null -eq $creator) {
                    continue
                }
                $family = [string](Get-OptionalPropertyValue -Object $creator -Name "family")
                $given = [string](Get-OptionalPropertyValue -Object $creator -Name "given")
                if (-not [string]::IsNullOrWhiteSpace("$given$family")) {
                    [pscustomobject][ordered]@{
                        creatorType = $creatorGroup.creatorType
                        firstName = $given
                        lastName = $family
                    }
                }
            }
        }
    )
}

function Get-SourceTitle {
    param([Parameter(Mandatory = $true)][object]$Work)

    $title = [string](Get-SourceFirstValue `
        (Get-OptionalPropertyValue -Object $Work -Name "title"))
    $subtitle = [string](Get-SourceFirstValue `
        (Get-OptionalPropertyValue -Object $Work -Name "subtitle"))
    if ([string]::IsNullOrWhiteSpace($subtitle) -or
        $title.EndsWith($subtitle, [StringComparison]::OrdinalIgnoreCase)) {
        return $title
    }
    "$($title.TrimEnd()): $($subtitle.Trim())"
}

function Get-SourcePage {
    param([Parameter(Mandatory = $true)][object]$Work)

    $pages = [string](Get-OptionalPropertyValue -Object $Work -Name "page")
    if (-not [string]::IsNullOrWhiteSpace($pages)) {
        return $pages
    }
    [string](Get-OptionalPropertyValue -Object $Work -Name "article-number")
}

function ConvertFrom-SourceAbstract {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }
    $plainText = [regex]::Replace($Value, "<[^>]+>", " ")
    $plainText = [Net.WebUtility]::HtmlDecode($plainText)
    [regex]::Replace($plainText.Trim(), "\s+", " ")
}

function Get-SourceInstitutionName {
    param([Parameter(Mandatory = $true)][object]$Work)

    $institutions = @(
        @(Get-OptionalPropertyValue -Object $Work -Name "institution") |
            Where-Object { $null -ne $_ }
    )
    if ($institutions.Count -eq 0) {
        return $null
    }
    [string](Get-OptionalPropertyValue -Object $institutions[0] -Name "name")
}

function Get-SourceItemType {
    param([AllowNull()][string]$CrossrefType)

    switch ($CrossrefType) {
        "journal-article" { "journalArticle" }
        "proceedings-article" { "conferencePaper" }
        "book-chapter" { "bookSection" }
        { $_ -in @("book", "monograph", "edited-book", "reference-book") } { "book" }
        "report" { "report" }
        "dissertation" { "thesis" }
        "posted-content" { "preprint" }
        default { $null }
    }
}

function Add-SourceField {
    param(
        [Parameter(Mandatory = $true)]
        [Collections.Specialized.OrderedDictionary]$Fields,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value -or
        ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) -or
        ($Value -is [Collections.ICollection] -and $Value.Count -eq 0)) {
        return
    }
    $Fields[$Name] = $Value
}

function ConvertFrom-CrossrefSourceWork {
    param([Parameter(Mandatory = $true)][object]$Work)

    $itemType = Get-SourceItemType `
        -CrossrefType ([string](Get-OptionalPropertyValue -Object $Work -Name "type"))
    $fields = [ordered]@{}
    Add-SourceField $fields "title" (Get-SourceTitle -Work $Work)
    Add-SourceField $fields "creators" @(Get-SourceCreator -Work $Work -ItemType $itemType)
    Add-SourceField $fields "abstractNote" (ConvertFrom-SourceAbstract `
        ([string](Get-OptionalPropertyValue -Object $Work -Name "abstract")))
    Add-SourceField $fields "DOI" ([string](Get-OptionalPropertyValue -Object $Work -Name "DOI"))
    Add-SourceField $fields "date" (Get-SourceDate -Work $Work)
    Add-SourceField $fields "url" ([string](Get-OptionalPropertyValue -Object $Work -Name "URL"))
    Add-SourceField $fields "language" ([string](Get-OptionalPropertyValue -Object $Work -Name "language"))
    Add-SourceField $fields "shortTitle" ([string](Get-SourceFirstValue `
        (Get-OptionalPropertyValue -Object $Work -Name "short-title")))
    Add-SourceField $fields "place" ([string](Get-OptionalPropertyValue -Object $Work -Name "publisher-location"))
    Add-SourceField $fields "archive" (ConvertTo-SourceListText `
        (Get-OptionalPropertyValue -Object $Work -Name "archive"))
    $licenses = @(
        @(Get-OptionalPropertyValue -Object $Work -Name "license") |
            Where-Object { $null -ne $_ }
    )
    if ($licenses.Count -gt 0) {
        Add-SourceField $fields "rights" (ConvertTo-SourceListText @(
            $licenses |
                ForEach-Object { Get-OptionalPropertyValue -Object $_ -Name "URL" }
        ))
    }

    $containerTitle = [string](Get-SourceFirstValue `
        (Get-OptionalPropertyValue -Object $Work -Name "container-title"))
    if ($itemType -eq "journalArticle") {
        Add-SourceField $fields "publicationTitle" $containerTitle
        Add-SourceField $fields "journalAbbreviation" ([string](Get-SourceFirstValue `
            (Get-OptionalPropertyValue -Object $Work -Name "short-container-title")))
        Add-SourceField $fields "publisher" ([string](Get-OptionalPropertyValue -Object $Work -Name "publisher"))
        Add-SourceField $fields "seriesTitle" ([string](Get-SourceFirstValue `
            (Get-OptionalPropertyValue -Object $Work -Name "series-title")))
        Add-SourceField $fields "volume" ([string](Get-OptionalPropertyValue -Object $Work -Name "volume"))
        Add-SourceField $fields "issue" ([string](Get-OptionalPropertyValue -Object $Work -Name "issue"))
        Add-SourceField $fields "pages" (Get-SourcePage -Work $Work)
        Add-SourceField $fields "ISSN" (ConvertTo-SourceListText `
            (Get-OptionalPropertyValue -Object $Work -Name "ISSN"))
    }
    elseif ($itemType -eq "conferencePaper") {
        Add-SourceField $fields "proceedingsTitle" $containerTitle
        $eventMetadata = Get-OptionalPropertyValue -Object $Work -Name "event"
        if ($null -ne $eventMetadata) {
            Add-SourceField $fields "conferenceName" ([string](Get-OptionalPropertyValue -Object $eventMetadata -Name "name"))
            Add-SourceField $fields "eventPlace" ([string](Get-OptionalPropertyValue -Object $eventMetadata -Name "location"))
        }
        Add-SourceField $fields "volume" ([string](Get-OptionalPropertyValue -Object $Work -Name "volume"))
        Add-SourceField $fields "issue" ([string](Get-OptionalPropertyValue -Object $Work -Name "issue"))
        Add-SourceField $fields "pages" (Get-SourcePage -Work $Work)
        Add-SourceField $fields "series" ([string](Get-SourceFirstValue `
            (Get-OptionalPropertyValue -Object $Work -Name "series-title")))
        Add-SourceField $fields "publisher" ([string](Get-OptionalPropertyValue -Object $Work -Name "publisher"))
        Add-SourceField $fields "ISBN" (ConvertTo-SourceListText `
            (Get-OptionalPropertyValue -Object $Work -Name "ISBN"))
        Add-SourceField $fields "ISSN" (ConvertTo-SourceListText `
            (Get-OptionalPropertyValue -Object $Work -Name "ISSN"))
    }
    elseif ($itemType -eq "bookSection") {
        Add-SourceField $fields "bookTitle" $containerTitle
        Add-SourceField $fields "series" ([string](Get-SourceFirstValue `
            (Get-OptionalPropertyValue -Object $Work -Name "series-title")))
        Add-SourceField $fields "volume" ([string](Get-OptionalPropertyValue -Object $Work -Name "volume"))
        Add-SourceField $fields "edition" ([string](Get-OptionalPropertyValue -Object $Work -Name "edition-number"))
        Add-SourceField $fields "pages" (Get-SourcePage -Work $Work)
        Add-SourceField $fields "publisher" ([string](Get-OptionalPropertyValue -Object $Work -Name "publisher"))
        Add-SourceField $fields "ISBN" (ConvertTo-SourceListText `
            (Get-OptionalPropertyValue -Object $Work -Name "ISBN"))
        Add-SourceField $fields "ISSN" (ConvertTo-SourceListText `
            (Get-OptionalPropertyValue -Object $Work -Name "ISSN"))
    }
    elseif ($itemType -eq "book") {
        Add-SourceField $fields "series" ([string](Get-SourceFirstValue `
            (Get-OptionalPropertyValue -Object $Work -Name "series-title")))
        Add-SourceField $fields "volume" ([string](Get-OptionalPropertyValue -Object $Work -Name "volume"))
        Add-SourceField $fields "edition" ([string](Get-OptionalPropertyValue -Object $Work -Name "edition-number"))
        Add-SourceField $fields "publisher" ([string](Get-OptionalPropertyValue -Object $Work -Name "publisher"))
        Add-SourceField $fields "ISBN" (ConvertTo-SourceListText `
            (Get-OptionalPropertyValue -Object $Work -Name "ISBN"))
        Add-SourceField $fields "ISSN" (ConvertTo-SourceListText `
            (Get-OptionalPropertyValue -Object $Work -Name "ISSN"))
    }
    elseif ($itemType -eq "report") {
        $institutionName = Get-SourceInstitutionName -Work $Work
        if ([string]::IsNullOrWhiteSpace($institutionName)) {
            $institutionName = [string](Get-OptionalPropertyValue -Object $Work -Name "publisher")
        }
        Add-SourceField $fields "institution" $institutionName
        Add-SourceField $fields "reportNumber" ([string](Get-OptionalPropertyValue -Object $Work -Name "number"))
        Add-SourceField $fields "seriesTitle" ([string](Get-SourceFirstValue `
            (Get-OptionalPropertyValue -Object $Work -Name "series-title")))
        Add-SourceField $fields "pages" (Get-SourcePage -Work $Work)
        Add-SourceField $fields "ISBN" (ConvertTo-SourceListText `
            (Get-OptionalPropertyValue -Object $Work -Name "ISBN"))
        Add-SourceField $fields "ISSN" (ConvertTo-SourceListText `
            (Get-OptionalPropertyValue -Object $Work -Name "ISSN"))
    }
    elseif ($itemType -eq "thesis") {
        $university = Get-SourceInstitutionName -Work $Work
        if ([string]::IsNullOrWhiteSpace($university)) {
            $university = [string](Get-OptionalPropertyValue -Object $Work -Name "publisher")
        }
        Add-SourceField $fields "university" $university
        Add-SourceField $fields "thesisType" ([string](Get-SourceFirstValue `
            (Get-OptionalPropertyValue -Object $Work -Name "degree")))
        $pageValue = [string](Get-OptionalPropertyValue -Object $Work -Name "page")
        if ($pageValue -match "^\d+$") {
            Add-SourceField $fields "numPages" $pageValue
        }
        Add-SourceField $fields "ISBN" (ConvertTo-SourceListText `
            (Get-OptionalPropertyValue -Object $Work -Name "ISBN"))
        Add-SourceField $fields "ISSN" (ConvertTo-SourceListText `
            (Get-OptionalPropertyValue -Object $Work -Name "ISSN"))
    }
    elseif ($itemType -eq "preprint") {
        $repository = [string](Get-OptionalPropertyValue -Object $Work -Name "group-title")
        if ([string]::IsNullOrWhiteSpace($repository)) {
            $repository = $containerTitle
        }
        Add-SourceField $fields "repository" $repository
        Add-SourceField $fields "genre" ([string](Get-OptionalPropertyValue -Object $Work -Name "subtype"))
    }

    [pscustomobject][ordered]@{
        fields = [pscustomobject]$fields
        itemType = $itemType
    }
}

function New-SourceNoMatch {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions",
        "",
        Justification = "Constructs an in-memory result."
    )]
    param()

    [pscustomobject][ordered]@{ matched = $false }
}

function Invoke-DefaultSourceHttp {
    param([Parameter(Mandatory = $true)][string]$Uri)

    try {
        [pscustomobject][ordered]@{
            statusCode = 200
            body = Invoke-RestMethod -Uri $Uri -Method Get -TimeoutSec 15
        }
    }
    catch {
        $statusCode = if ($null -ne $_.Exception.Response) {
            [int]$_.Exception.Response.StatusCode
        }
        else {
            0
        }
        if ($statusCode -eq 404) {
            return [pscustomobject][ordered]@{ statusCode = 404; body = $null }
        }
        throw
    }
}

function Invoke-CrossrefMetadataQuery {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Query,
        [scriptblock]$HttpAdapter
    )

    if ($null -eq $HttpAdapter) {
        $HttpAdapter = { param($Uri) Invoke-DefaultSourceHttp -Uri $Uri }
    }
    $kind = [string](Get-RequiredPropertyValue -Object $Query -Name "kind")
    if ($kind -eq "doi") {
        $requestedDoi = ConvertTo-SourceDoi `
            ([string](Get-RequiredPropertyValue -Object $Query -Name "value"))
        $uri = "$($script:CrossrefApiBase)/works/$([uri]::EscapeDataString($requestedDoi))"
        $transport = & $HttpAdapter $uri
        if ([int](Get-RequiredPropertyValue -Object $transport -Name "statusCode") -eq 404) {
            return New-SourceNoMatch
        }
        $work = Get-RequiredPropertyValue `
            -Object (Get-RequiredPropertyValue -Object $transport -Name "body") `
            -Name "message"
        $returnedDoi = ConvertTo-SourceDoi `
            ([string](Get-OptionalPropertyValue -Object $work -Name "DOI"))
        if ($requestedDoi -cne $returnedDoi) {
            return New-SourceNoMatch
        }
        $identityEvidence = "doi:$returnedDoi"
    }
    elseif ($kind -eq "title_first_author") {
        $title = [string](Get-RequiredPropertyValue -Object $Query -Name "title")
        $author = [string](Get-RequiredPropertyValue -Object $Query -Name "firstAuthor")
        $uri = "$($script:CrossrefApiBase)/works?query.title=$([uri]::EscapeDataString($title))" +
            "&query.author=$([uri]::EscapeDataString($author))&rows=$($script:CandidateLimit)"
        $transport = & $HttpAdapter $uri
        $message = Get-RequiredPropertyValue `
            -Object (Get-RequiredPropertyValue -Object $transport -Name "body") `
            -Name "message"
        $exact = @(
            foreach ($candidate in @(Get-OptionalPropertyValue -Object $message -Name "items")) {
                $candidateTitle = Get-SourceTitle -Work $candidate
                $authors = @(
                    @(Get-OptionalPropertyValue -Object $candidate -Name "author") |
                        Where-Object { $null -ne $_ }
                )
                if ($authors.Count -eq 0) {
                    continue
                }
                $candidateAuthor = "$([string](Get-OptionalPropertyValue -Object $authors[0] -Name 'given')) " +
                    "$([string](Get-OptionalPropertyValue -Object $authors[0] -Name 'family'))"
                if ((ConvertTo-SourceIdentityText $title) -ceq
                        (ConvertTo-SourceIdentityText $candidateTitle) -and
                    (ConvertTo-SourceIdentityText $author) -ceq
                        (ConvertTo-SourceIdentityText $candidateAuthor)) {
                    $candidate
                }
            }
        )
        if ($exact.Count -ne 1) {
            return New-SourceNoMatch
        }
        $work = $exact[0]
        $identityEvidence = "title-first-author:" +
            "$(ConvertTo-SourceIdentityText $title)|$(ConvertTo-SourceIdentityText $author)"
    }
    else {
        throw "Unsupported metadata query kind '$kind'."
    }

    $doi = ConvertTo-SourceDoi ([string](Get-OptionalPropertyValue -Object $work -Name "DOI"))
    $recordUrl = if ($doi) { "https://doi.org/$doi" } else {
        [string](Get-OptionalPropertyValue -Object $work -Name "URL")
    }
    [pscustomobject][ordered]@{
        matched = $true
        exact = $true
        reliable = $true
        formal = $true
        evidence = @($recordUrl, "crossref:$identityEvidence")
        record = ConvertFrom-CrossrefSourceWork -Work $work
    }
}

Export-ModuleMember -Function Invoke-CrossrefMetadataQuery
