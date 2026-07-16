# ============================================================================
# MIGRATED TO TheTVDB API v4
# ============================================================================
# Key changes from v3 to v4:
# - Authentication: Only requires 'apikey', optional 'pin' for user keys
# - Base URL: https://api4.thetvdb.com/v4/ 
# - Episode endpoints: /series/{id}/episodes/default with pagination
# - Field mapping: seasonNumber (was airedSeason), number (was airedEpisodeNumber), 
#   name (was episodeName), aired (was firstAired)
# - Token response: data.token (was token)
# - Episode data: data.episodes (was data)
# ============================================================================

[CmdletBinding()]
param(
    [Parameter(HelpMessage = "TheTVDB API Key")]
    [string]$ApiKey,
    
    [Parameter(HelpMessage = "TheTVDB Subscriber PIN (optional)")]
    [string]$Pin,
    
    [Parameter(HelpMessage = "Plex Server URL (e.g., http://server:32400)")]
    [string]$PlexServer,
    
    [Parameter(HelpMessage = "Plex Username")]
    [string]$PlexUsername,
    
    [Parameter(HelpMessage = "Plex Password")]
    [string]$PlexPassword,

    [Parameter(HelpMessage = "Plex Authentication Token (optional - bypasses login)")]
    [string]$PlexToken,
    
    [Parameter(HelpMessage = "Single show filter - process only this show (supports partial matching)")]
    [string]$SingleShowFilter,
    
    [Parameter(HelpMessage = "Comma-separated list of show names to ignore")]
    [string[]]$IgnoreShows,
    
    [Parameter(HelpMessage = "Output file path to save results (optional - if not specified, output goes to console)")]
    [string]$OutputFile,
    
    [Parameter(HelpMessage = "Use simple output format: Show Name (Year) - SXXEXX - Title")]
    [switch]$SimpleOutput,
    
    [Parameter(HelpMessage = "Include Season 0 (extras/specials) in results")]
    [switch]$IncludeExtras,

    [Parameter(HelpMessage = "Number of days to keep TVDB data cached (default: 1)")]
    [int]$CacheRetentionDays = 1,

    [Parameter(HelpMessage = "Force refresh of TVDB data, bypassing cache")]
    [switch]$ForceRefresh
)

# ============================================================================
# Configuration Variables (can be overridden by parameters)
# ============================================================================

# TheTVDB Authentication Information for API v4
# API Key is required, PIN is optional (only needed for user-supported keys)
$TheTVDBAuthentication = @{
    "apikey" = if ($ApiKey) { $ApiKey } else { "" }
    "pin"    = if ($Pin) { $Pin } else { "" } # Optional Subscriber PIN (only needed for user-supported keys)
}

# Plex Server Information - use parameters if provided, otherwise fall back to defaults
if (-not $PlexServer) { $PlexServer = "" }
if (-not $PlexUsername) { $PlexUsername = '' }
if (-not $PlexPassword) { $PlexPassword = '' }

# Array of show names to ignore, example included
$IgnoreList = if ($IgnoreShows -and $IgnoreShows.Count -gt 0) {
    [system.collections.generic.list[string]]::new($IgnoreShows)
}
else {
    [system.collections.generic.list[string]]::new()
}

# Single show filter - if specified, only this show will be processed (supports partial matching)
# Leave empty to process all shows (subject to IgnoreList)
# Examples: "Jeopardy!", "The Office", "Breaking Bad"
if (-not $SingleShowFilter) { $SingleShowFilter = "" }

# Cache related variables
$CacheFile = Join-Path $PSScriptRoot "tvdb_cache.json"
$TVDBCache = @{ }
if (Test-Path $CacheFile) {
    try {
        # ConvertFrom-Json -AsHashtable requires PowerShell 6+. Build the
        # top-level lookup explicitly so caching also works on PowerShell 5.1.
        $CacheData = Get-Content $CacheFile -Raw | ConvertFrom-Json
        foreach ($CacheProperty in $CacheData.PSObject.Properties) {
            $TVDBCache[$CacheProperty.Name] = $CacheProperty.Value
        }
        Write-Host "Loaded TVDB cache from $CacheFile" -ForegroundColor Gray
    }
    catch {
        Write-Warning "Failed to load TVDB cache, starting fresh."
    }
}

# Function to parse episode ranges (e.g., "S02E01-02" -> episodes 1 and 2)
function Get-EpisodeNumbers {
    param([string]$EpisodeString)
    
    $Episodes = @()
    
    if (-not $EpisodeString) { return $Episodes }

    # Handle range format like "S02E01-02" or "S02E01-E02"
    if ($EpisodeString -match 'S\d+E(\d+)[-]E?(\d+)') {
        $StartEp = [int]$matches[1]
        $EndEp = [int]$matches[2]
        if ($StartEp -le $EndEp) {
            for ($i = $StartEp; $i -le $EndEp; $i++) {
                $Episodes += $i
            }
        }
    }
    # Handle single episode format like "S02E01" or "S2021E11"
    elseif ($EpisodeString -match 'S\d+E(\d+)') {
        $Episodes += [int]$matches[1]
    }
    # Handle just E## or e## (common in titles/filenames after season identified)
    elseif ($EpisodeString -match '(?i)(?:^|[\s\.\-_])E(\d+)(?:$|[\s\.\-_])') {
        $Episodes += [int]$matches[1]
    }
    # Handle generic "Episode ##"
    elseif ($EpisodeString -match '(?i)Episode\s+(\d+)') {
        $Episodes += [int]$matches[1]
    }
    # Handle matching patterns like 1x01
    elseif ($EpisodeString -match '\d+x(\d+)') {
        $Episodes += [int]$matches[1]
    }
    
    return $Episodes
}

