<#
.SYNOPSIS
Calculate averages for the Four Key Metrics, based on a provided set of releases
#>
function Get-AverageMetricsForPeriod($releaseMetrics, $endDate) {
    $releaseCount = $releaseMetrics.Count
    $failedReleaseCount = @($releaseMetrics | Where-Object { $_.IsFix }).Count

    if ($releaseCount -gt 0) {
        $deploymentFrequencyDays = ($releaseMetrics | ForEach-Object { $_.Interval.TotalDays } | Measure-Object -Average).Average;
        $failRate = $failedreleaseCount / $releaseCount
        $leadTimeMeasures = $releaseMetrics | Where-Object { $null -ne $_.AverageCommitAge } | ForEach-Object { $_.AverageCommitAge.TotalDays } | Measure-Object -Average
        $leadTimeAverage = $leadTimeMeasures.Average;
    }
    else {
        $deploymentFrequencyDays = $null;
        $failRate = $null;
        $leadTimeAverage = $null;
    }

    if ($failedreleaseCount -gt 0) {
        $mttrMeasures = $releaseMetrics | Where-Object { $_.IsFix } | ForEach-Object { $_.Interval.TotalHours } | Measure-Object -Average
        $mttrAverage = $mttrMeasures.Average;
    }
    else {
        $mttrAverage = $null;
    }

    [PSCustomObject]@{
        EndDate                 = $endDate
        Releases                = $releaseCount;
        DeploymentFrequencyDays = $deploymentFrequencyDays;
        MttrHours               = $mttrAverage;
        LeadTimeDays            = $leadTimeAverage;
        FailRate                = $failRate;
    }
}

<#
.SYNOPSIS
Identify a list of releases, based on repository data
#>
function Get-Releases($releaseTagPattern, $fixTagPattern ) {
    $rawReleaseTags = (git for-each-ref --sort='-taggerdate' --format='%(tag),%(taggerdate:iso8601),%(refname),' "refs/tags/*.*.*")

    if ($LastExitCode -ne 0) {
        throw "Unable to analyse analysis root. Is the analysis root a git repository?"
    }

    foreach ($tag in $rawReleaseTags) {
        $split = $tag.Split(",")
        if ($split[0] -eq "") {
            Write-Warning "Tag $($split[2]) is a light-weight tag and will be ignored"
            continue
        }

        #Write-Host ($split[0] -match $fixTagPattern) + "Rele":$split[0]

        [PSCustomObject]@{
            Tag   = $split[0];
            Date  = [DateTime]::ParseExact($split[1], "yyyy-MM-dd HH:mm:ss zzz", $null);
            IsFix = ($split[0] -match $fixTagPattern)
        }
        
    }
}

<#
.SYNOPSIS
Get a list of all commits added to master between two release tags
#>
function Get-CommitsBetweenTags($start, $end, $subDirs) {
    $rawCommits = git log --pretty=format:"%h,%ai" "$start..$end" --no-merges -- $subDirs
    foreach ($commit in $rawCommits) {
        #Write-Host $commit
        $split = $commit.Split(",")
        [PSCustomObject]@{
            SHA  = $split[0];
            Date = [DateTime]::ParseExact($split[1], "yyyy-MM-dd HH:mm:ss zzz", $null)
        }
    }
}

function Assert-ReleaseShouldBeConsidered($thisReleaseTag, $ignoreReleases) {
    return !($ignoreReleases | Where-Object { $thisReleaseTag -Like $_ })
}

