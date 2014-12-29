# Project: tvinfomerk2vdr-ng.pl
#
# Support functions for DVR TVHeadend
#
# (C) & (P) 2014 - 2014 by by Peter Bieringer <pb@bieringer.de>
#
# License: GPLv2
#
# Implementation
#  service_data: ',' separated config_name containing $service:$user
#  dvr_data    : folders are stored in config and are separated by ':'
#
# Authors:
#  Peter Bieringer (bie)
#
# Changelog:
# 20141029/bie: new

use strict;
use warnings;
use utf8;

binmode(STDOUT, ":utf8");
binmode(STDERR, ":utf8");

require("inc/protocol-htsp.pl");

## debug/trace information
our %traceclass;
our %debugclass;

## global variables
our $progname;
our $progversion;
our %config;

## activate module
our  @dvr_list_supported;
push @dvr_list_supported, "tvheadend";
our %module_functions;
$module_functions{'dvr'}->{'tvheadend'}->{'autodetect'} = \&dvr_tvheadend_autodetect;
$module_functions{'dvr'}->{'tvheadend'}->{'init'} = \&dvr_tvheadend_init;
$module_functions{'dvr'}->{'tvheadend'}->{'get_channels'} = \&dvr_tvheadend_get_channels;
$module_functions{'dvr'}->{'tvheadend'}->{'get_timers'} = \&dvr_tvheadend_get_timers;
$module_functions{'dvr'}->{'tvheadend'}->{'create_update_delete_timers'} = \&dvr_tvheadend_create_update_delete_timers;

## local variables
my %tvheadend_confignames;
my %tvheadend_configs;

my $port;

## TVHeadend mappings
my %priority_mapping = (
	19 => 'Unimportant',
	39 => 'Low',
	59 => 'Normal',
	79 => 'High',
	99 => 'Important'
);

################################################################################
# autodetect DVR
################################################################################
sub dvr_tvheadend_autodetect() {
	if (
	    -e "/storage/.config/system.d/service.multimedia.tvheadend.service" # openelec

	) {
		return 1;
	};

	return 0;
};


################################################################################
################################################################################
# initialize values from DVR
################################################################################
sub dvr_tvheadend_init() {
	# destination port
	$port = 9981; # default
	if (defined $config{'dvr.port'}) {
		$port = $config{'dvr.port'};
	};

	return(0);
};


