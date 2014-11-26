# Project: tvinfomerk2vdr-ng.pl
#
# Support functions for DVR VDR
#
# (C) & (P) 2014 - 2014 by by Peter Bieringer <pb@bieringer.de>
#
# License: GPLv2
#
# Implementation
# service_data: ',' separated, stored in summary
# dvr_data    : stored in summary and realized by (shortened) prefix to title
#
# Authors:
#  Peter Bieringer (bie)
#
# Changelog:
# 20141104/bie: partially takeover from tvinfomerk2vdr-ng.pl

use strict;
use warnings;
use utf8;

binmode(STDOUT, ":utf8");
binmode(STDERR, ":utf8");

require("inc/protocol-svdrp.pl");

## debug/trace information
our %traceclass;
our %debugclass;

## global values
our $progname;
our $progversion;
our %config;

## activate module
our  @dvr_list_supported;
push @dvr_list_supported, "vdr";
our %module_functions;
$module_functions{'dvr'}->{'vdr'}->{'init'} = \&dvr_vdr_init;
$module_functions{'dvr'}->{'vdr'}->{'get_channels'} = \&dvr_vdr_get_channels;
$module_functions{'dvr'}->{'vdr'}->{'get_timers'} = \&dvr_vdr_get_timers;
$module_functions{'dvr'}->{'vdr'}->{'create_update_delete_timers'} = \&dvr_vdr_create_update_delete_timers;

## defaults
$config{"dvr.vdr.file.setup"} = "/etc/vdr/setup.conf";
my $port;

################################################################################
################################################################################
# initialize values from DVR
################################################################################
sub dvr_vdr_init() {
	my ($MarginStart, $MarginStop);

	### read margins from VDR setup.conf
	## Missing VDR feature: read such values via SVDRP
	logging("DEBUG", "VDR: try to read margins from setup.conf file: " . $config{"dvr.vdr.file.setup"});
	if(open(FILE, "<" . $config{"dvr.vdr.file.setup"})) {
		while(<FILE>) {
			chomp $_;
			next if ($_ !~ /^Margin(Start|Stop)\s*=\s*([0-9]+)$/o);
			if ($1 eq "Start") {
				$MarginStart = $2; # minutes
				logging("DEBUG", "VDR: setup.conf provide MarginStart: " . $MarginStart);
			} elsif ($1 eq "Stop") {
				$MarginStop = $2; # minutes
				logging("DEBUG", "VDR: setup.conf provide MarginStop : " . $MarginStop);
			};
		};
		close(FILE);
	};

	$config{"dvr.margin.start"} = $MarginStart if defined ($MarginStart);
	$config{"dvr.margin.stop"}  = $MarginStop  if defined ($MarginStop);

	$port = 2001; # default
	if (defined $config{'dvr.port'}) {
		$port = $config{'dvr.port'};
	};

	return 1;
};


################################################################################
################################################################################
# get channels from DVR
# arg1: pointer to channel array
################################################################################
sub dvr_vdr_get_channels($) {
	my $channels_ap = $_[0];

	#print "DEBUG : " . $0 . __FILE__ . (caller(0))[3];
	#
	logging("DEBUG", "get channels from DVR");

	my $channels_source_url;
	my $result;
	my $file;

	$file = undef;

	## preparation for fetching channels
	my $channels_file = $config{'dvr.host'} . "-channels.svdrp";

	$file = undef;
	if ($config{'dvr.source.type'} eq "file") {
		$channels_source_url = "file://" . $channels_file;
	} else {
		$channels_source_url = "svdrp://" . $config{'dvr.host'} . ":" . $port;

		if ($config{'dvr.source.type'} eq "network+store") {
			$file = $channels_file;
		};
	};

	$result = protocol_svdrp_get_channels($channels_ap, $channels_source_url, $file);
};