<#
.SYNOPSIS
Calculate a set of release metrics for a given set of releases
#>
function Get-ReleaseMetrics($releases, $subDirs, $startDate, $ignoreReleases) {
    $thisRelease = $releases[0]
    for ($i = 1; $i -lt $releases.Count; $i++) {
        $lastRelease = $releases[$i]
        #Write-Host $lastRelease

        if (Assert-ReleaseShouldBeConsidered $ThisRelease.Tag $ignoreReleases) {
            $commitAges = Get-CommitsBetweenTags $lastRelease.Tag $thisRelease.Tag $subDirs | Foreach-Object -Process { $thisRelease.Date - $_.Date } | Sort-Object
            if ($commitAges.Count -gt 0) {
                $mid = [Math]::Floor($commitAges.Count / 2)
                $AverageCommitAge = $commitAges[$mid]
            }
            else {
                $AverageCommitAge = $null;
            }

            [PSCustomObject]@{
                From             = $lastRelease.Tag;
                To               = $thisRelease.Tag;
                FromDate         = $lastRelease.Date;
                ToDate           = $thisRelease.Date;
                Interval         = $thisRelease.Date - $lastRelease.Date;
                IsFix            = $thisRelease.IsFix;
                AverageCommitAge = $AverageCommitAge;
            }
        }

        if ($lastRelease.Date -le $startDate) {
            break
        }

        $thisRelease = $lastRelease
    }
}

<#
.SYNOPSIS
Calculate the 4 key metrics aka Accelerate metrics for a repo

.DESCRIPTION
Calculate the 4 key metrics aka Accelerate metrics for a repo

#>
function global:Get-ReleaseMetricsForCheckout {
    [CmdletBinding()]
    param(
        # The path to the repo
        [Parameter(Mandatory = $true)]
        [string]$checkoutLocation,
        # The pattern for annotated tags in fnmatch format for git log
        [Parameter(Mandatory = $true)]
        [string]$releaseTagPattern,
        # The pattern for fix tags - in powershell wild card format
        [Parameter(Mandatory = $true)]
        [string]$fixTagPattern,
        # A start date to filter tags.  Only tags after this date will be used.
        [datetime]$startDate,
        # Optional, case sensitive. Filters commits to a particular set of sub directories for use in mono-repos
        [string[]]$repoSubDirs = @(""),
        # Optional. How many months back to report on
        [int]$lookbackMonths = 12,
        # Optional. Release/s to exclude from lead time analysis
        [string[]] $ignoreReleases = @("")
    )
    Push-Location $checkoutLocation

    $releases = Get-Releases $releaseTagPattern $fixTagPattern
    Get-ReleaseMetrics $releases $repoSubDirs $startDate $ignoreReleases

    Pop-Location
}

function global:Get-AverageReleaseMetrics {
    [CmdletBinding()]
    param(
        # Pre-processed release metrics
        [PSCustomObject[]]$releaseMetrics,
        # Optional. How many months back to report on
        [int]$lookbackMonths = 12,
        # Optional. How large a rolling window to use
        [int]$windowSizeDays = 30,
        # Optional. The interval between windows
        [int]$windowIntervalDays = 7
    )    
    $now = (Get-Date)
    $earliestDate = $now.AddMonths(-$lookbackMonths)

    for ($endDate = $now; $endDate -gt $earliestDate; $endDate = $endDate.AddDays(-$windowIntervalDays)) {
        $startDate = $endDate.AddDays(-$windowSizeDays)
        $lookbackReleases = @($releaseMetrics | Where-Object { $_.ToDate -ge $startDate -AND $_.ToDate -le $endDate })

        Get-AverageMetricsForPeriod $lookbackReleases $endDate
    }
}

<#
.SYNOPSIS
Generate an HTML report showing the Four Key Metrics from the result of Get-FourKeyMetrics

.DESCRIPTION
Generate an HTML report showing the Four Key Metrics from the result of Get-FourKeyMetrics