################################################################################
################################################################################
# get channels from DVR
# arg1: pointer to channel array
################################################################################
sub dvr_tvheadend_get_channels($) {
	my $channels_ap = $_[0];

	logging("DEBUG", "TVHEADEND: get channels");

	my @adapters;

	my $channels_source_url;
	my $adapters_source_url;
	my $rc;
	my $file;
	my $adapters_file = $config{'dvr.source.file.prefix'} . "-tv-adapter.json";
	my $channels_file = $config{'dvr.source.file.prefix'} . "-channels.json";

	my %channels_via_adapter;

	## preparation for fetching adapters
	$file = undef;
	if ($config{'dvr.source.type'} eq "file") {
		$adapters_source_url = "file://" . $adapters_file;
	} else {
		$adapters_source_url = "http://" . $config{'dvr.host'} . ":" . $port . "/tv/adapter";
		if ($config{'dvr.source.type'} eq "network+store") {
			$file = $adapters_file;
		};
	};

	## fetch adapters
	$rc = protocol_htsp_get_adapters(\@adapters, $adapters_source_url, $file);

	if ($rc != 0) {
		logging("CRIT", "TVHEADEND: protocol_htsp_get_adapters returned an error");
		return(1);
	};

	## run through adapters and get all channels
	foreach my $adapter_hp (@adapters) {
		## preparation for fetching channels
		my $channels_per_adapter_file = $config{'dvr.source.file.prefix'} . "-dvb-services" . $$adapter_hp{'identifier'} . ".json";
		my $channels_per_adapter_source_url;

		$file = undef;
		if ($config{'dvr.source.type'} eq "file") {
			$channels_per_adapter_source_url = "file://" . $channels_per_adapter_file;
		} else {
			$channels_per_adapter_source_url = "http://" . $config{'dvr.host'} . ":" . $port . "/dvb/services/" . $$adapter_hp{'identifier'} . "?op=get";
			if ($config{'dvr.source.type'} eq "network+store") {
				$file = $channels_per_adapter_file;
			};
		};

		$rc = protocol_htsp_get_channels_per_adapter($channels_ap, $channels_per_adapter_source_url, $$adapter_hp{'deliverySystem'}, $file);

		if ($rc != 0) {
			logging("CRIT", "TVHEADEND: protocol_htsp_get_channels_per_adapter returned an error");
			return(1);
		};

		## run through channels and create hash with important information
		foreach my $channel_hp (@$channels_ap) {
			if (! defined $channels_via_adapter{$$channel_hp{'name'}}) {
				$channels_via_adapter{$$channel_hp{'name'}}->{'ca'} = $$channel_hp{'ca'};
				$channels_via_adapter{$$channel_hp{'name'}}->{'group'} = $$channel_hp{'group'};
			};
		};
	};

	## get channels
	$file = undef;
	if ($config{'dvr.source.type'} eq "file") {
		$channels_source_url = "file://" . $channels_file;
	} else {
		$channels_source_url = "http://" . $config{'dvr.host'} . ":" . $port . "/channels?op=list";
		if ($config{'dvr.source.type'} eq "network+store") {
			$file = $channels_file;
		};
	};

	$rc = protocol_htsp_get_channels($channels_ap, $channels_source_url, $file);

	if ($rc != 0) {
		logging("CRIT", "TVHEADEND: protocol_htsp_get_channels returned an error");
		return(1);
	};

	## run through channels and apply information retrieved via adapters
	foreach my $channel_hp (@$channels_ap) {
		if (defined $channels_via_adapter{$$channel_hp{'name'}}) {
			if (defined $channels_via_adapter{$$channel_hp{'name'}}->{'ca'}) {
				$$channel_hp{'ca'} = $channels_via_adapter{$$channel_hp{'name'}}->{'ca'};
			};

			if (defined $channels_via_adapter{$$channel_hp{'name'}}->{'group'}) {
				$$channel_hp{'group'} = $channels_via_adapter{$$channel_hp{'name'}}->{'group'};
			};
		};
	};

	return(0);
};


