# Project: tvinfomerk2vdr-ng.pl
#
# Sophisticated SERVICE to DVR channel name mapper
#
# (P) & (C) 2013-2020 by Peter Bieringer <pb@bieringer.de>
#
# License: GPLv2
#
# Authors:
#  Peter Bieringer (bie)
#
# Changelog:
# 20130116/bie: initial release
# 20130128/bie: add 'quiet' option, extend translation
# 20130203/bie: prevent ATV to be matched to a.tv
# 20130825/bie: fix CA channel handling and add whitelist feature for CA groups
# 20131106/bie: skip channel with name "." (found in boutique "BASIS 1")
# 20140630/bie: add static mapping for new "ARD-alpha" (replacing "BR-alpha") and "TV5", blacklist "Sky Select" if (opt_skip_ca_channels==1)
# 20141108/bie: some rework and rename file to support-channelmap.pl
# 20141122/bie: catch also "NDR MV", do not overwrite first-hit in normalized map - display message instead
# 20150908/bie: remove "ARD - " (introduced by TVinfo in September 2015, breaking automatic HD channel mapping)
# 20160903/bie: create mapping for "EinsFestival" <-> "ONE"
# 20171203/bie: add normalized alternative name mapping
# 20181010/bie: fix/expand altnames handling for DVR
# 20190704/bie: ignore '+' found on "Anixe+"
# 20201222/bie: align log token, try to match also normalized+HD channels

use strict;
use warnings;
use utf8;
use Data::Dumper;

binmode(STDOUT, ":utf8");
binmode(STDERR, ":utf8");

my %vdr_channels;

our %chan;

# defaults can be overwritten by options
my $opt_skip_ca_channels = 1;
my $opt_force_hd_channels = 1;
my $opt_source_precedence = "CST"; # Cable->Satellite->Terestial;
my $opt_quiet = 0;


## static hardcoded translations (fuzzy mechanism don't work here)
my %channel_translations = (
	# (TVinfo) name		# vdr channels.conf
	'EinsExtr'             =>	'tagesschau24',
	'ARTEHDDE'	       =>	'arte HD',
	'MDR Sat'	       =>	'MDR S-Anhalt',
	'ARD'		       =>	'Das Erste',
	'Bayern'	       =>	'Bayerisches FS Süd',
	'ZDFinfokanal'	       =>	'ZDFinfo',
	'SRTL'		       =>	'SUPER RTL',
	'BR'	               =>	'Bayerisches FS Süd',
	'Home Shopping Europe' =>	'HSE',
	'Nick'                 =>	'NICK/COMEDY',
	'Comedy Central'       =>	'NICK/COMEDY',
	'TV5'		       =>       'TV5MONDE EUROPE', 
	'BR-alpha'	       =>	'ARD-alpha',
	'EinsFestival'	       =>	'ONE',
);

## match method number -> text
our %match_methods = (
	""	=> "no-match",
	"1"	=> "1:1",
	"2"	=> "translated 1:1",
	"3"	=> "normalized",
	"4"	=> "translated+normalized",
	"6"	=> "1:1 alternative Name",
);

## info strings
my %ca_info = (
	"0"	=> "",
	"1"	=> "CA",
);

my %hd_info = (
	"0"	=> "",
	"1"	=> "HD",
	"2"	=> "HDFB",
);

my $name_vdr;

