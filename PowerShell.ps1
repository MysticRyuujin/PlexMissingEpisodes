# TheTVDB Authentication Information
$TheTVDBAuthentication = @{
    "apikey" = ""
    "userkey" = "" # Account Identifier
    "username" = ""
}

# Plex Server Information
$PlexServer = "http://localhost:32400"
$PlexUsername = ''
$PlexPassword = ''

# Ignore Plex Certificate Issues
if ($PlexServer -match "https") {
    add-type "using System.Net; using System.Security.Cryptography.X509Certificates; public class TrustAllCertsPolicy : ICertificatePolicy { public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) { return true; } }"
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
}
		
# Try to authenticate with TheTVDB API to get a token
try {
    $TheTVDBToken = (Invoke-RestMethod -Uri "https://api.thetvdb.com/login" -Method Post -Body ($TheTVDBAuthentication | ConvertTo-Json) -ContentType 'application/json').token
} catch {
    Write-Host -ForegroundColor Red "Failed to get TheTVDB API Token:"
    Write-Host -ForegroundColor Red $_
    break
}

# Create TheTVDB API Headers
$TVDBHeaders = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$TVDBHeaders.Add("Accept", "application/json")
$TVDBHeaders.Add("Authorization", "Bearer $TheTVDBToken")

# Create Plex Headers
$PlexHeaders = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$PlexHeaders.Add("Authorization","Basic $([System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$PlexUsername`:$PlexPassword")))")
$PlexHeaders.Add("X-Plex-Client-Identifier","MissingTVEpisodes")
$PlexHeaders.Add("X-Plex-Product","PowerShell")
$PlexHeaders.Add("X-Plex-Version","V1")

# Try to get Plex Token
try {
    $PlexToken = (Invoke-RestMethod -Uri 'https://plex.tv/users/sign_in.json' -Method Post -Headers $PlexHeaders).user.authToken
    $PlexHeaders.Add("X-Plex-Token",$PlexToken)
    $PlexHeaders.Remove("Authorization")
} catch {
    Write-Host -ForegroundColor Red "Failed to get Plex Auth Token:"
    Write-Host -ForegroundColor Red $_
    break
}

# Try to get the Library IDs for TV Shows
try {
    $TVKeys = ((Invoke-RestMethod -Uri "$PlexServer/library/sections" -Headers $PlexHeaders).MediaContainer.Directory | ? { $_.type -eq "show" }).key
} catch {
    Write-Host -ForegroundColor Red "Failed to get Plex Library Sections:"
    if ($_.Exception.Response.StatusDescription -eq "Unauthorized") {
        Write-Host -ForegroundColor Red "Ensure that your source IP is configured under the `"List of IP addresses and networks that are allowed without auth`" setting"
    } else {
        Write-Host -ForegroundColor Red $_
    }
    break
}

# Get all RatingKeys
$RatingKeys = New-Object System.Collections.ArrayList
ForEach ($TVKey in $TVKeys) {
    $SeriesInfo = (Invoke-RestMethod -Uri "$PlexServer/library/sections/$TVKey/all/" -Headers $PlexHeaders).MediaContainer.Directory
    ForEach ($Series in $SeriesInfo) {
        [void]$RatingKeys.Add($Series.ratingKey)
    }
}
$RatingKeys = $RatingKeys | Sort -Unique

# Get all Show Data
$PlexShows = @{}
ForEach ($RatingKey in $RatingKeys) {
    $ShowData = (Invoke-RestMethod -Uri "$PlexServer/library/metadata/$RatingKey/" -Headers $PlexHeaders).MediaContainer.Directory
    $GUID = $ShowData.guid -replace ".*//(\d+).*",'$1'
    if ($PlexShows.ContainsKey($GUID)) {
        [void]$PlexShows[$GUID]["ratingKeys"].Add($RatingKey)
    } else {
        [void]$PlexShows.Add($GUID,@{
            "title" = $ShowData.title
            "ratingKeys" = New-Object System.Collections.ArrayList
            "seasons" = @{}
        })
        [void]$PlexShows[$GUID]["ratingKeys"].Add($ShowData.ratingKey)
    }
}
ForEach ($GUID in $PlexShows.Keys) {
    ForEach ($RatingKey in $PlexShows[$GUID]["ratingKeys"]) {
        $Episodes = (Invoke-RestMethod -Uri "$PlexServer/library/metadata/$RatingKey/allLeaves" -Headers $PlexHeaders).MediaContainer.Video
        $Seasons = $Episodes.parentIndex | Sort -Unique
        ForEach ($Season in $Seasons) {
            if (-not ($PlexShows[$GUID]["seasons"] -contains $Season)) {
                $PlexShows[$GUID]["seasons"][$Season] = New-Object System.Collections.ArrayList
            }
        }
        ForEach ($Episode in $Episodes) {
            [void]$PlexShows[$GUID]["seasons"][$Episode.parentIndex].Add(@{$Episode.index = $Episode.title})
        }
    }
}

# Missing Episodes
$Missing = @{}
ForEach ($GUID in $PlexShows.Keys) {
    $Page = 1
    try {
        $Results = (Invoke-RestMethod -Uri "https://api.thetvdb.com/series/$GUID/episodes?page=$page" -Headers $TVDBHeaders)
        $Episodes = $Results.data
        while ($Page -lt $Results.links.last) {
            $Page++
            $Results = (Invoke-RestMethod -Uri "https://api.thetvdb.com/series/$GUID/episodes?page=$page" -Headers $TVDBHeaders)
            $Episodes += $Results.data
        }
    } catch {
        $Episodes = $null
    }
    ForEach ($Episode in $Episodes) {
        if ($Episode.airedSeason -eq 0) { continue }
        if (-not $Episode.firstAired) { continue }
        if ((Get-Date).AddDays(-1) -lt (Get-Date $Episode.firstAired)) { continue }
        if (-not ($PlexShows[$GUID]["seasons"][$Episode.airedSeason.ToString()].Values -contains $Episode.episodeName)) {
	    if (-not ($PlexShows[$GUID]["seasons"][$Episode.airedSeason.ToString()].Keys -contains $Episode.airedEpisodeNumber)) {
                if (-not $Missing.ContainsKey($PlexShows[$GUID]["title"])) {
                    $Missing[$PlexShows[$GUID]["title"]] = New-Object System.Collections.ArrayList
                }
                [void]$Missing[$PlexShows[$GUID]["title"]].Add(@{
                    "airedSeason" = $Episode.airedSeason.ToString()
                    "airedEpisodeNumber" = $Episode.airedEpisodeNumber.ToString()
                    "episodeName" = $Episode.episodeName
                })
	    }
        }
    }
}

ForEach ($Show in $Missing.Keys) {
    $Seasons = $Missing[$Show].airedSeason | Sort -Unique
    ForEach ($Season in $Seasons) {
        $Episodes = $Missing[$Show] | ? { $_.airedSeason -eq $Season }
        ForEach ($Episode in $Episodes) {
            "{0} S{1:00}E{2:00} - {3}" -f $Show,[int]$Season,[int]$Episode.airedEpisodeNumber,$Episode.episodeName
        }
    }
}