# Normalize Plex and TVDB dates before comparing them. Plex normally returns
# yyyy-MM-dd strings, but XML deserialization can produce DateTime values.
function Get-NormalizedAiredDate {
    param($DateValue)

    if (-not $DateValue) { return $null }

    $DateText = [string]$DateValue
    if ($DateText -match '^(\d{4}-\d{2}-\d{2})') {
        return $matches[1]
    }

    try {
        return ([datetime]$DateValue).ToString('yyyy-MM-dd')
    }
    catch {
        return $null
    }
}

# Function to ensure console stays open when run directly
function Wait-ForUserInput {
    # Clear any remaining progress bars
    Write-Progress -Activity "Completed" -Completed
    Write-Host "`nPress any key to exit..." -ForegroundColor Green
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# Set error action preference to stop on errors
$ErrorActionPreference = "Stop"

# Ignore Plex Certificate Issues
if ($PlexServer -match "https") {
    Add-Type "using System.Net; using System.Security.Cryptography.X509Certificates; public class TrustAllCertsPolicy : ICertificatePolicy { public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) { return true; } }"
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
}

# Validate required configuration
if ([string]::IsNullOrWhiteSpace($TheTVDBAuthentication.apikey)) {
    Write-Host -ForegroundColor Red "ERROR: TheTVDB API key is required. Please fill in the apikey."
    if ($Host.Name -eq "ConsoleHost" -and [Environment]::UserInteractive) {
        Wait-ForUserInput
    }
    exit 1
}

if ([string]::IsNullOrWhiteSpace($PlexServer)) {
    Write-Host -ForegroundColor Red "ERROR: Plex Server URL is required."
    if ($Host.Name -eq "ConsoleHost" -and [Environment]::UserInteractive) {
        Wait-ForUserInput
    }
    exit 1
}
		
# Main execution wrapped in try-catch
try {
    Write-Host "Starting Plex Missing Episodes Check..." -ForegroundColor Green
    
    # Try to authenticate with TheTVDB API v4 to get a token
    try {
        # Prepare the authentication payload - remove pin if empty
        $authPayload = @{ "apikey" = $TheTVDBAuthentication.apikey }
        if (-not [string]::IsNullOrWhiteSpace($TheTVDBAuthentication.pin)) {
            $authPayload["pin"] = $TheTVDBAuthentication.pin
        }
        
        $TheTVDBToken = (Invoke-RestMethod -Uri "https://api4.thetvdb.com/v4/login" -Method Post -Body ($authPayload | ConvertTo-Json) -ContentType 'application/json').data.token
        Write-Host "Successfully authenticated with TheTVDB API v4" -ForegroundColor Green
    }
    catch {
        Write-Host -ForegroundColor Red "Failed to get TheTVDB API Token:"
        Write-Host -ForegroundColor Red $_
        throw
    }

    # Create TheTVDB API Headers
    $TVDBHeaders = [System.Collections.Generic.Dictionary[[String], [String]]]::new()
    $TVDBHeaders.Add("Accept", "application/json")
    $TVDBHeaders.Add("Authorization", "Bearer $TheTVDBToken")

    # Create Plex Headers
    $PlexHeaders = [System.Collections.Generic.Dictionary[[String], [String]]]::new()
    $PlexHeaders.Add("X-Plex-Client-Identifier", "MissingTVEpisodes")
    $PlexHeaders.Add("X-Plex-Product", "PowerShell")
    $PlexHeaders.Add("X-Plex-Version", "V1")

    if (-not [string]::IsNullOrWhiteSpace($PlexToken)) {
        $PlexHeaders.Add("X-Plex-Token", $PlexToken)
        Write-Host "Using provided Plex Token" -ForegroundColor Green
    }
    else {
        $PlexHeaders.Add("Authorization", "Basic $([System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$PlexUsername`:$PlexPassword")))")

        # Try to get Plex Token
        try {
            $PlexToken = (Invoke-RestMethod -Uri 'https://plex.tv/users/sign_in.json' -Method Post -Headers $PlexHeaders).user.authToken
            $PlexHeaders.Add("X-Plex-Token", $PlexToken)
            [void]$PlexHeaders.Remove("Authorization")
            Write-Host "Successfully authenticated with Plex" -ForegroundColor Green
        }
        catch {
            Write-Host -ForegroundColor Red "Failed to get Plex Auth Token:"
            Write-Host -ForegroundColor Red $_
            throw
        }
    }

    # Try to get the Library IDs for TV Shows
    try {
        $TVKeys = ((Invoke-RestMethod -Uri "$PlexServer/library/sections" -Headers $PlexHeaders).MediaContainer.Directory | Where-Object type -eq "show").key
        Write-Host "Found $($TVKeys.Count) TV library section(s)" -ForegroundColor Green
    }
    catch {
        Write-Host -ForegroundColor Red "Failed to get Plex Library Sections:"
        if ($_.Exception.Response.StatusDescription -eq "Unauthorized") {
            Write-Host -ForegroundColor Red "Ensure that your source IP is configured under the 'List of IP addresses and networks that are allowed without auth' setting"
        }
        else {
            Write-Host -ForegroundColor Red $_
        }
        throw
    }

    # Get all RatingKeys
    $RatingKeys = [System.Collections.Generic.List[int]]::new()
    $ProcessedShowCount = 0
    ForEach ($TVKey in $TVKeys) {
        $SeriesInfo = (Invoke-RestMethod -Uri "$PlexServer/library/sections/$TVKey/all/" -Headers $PlexHeaders).MediaContainer.Directory
        ForEach ($Series in $SeriesInfo) {
            $ShouldProcess = $false
            
            # Check if we should process this show
            if (-not [string]::IsNullOrWhiteSpace($SingleShowFilter)) {
                # Single show mode - only process shows matching the filter
                if ($Series.title -like "*$SingleShowFilter*") {
                    $ShouldProcess = $true
                    Write-Host "Found matching show: '$($Series.title)'" -ForegroundColor Cyan
                }
            }
            else {
                # Normal mode - process all shows except those in ignore list
                if ($null -eq $IgnoreList -or -not $IgnoreList.Contains($Series.title)) {
                    $ShouldProcess = $true
                }
            }
            
            if ($ShouldProcess) {
                [void]$RatingKeys.Add($Series.ratingKey)
                $ProcessedShowCount++
            }
        }
    }
    $RatingKeys = $RatingKeys | Sort-Object -Unique
    
    if (-not [string]::IsNullOrWhiteSpace($SingleShowFilter)) {
        Write-Host "Single show filter '$SingleShowFilter' - Found $($RatingKeys.Count) matching show(s) to process" -ForegroundColor Green
    }
    else {
        Write-Host "Found $($RatingKeys.Count) TV shows to process" -ForegroundColor Green
    }

    # Get all Show Data
    $PlexShows = @{ }
    $InvalidShows = @()
    $Progress = 0
    ForEach ($RatingKey in $RatingKeys) {
        $ShowData = (Invoke-RestMethod -Uri "$PlexServer/library/metadata/$RatingKey/" -Headers $PlexHeaders).MediaContainer.Directory
        $Progress++
        
        # Ensure ShowData and title exist before using in Write-Progress
        if ($ShowData -and $ShowData.title) {
            Write-Progress -Activity "Collecting Show Data" -Status $ShowData.title -PercentComplete ($Progress / $RatingKeys.Count * 100)
        }
        else {
            Write-Progress -Activity "Collecting Show Data" -Status "Processing..." -PercentComplete ($Progress / $RatingKeys.Count * 100)
        }
        
        # Extract GUID - handle both old and new Plex agents
        $GUID = $null
        
        # Try to extract TVDB ID from new agent XML format
        try {
            if ($ShowData.InnerXml -match '<Guid id="tvdb://(\d+)"') {
                $GUID = $matches[1]
            }
        }
        catch {
            # Fallback: leave $GUID as $null
        }
        # Fallback to old format
        if ($ShowData.guid -and !$GUID) {
            if ($ShowData.guid -match '://.*?/(\d+)') {
                $GUID = $matches[1]
            }
        }
        
        # Only process if we have a valid numeric GUID and valid ShowData
        if ($GUID -match '^\d+$' -and $ShowData -and $ShowData.title) {
            if ($PlexShows.ContainsKey($GUID)) {
                if ($PlexShows[$GUID]["ratingKeys"]) {
                    [void]$PlexShows[$GUID]["ratingKeys"].Add($RatingKey)
                }
            }
            else {
                [void]$PlexShows.Add($GUID, @{
                        "title"      = $ShowData.title
                        "year"       = if ($ShowData.year -and $null -ne $ShowData.year -and $ShowData.year -ne "") { $ShowData.year } else { $null }
                        "ratingKeys" = [System.Collections.Generic.List[int]]::new()
                        "seasons"    = @{ }
                    }
                )
                [void]$PlexShows[$GUID]["ratingKeys"].Add($ShowData.ratingKey)
            }
        }
        else {
            if ($ShowData -and $ShowData.title) {
                # Add to invalid shows - include the GUID if we found one but it was invalid
                $Reason = if (!$GUID) { "No TVDB ID found" } else { "Invalid TVDB ID: $GUID" }
                $InvalidShows += @{ Title = $ShowData.title; Reason = $Reason }
            }
        }
    }

    Write-Host "Collected data for $($PlexShows.Count) shows with valid TVDB IDs" -ForegroundColor Green
    
    if ($InvalidShows.Count -gt 0) {
        Write-Host "The following $($InvalidShows.Count) shows were skipped because a valid TVDB ID could not be found:" -ForegroundColor Yellow
        foreach ($Show in ($InvalidShows | Sort-Object Title)) {
            Write-Host "   • $($Show.Title) ($($Show.Reason))" -ForegroundColor Gray
        }
        Write-Host "   (Note: Ensure these shows are matched using the 'Plex TV Series' or 'TheTVDB' agent)" -ForegroundColor Gray
    }

    # Get Season data from Show Data
    $Progress = 0
    ForEach ($GUID in $PlexShows.Keys) {
        $Progress++
        
        # Ensure the show title exists before using it
        $ShowTitle = if ($PlexShows[$GUID]["title"]) { $PlexShows[$GUID]["title"] } else { "Unknown Show" }
        Write-Progress -Activity "Collecting Season Data" -Status $ShowTitle -PercentComplete ($Progress / $PlexShows.Count * 100)
        
        ForEach ($RatingKey in $PlexShows[$GUID]["ratingKeys"]) {
            $Episodes = (Invoke-RestMethod -Uri "$PlexServer/library/metadata/$RatingKey/allLeaves" -Headers $PlexHeaders).MediaContainer.Video
            
            # Safe check for episodes
            if ($null -eq $Episodes) {
                Write-Host "Warning: No episodes found for $ShowTitle (RatingKey: $RatingKey)" -ForegroundColor Yellow
                continue
            }
            
            $Seasons = $Episodes.parentIndex | Sort-Object -Unique
            ForEach ($Season in $Seasons) {
                # Cast to int to ensure type consistency with later lookups
                $SeasonInt = [int]$Season
                if (!($PlexShows[$GUID]["seasons"].ContainsKey($SeasonInt))) {
                    $PlexShows[$GUID]["seasons"][$SeasonInt] = [System.Collections.Generic.List[hashtable]]::new()
                }
            }
            # Track episodes with missing metadata for this show
            $MissingMetadataCount = 0
            $SampleMissingEpisodes = @()
            
            ForEach ($Episode in $Episodes) {
                # Try to determine episode numbers and aired date
                $EpisodeNumbers = @()
                $FilenameEpisodeNumbers = @()
                $FileNames = @()
                $AiredDate = if ($Episode.originallyAvailableAt) { $Episode.originallyAvailableAt } else { $null }

                # 1. Inspect every media filename for episode ranges and dates.
                if ($Episode.Media -and $Episode.Media.Part -and $Episode.Media.Part.file) {
                    foreach ($MediaPart in @($Episode.Media.Part)) {
                        if ($MediaPart.file) {
                            $FileName = [System.IO.Path]::GetFileNameWithoutExtension([string]$MediaPart.file)
                            $FileNames += $FileName
                            $FilenameEpisodeNumbers += @(Get-EpisodeNumbers -EpisodeString $FileName)

                            # Try to extract date from filename if missing from Plex metadata
                            if (!$AiredDate -and $FileName -match '(\d{4}[-\.]\d{2}[-\.]\d{2})') {
                                $AiredDate = $matches[1] -replace '\.', '-'
                            }
                        }
                    }

                    $FilenameEpisodeNumbers = @($FilenameEpisodeNumbers | Sort-Object -Unique)
                }

                # A filename range describes every episode in the file. Otherwise,
                # prefer Plex's index and use a single filename number as fallback.
                if ($FilenameEpisodeNumbers.Count -gt 1) {
                    $EpisodeNumbers = $FilenameEpisodeNumbers
                }
                elseif ($Episode.index) {
                    $EpisodeNumbers = @([int]$Episode.index)
                }
                elseif ($FilenameEpisodeNumbers.Count -eq 1) {
                    $EpisodeNumbers = $FilenameEpisodeNumbers
                }

                # 2. Try to extract from title if still no numbers
                if ($EpisodeNumbers.Count -eq 0 -and $Episode.title) {
                    $EpisodeNumbers = Get-EpisodeNumbers -EpisodeString $Episode.title
                }

                # 3. Handle daily shows: Year in parentIndex + Month-Day in title/filename
                if (!$AiredDate -and $Episode.parentIndex -gt 1900) {
                    if ($Episode.title -match '(\d{2})[-\.](\d{2})') {
                        $AiredDate = "$($Episode.parentIndex)-$($matches[1])-$($matches[2])"
                    }
                    else {
                        foreach ($FileName in $FileNames) {
                            if ($FileName -match '(\d{2})[-\.](\d{2})') {
                                $AiredDate = "$($Episode.parentIndex)-$($matches[1])-$($matches[2])"
                                break
                            }
                        }
                    }
                }

                if ($AiredDate) {
                    $AiredDate = Get-NormalizedAiredDate -DateValue $AiredDate
                }

                # Check if we still have nothing
                if ((!$Episode.parentIndex) -or ($EpisodeNumbers.Count -eq 0 -and !$AiredDate)) {
                    $MissingMetadataCount++
                    # Collect sample episodes for reporting (limit to first 3)
                    if ($SampleMissingEpisodes.Count -lt 3) {
                        $EpisodeInfo = @{
                            title       = $Episode.title
                            parentIndex = $Episode.parentIndex
                            index       = if ($EpisodeNumbers.Count -gt 0) { $EpisodeNumbers[0] } else { $null }
                        }
                        $SampleMissingEpisodes += $EpisodeInfo
                    }
                }
                else {
                    # Add to the collection
                    $SeasonInt = [int]$Episode.parentIndex
                    
                    # Store as a structured object
                    $EpData = @{
                        numbers = $EpisodeNumbers
                        date    = $AiredDate
                        title   = $Episode.title
                    }
                    [void]$PlexShows[$GUID]["seasons"][$SeasonInt].Add($EpData)
                }
            }
            
            # Report missing metadata issues for this show
            if ($MissingMetadataCount -gt 0) {
                Write-Host -ForegroundColor Yellow "⚠️  $ShowTitle has $MissingMetadataCount episodes with missing season/episode numbers"
                if ($SampleMissingEpisodes.Count -gt 0) {
                    Write-Host -ForegroundColor Gray "   Sample episodes with issues:"
                    foreach ($SampleEp in $SampleMissingEpisodes) {
                        $SeasonInfo = if ($SampleEp.parentIndex) { "S$($SampleEp.parentIndex)" } else { "S?" }
                        $EpisodeInfo = if ($SampleEp.index) { "E$($SampleEp.index)" } else { "E?" }
                        $Title = if ($SampleEp.title) { $SampleEp.title } else { "Untitled" }
                        Write-Host -ForegroundColor Gray "   • $SeasonInfo$EpisodeInfo - $Title"
                    }
                    if ($MissingMetadataCount -gt 3) {
                        Write-Host -ForegroundColor Gray "   • ... and $($MissingMetadataCount - 3) more"
                    }
                }
            }
        }
    }

    # Missing Episodes - Use GUID as key to avoid issues with shows in multiple libraries
    $Missing = @{ }
    $Progress = 0
    ForEach ($GUID in $PlexShows.Keys) {
        $Progress++
        
        # Ensure the show title exists before using it
        $ShowTitle = if ($PlexShows[$GUID]["title"]) { $PlexShows[$GUID]["title"] } else { "Unknown Show" }
        Write-Progress -Activity "Collecting Episode Data from TheTVDB" -Status $ShowTitle -PercentComplete ($Progress / $PlexShows.Count * 100)
        
        $Page = 0
        $Episodes = $null
        $UseCache = $false
        $CacheKey = [string]$GUID

        # Check if we have valid cached data
        if (-not $ForceRefresh -and $TVDBCache.ContainsKey($CacheKey)) {
            $CachedData = $TVDBCache[$CacheKey]
            try {
                $CacheTime = [datetime]$CachedData.Timestamp
                if ((Get-Date).AddDays(-$CacheRetentionDays) -lt $CacheTime) {
                    $Episodes = $CachedData.Episodes
                    $UseCache = $true
                }
            }
            catch {
                $UseCache = $false
            }
        }

        if (-not $UseCache) {
            try {
                # API v4 uses different pagination and endpoint structure
                $Results = (Invoke-RestMethod -Uri "https://api4.thetvdb.com/v4/series/$GUID/episodes/default?page=$Page" -Headers $TVDBHeaders)
                $Episodes = $Results.data.episodes
                
                # Handle pagination if there are more pages
                while ($Results.links -and $Results.links.next) {
                    $Page++
                    $Results = (Invoke-RestMethod -Uri "https://api4.thetvdb.com/v4/series/$GUID/episodes/default?page=$Page" -Headers $TVDBHeaders)
                    if ($Results.data.episodes) {
                        $Episodes += $Results.data.episodes
                    }
                }

                # Update cache if we got results
                if ($Episodes) {
                    $TVDBCache[$CacheKey] = @{
                        Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                        Episodes  = $Episodes
                    }
                }
            }
            catch {
                Write-Warning "Failed to get Episodes for $ShowTitle (GUID: $GUID): $($_.Exception.Message)"
                $Episodes = $null
            }
        }
    
        if ($Episodes) {
            ForEach ($Episode in $Episodes) {
                
                # API v4 uses different field names: seasonNumber instead of airedSeason, number instead of airedEpisodeNumber, name instead of episodeName
                if ($null -eq $Episode.seasonNumber -or [string]::IsNullOrWhiteSpace($Episode.seasonNumber)) { continue } # Ignore episodes with blank seasons (#11)
                if ($Episode.seasonNumber -eq 0 -and -not $IncludeExtras) { continue } # Ignore Season 0 / Specials unless user requested to include them
                if (!$Episode.aired) { continue } # Ignore unaired episodes (API v4 uses 'aired' instead of 'firstAired')
                
                # Check if episode aired more than 24 hours ago
                try {
                    if ((Get-Date).AddDays(-1) -lt (Get-Date $Episode.aired)) { continue }
                }
                catch {
                    # Skip if date parsing fails
                    continue
                }
                
                # Safe season check
                $seasonKey = [int]$Episode.seasonNumber
                $TVDBAiredDate = Get-NormalizedAiredDate -DateValue $Episode.aired
                if ($null -ne $PlexShows[$GUID]["seasons"] -and $PlexShows[$GUID]["seasons"].ContainsKey($seasonKey)) {
                    $PlexSeasonData = $PlexShows[$GUID]["seasons"][$seasonKey]
                    
                    # Check if episode is missing by date, number, or name
                    $EpisodeFound = $false
                    
                    if ($null -ne $PlexSeasonData) {
                        # Date is authoritative for year-based daily-show seasons.
                        foreach ($episodeRecord in $PlexSeasonData) {
                            if ($null -ne $episodeRecord -and $episodeRecord.date -and $TVDBAiredDate) {
                                $PlexAiredDate = Get-NormalizedAiredDate -DateValue $episodeRecord.date
                                if ($PlexAiredDate -eq $TVDBAiredDate) {
                                    $EpisodeFound = $true
                                    break
                                }
                            }
                        }

                        # For year-based seasons, reject number collisions when both
                        # records have different dates. Missing dates may still fall
                        # back to the episode number.
                        if (!$EpisodeFound) {
                            foreach ($episodeRecord in $PlexSeasonData) {
                                if ($null -ne $episodeRecord -and $episodeRecord.numbers -and $episodeRecord.numbers -contains [int]$Episode.number) {
                                    $PlexAiredDate = Get-NormalizedAiredDate -DateValue $episodeRecord.date
                                    if ($seasonKey -le 1900 -or !$TVDBAiredDate -or !$PlexAiredDate) {
                                        $EpisodeFound = $true
                                        break
                                    }
                                }
                            }
                        }

                        if (!$EpisodeFound) {
                            foreach ($episodeRecord in $PlexSeasonData) {
                                if ($null -ne $episodeRecord -and $episodeRecord.title -and $Episode.name -and $episodeRecord.title -eq $Episode.name) {
                                    $EpisodeFound = $true
                                    break
                                }
                            }
                        }
                    }
                    
                    if (!$EpisodeFound) {
                        if ($null -eq $Missing[$GUID]) {
                            $Missing[$GUID] = [System.Collections.Generic.List[hashtable]]::new()
                        }
                        [void]$Missing[$GUID].Add(@{
                                "airedSeason"        = [int]$Episode.seasonNumber
                                "airedEpisodeNumber" = [int]$Episode.number
                                "episodeName"        = $Episode.name
                            })
                    }
                }
                else {
                    # Season doesn't exist in Plex, so all episodes are missing
                    if ($null -eq $Missing[$GUID]) {
                        $Missing[$GUID] = [System.Collections.Generic.List[hashtable]]::new()
                    }
                    [void]$Missing[$GUID].Add(@{
                            "airedSeason"        = [int]$Episode.seasonNumber
                            "airedEpisodeNumber" = [int]$Episode.number
                            "episodeName"        = $Episode.name
                        })
                }
            }
        }
    }

    # Build the output content
    $OutputContent = @()
    
    if ($SimpleOutput) {
        # Simple output format: Show Name (Year) - SXXEXX - Title
        if ($Missing.Keys.Count -eq 0) {
            $OutputContent += "No missing episodes found! All shows are up to date."
        }
        else {
            # Convert GUID keys to show titles and sort
            $SortedShows = $Missing.Keys | ForEach-Object {
                @{
                    GUID = $_
                    Title = $PlexShows[$_]["title"]
                }
            } | Sort-Object Title
            
            ForEach ($ShowInfo in $SortedShows) {
                $GUID = $ShowInfo.GUID
                $Show = $ShowInfo.Title
                $ShowMissing = $Missing[$GUID]
                
                # Format show name with year if available
                $ShowNameWithYear = $Show
                if ($null -ne $PlexShows[$GUID] -and $null -ne $PlexShows[$GUID]["year"]) {
                    $ShowNameWithYear = "$Show ($($PlexShows[$GUID]["year"]))"
                }
                
                ForEach ($Episode in ($ShowMissing | Sort-Object { $_.airedSeason }, { $_.airedEpisodeNumber })) {
                    $OutputContent += ("{0} - S{1:00}E{2:00} - {3}" -f $ShowNameWithYear, $Episode.airedSeason, $Episode.airedEpisodeNumber, $Episode.episodeName)
                }
            }
        }
    }
    else {
        # Standard detailed output format
        $OutputContent += "=== MISSING EPISODES REPORT ==="
        $OutputContent += "Generated on: $(Get-Date)"
        $OutputContent += ""
        
        if ($Missing.Keys.Count -eq 0) {
            $OutputContent += "No missing episodes found! All shows are up to date."
        }
        else {
            $OutputContent += "Found missing episodes in $($Missing.Keys.Count) show(s):"
            $OutputContent += ""
            
            # Convert GUID keys to show titles and sort
            $SortedShows = $Missing.Keys | ForEach-Object {
                @{
                    GUID = $_
                    Title = $PlexShows[$_]["title"]
                }
            } | Sort-Object Title
            
            ForEach ($ShowInfo in $SortedShows) {
                $GUID = $ShowInfo.GUID
                $Show = $ShowInfo.Title
                $ShowMissing = $Missing[$GUID]
                $TotalShowMissing = if ($null -ne $ShowMissing) { $ShowMissing.Count } else { 0 }
                
                $OutputContent += $Show
                $OutputContent += "  Total missing episodes: $TotalShowMissing"
                
                # Group by season for summary
                $SeasonSummary = $ShowMissing | Group-Object airedSeason | Sort-Object { [int]$_.Name }
                $OutputContent += "  Missing episodes by season:"
                
                ForEach ($SeasonGroup in $SeasonSummary) {
                    $SeasonNum = $SeasonGroup.Name
                    # Handle cases where season number might be null, empty, or whitespace
                    if ([string]::IsNullOrWhiteSpace($SeasonNum)) {
                        $SeasonNum = 0
                        Write-Warning "Found episodes with blank season number for show: $Show"
                    } else {
                        $SeasonNum = [int]$SeasonNum
                    }
                    $EpisodeCount = $SeasonGroup.Count
                    $MinEp = ($SeasonGroup.Group.airedEpisodeNumber | Measure-Object -Minimum).Minimum
                    $MaxEp = ($SeasonGroup.Group.airedEpisodeNumber | Measure-Object -Maximum).Maximum
                    
                    # Format season number for display
                    $SeasonDisplay = $SeasonNum
                    
                    if ($EpisodeCount -le 10) {
                        $OutputContent += "    Season $SeasonDisplay`: $EpisodeCount episodes"
                        ForEach ($Episode in ($SeasonGroup.Group | Sort-Object { $_.airedEpisodeNumber })) {
                            $OutputContent += ("      S{0:00}E{1:00} - {2}" -f $SeasonNum, $Episode.airedEpisodeNumber, $Episode.episodeName)
                        }
                    }
                    else {
                        $OutputContent += "    Season $SeasonDisplay`: $EpisodeCount episodes (E$MinEp - E$MaxEp)"
                        
                        # Show first 3 and last 3 episodes for large seasons
                        $SortedEpisodes = $SeasonGroup.Group | Sort-Object { $_.airedEpisodeNumber }
                        $FirstThree = $SortedEpisodes | Select-Object -First 3
                        $LastThree = $SortedEpisodes | Select-Object -Last 3
                        
                        ForEach ($Episode in $FirstThree) {
                            $OutputContent += ("      S{0:00}E{1:00} - {2}" -f $SeasonNum, $Episode.airedEpisodeNumber, $Episode.episodeName)
                        }
                        if ($EpisodeCount -gt 6) {
                            $OutputContent += "      ... ($($EpisodeCount - 6) more episodes) ..."
                        }
                        if ($EpisodeCount -gt 3) {
                            ForEach ($Episode in $LastThree) {
                                $OutputContent += ("      S{0:00}E{1:00} - {2}" -f $SeasonNum, $Episode.airedEpisodeNumber, $Episode.episodeName)
                            }
                        }
                    }
                }
                $OutputContent += ""
            }
        }
        
        $TotalMissing = ($Missing.Values | ForEach-Object { if ($null -ne $_) { $_.Count } else { 0 } } | Measure-Object -Sum).Sum
        $OutputContent += "Total missing episodes across all shows: $TotalMissing"
        
        if (-not [string]::IsNullOrWhiteSpace($SingleShowFilter)) {
            $OutputContent += ""
            $OutputContent += "Note: Results filtered for shows matching '$SingleShowFilter'"
        }
        
        $OutputContent += ""
        $OutputContent += "=== END REPORT ==="
    }
    
    # Output to file or console
    if (-not [string]::IsNullOrWhiteSpace($OutputFile)) {
        # Clear progress bar before file operations
        Write-Progress -Activity "Completed" -Completed
        
        try {
            $OutputContent | Out-File -FilePath $OutputFile -Encoding UTF8
            Write-Host "Report saved to: $OutputFile" -ForegroundColor Green
        }
        catch {
            Write-Host "Error writing to file '$OutputFile': $($_.Exception.Message)" -ForegroundColor Red
            # Fall back to console output
            Write-Host "`nFalling back to console output:" -ForegroundColor Yellow
            $OutputContent | ForEach-Object { Write-Host $_ }
        }
    }
    else {
        # Clear progress bar before console output
        Write-Progress -Activity "Completed" -Completed
        
        if ($SimpleOutput) {
            # Simple output format for console
            if ($Missing.Keys.Count -eq 0) {
                Write-Host "No missing episodes found! All shows are up to date." -ForegroundColor Green
            }
            else {
                # Convert GUID keys to show titles and sort
                $SortedShows = $Missing.Keys | ForEach-Object {
                    @{
                        GUID = $_
                        Title = $PlexShows[$_]["title"]
                    }
                } | Sort-Object Title
                
                ForEach ($ShowInfo in $SortedShows) {
                    $GUID = $ShowInfo.GUID
                    $Show = $ShowInfo.Title
                    $ShowMissing = $Missing[$GUID]
                    
                    # Format show name with year if available
                    $ShowNameWithYear = $Show
                    if ($null -ne $PlexShows[$GUID] -and $null -ne $PlexShows[$GUID]["year"]) {
                        $ShowNameWithYear = "$Show ($($PlexShows[$GUID]["year"]))"
                    }
                    
                    ForEach ($Episode in ($ShowMissing | Sort-Object { $_.airedSeason }, { $_.airedEpisodeNumber })) {
                        Write-Host ("{0} - S{1:00}E{2:00} - {3}" -f $ShowNameWithYear, $Episode.airedSeason, $Episode.airedEpisodeNumber, $Episode.episodeName) -ForegroundColor White
                    }
                }
            }
        }
        else {
            # Standard detailed output format for console
            Write-Host "`n=== MISSING EPISODES REPORT ===" -ForegroundColor Yellow
            Write-Host "Generated on: $(Get-Date)" -ForegroundColor Gray

            if ($Missing.Keys.Count -eq 0) {
                Write-Host "`nNo missing episodes found! All shows are up to date." -ForegroundColor Green
            }
            else {
                Write-Host "`nFound missing episodes in $($Missing.Keys.Count) show(s):`n" -ForegroundColor Red
                
                # Convert GUID keys to show titles and sort
                $SortedShows = $Missing.Keys | ForEach-Object {
                    @{
                        GUID = $_
                        Title = $PlexShows[$_]["title"]
                    }
                } | Sort-Object Title
                
                ForEach ($ShowInfo in $SortedShows) {
                    $GUID = $ShowInfo.GUID
                    $Show = $ShowInfo.Title
                    $ShowMissing = $Missing[$GUID]
                    $TotalShowMissing = if ($null -ne $ShowMissing) { $ShowMissing.Count } else { 0 }
                    
                    Write-Host "$Show" -ForegroundColor Cyan
                    Write-Host "  Total missing episodes: $TotalShowMissing" -ForegroundColor Yellow
                    
                    # Group by season for summary
                    $SeasonSummary = $ShowMissing | Group-Object airedSeason | Sort-Object { [int]$_.Name }
                    Write-Host "  Missing episodes by season:" -ForegroundColor Gray
                    
                    ForEach ($SeasonGroup in $SeasonSummary) {
                        $SeasonNum = $SeasonGroup.Name
                        # Handle cases where season number might be null, empty, or whitespace
                        if ([string]::IsNullOrWhiteSpace($SeasonNum)) {
                            $SeasonNum = 0
                            Write-Warning "Found episodes with blank season number for show: $Show"
                        } else {
                            $SeasonNum = [int]$SeasonNum
                        }
                        $EpisodeCount = $SeasonGroup.Count
                        $MinEp = ($SeasonGroup.Group.airedEpisodeNumber | Measure-Object -Minimum).Minimum
                        $MaxEp = ($SeasonGroup.Group.airedEpisodeNumber | Measure-Object -Maximum).Maximum
                        
                        # Format season number for display
                        $SeasonDisplay = $SeasonNum
                        
                        if ($EpisodeCount -le 10) {
                            Write-Host "    Season $SeasonDisplay`: $EpisodeCount episodes" -ForegroundColor Gray
                            ForEach ($Episode in ($SeasonGroup.Group | Sort-Object { $_.airedEpisodeNumber })) {
                                Write-Host ("      S{0:00}E{1:00} - {2}" -f $SeasonNum, $Episode.airedEpisodeNumber, $Episode.episodeName) -ForegroundColor DarkGray
                            }
                        }
                        else {
                            Write-Host "    Season $SeasonDisplay`: $EpisodeCount episodes (E$MinEp - E$MaxEp)" -ForegroundColor Gray
                            
                            # Show first 3 and last 3 episodes for large seasons
                            $SortedEpisodes = $SeasonGroup.Group | Sort-Object { $_.airedEpisodeNumber }
                            $FirstThree = $SortedEpisodes | Select-Object -First 3
                            $LastThree = $SortedEpisodes | Select-Object -Last 3
                            
                            ForEach ($Episode in $FirstThree) {
                                Write-Host ("      S{0:00}E{1:00} - {2}" -f $SeasonNum, $Episode.airedEpisodeNumber, $Episode.episodeName) -ForegroundColor DarkGray
                            }
                            if ($EpisodeCount -gt 6) {
                                Write-Host "      ... ($($EpisodeCount - 6) more episodes) ..." -ForegroundColor DarkGray
                            }
                            if ($EpisodeCount -gt 3) {
                                ForEach ($Episode in $LastThree) {
                                    Write-Host ("      S{0:00}E{1:00} - {2}" -f $SeasonNum, $Episode.airedEpisodeNumber, $Episode.episodeName) -ForegroundColor DarkGray
                                }
                            }
                        }
                    }
                    Write-Host ""
                }
                
                $TotalMissing = ($Missing.Values | ForEach-Object { if ($null -ne $_) { $_.Count } else { 0 } } | Measure-Object -Sum).Sum
                Write-Host "Total missing episodes across all shows: $TotalMissing" -ForegroundColor Yellow
                
                if (-not [string]::IsNullOrWhiteSpace($SingleShowFilter)) {
                    Write-Host "`nNote: Results filtered for shows matching '$SingleShowFilter'" -ForegroundColor Cyan
                }
            }
            
            Write-Host "`n=== END REPORT ===" -ForegroundColor Yellow
        }
    }

    # Save the updated TVDB cache
    if ($TVDBCache.Count -gt 0) {
        try {
            $TVDBCache | ConvertTo-Json -Depth 10 | Out-File -FilePath $CacheFile -Encoding UTF8
            Write-Host "Updated TVDB cache saved to $CacheFile" -ForegroundColor Gray
        }
        catch {
            Write-Warning "Failed to save TVDB cache: $($_.Exception.Message)"
        }
    }

}
catch {
    # Clear progress bar on error
    Write-Progress -Activity "Completed" -Completed
    
    Write-Host -ForegroundColor Red "`nAn error occurred:"
    Write-Host -ForegroundColor Red $_.Exception.Message
    Write-Host -ForegroundColor Red "`nFull error details:"
    Write-Host -ForegroundColor Red $_
    Write-Host -ForegroundColor Red "`nError occurred at line: $($_.InvocationInfo.ScriptLineNumber)"
    Write-Host -ForegroundColor Red "Command: $($_.InvocationInfo.Line)"
    
    # Only wait for input if not writing to file and running interactively
    if ([string]::IsNullOrWhiteSpace($OutputFile) -and $Host.Name -eq "ConsoleHost" -and [Environment]::UserInteractive) {
        Wait-ForUserInput
    }
    exit 1
}

# Wait for user input if script was run directly (not from PowerShell console) and not writing to file
if ([string]::IsNullOrWhiteSpace($OutputFile) -and $Host.Name -eq "ConsoleHost" -and [Environment]::UserInteractive) {
    Wait-ForUserInput
}