#>
function global:New-FourKeyMetricsReport {
    [CmdletBinding()]
    param(
        # The output of Get-FourKeyMetrics
        [Parameter(Mandatory = $true)]
        $metrics,
        # Product name to show in the report
        [Parameter(Mandatory = $true)]
        [string]$productName,
        # The text to display in the window size caption
        [Parameter(Mandatory = $true)]
        [string]$windowSize,
        # Optional. Location for the output file to be created at
        [string]$outFilePath = "."
    )

    $reportStartDate = $metrics[0].EndDate
    $reportEndDate = $metrics[-1].EndDate
    $report = New-Item -Path $outFilePath -Name $productName'.html' -Force
    $data = ($metrics | ForEach-Object { ConvertTo-JsonWithJavascript $_ }) -join ",`r`n"
    Get-Content "$PSScriptRoot\FourKeyMetricsTemplate.html" -Raw | 
    ForEach-Object { 
        $_ -replace "REPLACEME", ($data) `
            -replace "REPLACEREPO", $productName `
            -replace "REPLACEWINDOWSIZE", $windowSize `
            -replace "REPORTSTARTDATE", "new Date($(DateTimeToTimestamp($reportStartDate)))" `
            -replace "REPORTENDDATE", "new Date($(DateTimeToTimestamp($reportEndDate)))"
    } |
    Out-File $report -Encoding ASCII -Force
    return $report
}

function ConvertTo-JsonWithJavascript($period) {
    "[new Date($(DateTimeToTimestamp($period.EndDate))), $(ValueOrNull($period.DeploymentFrequencyDays)), $(ValueOrNull($period.LeadTimeDays)), $(ValueOrNull($period.FailRate)), $(ValueOrNull($period.MttrHours))]"
}

function ValueOrNull($value) {
    if ($null -eq $value) { "null" } else { $value }
}

function DateTimeToTimestamp($datetime) {
    return [Math]::Floor(1000 * (Get-Date -Date $datetime -UFormat %s))
}

<#
.SYNOPSIS
Creates a zip of the provided HTML report, and optionally uploads it to Octopus Deploy

