# PlexMissingEpisodes

Scripts for finding missing episodes from your Plex library.

Edit the variables at the top of the script with your TheTVDB authentication information and set the PlexServer as required...

PowerShell version uses the new TheTVDB API and is way more updated than the Perl version. The PowerShell version does not require you to specify a section, as it will search all sections listed as "TV Shows" in Plex.

For now, the Perl version requires you to specify the section ID which you can find via `http://localhost:32400/library/sections` (replace localhost with the plex server if not local)
