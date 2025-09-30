# PlexMissingEpisodes

A PowerShell script that identifies missing TV show episodes in your Plex library by comparing against TheTVDB's episode database.

## Features

- **Automatic Discovery**: Scans all TV show libraries in Plex without manual section configuration
- **TheTVDB Integration**: Uses TheTVDB API v4 for accurate episode data
- **Smart Episode Detection**: Handles multi-episode files and episode ranges (e.g., "S02E01-02")
- **Flexible Configuration**: Configure via command-line parameters or script variables
- **Dual Output Formats**:
  - **Standard**: Detailed reports with summaries and grouping
  - **Simple**: Clean one-line format perfect for searching and automation
- **Flexible Output**: Console output with colors OR save directly to file with timestamp
- **Flexible Filtering**: Process all shows, ignore specific shows, or focus on a single show
- **Year Detection**: Automatically includes show year when available from Plex metadata
- **Detailed Reporting**: Shows missing episodes organized by season with episode names
- **Automation Friendly**: No user prompts when saving to file, perfect for scheduled tasks
- **Metadata Validation**: Reports episodes with missing season/episode numbers
- **Comprehensive Error Handling**: Robust authentication and API error management

## Quick Start

1. **Get TheTVDB API Key**: Register at [TheTVDB.com](https://thetvdb.com/api-information) and obtain your API key
2. **Configure Script**: Either edit the configuration variables in `PlexMissingEpisodes.ps1` OR pass parameters when running
3. **Run Script**: Execute the PowerShell script with or without parameters

## Configuration

You can configure the script in two ways:

### Method 1: Command Line Parameters (Recommended)

Pass configuration as parameters when running the script:

```powershell
./PlexMissingEpisodes.ps1 -ApiKey "your-api-key" -PlexServer "http://your-server:32400" -PlexUsername "username" -PlexPassword "password"
```

### Method 2: Edit Script Variables

Edit the default values in the script's configuration section (lines 45-67). Parameters will override these defaults when provided:

```powershell
# TheTVDB Authentication - update the fallback values
$TheTVDBAuthentication = @{
    "apikey" = if ($ApiKey) { $ApiKey } else { "your-api-key-here" }
    "pin"    = if ($Pin) { $Pin } else { "" } # Optional: Only needed for subscriber keys
}

# Plex Server Settings - update the fallback values
if (-not $PlexServer) { $PlexServer = "http://your-plex-server:32400" }
if (-not $PlexUsername) { $PlexUsername = 'your-username' }
if (-not $PlexPassword) { $PlexPassword = 'your-password' }

# Filtering Options - update the fallback values
# Array of show names to ignore, example included
$IgnoreList = if ($IgnoreShows) { $IgnoreShows } else {
    [system.collections.generic.list[string]]::new(
        # "Jeopardy!"
    )
}
if (-not $SingleShowFilter) { $SingleShowFilter = "" }
```

**Note**: Parameters take precedence over script variables, allowing you to save defaults in the script while overriding specific values as needed.

## Parameters

| Parameter | Type | Description | Example |
|-----------|------|-------------|---------|
| `-ApiKey` | String | TheTVDB API key (required) | `-ApiKey "abc123"` |
| `-Pin` | String | TheTVDB Subscriber PIN (optional) | `-Pin "1234"` |
| `-PlexServer` | String | Plex server URL | `-PlexServer "http://server:32400"` |
| `-PlexUsername` | String | Plex username | `-PlexUsername "myuser"` |
| `-PlexPassword` | String | Plex password | `-PlexPassword "mypass"` |
| `-SingleShowFilter` | String | Process only this show (partial matching) | `-SingleShowFilter "Breaking Bad"` |
| `-IgnoreShows` | String[] | Shows to ignore (comma-separated) | `-IgnoreShows "Show1","Show2"` |
| `-OutputFile` | String | Save results to file instead of console | `-OutputFile "missing.txt"` |
| `-SimpleOutput` | Switch | Use simple one-line format for easy searching | `-SimpleOutput` |

## Usage Examples

### Basic Usage (using script defaults)

```powershell
./PlexMissingEpisodes.ps1
```

### With Parameters

```powershell
# Minimal parameters (others use script defaults)
./PlexMissingEpisodes.ps1 -ApiKey "your-tvdb-api-key"

# Full configuration via parameters
./PlexMissingEpisodes.ps1 -ApiKey "your-api-key" -PlexServer "http://server:32400" -PlexUsername "user" -PlexPassword "pass"

# Focus on specific show
./PlexMissingEpisodes.ps1 -SingleShowFilter "Breaking Bad"

# Ignore multiple shows
./PlexMissingEpisodes.ps1 -IgnoreShows "Jeopardy!","Daily Show","News"

# Save output directly to file (no "Press any key" prompt)
./PlexMissingEpisodes.ps1 -OutputFile "missing-episodes.txt"

# Use simple output format for easy searching
./PlexMissingEpisodes.ps1 -SimpleOutput

# Combine simple output with file saving
./PlexMissingEpisodes.ps1 -SimpleOutput -OutputFile "missing-simple.txt"
```

### Save Output to File

```powershell
# Using the OutputFile parameter (recommended - includes timestamp and no user prompt)
./PlexMissingEpisodes.ps1 -OutputFile "missing-episodes.txt"

# Save simple format for automation/processing
./PlexMissingEpisodes.ps1 -SimpleOutput -OutputFile "missing-simple.txt"

# Using shell redirection (alternative method)
./PlexMissingEpisodes.ps1 -ApiKey "your-key" | Out-File "missing-episodes.txt"
```

### Get Help

```powershell
Get-Help ./PlexMissingEpisodes.ps1 -Detailed
```

## Requirements

- **PowerShell 5.1+**
- **Network Access**: Internet connection for TheTVDB API and Plex server access
- **TheTVDB API Key**: Free registration required
- **Plex Credentials**: Username/password or configure IP allowlist in Plex settings

## Output Formats

The script provides two output formats:

### Standard Format (Default)

- **Progress Tracking**: Real-time updates during library scanning
- **Missing Episode Report**: Detailed breakdown by show and season
- **Metadata Warnings**: Alerts for episodes with missing information
- **Summary Statistics**: Total count of missing episodes

```text
=== MISSING EPISODES REPORT ===
Show Name
  Total missing episodes: 5
  Missing episodes by season:
    Season 1: 2 episodes
      S01E03 - Episode Title
      S01E07 - Another Episode
    Season 2: 3 episodes
      S02E01 - Season Premiere
      ...
```

### Simple Format (`-SimpleOutput`)

Perfect for automation, searching, and scripting with clean one-line entries:

```text
What We Do in the Shadows (2019) - S03E06 - The Escape
Breaking Bad (2008) - S02E03 - Bit by a Dead Bee  
The Office (2005) - S05E14 - Lecture Circuit: Part 1
```

**Format**: `Show Name (Year) - SXXEXX - Episode Title`

- Includes year when available from Plex metadata
- One line per missing episode
- Easy to grep, sort, and process with other tools

## Practical Examples

### Scenario 1: First-time Setup

If you're running the script for the first time and want to override the default credentials:

```powershell
./PlexMissingEpisodes.ps1 -ApiKey "your-tvdb-key" -PlexServer "http://192.168.1.100:32400" -PlexUsername "admin" -PlexPassword "securepass"
```

### Scenario 2: Check Specific Show

To quickly check missing episodes for a specific show without editing the script:

```powershell
./PlexMissingEpisodes.ps1 -SingleShowFilter "Stranger Things"
```

### Scenario 3: Exclude Multiple Shows

To run the check while ignoring several shows that you know have issues:

```powershell
./PlexMissingEpisodes.ps1 -IgnoreShows "The Daily Show","Saturday Night Live","Jeopardy!"
```

### Scenario 4: Save Configuration, Override Specific Values

Keep your default settings in the script but override just the show filter:

```powershell
# Script has your default Plex/TVDB settings, but you want to check one show
./PlexMissingEpisodes.ps1 -SingleShowFilter "The Office"
```

### Scenario 5: Simple Output for Easy Searching

Use simple output format for automation and easy searching:

```powershell
# Get simple output for all shows
./PlexMissingEpisodes.ps1 -SimpleOutput

# Search for specific shows in simple output
./PlexMissingEpisodes.ps1 -SimpleOutput | grep "Breaking Bad"

# Count missing episodes per show
./PlexMissingEpisodes.ps1 -SimpleOutput | cut -d' ' -f1-3 | sort | uniq -c

# Save simple output to file for processing
./PlexMissingEpisodes.ps1 -SimpleOutput -OutputFile "missing-simple.txt"
```

### Scenario 6: Automated Reports

For scheduled tasks or automation where you don't want user interaction:

```powershell
# Save to timestamped file automatically (no "Press any key" prompt)
./PlexMissingEpisodes.ps1 -OutputFile "reports/missing-episodes-$(Get-Date -Format 'yyyy-MM-dd').txt"

# Run specific show check and save results
./PlexMissingEpisodes.ps1 -SingleShowFilter "Game of Thrones" -OutputFile "got-missing.txt"

# Get simple format for automated processing
./PlexMissingEpisodes.ps1 -SimpleOutput -OutputFile "missing-simple.txt"
```

## Troubleshooting

- **Authentication Errors**: Verify TheTVDB API key and Plex credentials
- **Network Issues**: Check Plex server URL and network connectivity
- **Missing Shows**: Ensure shows have proper TVDB metadata in Plex
- **Console Closes**: Run from PowerShell window or use output redirection
- **Parameter Issues**: Use `Get-Help ./PlexMissingEpisodes.ps1` to see parameter syntax
