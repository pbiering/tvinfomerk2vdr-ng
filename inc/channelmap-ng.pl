#!/usr/bin/perl
#
# Sophisticated Station (tvinfo sender) to VDR channel name mapper
#
# (P) & (C) 2013-2014 by Peter Bieringer <pb@bieringer.de>
#
# License: GPLv2
#
# Authors:
#  Peter Bieringer (bie)
#
# Changelog:
# 20130116/pb: initial release
# 20130128/pb: add 'quiet' option, extend translation
# 20130203/pb: prevent ATV to be matched to a.tv
# 20130825/pb: fix CA channel handling and add whitelist feature for CA groups
# 20131106/pb: skip channel with name "." (found in boutique "BASIS 1")
# 20140630/pb: add static mapping for new "ARD-alpha" (replacing "BR-alpha") and "TV5", blacklist "Sky Select" if (opt_skip_ca_channels==1)

use strict;
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
	$input =~ s/(NDR) (NDS|SH|HH)/$1/igo; 		# NDR
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
# skip_ca_channels   = 0: do not skip VDR channels requiring Common Access (encrypted channels)
#                   != 0: skip VDR channels requiring Common Access (encrypted channels)
#
# force_hd_channels  = 0: do not lookup service names in VDR channels with suffix HD
#                   != 0: try to find service name in VDR channels with suffix HD (map to HD channel if available)
#
# source_precedence [T][C][S]: order or source preference, if a channel name is available in more sources
#
# quiet                 : be quiet on non critical problems
#
sub channelmap($$$;$) {
	my $service = $_[0];
	my $vdr_channel_ap = $_[1];
	my $service_id_list_hp = $_[2];
	my $flags_hp = $_[3];

	my %vdr_channel_name_map_normalized;
	my @opt_whitelist_ca_groups;

	# Hash of VDR channel names to vdr_id
	my %vdr_channels_id_by_name;

	if ($service ne "tvinfo") {
		logging("ERROR", "Channelmap: unsupported service: " . $service);
		return 1;
	};

	if (defined $$flags_hp{'skip_ca_channels'}) {
		logging("DEBUG", "Channelmap: option 'skip_ca_channels' specified: " . $$flags_hp{'skip_ca_channels'});
		$opt_skip_ca_channels = $$flags_hp{'skip_ca_channels'};
	};

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

	if (defined $$flags_hp{'whitelist_ca_groups'} && $$flags_hp{'whitelist_ca_groups'} ne "") {
		logging("DEBUG", "Channelmap: option 'whitelist_ca_groups' specified: " . $$flags_hp{'whitelist_ca_groups'});
		@opt_whitelist_ca_groups = split /,/, $$flags_hp{'whitelist_ca_groups'};
	};

	# create precedence lookup hash
	my %source_precedence;
	for (my $p = 1; $p <= 3; $p++) {
		$source_precedence{substr($opt_source_precedence, $p - 1, 1)} = $p;
	};

	logging("DEBUG", "Channelmap: process VDR channels (skip_ca_channels=" . $opt_skip_ca_channels . " source_precedence=" . $opt_source_precedence . ")");

        foreach my $channel_hp (@$vdr_channel_ap) {
		my $vpid_extracted = (split /[+=]/, $$channel_hp{'vpid'})[0];
		logging("TRACE", "Channelmap: analyze channel name:'" . $$channel_hp{'name'} . "' vpid:" . $$channel_hp{'vpid'} . " (" . $vpid_extracted . ")");

		if ($vpid_extracted eq "0" || $vpid_extracted eq "1") {
			# skip (encrypted) radio channels
			logging("DEBUG", "Channelmap: skip VDR channel(radio): " . sprintf("%4d / %s", $$channel_hp{'vdr_id'}, $$channel_hp{'name'}));
			next;
		};

		my ($name, $group) = split /;/, $$channel_hp{'name'};

		$group = "" if (! defined $group); # default

		$name = encode("iso-8859-1", decode("utf8", $name)); # convert charset
		$group = encode("iso-8859-1", decode("utf8", $group)); # convert charset

		my $source = substr($$channel_hp{'source'}, 0, 1); # first char of source

		if ($$channel_hp{'ca'} ne "0") {
			# skip non-free channels depending on option

			if ($opt_skip_ca_channels ne "0") {
				# generally disabled
				logging("DEBUG", "Channelmap: skip VDR channel(CA): " . sprintf("%4d / %s [%s]", $$channel_hp{'vdr_id'}, $name, $group));
				next;
			};

			if ($group eq "") {
				# group empty
				logging("DEBUG", "Channelmap: skip VDR channel(CA): " . sprintf("%4d / %s [%s] (cA group empty)", $$channel_hp{'vdr_id'}, $name, $group));
				next;
			};

			if (! grep { /^$group$/i } @opt_whitelist_ca_groups) {
				# group not in whitelist
				logging("DEBUG", "Channelmap: skip VDR channel(CA): " . sprintf("%4d / %s [%s] (cA group not in whitelist)", $$channel_hp{'vdr_id'}, $name, $group));
				next;
			};
		} else {
			if ($name =~ /^(Sky Select.*)$/o) {
				# skip special channels channels depending on name and option
				if ($opt_skip_ca_channels ne "0") {
					# generally disabled
					logging("DEBUG", "Channelmap: skip VDR channel(CA-like): " . sprintf("%4d / %s [%s]", $$channel_hp{'vdr_id'}, $name, $group));
					next;
				};
			};
		};

		logging("DEBUG", "Channelmap: process VDR channel: " . sprintf("%4d / %s [%s]", $$channel_hp{'vdr_id'}, $name, $group));

		foreach my $name_part (split /,/, $name) {
			$name_part =~ s/ - CV$//ogi; # remove boutique suffices

			if ($name_part eq ".") {
				logging("DEBUG", "Channelmap: skip VDR channel ('.'): " . sprintf("%4d / %s [%s]", $$channel_hp{'vdr_id'}, $name_part, $group));
				next;
			};

			if (! defined $vdr_channels_id_by_name{$name_part}->{'vdr_id'}) {
				# add name/id to hash
				$vdr_channels_id_by_name{$name_part}->{'vdr_id'} = $$channel_hp{'vdr_id'};
				$vdr_channels_id_by_name{$name_part}->{'source'} = $source;
				logging("DEBUG", "Channelmap: add VDR channel name: " . sprintf("%4d / %s [%s]", $$channel_hp{'vdr_id'}, $name_part, $group));
			} else {
				# already inserted
				if ($vdr_channels_id_by_name{$name_part}->{'source'} eq $source) {
					logging("WARN", "Channelmap: probably duplicate VDR channel name with same source, entry already added with ID: " . sprintf("%4d / %s (%s)", $$channel_hp{'vdr_id'}, $name, $vdr_channels_id_by_name{$name_part}->{'vdr_id'}))  if ($opt_quiet ne "1");
				} else {
					# check precedence
					if ($source_precedence{$source} < $source_precedence{$vdr_channels_id_by_name{$name_part}->{'source'}}) {
						logging("NOTICE", "Channelmap: overwrite duplicate VDR channel name because of source precedence: " . sprintf("%4d / %s", $$channel_hp{'vdr_id'}, $name));
						$vdr_channels_id_by_name{$name_part}->{'vdr_id'} = $$channel_hp{'vdr_id'};
						$vdr_channels_id_by_name{$name_part}->{'source'} = $source;
					} else {
						logging("NOTICE", "Channelmap: do not overwrite duplicate VDR channel name because of source precedence: " . sprintf("%4d / %s", $$channel_hp{'vdr_id'}, $name));
					};
				};
			};
		};
	};

	# Add normalized channel names
	foreach my $name (keys %vdr_channels_id_by_name) {
		my $name_normalized = normalize($name);
		next if (length($name_normalized) == 0);

		$vdr_channel_name_map_normalized{$name_normalized} = $name;
		logging("DEBUG", "Channelmap: normalized VDR channel name: " . sprintf("%-30s (%s)", $name_normalized, $name));
	};

	## Run through service channel names
	logging("DEBUG", "Channelmap: process service channel names (force_hd_channels=" . $opt_force_hd_channels . ")");

        foreach my $id (keys %$service_id_list_hp) {
		my $name = $$service_id_list_hp{$id}->{'name'};
		my $name_normalized = normalize($name);
		my $name_translated = $channel_translations{$name};

		my $vdr_id = undef;

		logging("DEBUG", "Channelmap: process service channel name: " . $name);

		# search for name in VDR channels 1:1
		if (defined $vdr_channels_id_by_name{$name}->{'vdr_id'}) {
			# 1:1 hit
			logging("DEBUG", "Channelmap: service channel name hit (1:1): " . $name);
			$vdr_id = $vdr_channels_id_by_name{$name}->{'vdr_id'};
			goto('VDR_ID_FOUND');
		};

		# search for name in VDR channels (translated)
		if (defined $name_translated) {
			if (defined $vdr_channels_id_by_name{$name_translated}->{'vdr_id'}) {
				logging("DEBUG", "Channelmap: service channel name hit (translated 1:1): " . $name . " = " . $name_translated);
				$vdr_id = $vdr_channels_id_by_name{$name_translated}->{'vdr_id'};
				goto('VDR_ID_FOUND');
			};
		};

		# search for name in VDR channels (normalized)
		if (defined $vdr_channel_name_map_normalized{$name_normalized}) {
			logging("DEBUG", "Channelmap: service channel name hit (normalized): " . $name . " = " . $vdr_channel_name_map_normalized{$name_normalized});
			$vdr_id = $vdr_channels_id_by_name{$vdr_channel_name_map_normalized{$name_normalized}}->{'vdr_id'};
			goto('VDR_ID_FOUND');
		};

		# search for name in VDR channels (translated & normalized)
		if (defined $name_translated) {
			my $name_normalized = normalize($name_translated);
			if (defined $vdr_channel_name_map_normalized{$name_normalized}) {
				logging("DEBUG", "Channelmap: service channel name hit (translated & normalized): " . $name . " = " . $vdr_channel_name_map_normalized{$name_normalized});
				$vdr_id = $vdr_channels_id_by_name{$vdr_channel_name_map_normalized{$name_normalized}}->{'vdr_id'};
				goto('VDR_ID_FOUND');
			};
		};

		# Unmatched channel
		logging("ERROR", "Channelmap: can't find service channel name: " . $name . " (normalized: " . $name_normalized . ")") if ($opt_quiet ne "1");
		next;

VDR_ID_FOUND:
		logging("DEBUG", "Channelmap: found VDR_ID for service channel name: " . $name . " = " . $vdr_id);

		# set vdr_id;
		$$service_id_list_hp{$id}->{'vdr_id'} = $vdr_id;

		next if ($opt_force_hd_channels ne "1");

		# Map to HD channels, when existing
		$name = $$service_id_list_hp{$id}->{'name'} . " HD";
		$name_normalized = normalize($name);
		$name_translated = undef;

		if (defined $channel_translations{$$service_id_list_hp{$id}->{'name'}}) {
			$name_translated = $channel_translations{$$service_id_list_hp{$id}->{'name'}} . " HD";
		};

		logging("DEBUG", "Channelmap: process forced-to-HD service channel name: " . $name . " (" . $name_normalized . ")");

		# search for name in VDR channels 1:1
		if (defined $vdr_channels_id_by_name{$name}->{'vdr_id'}) {
			# 1:1 hit
			logging("DEBUG", "Channelmap: forced-to-HD service channel name hit (1:1): " . $name);
			$vdr_id = $vdr_channels_id_by_name{$name}->{'vdr_id'};
			goto('VDR_ID_FOUND_HD');
		};

		# search for name in VDR channels (translated)
		if (defined $name_translated) {
			if (defined $vdr_channels_id_by_name{$name_translated}->{'vdr_id'}) {
				logging("DEBUG", "Channelmap: forced-to-HD service channel name hit (translated 1:1): " . $name . " = " . $name_translated);
				$vdr_id = $vdr_channels_id_by_name{$name_translated}->{'vdr_id'};
				goto('VDR_ID_FOUND_HD');
			};
		};

		# search for name in VDR channels (normalized)
		if (defined $vdr_channel_name_map_normalized{$name_normalized}) {
			logging("DEBUG", "Channelmap: forced-to-HD service channel name hit (normalized): " . $name . " = " . $vdr_channel_name_map_normalized{$name_normalized} . " HD");
			$vdr_id = $vdr_channels_id_by_name{$vdr_channel_name_map_normalized{$name_normalized}}->{'vdr_id'};
			goto('VDR_ID_FOUND_HD');
		};

		# search for name in VDR channels (translated & normalized)
		if (defined $name_translated) {
			my $name_normalized = normalize($name_translated);
			if (defined $vdr_channel_name_map_normalized{$name_normalized}) {
				logging("DEBUG", "Channelmap: forced-to-HD service channel name hit (translated & normalized): " . $name . " = " . $vdr_channel_name_map_normalized{$name_normalized});
				$vdr_id = $vdr_channels_id_by_name{$vdr_channel_name_map_normalized{$name_normalized}}->{'vdr_id'};
				goto('VDR_ID_FOUND_HD');
			};
		};

		# no HD channel found
		next;

VDR_ID_FOUND_HD:
		logging("DEBUG", "Channelmap: found VDR_ID for forced-to-HD service channel name: " . $name . " = " . $vdr_id);

		# set vdr_id;
		$$service_id_list_hp{$id}->{'vdr_id'} = $vdr_id;
	};
};

return 1;