################################################################################
################################################################################
# get timers from DVR
# arg1: pointer to timer array
################################################################################
sub dvr_tvheadend_get_timers($) {
	my $timers_ap = $_[0];

	my $timers_source_url;
	my $confignames_source_url;
	my $rc;
	my $file;
	my $timers_file = $config{'dvr.source.file.prefix'} . "_dvrlist_upcoming.json";
	my $confignames_file = $config{'dvr.source.file.prefix'} . "-confignames.json";

	my @confignames;
	my @configs;

	## preparation for configs
	$file = undef;
	if ($config{'dvr.source.type'} eq "file") {
		$confignames_source_url = "file://" . $confignames_file;
	} else {
		$confignames_source_url = "http://" . $config{'dvr.host'} . ":" . $port . "/confignames?op=list";
		if ($config{'dvr.source.type'} eq "network+store") {
			$file = $confignames_file;
		};
	};

	## fetch confignames
	$rc = protocol_htsp_get_confignames(\@confignames, $confignames_source_url, $file);

	if ($rc != 0) {
		logging("CRIT", "TVHEADEND: protocol_htsp_get_confignames returned an error");
		return(1);
	};

	foreach my $configname_hp (@confignames) {
		if ($$configname_hp{'identifier'} eq "") {
			$$configname_hp{'identifier'} = "default";
		};

		$tvheadend_configs{$$configname_hp{'identifier'}} = $$configname_hp{'name'};

		## preparation for fetching configs
		my $config_file = $config{'dvr.host'} . "-dvr-config-" . $$configname_hp{'identifier'} . ".json";
		my $config_source_url;

		$file = undef;
		if ($config{'dvr.source.type'} eq "file") {
			$config_source_url = "file://" . $config_file;
		} else {
			$config_source_url = "http://" . $config{'dvr.host'} . ":" . $port . "/dvr?op=loadSettings";
			if ($$configname_hp{'identifier'} ne "default") {
				$config_source_url .= "&config_name=" . $$configname_hp{'identifier'};
			};

			if ($config{'dvr.source.type'} eq "network+store") {
				$file = $config_file;
			};
		};

		$rc = protocol_htsp_get_config(\@configs, $config_source_url, $file);

		if ($rc != 0) {
			logging("CRIT", "TVHEADEND: protocol_htsp_get_config returned an error");
			return(1);
		};

		foreach my $config_hp (@configs) {
			$tvheadend_configs{$$configname_hp{'identifier'}} = $config_hp;
		};

		#foreach my $key (sort keys $tvheadend_configs{$$configname_hp{'identifier'}}) {
		#	printf "%s=%s\n", $key, $tvheadend_configs{$$configname_hp{'identifier'}}->{$key};
		#};
	};

	## preparation for fetching timers
	$file = undef;
	if ($config{'dvr.source.type'} eq "file") {
		$timers_source_url = "file://" . $timers_file;
	} else {
		$timers_source_url = "http://" . $config{'dvr.host'} . ":" . $port . "/dvrlist_upcoming?limit=9999";
		if ($config{'dvr.source.type'} eq "network+store") {
			$file = $timers_file;
		};
	};

	## fetch timers
	$rc = protocol_htsp_get_timers($timers_ap, $timers_source_url, $file);

	if ($rc != 0) {
		logging("CRIT", "TVHEADEND: protocol_htsp_get_timers returned an error");
		return(1);
	};

	foreach my $timer_hp (@$timers_ap) {
		## extract service/dvr data from config of timer
		$$timer_hp{'start_margin'} = $tvheadend_configs{$$timer_hp{'config'}}->{'preExtraTime'};
		$$timer_hp{'stop_margin'} =  $tvheadend_configs{$$timer_hp{'config'}}->{'postExtraTime'};

		$$timer_hp{'dvr_data'} = "";

		## extract service/dvr data
		if ($$timer_hp{'config'} ne "default") {
			# config is equal to service_data
			$$timer_hp{'service_data'} = $$timer_hp{'config'};

			# create list of users
			my @users;
			foreach my $service_user (split(",", $$timer_hp{'service_data'})) {
				$service_user =~ /^([^:]+):([^:]+)$/o;
				my ($service, $user) = ($1, $2);
				push @users, $user;
			};

			#logging("TRACE", "TVHEADEND: list of users: " . join(",", @users));

			# retrieve folder from storage
			my @dvr_data;
			$tvheadend_configs{$$timer_hp{'config'}}->{'storage'} =~ /.*\/([^\/]*)\/?/o;
			if ((defined $1) && (length($1) > 0)) {
				#logging("TRACE", "TVHEADEND: non-empty folder: " . $1);
				my $c = 0;
				foreach my $folder (split(":", $1)) {
					$folder = "." if ((! defined $folder) || ($folder eq ""));
					push @dvr_data, $users[$c] . ":folder:" . $folder;
					$c++;
				};
			} else {
				#logging("TRACE", "TVHEADEND: empty folder");
				foreach my $user (@users) {
					push @dvr_data, $user . ":folder:.";
				};
			};
			#logging("TRACE", "TVHEADEND: dvr data: " . join(",", @dvr_data));
			$$timer_hp{'dvr_data'} = join(",", @dvr_data);
		} else {
			$$timer_hp{'service_data'} = "system:local";
		};

		logging("DEBUG", "TVHEADEND:"
			. " tid="      . sprintf("%-2d", $$timer_hp{'tid'})
			. " cname="    . sprintf("%-20s",$$timer_hp{'cid'})
			. " start="    . strftime("%Y%m%d-%H%M", localtime($$timer_hp{'start_ut'}))
			. " end="      . strftime("%H%M", localtime($$timer_hp{'stop_ut'}))
			. " margins="  . $$timer_hp{'start_margin'} . "/" . $$timer_hp{'stop_margin'}
			. " title='"   . $$timer_hp{'title'} . "'"
			. " s_d="      . $$timer_hp{'service_data'}
			. " d_d="      . $$timer_hp{'dvr_data'}
		);
	};

	return(0);
};