## normalize channel names
sub normalize($) {
	my $input = $_[0];

	$input =~ s/ FS / /go; # remove " FS "
	$input =~ s/ FS$//go;  # remove " FS"
	$input =~ s/( |-)Fernsehen//goi; # remove "( |-)Fernsehen"
	$input =~ s/Fern$//g; # remove " Fern"
	$input =~ s/ II$/2/g; # replace " II" with "2"
	$input =~ s/ SD$//g; # remove " SD"

	$input =~ s/ Germany //go;
	$input =~ s/ Germany$//go;

	$input =~ s/ Deutschland //go;
	$input =~ s/ Deutschland$//go;

	$input =~ s/ Europe //go;
	$input =~ s/ Europe$//go;

	$input =~ s/ European //go;
	$input =~ s/ European$//go;

	$input =~ s/ World //go;
	$input =~ s/ World$//go;

	$input =~ s/ Int. //go;
	$input =~ s/ Int.$//go;

	$input =~ s/DErste/DasErste/g; # expand "D" -> "Das"

	$input =~ s/Bayerisches/BR/g;

	$input =~ s/ARD - (.*)/$1/g; # remove "ARD - " token

	# shift 'HD'
	$input =~ s/^(.*) HD (.*)$/$1 $2 HD/ig; # WDR HD Köln

	$input = lc($input);

	$input =~ s/(WDR) (Köln|Wuppertal)/$1/igo; 	# WDR
	$input =~ s/(SWR) (RP|BW)/$1/igo;          	# SWR
	$input =~ s/(MDR) (Thüringen|S-Anhalt)/$1/igo;  # MDR
	$input =~ s/(NDR) (NDS|SH|HH|MV)/$1/igo; 	# NDR
	$input =~ s/(RBB) (Berlin|Brandenburg)/$1/igo; 	# RBB

	$input =~ s/1/eins/g;
	$input =~ s/2/zwei/g;
	$input =~ s/3/drei/g;
	$input =~ s/4/vier/g;
	$input =~ s/5/fuenf/g;
	$input =~ s/6/sechs/g;
	$input =~ s/7/sieben/g;
	$input =~ s/8/acht/g;
	$input =~ s/9/neun/g;
	$input =~ s/0/null/g;

	$input =~ s/ä/ae/g;
	$input =~ s/ö/oe/g;
	$input =~ s/ü/ue/g;
	
	$input =~ s/\.//g if ($input !~ /^a\.tv/);
	$input =~ s/_//g;
	$input =~ s/-//g;
	$input =~ s/\+//g;

	$input =~ s/ *//og; # remove inbetween spaces

	return($input);
};