################################################################################
################################################################################
# get timers from DVR
# arg1: pointer to timer array
################################################################################
sub dvr_vdr_get_timers($) {
	my $timers_ap = $_[0];

	my $timers_source_url;
	my $result;
	my $file;
	my $timers_file = $config{'dvr.host'} . "-timers.svdrp";

	## preparation for fetching timers
	$file = undef;
	if ($config{'dvr.source.type'} eq "file") {
		$timers_source_url = "file://" . $timers_file;
	} else {
		$timers_source_url = "svdrp://" . $config{'dvr.host'} . ":" . $port;

		if ($config{'dvr.source.type'} eq "network+store") {
			$file = $timers_file;
		};
	};

	## fetch timers
	$result = protocol_svdrp_get_timers($timers_ap, $timers_source_url, $file);

	if ($result != 0) {
		die "protocol_svdrp_get_timers";
	};

	## extract service/dvr data
	foreach my $timer_hp (@$timers_ap) {
		$$timer_hp{'service_data'} = "";
		$$timer_hp{'dvr_data'} = "";

		if ($$timer_hp{'summary'} =~ s/\(Timer von TVInfo\)//o) {
			# backward compatibility
			my $service_provider = "tvinfo";

			my @service_data_a;
			my @dvr_data_a;
			my @userlist_a;

			if ($$timer_hp{'summary'} =~ s/\(tvinfo-user=([^)]*)\)//o) {
				my $service_user = $1;

				foreach my $user (split(",", $service_user)) {
					push @userlist_a, $user;
					push @service_data_a, $service_provider . ":" . $user;
				};
				$$timer_hp{'service_data'} = join(",", @service_data_a);
			};

			if ($$timer_hp{'summary'} =~ s/\(tvinfo-folder=([^)]*)\)//o) {
				my $dvr_user_data = $1;

				my $i = 0;
				foreach my $data (split(",", $dvr_user_data)) {
					push @dvr_data_a, $userlist_a[$i] . ":folder:" . $data if defined ($userlist_a[$i]);
					$i++;
				};
				$$timer_hp{'dvr_data'} = join(",", @dvr_data_a);
			};
		};

		# new data storage format
		if ($$timer_hp{'summary'} =~ s/\(service-data=([^)]*)\)//o) {
			$$timer_hp{'service_data'} = $1;
		};

		if ($$timer_hp{'summary'} =~ s/\(dvr-data=([^)]*)\)//o) {
			$$timer_hp{'dvr_data'} = $1;
		};

		if ($$timer_hp{'summary'} =~ s/\(dvr-margins=(\d+)\/(\d+)\)//o) {
			$$timer_hp{'start_margin'} = $1;
			$$timer_hp{'stop_margin'}  = $2;
		};

		# default margin handling
		$$timer_hp{'start_margin'} = $config{"dvr.margin.start"} if (! defined $$timer_hp{'start_margin'});
		$$timer_hp{'stop_margin'}  = $config{"dvr.margin.stop"}  if (! defined $$timer_hp{'stop_margin'});

		# adjust timer start/stop with margins
		$$timer_hp{'start_ut'} += $$timer_hp{'start_margin'} * 60; # seconds
		$$timer_hp{'stop_ut'}  -= $$timer_hp{'stop_margin'}  * 60; # seconds

		# remove trailing |
		$$timer_hp{'summary'} =~ s/\|$//o;

		# remove folder from title
		my $folder;
		if ($$timer_hp{'title'} =~ /^([^~]*)~(.*)/) {
			$folder = $1;
			$$timer_hp{'title'} = $2;
		} else {
			$folder = "."; # 'no-folder'
		};

		# fallback defaults
		if ($$timer_hp{'service_data'} eq "") {
			$$timer_hp{'service_data'} = "system:local";
		};

		if ($$timer_hp{'dvr_data'} eq "") {
			if (defined $folder) {
				$$timer_hp{'dvr_data'} = "local:folder:" . $folder;
			};
		};

		logging("DEBUG", "VDR:"
			. " tid="      . sprintf("%3d", $$timer_hp{'tid'})
			. " cid="      . sprintf("%3d", $$timer_hp{'cid'})
			. " start="    . strftime("%Y%m%d-%H%M", localtime($$timer_hp{'start_ut'}))
			. " end="      . strftime("%H%M", localtime($$timer_hp{'stop_ut'}))
			. " margins="  . $$timer_hp{'start_margin'} . "/" . $$timer_hp{'stop_margin'}
			. " title='"   . $$timer_hp{'title'} . "'"
			. " summary='" . $$timer_hp{'summary'} . "'"
			. " s_d="      . $$timer_hp{'service_data'}
			. " d_d="      . $$timer_hp{'dvr_data'}
		);
	};

	logging("DEBUG", "VDR: amount of timers received via SVDRP/file: " . scalar(@$timers_ap));
};


