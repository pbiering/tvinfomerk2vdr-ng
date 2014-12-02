# Project: tvinfomerk2vdr-ng.pl
#
# Support functions for channels
#
# (C) & (P) 2014 - 2014 by by Peter Bieringer <pb@bieringer.de>
#
# License: GPLv2
#
# Authors:
#  Peter Bieringer (bie)
#
# Changelog:
# 20141107/bie: new

use strict;
use warnings;
use utf8;

binmode(STDOUT, ":utf8");
binmode(STDERR, ":utf8");

use Storable qw(dclone freeze thaw);

our $debug;
our %debug_class;

###############################################################################
## Functions
###############################################################################

###############################################################################
## print DVR channels
###############################################################################
sub print_dvr_channels($) {
	my $channels_ap = $_[0];

	my $name_maxlen = 0;
	my $group_maxlen = 0;
	foreach my $channel_hp (@$channels_ap) {
		if (length($$channel_hp{'name'}) > $name_maxlen) {
			$name_maxlen = length($$channel_hp{'name'});
		};
		if (length($$channel_hp{'group'}) > $group_maxlen) {
			$group_maxlen = length($$channel_hp{'group'});
		};
	};

	foreach my $channel_hp (sort { $$a{'group'} cmp $$b{'group'} } sort { $$a{'name'} cmp $$b{'name'} } @$channels_ap) {
		my $time = "";

		if (defined $$channel_hp{'timerange'}) {
			$time = "  timerange=" . $$channel_hp{'timerange'};
		};

		logging("DEBUG", sprintf("channel  cid=%5s  source=%s  type=%s  ca=%d  name=%-" . $name_maxlen . "s  group=%-" . $group_maxlen . "s  altnames=%s%s",
			$$channel_hp{'cid'},
			$$channel_hp{'source'},
			$$channel_hp{'type'},
			$$channel_hp{'ca'},
			$$channel_hp{'name'},
			$$channel_hp{'group'},
			$$channel_hp{'altnames'},
			$time,
		));
	};
};


###############################################################################
## expand DVR channels
# check for stations which share a channel and expand them
###############################################################################
sub expand_dvr_channels($) {
	my $channels_ap = $_[0];

	#logging("DEBUG", "expand_dvr_channels called");

	# run through given channels
	foreach my $channel_hp (@$channels_ap) {
		if ($$channel_hp{'name'} eq "neo/KiKA") {
			$$channel_hp{'altnames'} .= "zdf_neo,KiKa";
			$$channel_hp{'expanded'} = 1;

			# clone and apply timerange
			my $serialized = freeze $channel_hp;
			my %copy1 = %{ thaw($serialized) };
			my %copy2 = %{ thaw($serialized) };

			logging("INFO", "CHANNELS: found DVR channel having 2 stations (expand): " . $$channel_hp{'name'});

			$copy1{'name'} = "zdf_neo";
			$copy1{'timerange'} = "2100-0559";
			$copy1{'altnames'} = $$channel_hp{'name'}; # store original name in altnames
			$copy1{'origcid'}  = $$channel_hp{'cid'};  # store original cid in origcid
			$copy1{'cid'} .= "#1";
			push @$channels_ap, \%copy1;

			$copy2{'name'} = "KiKa";
			$copy2{'timerange'} = "0600-2059";
			$copy2{'altnames'} = $$channel_hp{'name'}; # store original name in altnames
			$copy2{'origcid'}  = $$channel_hp{'cid'};  # store original cid in origcid
			$copy2{'cid'} .= "#2";
			push @$channels_ap, \%copy2;
		} else {
			$$channel_hp{'expanded'} = 0;
		};
	};
};

