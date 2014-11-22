#!/usr/bin/perl
#
# Sophisticated SERVICE to DVR channel name mapper
#
# (P) & (C) 2013-2014 by Peter Bieringer <pb@bieringer.de>
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

use strict;
use warnings;
use utf8;

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
	my @opt_whitelist_ca_groups;

	# Hash of DVR channel names to cid
	my %dvr_channels_id_by_name;

	if (defined $$flags_hp{'force_hd_channels'}) {
		logging("DEBUG", "Channelmap: option 'force_hd_channels' specified: " . $$flags_hp{'force_hd_channels'});
		$opt_force_hd_channels = $$flags_hp{'force_hd_channels'};
	};

	if (defined $$flags_hp{'quiet'}) {
		logging("DEBUG", "Channelmap: option 'quiet' specified: " . $$flags_hp{'quiet'});
		$opt_quiet = $$flags_hp{'quiet'};
	};

	if (defined $$flags_hp{'source_precedence'}) {
		if ($$flags_hp{'source_precedence'} =~ /^[STC]{3}$/) {
			logging("DEBUG", "Channelmap: option 'source_precedence' specified: " . $$flags_hp{'source_precedence'});
			$opt_source_precedence = $$flags_hp{'source_precedence'};
		} else {
			logging("ERROR", "Channelmap: option 'source_precedence' is not valid -> ignored: " . $$flags_hp{'source_precedence'});
		};
	};

	# create precedence lookup hash
	my %source_precedence;
	for (my $p = 1; $p <= 3; $p++) {
		$source_precedence{substr($opt_source_precedence, $p - 1, 1)} = $p;
	};

	logging("DEBUG", "Channelmap: process DVR channels (source_precedence=" . $opt_source_precedence . ")");

        foreach my $channel_hp (sort { $$a{'name'} cmp $$b{'name'} } @$channels_dvr_ap) {
		logging("DEBUG", "Channelmap: analyze channel name:'" . $$channel_hp{'name'} . "'");

		my $name = $$channel_hp{'name'};
		my $source = $$channel_hp{'source'};

		#logging("DEBUG", "Channelmap: process DVR channel: " . sprintf("%4d / %s [%s]", $$channel_hp{'cid'}, $name, $group));

		foreach my $name_part (split /,/, $name) {
			$name_part =~ s/ - CV$//ogi; # remove boutique suffices

			if (! defined $dvr_channels_id_by_name{$name_part}->{'cid'}) {
				# add name/id to hash
				$dvr_channels_id_by_name{$name_part}->{'cid'} = $$channel_hp{'cid'};
				$dvr_channels_id_by_name{$name_part}->{'source'} = $source;
				logging("DEBUG", "Channelmap: add DVR channel name: " . sprintf("%s / %s", $$channel_hp{'cid'}, $name_part));
			} else {
				# already inserted
				if ($dvr_channels_id_by_name{$name_part}->{'source'} eq $source) {
					logging("WARN", "Channelmap: probably duplicate DVR channel name with same source, entry already added with ID: " . sprintf("%4d / %s (%s)", $$channel_hp{'cid'}, $name, $dvr_channels_id_by_name{$name_part}->{'cid'}))  if ($opt_quiet ne "1");
				} else {
					# check precedence
					if ($source_precedence{$source} < $source_precedence{$dvr_channels_id_by_name{$name_part}->{'source'}}) {
						logging("NOTICE", "Channelmap: overwrite duplicate DVR channel name because of source precedence: " . sprintf("%4d / %s", $$channel_hp{'cid'}, $name));
						$dvr_channels_id_by_name{$name_part}->{'cid'} = $$channel_hp{'cid'};
						$dvr_channels_id_by_name{$name_part}->{'source'} = $source;
					} else {
						logging("NOTICE", "Channelmap: do not overwrite duplicate DVR channel name because of source precedence: " . sprintf("%4d / %s", $$channel_hp{'cid'}, $name));
					};
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
			logging("DEBUG", "Channelmap: normalized DVR channel name: " . sprintf("%-30s (%s) skipped, already filled with: '%s'", $name_normalized, $name, $dvr_channel_name_map_normalized{$name_normalized}));
		} else {
			$dvr_channel_name_map_normalized{$name_normalized} = $name;
			logging("DEBUG", "Channelmap: normalized DVR channel name: " . sprintf("%-30s (%s)", $name_normalized, $name));
		};
	};

	## Run through service channel names
	logging("DEBUG", "Channelmap: process service channel names (force_hd_channels=" . $opt_force_hd_channels . ")");

        foreach my $id (keys %$service_id_list_hp) {
		my $name = $$service_id_list_hp{$id}->{'name'};
		my $altnames = $$service_id_list_hp{$id}->{'altnames'};
		my $name_normalized = normalize($name);
		my $name_translated = $channel_translations{$name};
		my $match_method = undef;

		my $cid = undef;

		logging("TRACE", "Channelmap: process service channel name: " . $name);

		# search for name in DVR channels 1:1
		if (defined $dvr_channels_id_by_name{$name}->{'cid'}) {
			# 1:1 hit
			logging("DEBUG", "Channelmap: service channel name hit (1:1): " . $name);
			$cid = $dvr_channels_id_by_name{$name}->{'cid'};
			$match_method = 1; # 1:1
			goto('DVR_ID_FOUND');
		};

		# run through alternative names
		if (defined $altnames) {
			logging("TRACE", "Channelmap: process service channel alternative name list: " . $altnames);
			for my $altname (split '\|', $altnames) {
				if ($altname eq $name) {
					# don't check default name again
					next;
				};
				logging("TRACE", "Channelmap: process service channel alternative name: " . $altname);

				if (defined $dvr_channels_id_by_name{$altname}->{'cid'}) {
					# 1:1 hit
					logging("DEBUG", "Channelmap: service channel name hit (1:1 alternative name): " . $altname);
					$cid = $dvr_channels_id_by_name{$altname}->{'cid'};
					$match_method = 6; # 1:1 alternative name
					goto('DVR_ID_FOUND');
				};
			};
		};

		# search for name in DVR channels (translated)
		if (defined $name_translated) {
			if (defined $dvr_channels_id_by_name{$name_translated}->{'cid'}) {
				logging("DEBUG", "Channelmap: service channel name hit (translated 1:1): " . $name . " = " . $name_translated);
				$cid = $dvr_channels_id_by_name{$name_translated}->{'cid'};
				$match_method = 2; #  translated 1:1
				goto('DVR_ID_FOUND');
			};
		};

		# search for name in DVR channels (normalized)
		if (defined $dvr_channel_name_map_normalized{$name_normalized}) {
			logging("DEBUG", "Channelmap: service channel name hit (normalized): " . $name . " = " . $dvr_channel_name_map_normalized{$name_normalized});
			$cid = $dvr_channels_id_by_name{$dvr_channel_name_map_normalized{$name_normalized}}->{'cid'};
			$match_method = 3; # normalized
			goto('DVR_ID_FOUND');
		};

		# search for name in DVR channels (translated & normalized)
		if (defined $name_translated) {
			my $name_normalized = normalize($name_translated);
			if (defined $dvr_channel_name_map_normalized{$name_normalized}) {
				logging("DEBUG", "Channelmap: service channel name hit (translated & normalized): " . $name . " = " . $dvr_channel_name_map_normalized{$name_normalized});
				$cid = $dvr_channels_id_by_name{$dvr_channel_name_map_normalized{$name_normalized}}->{'cid'};
				$match_method = 4; # translated+normalized
				goto('DVR_ID_FOUND');
			};
		};

		# Unmatched channel
		logging("ERROR", "Channelmap: can't find service channel name: " . $name . " (normalized: " . $name_normalized . ")") if ($opt_quiet ne "1");
		next;

DVR_ID_FOUND:
		logging("DEBUG", "Channelmap: found CID for service channel name: " . $name . " = " . $cid . " (match method: " . $match_method . ")");

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

		logging("DEBUG", "Channelmap: process forced-to-HD service channel name: " . $name . " (" . $name_normalized . ")");

		# search for name in DVR channels 1:1
		if (defined $dvr_channels_id_by_name{$name}->{'cid'}) {
			# 1:1 hit
			logging("DEBUG", "Channelmap: forced-to-HD service channel name hit (1:1): " . $name);
			$cid = $dvr_channels_id_by_name{$name}->{'cid'};
			goto('DVR_ID_FOUND_HD');
		};

		# search for name in DVR channels (translated)
		if (defined $name_translated) {
			if (defined $dvr_channels_id_by_name{$name_translated}->{'cid'}) {
				logging("DEBUG", "Channelmap: forced-to-HD service channel name hit (translated 1:1): " . $name . " = " . $name_translated);
				$cid = $dvr_channels_id_by_name{$name_translated}->{'cid'};
				goto('DVR_ID_FOUND_HD');
			};
		};

		# search for name in DVR channels (normalized)
		if (defined $dvr_channel_name_map_normalized{$name_normalized}) {
			logging("DEBUG", "Channelmap: forced-to-HD service channel name hit (normalized): " . $name . " = " . $dvr_channel_name_map_normalized{$name_normalized} . " HD");
			$cid = $dvr_channels_id_by_name{$dvr_channel_name_map_normalized{$name_normalized}}->{'cid'};
			goto('DVR_ID_FOUND_HD');
		};

		# search for name in DVR channels (translated & normalized)
		if (defined $name_translated) {
			my $name_normalized = normalize($name_translated);
			if (defined $dvr_channel_name_map_normalized{$name_normalized}) {
				logging("DEBUG", "Channelmap: forced-to-HD service channel name hit (translated & normalized): " . $name . " = " . $dvr_channel_name_map_normalized{$name_normalized});
				$cid = $dvr_channels_id_by_name{$dvr_channel_name_map_normalized{$name_normalized}}->{'cid'};
				goto('DVR_ID_FOUND_HD');
			};
		};

		# no HD channel found
		next;

DVR_ID_FOUND_HD:
		logging("DEBUG", "Channelmap: found DVR_ID for forced-to-HD service channel name: " . $name . " = " . $cid);

		# set cid;
		$$service_id_list_hp{$id}->{'cid'} = $cid;
	};
};

## prepare stations_vdr by normalizing DVR channels
sub prepare_stations_vdr($$) {
	my $stations_hp = $_[0];
	my $channels_ap = $_[1];
	logging("DEBUG", "ChannelPrep: start preperation of DVR channels");

        foreach my $channel_hp (@$channels_ap) {
		my $vpid_extracted;
		my $hd = 0;
		my $ca = 0;

		logging("TRACE", "ChannelPrep: analyze channel name:'" . $$channel_hp{'name'} . "' vpid:" . $$channel_hp{'vpid'});

		if ($$channel_hp{'vpid'} =~ /^([0-9]+)(\+[^=]+)?=([0-9]+)$/) {
			$vpid_extracted = $1;
			if ($3 != 2) {
				$hd = 1;
			}
		} elsif ($$channel_hp{'vpid'} =~ /^([0-9]+)$/) {
			# fallback
			$vpid_extracted = $1;
		};

		if ($vpid_extracted eq "0" || $vpid_extracted eq "1") {
			# skip (encrypted) radio channels
			logging("TRACE", "ChannelPrep: skip DVR channel(radio): " . sprintf("%4d / %s", $$channel_hp{'cid'}, $$channel_hp{'name'}));
			next;
		};

		my ($name, $group) = split /;/, $$channel_hp{'name'};

		if ($name eq ".") {
			# skip (encrypted) radio channels
			logging("TRACE", "ChannelPrep: skip DVR channel with only '.' in name: " . sprintf("%4d / %s", $$channel_hp{'cid'}, $$channel_hp{'name'}));
			next;
		} elsif ($name =~ /^[0-9]{3} - [0-9]{2}\|[0-9]{2}$/) {
			# skip (encrypted) radio channels
			logging("TRACE", "ChannelPrep: skip DVR channel with time-based name: " . sprintf("%4d / %s", $$channel_hp{'cid'}, $$channel_hp{'name'}));
			next;
		};

		$group = "" if (! defined $group); # default

		$name = encode("iso-8859-1", decode("utf8", $name)); # convert charset
		$group = encode("iso-8859-1", decode("utf8", $group)); # convert charset

		my $ca_info = "";

		if ($$channel_hp{'ca'} ne "0") {
			$ca = 1;
		};

		my @altnames = split /,/, $name;

		if (scalar(@altnames) > 1) {
			$name = shift @altnames;
		} else {
			undef @altnames;
		};

		if ($$channel_hp{'vpid'} =~ /^([0-9]+)$/) {
			# fallback for HD detection
			if ($name =~ / HD$/) {
				$hd = 2;
			};
		};

		my $source = substr($$channel_hp{'source'}, 0, 1); # first char of source

		my $id = $$channel_hp{'cid'};

		logging("TRACE", "ChannelPrep: prepare channel name: " . sprintf("%-35s %-20s %2s %-4s %4s %s", $name, $group, $ca_info{$ca}, $hd_info{$hd}, $id, join(',', @altnames)));

		#logging("DEBUG", "Channelmap: found DVR_ID for forced-to-HD service channel name: " . $name . " = " . $cid);

		$$stations_hp{$id}->{'name'}          = $name;
		$$stations_hp{$id}->{'group'}         = $group;
		$$stations_hp{$id}->{'ca'}            = $ca;
		$$stations_hp{$id}->{'hd'}            = $hd;
		$$stations_hp{$id}->{'altnames'}      = join(',', @altnames);
		$$stations_hp{$id}->{'norm_name'}     = normalize($name);
		$$stations_hp{$id}->{'norm_altnames'} = normalize(join(',', @altnames));
	};

	# print table
	my $format_string = "%-35s %-20s %2s %-4s %4s %s (%s)";
	logging("DEBUG", "ChannelPrep/DVR: " . sprintf($format_string, "name", "group", "ca", "hd", "id", "altnames", "normalized names"));

	for my $id (sort { $$stations_hp{$a}->{'group'} cmp $$stations_hp{$b}->{'group'} } sort { lc($$stations_hp{$a}->{'name'}) cmp lc($$stations_hp{$b}->{'name'}) } keys %$stations_hp) {
		logging("DEBUG", "ChannelPrep/DVR: " . sprintf($format_string, $$stations_hp{$id}->{'name'}, $$stations_hp{$id}->{'group'}, $ca_info{$$stations_hp{$id}->{'ca'}}, $hd_info{$$stations_hp{$id}->{'hd'}}, $id, $$stations_hp{$id}->{'altnames'}, $$stations_hp{$id}->{'norm_name'} . "," . $$stations_hp{$id}->{'norm_altnames'}));
	};
};


## prepare stations_vdr by normalizing DVR channels
sub prepare_stations_tvinfo($$) {
	my $stations_hp = $_[0];
	my $channels_hp = $_[1];

	logging("DEBUG", "ChannelPrep/TVinfo: start preperation of channels");

        foreach my $channel_hp (keys %$channels_hp) {
		my $id = $channel_hp;
		my $name = $$channels_hp{$id}->{'name'};
		my @altnames = grep(!/^$name$/, split /,/, $$channels_hp{$id}->{'altnames'}); # filter duplicate $name

		logging("TRACE", "ChannelPrep/TVinfo: prepare channel name: " . sprintf("%-35s %4s %s", $name, $id, join(',', @altnames)));

		$$stations_hp{$id}->{'name'}          = $name;
		$$stations_hp{$id}->{'altnames'}      = join(',', @altnames);
		$$stations_hp{$id}->{'norm_name'}     = normalize($name);
		$$stations_hp{$id}->{'norm_altnames'} = normalize(join(',', @altnames));
	};

	# print table
	my $format_string = "%-35s %4s %s (%s)";
	logging("DEBUG", "ChannelPrep/TVinfo: " . sprintf($format_string, "name", "id", "altnames", "normalized names"));

	for my $id (sort { lc($$stations_hp{$a}->{'name'}) cmp lc($$stations_hp{$b}->{'name'}) } keys %$stations_hp) {
		logging("DEBUG", "ChannelPrep/TVinfo: " . sprintf($format_string, $$stations_hp{$id}->{'name'}, $id, $$stations_hp{$id}->{'altnames'}, $$stations_hp{$id}->{'norm_name'} . "," . $$stations_hp{$id}->{'norm_altnames'}));
	};
	die;
};

return 1;