################################################################################
################################################################################
# update timers DVR
# arg1: pointer to timers array
# arg2: pointer to timers action hash
# arg3: pointer to new timers pointers
# 
# TVHEADEND do not support update of timers, means they will be deleted and recreated
################################################################################
sub dvr_tvheadend_create_update_delete_timers($$$) {
	my $timers_dvr_ap = $_[0];
	my $d_timers_action_hp = $_[1];
	my $d_timers_new_ap = $_[2];

	my @d_timers_delete;
	my @d_timers_new;
	my @d_configs_new;

	my $result;
	my $file;
	my $timers_file = $config{'dvr.source.file.prefix'} . "-timers-actions.http";
	my $timers_action_url;

	## preparation for applying actions on timers
	$file = undef;
	if ($config{'dvr.destination.type'} eq "file") {
		$timers_action_url = "file://" . $timers_file;
	} elsif ($config{'dvr.destination.type'} eq "network") {
		$timers_action_url = "http://" . $config{'dvr.host'} . ":" . $port;
	};

	## create map of timers
	my %dvr_timers_array_map;
	for (my $a = 0; $a < scalar(@$timers_dvr_ap); $a++) {
		my $entry_hp = $$timers_dvr_ap[$a];

		$dvr_timers_array_map{$$entry_hp{'tid'}} = $a;
	};

	## run through timers actions
	foreach my $d_timer_num (sort { $a <=> $b } keys %$d_timers_action_hp) {
		my $action = (keys(%{$$d_timers_action_hp{$d_timer_num}}))[0];
		logging("INFO", "TVHEADEND: ACTION tid=" . $d_timer_num . " action=" . $action);
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
			foreach my $key (keys %{$$d_timers_action_hp{$d_timer_num}->{'modify'}}) {
				$timer_new{$key} = $$d_timers_action_hp{$d_timer_num}->{'modify'}->{$key};
			};

			# TODO: adjust dvr_data
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

	## run through new timers and retrieve maximum lifetime
	my $lifetime_max = 0;
	foreach my $timer_hp (@d_timers_new) {
		if ($$timer_hp{'lifetime'} > $lifetime_max) {
			$lifetime_max = $$timer_hp{'lifetime'};
		};
	};

	## run through new timers and adjust/extend informations
	foreach my $timer_hp (@d_timers_new) {
		$$timer_hp{'config'} = $$timer_hp{'service_data'};

		# map priority 0-99 to names
		my $priority_new = "";
		foreach my $limit (sort { $a <=> $b } keys %priority_mapping) {
			if ($$timer_hp{'priority'} <= $limit) {
				$priority_new = $priority_mapping{$limit};
				last;
			};
		};
		if ($priority_new ne "") {
			$$timer_hp{'priority'} = $priority_new;
		} else {
			die "ERROR during priority mapping - FIX CODE";
		};

		my $folder = dvr_create_foldername_from_timer_data($timer_hp, "tvheadend");
		$folder = "" if ($folder eq "."); # clear non-empty folder

		# check configuration
		my $flag_create_adjust_config = undef;

		if (! defined $tvheadend_configs{$$timer_hp{'config'}}) {
			$flag_create_adjust_config = "default";
			logging("INFO", "TVHEADEND: config missing - need to create a new one" . $$timer_hp{'config'});
		} else {
			if (	($tvheadend_configs{$$timer_hp{'config'}}->{'preExtraTime'}  != $config{"dvr.margin.start"})
			    ||	($tvheadend_configs{$$timer_hp{'config'}}->{'postExtraTime'} != $config{"dvr.margin.stop"})
			    ||	($tvheadend_configs{$$timer_hp{'config'}}->{'retention'}     != $lifetime_max)
			) {
				logging("INFO", "TVHEADEND: config need update (margins/retention)"
					. " preExtraTime=" . $tvheadend_configs{$$timer_hp{'config'}}->{'preExtraTime'}
					. " start_margin=" . $config{"dvr.margin.start"}
					. " postExtraTime=" . $tvheadend_configs{$$timer_hp{'config'}}->{'postExtraTime'}
					. " stop_margin=" . $config{"dvr.margin.stop"}
					. " retention=" . $tvheadend_configs{$$timer_hp{'config'}}->{'retention'}
					. " lifetime=" . $lifetime_max
				);
				$flag_create_adjust_config = $$timer_hp{'config'};
			};

			# extract folder from config
			$tvheadend_configs{$$timer_hp{'config'}}->{'storage'} =~ /.*\/([^\/]*)\/?/o;
			my $folder_config = $1;

			if ((length($folder) > 0)
			    &&$folder_config ne $folder
			) {
				logging("INFO", "TVHEADEND: config need update (folder)"
					. " storage=" . $tvheadend_configs{$$timer_hp{'config'}}->{'storage'}
					. " (" . $folder_config . ")"
					. " folder="  . $folder
					. " retention="  . $lifetime_max
				);
				$flag_create_adjust_config = $$timer_hp{'config'};
			};
		};

		if (defined $flag_create_adjust_config) {
			# copy default config
			my $serialized = freeze($tvheadend_configs{$flag_create_adjust_config});
			my %config_new = %{ thaw($serialized) };

			$config_new{'identifier'}    = $$timer_hp{'config'};
			$config_new{'preExtraTime'}  = $config{"dvr.margin.start"};
			$config_new{'postExtraTime'} = $config{"dvr.margin.stop"};
			$config_new{'retention'}     = $lifetime_max;

			if (length($folder) > 0) {
				$config_new{'storage'} = $tvheadend_configs{'default'}->{'storage'};
				$config_new{'storage'} .= "/" if ($config_new{'storage'} !~ /\/$/o);
				$config_new{'storage'} .= $folder;
			};

			logging("INFO", "TVHEADEND: create/update config:"
				. " identifieer="   . $config_new{'identifier'}
				. " preExtraTime="  . $config_new{'preExtraTime'}
				. " postExtraTime=" . $config_new{'postExtraTime'}
				. " retention="     . $config_new{'retention'}
				. " storage="       . $config_new{'storage'}
			);

			push @d_configs_new, \%config_new;

			$tvheadend_configs{$$timer_hp{'config'}} = \%config_new;
		} else {
			# check margins
		}; 
	};

	logging("DEBUG", "TVHEADEND: amount of configs to create/update: " . scalar(@d_configs_new));
	foreach my $config_hp (@d_configs_new) {
		logging("DEBUG", "TVHEADEND: config create/update"
			. " identifier="    . $$config_hp{'identifier'}
			. " storage="       . $$config_hp{'storage'}
			. " preExtraTime="  . $$config_hp{'preExtraTime'}
			. " postExtraTime=" . $$config_hp{'postExtraTime'}
		);
	};

	logging("DEBUG", "TVHEADEND: amount of timers to delete: " . scalar(@d_timers_delete));
	foreach my $timer_num (@d_timers_delete) {
		my $timer_hp = $$timers_dvr_ap[$dvr_timers_array_map{$timer_num}];

		logging("DEBUG", "TVHEADEND: delete"
			. " tid="      . sprintf("%d", $$timer_hp{'tid'})
			. " cid="      . sprintf("%d", $$timer_hp{'cid'})
			. " start="    . strftime("%Y%m%d-%H%M", localtime($$timer_hp{'start_ut'}))
			. " end="      . strftime("%H%M", localtime($$timer_hp{'stop_ut'}))
			. " title='"   . $$timer_hp{'title'} . "'"
			. " s_d="      . $$timer_hp{'service_data'}
			. " d_d="      . $$timer_hp{'dvr_data'}
		);
	};

	logging("DEBUG", "TVHEADEND: amount of timers to add: " . scalar(@d_timers_new));
	foreach my $timer_hp (@d_timers_new) {
		# tvheadend don't support a 'summary'
		logging("DEBUG", "TVHEADEND: new"
			. " cid="      . sprintf("%-2d", $$timer_hp{'cid'})
			. " start="    . strftime("%Y%m%d-%H%M", localtime($$timer_hp{'start_ut'}))
			. " end="      . strftime("%H%M", localtime($$timer_hp{'stop_ut'}))
			. " title='"   . $$timer_hp{'title'} . "'"
			. " config='"  . $$timer_hp{'config'} . "'"
		);
	};

	# delete/add timers
	my $rc = protocol_htsp_delete_add_timers(\@d_timers_delete, \@d_timers_new, \@d_configs_new, $timers_action_url);
	return($rc);
};


#### END
return 1;