###############################################################################
## filter DVR channels
###############################################################################
sub filter_dvr_channels($$$) {
	my $channels_ap = $_[0];
	my $channels_filtered_ap = $_[1];
	my $channel_filter_hp = $_[2];

	my $include_ca_channels = 0;
	my @whitelist_ca_groups;

	# check filter options
	if (defined $$channel_filter_hp{'include_ca_channels'}) {
		logging("DEBUG", "CHANNELS: option 'include_ca_channels' specified: " . $$channel_filter_hp{'include_ca_channels'});
		$include_ca_channels = $$channel_filter_hp{'include_ca_channels'};
	};

	if (defined $$channel_filter_hp{'whitelist_ca_groups'} && $$channel_filter_hp{'whitelist_ca_groups'} ne "") {
		logging("DEBUG", "CHANNELS: option 'whitelist_ca_groups' specified: " . $$channel_filter_hp{'whitelist_ca_groups'});
		@whitelist_ca_groups = split /,/, $$channel_filter_hp{'whitelist_ca_groups'};
	};

	# run through given channels
	foreach my $channel_hp (sort { $$a{'group'} cmp $$b{'group'} } sort { $$a{'name'} cmp $$b{'name'} } @$channels_ap) {
		if ($$channel_hp{'ca'} ne "0") {
			# skip non-free channels depending on option

			if ($include_ca_channels eq "0") {
				# generally disabled
				logging("DEBUG", "CHANNELS: skip DVR channel(CA): " . $$channel_hp{'name'});
				next;
			};

			if ($$channel_filter_hp{'whitelist_ca_groups'} ne "*") {
				if (! grep { /^$$channel_hp{'group'}$/i } @whitelist_ca_groups) {
					# group not in whitelist
					logging("DEBUG", "CHANNELS: skip DVR channel(CA): " . $$channel_hp{'name'} . " (cA group not in whitelist: " . $$channel_hp{'group'} . ")");
					next;
				};
			};
		} else {
			# TODO blacklist others
			if ($$channel_hp{'name'} =~ /^(Sky Select.*)$/o) {
				# skip special channels channels depending on name and option
				if ($include_ca_channels eq "0") {
					# generally disabled
					logging("DEBUG", "CHANNELS: skip DVR channel(CA-like): " . $$channel_hp{'name'});
					next;
				};
			};
		};

		logging("TRACE", "CHANNELS: copy DVR channel: " . $$channel_hp{'name'});
		push @$channels_filtered_ap, $channel_hp;
	};
};


###############################################################################
## get channel name by cid
###############################################################################
sub get_channel_name_by_cid($$) {
	my $channels_ap = $_[0];
	my $cid = $_[1];

	# run through given channels
	foreach my $channel_hp (@$channels_ap) {
		if ($$channel_hp{'cid'} eq $cid) {
			return $$channel_hp{'name'};
		};
	};

	die("cid=" . $cid . " not found");
};


###############################################################################
## print service channels
###############################################################################
sub print_service_channels($) {
	my $channels_ap = $_[0];

	my $name_maxlen = 0;
	foreach my $channel_hp (@$channels_ap) {
		if (length($$channel_hp{'name'}) > $name_maxlen) {
			$name_maxlen = length($$channel_hp{'name'});
		};
	};

	foreach my $channel_hp (sort { $$a{'name'} cmp $$b{'name'} } @$channels_ap) {
		logging("DEBUG", sprintf("CHANNELS: cid=%4d  enabled=%d name=%-" . $name_maxlen . "s  altnames=%s",
			$$channel_hp{'cid'},
			$$channel_hp{'enabled'},
			$$channel_hp{'name'},
			$$channel_hp{'altnames'},
		));
	};
};

###############################################################################
## filter DVR channels
###############################################################################
sub filter_service_channels($$$) {
	my $channels_ap = $_[0];
	my $channels_filtered_ap = $_[1];
	my $channel_filter_hp = $_[2];

	my $skip_not_enabled = 0;

	# check filter options
	if (defined $$channel_filter_hp{'skip_not_enabled'}) {
		logging("DEBUG", "CHANNEL: option 'skip_not_enabled' specified: " . $$channel_filter_hp{'skip_not_enabled'});
		$skip_not_enabled = $$channel_filter_hp{'skip_not_enabled'};
	};

	# run through given channels
	foreach my $channel_hp (sort { $$a{'name'} cmp $$b{'name'} } @$channels_ap) {
		if ($$channel_hp{'enabled'} eq "0") {
			# skip not-enabled channels

			if ($skip_not_enabled ne "0") {
				# generally disabled
				logging("TRACE", "CHANNEL: skip channel(not-enabled): " . $$channel_hp{'name'});
				next;
			};
		};

		logging("TRACE", "CHANNEL: copy channel: " . $$channel_hp{'name'});
		push @$channels_filtered_ap, $channel_hp;
	};
};


