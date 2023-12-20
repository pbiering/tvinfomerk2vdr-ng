# Project: tvinfomerk2vdr-ng.pl
#
#
# Support functions for DVR
#
# (C) & (P) 2014-2023 by by Peter Bieringer <pb@bieringer.de>
#
# License: GPLv2
#
# Authors:
#  Peter Bieringer (bie)
#
# Changelog:
# 20141115/bie: new
# 20231220/bie: skip timer which has no expanded attribute

use strict;
use warnings;
use utf8;

our $foldername_max;
our $titlename_max;

our $debug;
our %debug_class;


###############################################################################
###############################################################################
## Support functions
###############################################################################
###############################################################################

###############################################################################
###############################################################################
## Create a combined folder name from list of folders
# if any of the given folder = ".", then the result is also "."
# if array is empty, also return "."
###############################################################################
sub createfoldername(@) {
	if (scalar(@_) == 0) {
		return(".");
	};

	my %uniq;
	foreach my $folder (@_) {
		# store entries in hash, automatic remove duplicates
		$uniq{$folder} = 1;
	};

	my $length_entry = $foldername_max / scalar(keys %uniq);

	logging("TRACE", "FOLDER: foldername_max=" . $foldername_max . " length_entry=" . $length_entry . " list-of-folders: " . join(",", keys %uniq));

	my $result = "";
	for my $folder (sort keys %uniq) {
		if ($folder eq ".") {
			next; # skip this folder
		};
		$result .= substr($folder, 0, $length_entry);
	};

	$result = "." if ($result eq ""); # map empty to 'no-folder'

	return ($result);
};


###############################################################################
###############################################################################
## Create a combined folder name from timer data
###############################################################################
sub dvr_create_foldername_from_timer_data($;$) {
	my $timer_hp = $_[0];
	my $folder;

	my @folder_list = grep(/:folder:/o, sort split(",", $$timer_hp{'dvr_data'}));
	foreach (@folder_list) {
		s/.*:folder://o; # remove token
	};

	#logging("DEBUG", "folder list=" . join(",", @folder_list));
	if ((defined $_[1]) && ($_[1] eq "tvheadend")) {
		foreach (@folder_list) {
			s/^\.$//o; # replace '.' by empty
		};
		$folder = join(":", @folder_list);

		$folder = "." if ($folder =~ /^:+$/o); # map complete empty folder to 'no-folder'
	} else {
		$folder = createfoldername(@folder_list);
	};

	return ($folder);
};


###############################################################################
###############################################################################
## Shorten title to titlename_max
###############################################################################
sub shorten_titlename($) {
	if (length($_[0]) <= $titlename_max) {
		# nothing to do
		return($_[0]);
	} else {
		return(substr($_[0], 0, $titlename_max - 3) . "...");
	};
};


###############################################################################
###############################################################################
## convert in timers channel name to channel id
# in case of 2 stations share a channel map according to time
###############################################################################
sub dvr_convert_timers_channels($$) {
	my $timers_ap = $_[0];
	my $channels_ap = $_[1];

	#logging("DEBUG", "dvr_convert_timers_channels called");

	# create hash with names and altnames
	my %channels_lookup_by_name;
	my %channels_lookup_by_cid;
	foreach my $channel_hp (@$channels_ap) {
		$channels_lookup_by_name{$$channel_hp{'name'}}->{'cid'}       = $$channel_hp{'cid'};
		$channels_lookup_by_name{$$channel_hp{'name'}}->{'timerange'} = $$channel_hp{'timerange'};

		$channels_lookup_by_cid{$$channel_hp{'cid'}}->{'altnames'}  = $$channel_hp{'altnames'};
		$channels_lookup_by_cid{$$channel_hp{'cid'}}->{'expanded'}  = $$channel_hp{'expanded'};
	};

	## convert channel names stored in cid with real cid
	foreach my $timer_hp (@$timers_ap) {
		if (defined $channels_lookup_by_name{$$timer_hp{'cid'}}) {
			$$timer_hp{'cid'} = $channels_lookup_by_name{$$timer_hp{'cid'}}->{'cid'};
		};
	};

	## check for channels which needs to be expanded
	foreach my $timer_hp (@$timers_ap) {
		next if (! $channels_lookup_by_cid{$$timer_hp{'cid'}}->{'expanded'});
		if ($channels_lookup_by_cid{$$timer_hp{'cid'}}->{'expanded'} == 1) {
			my $timer_start = strftime("%H%M", localtime($$timer_hp{'start_ut'}));
			my $timer_stop  = strftime("%H%M", localtime($$timer_hp{'stop_ut'}));

			logging("DEBUG", "timer found with expanded channel:"
				. " tid="   . $$timer_hp{'tid'}
				. " cid="   . $$timer_hp{'cid'}
				. " start=" . $timer_start
				. " stop="  . $timer_stop
				. " altnames=" . $channels_lookup_by_cid{$$timer_hp{'cid'}}->{'altnames'}
			);

			my $match = 0;
			my $newname;
			my ($channel_start, $channel_stop);
			foreach my $altname (split(",", $channels_lookup_by_cid{$$timer_hp{'cid'}}->{'altnames'})) {
				($channel_start, $channel_stop) = split("-", $channels_lookup_by_name{$altname}->{'timerange'});
				logging("DEBUG", "check against expanded channel:"
					. " start=" . $channel_start
					. " stop="  . $channel_stop
					. " name="  . $altname
				);

				if ($channel_stop > $channel_start) {
					# e.g. 0600-2059
					if (($timer_start >= $channel_start) && ($timer_start <= $channel_stop)) {
						if ($timer_stop <= $channel_stop) {
							$match = 1; #ok
							$newname = $altname;
						} else {
							$match = 2; # stop is out-of-range
							$newname = $altname;
						};
					};
				} else {
					# e.g. 2100-0559
					if (($timer_start >= $channel_start) || ($timer_start <= $channel_stop)) {
						if (($timer_stop >= $channel_start) || ($timer_stop <= $channel_stop)) {
							$match = 1; #ok
							$newname = $altname;
						} else {
							$match = 2; # stop is out-of-range
							$newname = $altname;
						};
					};
				};
				last if ($match > 0);
			};

			if ($match == 1) {
				logging("DEBUG", "selected channel of timer with expanded channel:"
					. " cid="     . $$timer_hp{'cid'}
					. " -> name=" . $newname
					. " cid="     . $channels_lookup_by_name{$newname}->{'cid'}
				);
				$$timer_hp{'cid'} = $channels_lookup_by_name{$newname}->{'cid'};
			} elsif ($match == 2) {
				logging("WARN", "stop time of timer out of expanded channel time range:"
					. " start=" . $channel_start
					. " stop="  . $channel_stop
					. " cid="   . $$timer_hp{'cid'}
					. " -> name=" . $newname
					. " cid="     . $channels_lookup_by_name{$newname}->{'cid'}
				);
				$$timer_hp{'cid'} = $channels_lookup_by_name{$newname}->{'cid'};
			} else {
				logging("CRIT", "no expanded channel found - FIX CODE");
				exit 1;
			};
		};
	};
	return 0;
};

#### END
return 1;