### Channel Map Function
## supported flags (in a hash)
#
# force_hd_channels  = 0: do not lookup service names in DVR channels with suffix HD
#                   != 0: try to find service name in DVR channels with suffix HD (map to HD channel if available)
#
# source_precedence [T][C][S]: order or source preference, if a channel name is available in more sources
#
# quiet                 : be quiet on non critical problems
#
sub channelmap($$$$) {
	my $service_id_list_hp = $_[0];
	my $channels_dvr_ap = $_[1];
	my $channels_service_ap = $_[2];
	my $flags_hp = $_[3];

	my %service_id_list;

	# fill hash (workaround to reuse code for now TODO)
        foreach my $channel_hp (@$channels_service_ap) {
		$$service_id_list_hp{$$channel_hp{'cid'}}->{'name'} = $$channel_hp{'name'};
		$$service_id_list_hp{$$channel_hp{'cid'}}->{'altnames'} = $$channel_hp{'altnames'};
	};

	my %dvr_channel_name_map_normalized;
	my %dvr_channel_name_map_altnames;
	my %dvr_channel_name_map_altnames_normalized;
	my @opt_whitelist_ca_groups;

	# Hash of DVR channel names to cid
	my %dvr_channels_id_by_name;

	if (defined $$flags_hp{'force_hd_channels'}) {
		logging("DEBUG", "ChannelMap: option 'force_hd_channels' specified: " . $$flags_hp{'force_hd_channels'});
		$opt_force_hd_channels = $$flags_hp{'force_hd_channels'};
	};

	if (defined $$flags_hp{'quiet'}) {
		logging("DEBUG", "ChannelMap: option 'quiet' specified: " . $$flags_hp{'quiet'});
		$opt_quiet = $$flags_hp{'quiet'};
	};

	if (defined $$flags_hp{'source_precedence'}) {
		if ($$flags_hp{'source_precedence'} =~ /^[STC]{3}$/) {
			logging("DEBUG", "ChannelMap: option 'source_precedence' specified: " . $$flags_hp{'source_precedence'});
			$opt_source_precedence = $$flags_hp{'source_precedence'};
		} else {
			logging("ERROR", "ChannelMap: option 'source_precedence' is not valid -> ignored: " . $$flags_hp{'source_precedence'});
		};
	};

	# create precedence lookup hash
	my %source_precedence;
	for (my $p = 1; $p <= 3; $p++) {
		$source_precedence{substr($opt_source_precedence, $p - 1, 1)} = $p;
	};

	logging("DEBUG", "ChannelMap: process DVR channels (source_precedence=" . $opt_source_precedence . ")");

        foreach my $channel_hp (sort { $$a{'name'} cmp $$b{'name'} } @$channels_dvr_ap) {
		logging("DEBUG", "ChannelMap: analyze channel name:'" . $$channel_hp{'name'} . "'");

		my $name = $$channel_hp{'name'};
		my $source = $$channel_hp{'source'};

		#logging("DEBUG", "ChannelMap: process DVR channel: " . sprintf("%4d / %s [%s]", $$channel_hp{'cid'}, $name, $group));

		$name =~ s/ - CV$//ogi; # remove boutique suffices

		if (! defined $dvr_channels_id_by_name{$name}->{'cid'}) {
			# add name/id to hash
			$dvr_channels_id_by_name{$name}->{'cid'} = $$channel_hp{'cid'};
			$dvr_channels_id_by_name{$name}->{'source'} = $source;
			logging("DEBUG", "ChannelMap: add DVR channel name: " . sprintf("%s / %s", $$channel_hp{'cid'}, $name));
		} else {
			# already inserted
			if ($dvr_channels_id_by_name{$name}->{'source'} eq $source) {
				logging("WARN", "ChannelMap: probably duplicate DVR channel name with same source, entry already added with ID: " . sprintf("%4d / %s (%s)", $$channel_hp{'cid'}, $name, $dvr_channels_id_by_name{$name}->{'cid'}))  if ($opt_quiet ne "1");
			} else {
				# check precedence
				if ($source_precedence{$source} < $source_precedence{$dvr_channels_id_by_name{$name}->{'source'}}) {
					logging("NOTICE", "ChannelMap: overwrite duplicate DVR channel name because of source precedence: " . sprintf("%4d / %s", $$channel_hp{'cid'}, $name));
					$dvr_channels_id_by_name{$name}->{'cid'} = $$channel_hp{'cid'};
					$dvr_channels_id_by_name{$name}->{'source'} = $source;
				} else {
					logging("NOTICE", "ChannelMap: do not overwrite duplicate DVR channel name because of source precedence: " . sprintf("%4d / %s", $$channel_hp{'cid'}, $name));
				};
			};
		};

		# add altnames
		if (defined $$channel_hp{'altnames'} && length($$channel_hp{'altnames'}) > 0) {
			foreach my $altname (split '\|', $$channel_hp{'altnames'}) {
				if ($altname eq $name) {
					# don't check default name again
					next;
				};
				# TODO more intelligent logic if necessary
				if (defined $dvr_channel_name_map_altnames{$altname}) {
					logging("DEBUG", "ChannelMap: DVR channel alternative name: " . sprintf("%-30s (%s) skipped, already filled with: '%s'", $altname, $name, $dvr_channel_name_map_altnames{$altname}));
				} else {
					$dvr_channel_name_map_altnames{$altname} = $name;
					logging("DEBUG", "ChannelMap: add DVR channel alternative name: " . sprintf("%-30s (%s)", $altname, $name));
				};
			};
		};
	};

	# Add normalized channel names
	foreach my $name (sort keys %dvr_channels_id_by_name) {
		my $name_normalized = normalize($name);
		next if (length($name_normalized) == 0);

		# TODO more intelligent logic if necessary
		if (defined $dvr_channel_name_map_normalized{$name_normalized}) {
			logging("DEBUG", "ChannelMap: normalized DVR channel name: " . sprintf("%-30s (%s) skipped, already filled with: '%s'", $name_normalized, $name, $dvr_channel_name_map_normalized{$name_normalized}));
		} else {
			$dvr_channel_name_map_normalized{$name_normalized} = $name;
			logging("DEBUG", "ChannelMap: normalized DVR channel name: " . sprintf("%-30s (%s)", $name_normalized, $name));
		};
	};

	# Add normalized alternative channel names
	foreach my $altname (sort keys %dvr_channel_name_map_altnames) {
		my $name = $dvr_channel_name_map_altnames{$altname};
		my $name_normalized = normalize($altname);
		next if (length($name_normalized) == 0);

		# TODO more intelligent logic if necessary
		if (defined $dvr_channel_name_map_normalized{$name_normalized}) {
			logging("DEBUG", "ChannelMap: normalized DVR channel alternative name: " . sprintf("%-30s (%s) skipped, already filled with: '%s'", $name_normalized, $name, $dvr_channel_name_map_normalized{$name_normalized}));
		} else {
			$dvr_channel_name_map_normalized{$name_normalized} = $name;
			logging("DEBUG", "ChannelMap: normalized DVR channel alternative name: " . sprintf("%-30s (%s)", $name_normalized, $name));
		};
	};

	## Run through service channel names
	logging("DEBUG", "ChannelMap: process service channel names (force_hd_channels=" . $opt_force_hd_channels . ")");

        foreach my $id (keys %$service_id_list_hp) {
		my $name = $$service_id_list_hp{$id}->{'name'};
		my $altnames = $$service_id_list_hp{$id}->{'altnames'};
		my $name_normalized = normalize($name);
		my $name_translated = $channel_translations{$name};
		my $match_method = undef;

		my $cid = undef;

		logging("TRACE", "ChannelMap: process service channel name: **" . $name . "**");

		# search for name in DVR channels 1:1
		if (defined $dvr_channels_id_by_name{$name}->{'cid'}) {
			# 1:1 hit
			logging("DEBUG", "ChannelMap: service channel name hit (1:1): " . $name);
			$cid = $dvr_channels_id_by_name{$name}->{'cid'};
			$match_method = 1; # 1:1
			goto('DVR_ID_FOUND');
		};

		# search for name in DVR alternative names
		if (defined $dvr_channel_name_map_altnames{$name}) {
			logging("DEBUG", "ChannelMap: service channel name hit (DVR altname): " . $name . " = " . $dvr_channel_name_map_normalized{$name_normalized});
			$cid = $dvr_channels_id_by_name{$dvr_channel_name_map_altnames{$name}}->{'cid'};
			$match_method = 11; # DVR alternative name
			goto('DVR_ID_FOUND');
		};

		# run through service alternative names
		if (defined $altnames) {
			logging("TRACE", "ChannelMap: process service channel alternative name list: " . $altnames);
			for my $altname (split '\|', $altnames) {
				if ($altname eq $name) {
					# don't check default name again
					next;
				};
				logging("TRACE", "ChannelMap: process service channel alternative name: " . $altname);

				if (defined $dvr_channels_id_by_name{$altname}->{'cid'}) {
					# 1:1 hit
					logging("DEBUG", "ChannelMap: service channel name hit (1:1 alternative name): " . $altname);
					$cid = $dvr_channels_id_by_name{$altname}->{'cid'};
					$match_method = 6; # 1:1 alternative name
					goto('DVR_ID_FOUND');
				};

				# search for name in DVR alternative names
				if (defined $dvr_channel_name_map_altnames{$altname}) {
					logging("DEBUG", "ChannelMap: service channel name hit (1:1 alternative name with DVR altname): " . $name . " = " . $dvr_channel_name_map_altnames{$altname});
					$cid = $dvr_channels_id_by_name{$dvr_channel_name_map_altnames{$name}}->{'cid'};
					$match_method = 16; # 1:1 alternative name with DVR alternative name
					goto('DVR_ID_FOUND');
				};
			};
		};

		# search for name in DVR channels (translated)
		if (defined $name_translated) {
			logging("TRACE", "ChannelMap: process service channel translated name: " . $name_translated);
			if (defined $dvr_channels_id_by_name{$name_translated}->{'cid'}) {
				logging("DEBUG", "ChannelMap: service channel name hit (translated 1:1): " . $name . " = " . $name_translated);
				$cid = $dvr_channels_id_by_name{$name_translated}->{'cid'};
				$match_method = 2; #  translated 1:1
				goto('DVR_ID_FOUND');
			};
		};

		# search for name in DVR channels (normalized)
		logging("TRACE", "ChannelMap: process service channel normalized name: " . $name_normalized);
		if (defined $dvr_channel_name_map_normalized{$name_normalized}) {
			logging("DEBUG", "ChannelMap: service channel name hit (normalized): " . $name . " = " . $dvr_channel_name_map_normalized{$name_normalized});
			$cid = $dvr_channels_id_by_name{$dvr_channel_name_map_normalized{$name_normalized}}->{'cid'};
			$match_method = 3; # normalized
			goto('DVR_ID_FOUND');
		};

		# search for name in DVR channels (normalized) + HD
		logging("TRACE", "ChannelMap: process service channel normalized+HD name: " . $name_normalized . "hd");
		if (defined $dvr_channel_name_map_normalized{$name_normalized . "hd"}) {
			logging("DEBUG", "ChannelMap: service channel name hit (normalized+HD): " . $name . " = " . $dvr_channel_name_map_normalized{$name_normalized . "hd"});
			$cid = $dvr_channels_id_by_name{$dvr_channel_name_map_normalized{$name_normalized . "hd"}}->{'cid'};
			$match_method = 13; # normalized+HD
			goto('DVR_ID_FOUND');
		};

		# search for name in DVR channels (translated & normalized)
		if (defined $name_translated) {
			my $name_normalized = normalize($name_translated);
			logging("TRACE", "ChannelMap: process service channel translated/normalized name: " . $name_normalized);
			if (defined $dvr_channel_name_map_normalized{$name_normalized}) {
				logging("DEBUG", "ChannelMap: service channel name hit (translated & normalized): " . $name . " = " . $dvr_channel_name_map_normalized{$name_normalized});
				$cid = $dvr_channels_id_by_name{$dvr_channel_name_map_normalized{$name_normalized}}->{'cid'};
				$match_method = 4; # translated+normalized
				goto('DVR_ID_FOUND');
			};
		};

		# run through normalized alternative names
		if (defined $altnames) {
			logging("TRACE", "ChannelMap: process service channel normalized alternative name list: " . $altnames);
			for my $altname (split '\|', $altnames) {
				if ($altname eq $name) {
					# don't check default name again
					next;
				};
				my $name_normalized = normalize($altname);
				logging("TRACE", "ChannelMap: process service channel normalized alternative name: " . $name_normalized);

				if (defined $dvr_channel_name_map_normalized{$name_normalized}) {
					# normalized hit
					logging("DEBUG", "ChannelMap: service channel name hit (normalized alternative name): " . $name_normalized);
					$cid = $dvr_channels_id_by_name{$dvr_channel_name_map_normalized{$name_normalized}}->{'cid'};
					$match_method = 7; # normalized alternative name
					goto('DVR_ID_FOUND');
				};
			};
		};

		# Unmatched channel
		logging("ERROR", "ChannelMap: can't find service channel name: " . $name . " (normalized: " . $name_normalized . ")") if ($opt_quiet ne "1");
		next;

DVR_ID_FOUND:
		logging("DEBUG", "ChannelMap: found CID for service channel name: " . $name . " = " . $cid . " (match method: " . $match_method . ")");

		# set cid;
		$$service_id_list_hp{$id}->{'cid'} = $cid;
		$$service_id_list_hp{$id}->{'match_method'} = $match_method;

		next if ($opt_force_hd_channels ne "1");

		# Map to HD channels, when existing
		$name = $$service_id_list_hp{$id}->{'name'} . " HD";
		$name_normalized = normalize($name);
		$name_translated = undef;

		if (defined $channel_translations{$$service_id_list_hp{$id}->{'name'}}) {
			$name_translated = $channel_translations{$$service_id_list_hp{$id}->{'name'}} . " HD";
		};

		logging("DEBUG", "ChannelMap: process forced-to-HD service channel name: " . $name . " (" . $name_normalized . ")");

		# search for name in DVR channels 1:1
		if (defined $dvr_channels_id_by_name{$name}->{'cid'}) {
			# 1:1 hit
			logging("DEBUG", "ChannelMap: forced-to-HD service channel name hit (1:1): " . $name);
			$cid = $dvr_channels_id_by_name{$name}->{'cid'};
			goto('DVR_ID_FOUND_HD');
		};

		# search for name in DVR channels (translated)
		if (defined $name_translated) {
			if (defined $dvr_channels_id_by_name{$name_translated}->{'cid'}) {
				logging("DEBUG", "ChannelMap: forced-to-HD service channel name hit (translated 1:1): " . $name . " = " . $name_translated);
				$cid = $dvr_channels_id_by_name{$name_translated}->{'cid'};
				goto('DVR_ID_FOUND_HD');
			};
		};

		# search for name in DVR channels (normalized)
		if (defined $dvr_channel_name_map_normalized{$name_normalized}) {
			logging("DEBUG", "ChannelMap: forced-to-HD service channel name hit (normalized): " . $name . " = " . $dvr_channel_name_map_normalized{$name_normalized});
			$cid = $dvr_channels_id_by_name{$dvr_channel_name_map_normalized{$name_normalized}}->{'cid'};
			goto('DVR_ID_FOUND_HD');
		};

		# search for name in DVR channels (translated & normalized)
		if (defined $name_translated) {
			my $name_normalized = normalize($name_translated);
			if (defined $dvr_channel_name_map_normalized{$name_normalized}) {
				logging("DEBUG", "ChannelMap: forced-to-HD service channel name hit (translated & normalized): " . $name . " = " . $dvr_channel_name_map_normalized{$name_normalized});
				$cid = $dvr_channels_id_by_name{$dvr_channel_name_map_normalized{$name_normalized}}->{'cid'};
				goto('DVR_ID_FOUND_HD');
			};
		};

		# no HD channel found
		next;

DVR_ID_FOUND_HD:
		logging("DEBUG", "ChannelMap: found DVR_ID for forced-to-HD service channel name: " . $name . " = " . $cid);

		# set cid;
		$$service_id_list_hp{$id}->{'cid'} = $cid;
	};
};


## END
return 1;