###############################################################################
## print service/dvr channel map
###############################################################################
sub print_service_dvr_channel_map($$;$) {
	my $service_cid_to_dvr_cid_map_hp = $_[0];
	my $channels_dvr_ap = $_[1];
	my $info_level = $_[2];

	my $d_cid_maxlen = 0;
	my $s_name_maxlen = 0;
	my $d_cid_flag = ""; # default, right alignment

	my $count_all = 0;
	my $count_match = 0;
	my $count_notfound = 0;

	foreach my $s_cid (keys %$service_cid_to_dvr_cid_map_hp) {
		if (length($$service_cid_to_dvr_cid_map_hp{$s_cid}->{'name'}) > $s_name_maxlen) {
			$s_name_maxlen = length($$service_cid_to_dvr_cid_map_hp{$s_cid}->{'name'});
		};

		if (defined $$service_cid_to_dvr_cid_map_hp{$s_cid}->{'cid'} &&
			length($$service_cid_to_dvr_cid_map_hp{$s_cid}->{'cid'}) > $d_cid_maxlen) {
			if ($$service_cid_to_dvr_cid_map_hp{$s_cid}->{'cid'} !~ /^[0-9]+$/o) {
				$d_cid_flag = "-"; # text, left alignment
			};
			$d_cid_maxlen = length($$service_cid_to_dvr_cid_map_hp{$s_cid}->{'cid'});
		};
	};


	logging("INFO", "SERVICE => DVR channel mapping result") if (defined $info_level);

	foreach my $s_cid (sort { lc($$service_cid_to_dvr_cid_map_hp{$a}->{'name'}) cmp lc($$service_cid_to_dvr_cid_map_hp{$b}->{'name'}) } keys %$service_cid_to_dvr_cid_map_hp) {
		my $d_cid  = $$service_cid_to_dvr_cid_map_hp{$s_cid}->{'cid'};
		my $s_name = $$service_cid_to_dvr_cid_map_hp{$s_cid}->{'name'};

		$count_all++;

		if (! defined $d_cid || $d_cid eq "0" || $d_cid eq "") {
			logging("WARN", "SERVICE: no DVR channel found: " . sprintf("%-" . $s_name_maxlen . "s %3d", $s_name, $s_cid) . " (candidate for deselect)");
			$count_notfound++;
			next;
		};

		$count_match++;

		my $d_name = get_channel_name_by_cid($channels_dvr_ap, $d_cid);

		my $loglevel = "DEBUG";
		$loglevel = "INFO" if (defined $info_level);

		logging($loglevel, "SERVICE: DVR channel mapping : " . sprintf("%-" . $s_name_maxlen . "s %3d => %" . $d_cid_flag . $d_cid_maxlen . "s  %s", $s_name, $s_cid,$d_cid, $d_name));
	};

	my $loglevel = "INFO";
	$loglevel = "WARN" if ($count_notfound > 0);
	logging($loglevel, "SERVICE => DVR channel mapping statistics: num=" . $count_all . " match=" . $count_match . " notfound=" . $count_notfound);
};


###############################################################################
## print special service/dvr channel map
# TODO: bring back to work
###############################################################################
sub print_service_dvr_channel_map_special($$;$) {

	my %tvinfo_AlleSender_id_list;
	my @channels;
	my %tvinfo_MeineSender_id_list;
	my $MeineSender_count;

	##############################
	## Channel Check 'Alle Sender'
	##############################

	logging("INFO", "AlleSender: VDR Channel mapping result (TVinfo-Name TVinfo-ID Match-Flag(*) VDR-Name VDR-Bouquet");

	my $AlleSender_count = 0;
	my $AlleSender_count_nomatch = 0;
	foreach my $id (sort { lc($tvinfo_AlleSender_id_list{$a}->{'name'}) cmp lc($tvinfo_AlleSender_id_list{$b}->{'name'}) } keys %tvinfo_AlleSender_id_list) {
		my $vdr_id   = $tvinfo_AlleSender_id_list{$id}->{'vdr_id'};

		if (! defined $vdr_id || $vdr_id == 0) {
			$AlleSender_count_nomatch++;
			next;
		};

		$AlleSender_count++;

		my $name     = $tvinfo_AlleSender_id_list{$id}->{'name'};
		my ($vdr_name, $vdr_bouquet) = split /;/, encode("iso-8859-1", decode("utf8", ${$channels[$vdr_id - 1]}{'name'}));
		$vdr_bouquet = "" if (! defined $vdr_bouquet);

		my $checked = ""; my $ca = "";
		$checked = "*" if (defined $tvinfo_MeineSender_id_list{$id}->{'vdr_id'});

		$ca = "CA" if (${$channels[$vdr_id - 1]}{'ca'} ne "0");

		my $loglevel = "DEBUG";

		logging($loglevel, "AlleSender: VDR Channel mapping: " . sprintf("%-20s %4d %1s %2s %-30s %-15s", $name, $vdr_id, $checked, $ca, $vdr_name, $vdr_bouquet));
	};

	foreach my $id (sort { lc($tvinfo_AlleSender_id_list{$a}->{'name'}) cmp lc($tvinfo_AlleSender_id_list{$b}->{'name'}) } keys %tvinfo_AlleSender_id_list) {
		my $vdr_id   = $tvinfo_AlleSender_id_list{$id}->{'vdr_id'};

		if (defined $vdr_id) {
			next;
		};

		my $name     = $tvinfo_AlleSender_id_list{$id}->{'name'};

		logging("DEBUG", "AlleSender: VDR Channel mapping missing: " . sprintf("%-20s", $name));
	};
	logging("INFO", "AlleSender amount (cross-check summary): " . $AlleSender_count . " (delta=" . ($AlleSender_count - $MeineSender_count) . " [should be 0] nomatch=" . $AlleSender_count_nomatch ." [station not existing in VDR])");

		logging("NOTICE", "End of Channel Map results (stop here on request)");
};

#### END
return 1;