################################################################################
################################################################################
# update timers DVR
# arg1: pointer to timers array
# arg2: pointer to timers action hash
# arg3: pointer to new timers pointers
# 
# VDR do not support update of timers, means they will be deleted and recreated
################################################################################
sub dvr_vdr_create_update_delete_timers($$$) {
	my $timers_dvr_ap = $_[0];
	my $d_timers_action_hp = $_[1];
	my $d_timers_new_ap = $_[2];

	my @d_timers_delete;
	my @d_timers_new;

	my $result;
	my $file;
	my $timers_file = $config{'dvr.host'} . "-timers-actions.svdrp";
	my $timers_action_url;

	## preparation for applying actions on timers
	$file = undef;
	if ($config{'dvr.destination.type'} eq "file") {
		$timers_action_url = "file://" . $timers_file;
	} elsif ($config{'dvr.destination.type'} eq "network") {
		$timers_action_url = "svdrp://" . $config{'dvr.host'} . ":" . $port;
	};

	## create map of timers
	my %dvr_timers_array_map;
	for (my $a = 0; $a < scalar(@$timers_dvr_ap); $a++) {
		my $entry_hp = $$timers_dvr_ap[$a];

		$dvr_timers_array_map{$$entry_hp{'tid'}} = $a;
	};

	## run through timers actions
	foreach my $d_timer_num (sort { $a <=> $b } keys %$d_timers_action_hp) {
		my $action = (keys($$d_timers_action_hp{$d_timer_num}))[0];
		#logging("INFO", "VDR-ACTION: tid=" . $d_timer_num . " action=" . $action);
		if ($action eq "delete") {
			push @d_timers_delete, $d_timer_num;
		} elsif ($action eq "modify") {
			# lookup timer
			my $dvr_timer_array_num = $dvr_timers_array_map{$d_timer_num};

			my $timer_hp = $$timers_dvr_ap[$dvr_timer_array_num];

			# copy timer
			my $serialized = freeze($timer_hp);
			my %timer_new = %{ thaw($serialized) };

			# modify copied timer
			foreach my $key (keys $$d_timers_action_hp{$d_timer_num}->{'modify'}) {
				$timer_new{$key} = $$d_timers_action_hp{$d_timer_num}->{'modify'}->{$key};
			};

			push @d_timers_new, \%timer_new;
			push @d_timers_delete, $d_timer_num;
		} else {
			die "unsupported action: $action - FIX CODE";
		};
	};

	## run through timers actions
	foreach my $timer_hp (@$d_timers_new_ap) {
		# push timer to list
		push @d_timers_new, $timer_hp;
	};

	## run through new timers and adjust/extend informations
	foreach my $timer_hp (@d_timers_new) {
		# Set margins
		$$timer_hp{'start_margin'} = $config{"dvr.margin.start"} if (! defined $$timer_hp{'start_margin'});
		$$timer_hp{'stop_margin'}  = $config{"dvr.margin.stop"}  if (! defined $$timer_hp{'stop_margin'});

		# Apply margins
		$$timer_hp{'start_ut'} -= $$timer_hp{'start_margin'} * 60; # seconds
		$$timer_hp{'stop_ut'}  += $$timer_hp{'stop_margin'}  * 60; # seconds

		## append dvr_data and service_data to summary
		$$timer_hp{'summary'} .= "|"
			. "(service-data=" . $$timer_hp{'service_data'} . ")"
			. "(dvr-data="     . $$timer_hp{'dvr_data'} . ")"
			. "(dvr-margins="  . $$timer_hp{'start_margin'} . "/" . $$timer_hp{'stop_margin'} . ")"
		;

		my $folder = dvr_create_foldername_from_timer_data($timer_hp);

		if ((length($folder) > 0) && ($folder ne ".")) {
			$$timer_hp{'title'} = $folder . "~" . $$timer_hp{'title'};
		};
	};

	logging("DEBUG", "VDR: amount of timers to delete: " . scalar(@d_timers_delete));
	foreach my $timer_num (@d_timers_delete) {
		my $timer_hp = $$timers_dvr_ap[$dvr_timers_array_map{$timer_num}];

		logging("DEBUG", "VDR: delete"
			. " tid="      . sprintf("%d", $$timer_hp{'tid'})
			. " cid="      . sprintf("%d", $$timer_hp{'cid'})
			. " start="    . strftime("%Y%m%d-%H%M", localtime($$timer_hp{'start_ut'}))
			. " end="      . strftime("%H%M", localtime($$timer_hp{'stop_ut'}))
			. " title='"   . $$timer_hp{'title'} . "'"
			. " summary='" . $$timer_hp{'summary'} . "'"
			. " s_d="      . $$timer_hp{'service_data'}
			. " d_d="      . $$timer_hp{'dvr_data'}
		);
	};

	logging("DEBUG", "VDR: amount of timers to add: " . scalar(@d_timers_new));
	foreach my $timer_hp (@d_timers_new) {
		logging("DEBUG", "VDR: new"
			. " cid="      . sprintf("%d", $$timer_hp{'cid'})
			. " start="    . strftime("%Y%m%d-%H%M", localtime($$timer_hp{'start_ut'}))
			. " end="      . strftime("%H%M", localtime($$timer_hp{'stop_ut'}))
			. " title='"   . $$timer_hp{'title'} . "'"
			. " summary='" . $$timer_hp{'summary'} . "'"
		);
	};

	# delete/add timers
	protocol_svdrp_delete_add_timers(\@d_timers_delete, \@d_timers_new, $timers_action_url);
};


#### END
return 1;
