use strict;
use XML::Simple;
use LWP::Simple;
use Archive::Zip;
use Archive::Zip::MemberRead;
use Encode qw( encode );
use DateTime;
use DateTime::Format::Strptime qw( );
use Sort::Naturally;

$|=1;
my $dt = DateTime->now;

my $apiKey = ''; # TheTVDB API Key
my $plexserver = 'localhost'; # IP or Hostname of Plex Server
my $plexport = '32400';
my $sectionid = '3'; # Section ID to scan for missing episodes

my ($xmlmirror, $bannermirror, $zipmirror) = &TVDB_GetMirrors();

my @plexseries = &PLEX_GetAllSeries();
my @plexguids;
foreach my $series (@plexseries)
{
	push(@plexguids, &PLEX_GetSeriesGUID($series));
}

my %myepisodes;

for (my $i = 0; $i < @plexguids; $i++)
{
	$myepisodes{$plexguids[$i]} = &PLEX_MyEpisodes($plexseries[$i]);
}

my %allepisodes;

for (my $i = 0; $i < @plexguids; $i++)
{
	$allepisodes{$plexguids[$i]} = &TVDB_GetAllEpisodes($plexguids[$i]);
}
my %missing;
foreach my $pkey (keys %allepisodes)
{
	foreach my $key (keys %{$allepisodes{$pkey}})
	{
		if (!defined($myepisodes{$pkey}{$key}))
		{
			if ($key !~ /S00E/)
			{
				$missing{"$myepisodes{$pkey}{'title'} - $key"} = 1;
			}
		}
	}
}

foreach my $missing (nsort keys %missing)
{
	print "$missing\n";
}

sub PLEX_MyEpisodes()
{
	my $seriesid = $_[0];
	my $dom = &getDom('http://'.$plexserver.':'.$plexport.'/library/metadata/'.$_[0].'/allLeaves');
	my %episodes;
	$episodes{'title'} = $dom->{'parentTitle'};
	foreach my $key (keys %{$dom->{'Video'}})
	{
		$episodes{sprintf ("S%02dE%02d", $dom->{'Video'}->{$key}->{'parentIndex'}, $dom->{'Video'}->{$key}->{'index'})} = 1;
	}
	return \%episodes;
}

sub PLEX_GetSeriesGUID()
{
	my $dom = &getDom('http://'.$plexserver.':'.$plexport.'/library/metadata/'.$_[0].'/');
	my $guid = $1 if ($dom->{'Directory'}->{'/library/metadata/'.$_[0].'/children'}->{'guid'} =~ m#//(\d+)?#);
	return $guid;
}

sub PLEX_GetAllSeries()
{
	my $dom = &getDom('http://'.$plexserver.':'.$plexport.'/library/sections/'.$sectionid.'/all/');
	my @series;
	foreach my $key (keys %{$dom->{'Directory'}})
	{
		push(@series, $dom->{'Directory'}->{$key}->{'ratingKey'});
	}
	return @series;
}

sub getDom()
{
	my $url = $_[0];
	my $data = get($url);
	my $parser = new XML::Simple;
	return $parser->XMLin(encode("UTF-8", $data), ForceArray => 1);
}

sub TVDB_GetMirrors()
{
	my $mirrors_url = 'http://thetvdb.com/api/' . $apiKey . '/mirrors.xml';
	my $dom = &getDom($mirrors_url);
	
	my @xmlmirrors;
	my @bannermirrors;
	my @zipmirrors;

	foreach my $mirror (@{$dom->{'Mirror'}})
	{
		if ($mirror->{'typemask'}[0] & (1<<0))
		{
			push(@xmlmirrors, $mirror->{'mirrorpath'}[0]);
		}
		if ($mirror->{'typemask'}[0] & (1<<1))
		{
			push(@bannermirrors, $mirror->{'mirrorpath'}[0]);
		}
		if ($mirror->{'typemask'}[0] & (1<<2))
		{
			push(@zipmirrors, $mirror->{'mirrorpath'}[0]);
		}
	}
	return ($xmlmirrors[rand(@xmlmirrors)], $bannermirrors[rand(@bannermirrors)], $zipmirrors[rand(@zipmirrors)]);
}

sub TVDB_GetAllEpisodes()
{
	my $seriesid = $_[0];
	my $url = $zipmirror . '/api/' . $apiKey . '/series/' . $seriesid . '/all/en.zip';
	my $zipname = "$seriesid" . '_en.zip';
	getstore($url, $seriesid . '_en.zip') unless ((-e $zipname) or (defined($_[1]) and ($_[1] eq 1)));
	my $zip = Archive::Zip->new();
	my $status = $zip->read($zipname);
	my $file = Archive::Zip::MemberRead->new($zip, "en.xml");
	my $xml;
	while (defined(my $line = $file->getline()))
	{
		$xml .= $line;
	}
	my $parser = new XML::Simple;
	my $dom = $parser->XMLin(encode("UTF-8", $xml), ForceArray => 1);
	
	my %episodes;
	my $format = DateTime::Format::Strptime->new(
		pattern   => '%Y-%m-%d',
		time_zone => 'local',
		on_error  => 'croak',
	);
	foreach my $episode (@{$dom->{'Episode'}})
	{
		$episode->{'FirstAired'}[0] = "3000-01-01" if (ref($episode->{'FirstAired'}[0]) eq "HASH");
		my $airdate = $format->parse_datetime($episode->{'FirstAired'}[0]);
		if (DateTime->compare($dt, $airdate) == 1)
		{
			$episodes{sprintf("S%02dE%02d", $episode->{'SeasonNumber'}[0], $episode->{'EpisodeNumber'}[0])} = 1;
		}
		
	}
	return \%episodes;
}