.DESCRIPTION
Creates a zip file of the provided HTML report, ready to be saved as a TeamCity artefact
(done by consumer build scripts to avoid coupling this part of the system to TeamCity).
If the OctopusFeedApiKey is specified, this file is also uploaded to Octopus Deploy,
enabling ITOps to distibute it to internal systems (including http://acceleratemetrics.red-gate.com/).

#>
function global:Publish-FourKeyMetricsReport {
    [CmdletBinding()]
    param(
        # The output of New-FourKeyMetricsReport
        [Parameter(Mandatory = $true)]
        $reportFile,
        # Name to use for the Octopus Package. Recommend 'FourKeyMetrics-[ProductName]'.
        [Parameter(Mandatory = $true)]
        [string]$packageName,
        # Optional. API key for Octopus Deploy. $null/empty to skip publishing to Octopus
        [string]$OctopusFeedApiKey,
        # Semver-compatible version number for the Octopus package.
        [Parameter(Mandatory = $true)]
        [string]$versionNumber
    )

    $outputZip = "$($packageName -replace '\s', '').$($versionNumber).zip"

    Compress-Archive -Path $reportFile -CompressionLevel Optimal -DestinationPath $outputZip -Force

    if ($OctopusFeedApiKey) {
        try {
            $packagePath = Resolve-Path $outputZip
            $wc = new-object System.Net.WebClient
            $wc.UploadFile("https://octopus.red-gate.com/api/packages/raw?apiKey=$($OctopusFeedApiKey)", $packagePath) | Out-Null
        }
        catch {
            Write-Error  $_
            throw
        }
    }
}

<#
.SYNOPSIS
Build and publish a new Four Key Metrics report

.DESCRIPTION
Fascade around Get-FourKeyMetrics, New-FourKetMetricsReport, and Publsh-FourKeyMetricsReport

#>
function global:Invoke-FourKeyMetricsReportGeneration {
    [CmdletBinding()]
    param(
        # Optional. The API key of the Octopus Deploy server to push packages to. $null means don't publish to Octopus
        [string] $OctopusFeedApiKey,
        # The location of the checked out repository to analyse
        [Parameter(Mandatory = $true)]
        [string] $CheckoutLocation,
        # Name of the product we are reporting on (used as a label in reports)
        [Parameter(Mandatory = $true)]
        [string] $ProductName,
        # The pattern for annotated tags in fnmatch format for git log (default: gitflow)
        [string] $ReleaseTagPattern = "(\d+)\.(\d+)\.0",
        # The pattern for fix tags - in powershell wild card format (default: gitflow)
        [string] $FixTagPattern = "(\d+)\.(\d+)\.[1-99]", 
        # Name for the report package we will deploy to Octopus
        [string] $ReportPackageName,
        # Version number to publish the report under
        [string] $ReportVersionNumber,
        # Optional. Filters commits to a particular set of sub directories for the product we are interested in
        [string[]] $RepoSubDirs = (""),
        # Optional. A start date to filter tags.  Only tags after this date will be used.
        [datetime] $StartDate = "01/01/2019",
        # Optional. How many months back to report on
        [int] $LookbackMonths = 12,
        # Optional. The size (in days) of the rolling window used for metric averaging
        [int] $WindowSizeDays = 30,
        # Optional. The interval (in days) between each point in the graph
        [int] $WindowIntervalDays = 7,
        # Optional. Location for report files to be created
        [string] $OutFilePath = ".",
        # Optional. Release/s to exclude from lead time analysis
        [string[]] $ignoreReleases = @("")
    )

    $releaseMetrics = Get-ReleaseMetricsForCheckout `
        -checkoutLocation $CheckoutLocation `
        -releaseTagPattern $ReleaseTagPattern `
        -fixTagPattern $FixTagPattern `
        -startDate $StartDate `
        -repoSubDirs $RepoSubDirs `
        -lookbackMonths $LookbackMonths `
        -ignoreReleases $ignoreReleases

    $averageReleaseMetrics = Get-AverageReleaseMetrics `
        -lookbackMonths $LookbackMonths `
        -releaseMetrics $releaseMetrics `
        -windowSizeDays $WindowSizeDays `
        -windowIntervalDays $WindowIntervalDays

    $reportFile = New-FourKeyMetricsReport -metrics $averageReleaseMetrics -productName $ProductName -outFilePath $OutFilePath -windowSize "$windowSizeDays days"

    if (PublishCredentialsProvided($OctopusFeedApiKey, $ReportPackageName, $ReportVersionNumber)) {
        Publish-FourKeyMetricsReport -reportFile $reportFile -packageName $ReportPackageName -octopusFeedApiKey $OctopusFeedApiKey -versionNumber $ReportVersionNumber
    }

    return $reportFile
}

function PublishCredentialsProvided($OctopusFeedApiKey, $ReportPackageName, $ReportVersionNumber) {
    if ($ReportPackageName -eq '' -Or $OctopusFeedApiKey -eq '' -Or $ReportVersionNumber -eq '') {
        Write-Warning "Publish credentials not provided - skipping publish step"
        $false
    }
    else { $true }
}

<#
.SYNOPSIS
Write out a list of releases and all work that was first included in that release
#>
function Measure-LeadTimeData {
    [CmdletBinding()]
    param(
        # The location of the checked out repository to analyse
        [Parameter(Mandatory = $true)]
        [string] $CheckoutLocation,
        # The pattern for annotated tags in fnmatch format for git log
        [Parameter(Mandatory = $true)]
        [string] $ReleaseTagPattern,
        # Optional. A start date to filter tags.  Only tags after this date will be used.
        [datetime] $StartDate
    )
    Push-Location $checkoutLocation

    $releases = Get-Releases $releaseTagPattern ""

    $thisRelease = $releases[0]
    for ($i = 1; $i -lt $releases.Count; $i++) {
        $lastRelease = $releases[$i]

        Write-Host $lastRelease.Tag + "|"+ $thisRelease.Tag

        $commitsInRelease = git log --pretty=format:"%s" --grep="Merge branch 'release/*.*.*'" "$($lastRelease.Tag)..$($thisRelease.Tag)"

        $message = "$($LastRelease.Tag) -> $($thisRelease.Tag) Released $($ThisRelease.Date)"
        Add-Content LeadTimeData.txt $message
        foreach ($commit in $commitsInRelease) {
            #Write-Host $commit
            Add-Content LeadTimeData.txt $commit
        }
        Add-Content LeadTimeData.txt " "

        if ($lastRelease.Date -le $startDate) {
            break
        }

        $thisRelease = $lastRelease
    }

    Pop-Location
}
