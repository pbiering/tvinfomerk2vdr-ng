# Project: tvinfomerk2vdr-ng.pl
#
# Support functions for HTSP backends like TVHeadend API
#
# (C) & (P) 2014 - 2014 by by Peter Bieringer <pb@bieringer.de>
#
# License: GPLv2
#
# Authors:
#  Peter Bieringer (bie)
#
# Changelog:
# 20141028/bie: new
# 20141229/bie: improved error handling

use strict;
use warnings;
use utf8;

use JSON;
use Data::Dumper;
use LWP;
use HTTP::Request::Common;
use POSIX qw(strftime);

binmode(STDOUT, ":utf8");
binmode(STDERR, ":utf8");

## internal web requests
my $htsp_client = LWP::UserAgent->new;
$htsp_client->agent("Mozilla/4.0 (tvinfomerk2vdr-ng)");

## debug/trace information
our %traceclass;
our %debugclass;

our %config;

################################################################################
################################################################################
# get generic via HTSP
# return code: =0:ok !=0:problem
################################################################################
sub protocol_htsp_get_generic($$;$) {
	my $contents_json_p = $_[0];
	my $source_url = $_[1];
	my $file_write_raw = $_[2];

	logging("DEBUG", "HTSP: source_url=$source_url");

	$source_url =~ /^(file|https?):\/\/(.*)$/o;

	if (! defined $1 || ! defined $2) {
		die "Unsupported source_url=$source_url - FIX CODE";
	};

	my $source = $1;
	my $location = $2;

	if ($source eq "file") {
		logging("INFO", "HTSP: read raw contents from file: " . $location);
		if (!open(FILE, "<$location")) {
			logging("ERROR", "HTSP: can't read raw contents from file: " . $location . " (" . $! . ")");
			return(1);
		};
		$$contents_json_p = <FILE>;
		close(FILE);
	} else {
		my $req = HTTP::Request->new(GET => $source_url);

		if (defined $config{'dvr.credentials'}) {
			my ($user, $pass) = split ":",$config{'dvr.credentials'};
			$req->authorization_basic($user, $pass);
		};

		my $response = $htsp_client->request($req);

		if (! $response->is_success) {
			logging("ERROR", "HTSP: can't fetch: " . $source_url . ($response->status_line));
			return(1);
		};

		$$contents_json_p = $response->content;

		if (defined $file_write_raw) {
			logging("NOTICE", "HTSP: write raw contents to file: " . $file_write_raw);
			if (!open(FILE, ">$file_write_raw")) {
				logging("ERROR", "HTSP: can't write raw contents to file: " . $location . " (" . $! . ")");
				return(1);
			};
			print FILE $$contents_json_p;
			close(FILE);
			logging("NOTICE", "HTSP: raw contents written to file: " . $file_write_raw);
		};
	};

	return(0);
};


################################################################################
################################################################################
# get channels via HTSP
# arg1: pointer to channel array
# arg2: URL of channels source
# debug
# trace:   print contents using Dumper
# 	 2=print raw contents
# return code: =0:ok !=0:problem
#        
# JSON structure:
#   {
#          'entries' => [
#                         {
#                           'epg_post_end' => 0,
#                           'chid' => 51,
#                           'number' => 0,
#                           'tags' => '',
#                           'name' => '1-2-3.tv interactive (Internet)',
#                           'epg_pre_start' => 0
#                         },
#                         {
#                           'epg_post_end' => 0,
#                           'chid' => 7,
#                           'number' => 0,
#                           'tags' => '1,2,3',
#                           'name' => '3sat',
#                           'epg_pre_start' => 0
#                         },
#                         ...
################################################################################
sub protocol_htsp_get_channels($$;$) {
	my $channels_p = $_[0];
	my $channels_source_url = $_[1];
	my $channels_file_write_raw = $_[2];

	$channels_source_url =~ /^(file|https?):\/\/(.*)$/o;

	if (! defined $1 || ! defined $2) {
		die "Unsupported channels_source_url=$channels_source_url - FIX CODE";
	};

	my $source = $1;
	my $location = $2;

	my $contents_json;

	undef @$channels_p;

	if ($source eq "file") {
		logging("INFO", "HTSP: read raw contents from file: " . $location);
		if (!open(FILE, "<$location")) {
			logging("ERROR", "HTSP: can't read raw contents from file: " . $location . " (" . $! . ")");
			return(1);
		};
		$contents_json = <FILE>;
		close(FILE);
	} else {
		my $req = HTTP::Request->new(GET => $channels_source_url);

		if (defined $config{'dvr.credentials'}) {
			my ($user, $pass) = split ":",$config{'dvr.credentials'};
			$req->authorization_basic($user, $pass);
		};

		my $response = $htsp_client->request($req);

		if (! $response->is_success) {
			logging("ERROR", "HTSP: can't fetch channels(services): " . $response->status_line);
			return(1);
		};

		$contents_json = $response->content;

		if (defined $channels_file_write_raw) {
			logging("NOTICE", "JSON write raw channels contents to file: " . $channels_file_write_raw);
			if (!open(FILE, ">$channels_file_write_raw")) {
				logging("ERROR", "HTSP: can't write raw contents to file: " . $channels_file_write_raw . " (" . $! . ")");
				return(1);
			};
			print FILE $contents_json;
			close(FILE);
			logging("NOTICE", "JSON raw contents of channels written to file written: " . $channels_file_write_raw);
		};
	};

	if (defined $traceclass{'HTSP'} && ($traceclass{'HTSP'} & 0x1000)) {
		print "TRACE : JSON contents RAW\n";
		print "$contents_json\n";
	};

	my @contents_json_decoded = JSON->new->utf8->decode($contents_json);

	if (defined $traceclass{'HTSP'} && ($traceclass{'HTSP'} & 0x2000)) {
		print "TRACE : JSON contents DUMPER\n";
		print Dumper(@contents_json_decoded);
	};

	foreach my $key (@contents_json_decoded) {
		#print "TRACE : key=$key\n" if defined ($traceclass{'HTSP'});
		if (ref($key) ne "HASH") {
			print "WARN  : key=$key is not a hash reference - skip\n";
			next;
		};

		if (! defined $$key{'entries'}) {
			print "WARN  : key=$key is hash reference, but missing 'entries' key - skip\n";
			next;
		};

		foreach my $entry(@{$$key{'entries'}}) {
			my ($name, $type);

			if (! defined $$entry{'name'}) {
				# skip if not defined: channelname
				next;
			};

			# check: channelname
			if ($$entry{'name'} =~ /\(Internet\)/o) {
				# skip if matching: (Internet)
				print "TRACE : found channel name=" . $$entry{'name'} . " but skip (hardcoded blacklist)\n"  if (defined $traceclass{'HTSP'} && ($traceclass{'HTSP'} && 0x1000));
				next;
			};
			$name = $$entry{'name'};

			logging("TRACE", "found channel name='" . $name . "'"
				. " cid="  . $$entry{'chid'}
			);

			push @$channels_p, {
				'cid'      => $$entry{'chid'},
				'name'     => $name,
				'altnames' => "",
				'type'     => "n/a"   , # unknown via this interface
				'source'   => "n/a"   , # unknown via this interface
				'ca'       => 0,     # unknown via this interface
				'sid'      => "n/a"   , # unknown via this interface
				'group'    => "n/a"   , # unknown via this interface
			};
		};
	};
};


################################################################################
################################################################################
# get channels per adapter via HTSP
# arg1: pointer to channel array
# arg2: URL of channels source
# arg3: adapter
# debug
# trace:   print contents using Dumper
# 	 2=print raw contents
# return code: =0:ok !=0:problem
#        
# JSON structure:
#   {
#          'entries' => [
#                         {
#                           'mux' => '738,000 kHz',
#                           'network' => 'ARD BR',
#                           'enabled' => 1,
#                           'typenum' => 1,
#                           'svcname' => 'arte',
#                           'pmt' => 32,
#                           'id' => '_dev_dvb_adapter0_Siano_Mobile_Digital_MDTV_Receiver738000000_0002',
#                           'prefcapid' => 0,
#                           'pcr' => 33,
#                           'provider' => 'BR',
#                           'dvb_eit_enable' => 1,
#                           'channel' => 0,
#                           'channelname' => 'arte',
#                           'typestr' => 'SDTV',
#                           'sid' => 2,
#                           'type' => 'SDTV (0x0001)'
#                           'encryption' => 'BetaCrypt',
#                         },
#
# sid	Service ID
################################################################################
sub protocol_htsp_get_channels_per_adapter($$$;$) {
	my $channels_p = $_[0];
	my $channels_source_url = $_[1];
	my $deliverySystem = $_[2];
	my $channels_file_write_raw = $_[3];

	#print "DEBUG : channels_source_url=$channels_source_url channels_file_write_raw=$channels_file_write_raw\n" if defined ($debugclass{'HTSP'});

	$channels_source_url =~ /^(file|https?):\/\/(.*)$/o;

	if (! defined $1 || ! defined $2) {
		die "Unsupported channels_source_url=$channels_source_url - FIX CODE";
	};

	my $source = $1;
	my $location = $2;

	my $contents_json;

	# convert deliverySystem
	my $channel_source;
	if ($deliverySystem =~ /^DVB-([CST])$/o) {
		$channel_source = $1;
	} else {
		die "unsupported deliverySystem=$deliverySystem - FIX CODE";
	};

	undef @$channels_p;

	if ($source eq "file") {
		logging("INFO", "HTSP: read raw contents from file: " . $location);
		if (!open(FILE, "<$location")) {
			logging("ERROR", "HTSP: can't read raw contents from file: " . $location . " (" . $! . ")");
			return(1);
		};
		$contents_json = <FILE>;
		close(FILE);
	} else {
		my $req = HTTP::Request->new(GET => $channels_source_url);

		if (defined $config{'dvr.credentials'}) {
			my ($user, $pass) = split ":",$config{'dvr.credentials'};
			$req->authorization_basic($user, $pass);
		};

		my $response = $htsp_client->request($req);

		if (! $response->is_success) {
			logging("ERROR", "HTSP: can't fetch channels(services): " . $response->status_line);
			return(1);
		};

		$contents_json = $response->content;

		if (defined $channels_file_write_raw) {
			logging("NOTICE", "JSON write raw channels contents to file: " . $channels_file_write_raw);
			if (!open(FILE, ">$channels_file_write_raw")) {
				logging("ERROR", "HTSP: can't write raw contents to file: " . $channels_file_write_raw . " (" . $! . ")");
				return(1);
			};
			print FILE $contents_json;
			close(FILE);
			logging("NOTICE", "JSON raw contents of channels written to file written: " . $channels_file_write_raw);
		};
	};

	if (defined $traceclass{'HTSP'} && ($traceclass{'HTSP'} & 0x0010)) {
		print "TRACE : JSON contents RAW\n";
		print "$contents_json\n";
	};

	my @contents_json_decoded = JSON->new->utf8->decode($contents_json);

	if (defined $traceclass{'HTSP'} && ($traceclass{'HTSP'} & 0x0020)) {
		print "TRACE : JSON contents DUMPER\n";
		print Dumper(@contents_json_decoded);
	};

	foreach my $key (@contents_json_decoded) {
		#print "TRACE : key=$key\n" if defined ($traceclass{'HTSP'});
		if (ref($key) ne "HASH") {
			print "WARN  : key=$key is not a hash reference - skip\n";
			next;
		};

		if (! defined $$key{'entries'}) {
			print "WARN  : key=$key is hash reference, but missing 'entries' key - skip\n";
			next;
		};

		foreach my $entry(@{$$key{'entries'}}) {
			#print "TRACE : key=$entry\n" if defined ($traceclass{'HTSP'});

			my ($name, $type);

			if (! defined $$entry{'channelname'}) {
				# skip if not defined: channelname
				next;
			};

			# check: channelname
			if ($$entry{'channelname'} =~ /\(Internet\)/o) {
				# skip if matching: (Internet)
				print "TRACE : found channelname=" . $$entry{'channelname'} . " but skip (hardcoded blacklist)\n"  if (defined $traceclass{'HTSP'} && ($traceclass{'HTSP'} && 0x1000));
				next;
			};
			$name = $$entry{'channelname'};

			# check: enabled
			if ($$entry{'enabled'} !~ /^1$/o) {
				# skip if not enabled)
				logging("TRACE", "HTSP: found channelname=" . $$entry{'channelname'} . " but skip (no 'typestr')") if (defined $traceclass{'HTSP'} && ($traceclass{'HTSP'} && 0x2000));
				next;
			};

			# check: type
			if (defined $$entry{'typestr'}) {
				$type = $$entry{'typestr'};
				$type =~ s/TV$//o;
			} else {
				# skip if not supported: type
				logging("TRACE", "HTSP: found channelname=" . $$entry{'channelname'} . " but skip (not enabled)") if (defined $traceclass{'HTSP'} && ($traceclass{'HTSP'} && 0x4000));
				next;
			};

			my $ca = 0;
			$ca = 1 if ((defined $$entry{'encryption'}) && ($$entry{'encryption'} ne "")); 

			logging("TRACE", "found channel name='" . $name . "'"
				. " type=" . $type
				. " sid="  . $$entry{'sid'}
				. " pmt="  . $$entry{'pmt'}
				. " pcr="  . $$entry{'pcr'}
				. " ca="   . $ca
				. " group='". $$entry{'provider'} . "'"
			);

			push @$channels_p, {
				'cid'      => $$entry{'id'},
				'name'     => $name,
				'source'   => $channel_source,
				'altnames' => "",
				'type'     => $type,
				'ca'       => $ca,
				'sid'      => $$entry{'sid'},
				'group'    => $$entry{'provider'}
			};
		};
	};
};


################################################################################
################################################################################
# get adapters via HTSP
# arg1: pointer to adapter array
# arg2: URL of adapter source
# debug
# trace:   print contents using Dumper
# 	 2=print raw contents
# return code: =0:ok !=0:problem
#        
# JSON structure:
#        {
#          'entries' => [
#                         {
#                           'path' => '/dev/dvb/adapter0',
#                           'deliverySystem' => 'DVB-T',
#                           'muxes' => 8,
#                           'freqMin' => 44250,
#                           'symrateMax' => 0,
#                           'symrateMin' => 0,
#                           'freqStep' => 250,
#                           'initialMuxes' => 0,
#                           'ber' => 0,
#                           'devicename' => 'Siano Mobile Digital MDTV Receiver',
#                           'freqMax' => 867250,
#                           'hostconnection' => 'USB (480 Mbit/s)',
#                           'uncavg' => 0,
#                           'name' => 'Siano Mobile Digital MDTV Receiver',
#                           'currentMux' => 'MEDIA BROADCAST: 578,000 kHz',
#                           'satConf' => 0,
#                           'unc' => 0,
#                           'type' => 'dvb',
#                           'services' => 40,
#                           'signal' => 0,
#                           'snr' => 0,
#                           'identifier' => '_dev_dvb_adapter0_Siano_Mobile_Digital_MDTV_Receiver'
#                         }
#                       ]
#        };
################################################################################
sub protocol_htsp_get_adapters($$;$) {
	my $adapters_ap = $_[0];
	my $adapters_source_url = $_[1];
	my $adapters_file_write_raw = $_[2];

	logging("DEBUG", "adapters_source_url=$adapters_source_url");

	$adapters_source_url =~ /^(file|https?):\/\/(.*)$/o;

	if (! defined $1 || ! defined $2) {
		die "Unsupported adapters_source_url=$adapters_source_url - FIX CODE";
	};

	my $source = $1;
	my $location = $2;

	my $contents_json;

	if ($source eq "file") {
		logging("INFO", "HTSP: read raw contents from file: " . $location);
		if (!open(FILE, "<$location")) {
			logging("ERROR", "HTSP: can't read raw contents from file: " . $location . " (" . $! . ")");
			return(1);
		};
		$contents_json = <FILE>;
		close(FILE);
	} else {
		my $req = HTTP::Request->new(GET => $adapters_source_url);

		if (defined $config{'dvr.credentials'}) {
			my ($user, $pass) = split ":",$config{'dvr.credentials'};
			$req->authorization_basic($user, $pass);
		};

		my $response = $htsp_client->request($req);

		if (! $response->is_success) {
			logging("ERROR", "HTSP: can't fetch adapters: " . $response->status_line);
			return(1);
		};

		$contents_json = $response->content;

		if (defined $adapters_file_write_raw) {
			logging("NOTICE", "HTSP: write raw adapter contents to file: " . $adapters_file_write_raw);
			if (!open(FILE, ">$adapters_file_write_raw")) {
				logging("ERROR", "HTSP: can't write raw contents to file: " . $adapters_file_write_raw . " (" . $! . ")");
				return(1);
			};
			print FILE $contents_json;
			close(FILE);
			logging("NOTICE", "JSON raw contents of adapters written to file written: " . $adapters_file_write_raw);
		};
	};

	if (defined $traceclass{'HTSP'} && ($traceclass{'HTSP'} & 0x0001)) {
		print "TRACE : JSON contents RAW\n";
		print "$contents_json\n";
	};

	my @contents_json_decoded = JSON->new->utf8->decode($contents_json);

	if (defined $traceclass{'HTSP'} && ($traceclass{'HTSP'} & 0x0002)) {
		print "TRACE : JSON contents DUMPER\n";
		print Dumper(@contents_json_decoded);
	};

	foreach my $key (@contents_json_decoded) {
		#print "TRACE : key=$key\n" if defined ($traceclass{'HTSP'});
		if (ref($key) ne "HASH") {
			print "WARN  : key=$key is not a hash reference - skip\n";
			next;
		};

		if (! defined $$key{'entries'}) {
			print "WARN  : key=$key is hash reference, but missing 'entries' key - skip\n";
			next;
		};

		foreach my $entry(@{$$key{'entries'}}) {
			#print "TRACE : key=$entry\n" if defined ($traceclass{'HTSP'});

			my ($identifier, $devicename);

			if (! defined $$entry{'identifier'}) {
				# skip if not defined
				next;
			};

			$identifier = $$entry{'identifier'};

			# check: name
			if (defined $$entry{'devicename'}) {
				$devicename = $$entry{'devicename'};
			} else {
				# skip if no devicename
				next;
			};

			logging("DEBUG", "HTSP: found adapter devicename='" . $devicename . "'"
				. " identifier=" . $identifier
			);

			push @$adapters_ap, {
				'identifier' => $identifier,
				'devicename' => $devicename,
				'deliverySystem' => $$entry{'deliverySystem'}
			};
		};
	};
};


################################################################################
################################################################################
# get confignames via HTSP
# arg1: pointer to config array
# arg2: URL of config source
# return code: =0:ok !=0:problem
#
# JSON structure:
#        {
#          'entries' => [
#                         {
#                           'identifier' => 'tvinfo:TEST',
#                           'name' => 'tvinfo:TEST'
#                         },
#                         {
#                           'name' => '(default)',
#                           'identifier' => ''
#                         }
#                       ]
#        };
################################################################################
sub protocol_htsp_get_confignames($$;$) {
	my $confignames_ap = $_[0];
	my $confignames_source_url = $_[1];
	my $confignames_file_write_raw = $_[2];

	my $contents_json;

	my $rc = protocol_htsp_get_generic(\$contents_json, $confignames_source_url, $confignames_file_write_raw);
	if ($rc != 0) {
		logging("FATAL", "protocol_htsp_get_generic returned an error");
		return(1);
	};

	if (defined $traceclass{'HTSP'} && ($traceclass{'HTSP'} & 0x00010000)) {
		print "TRACE : JSON contents RAW\n";
		print "$contents_json\n";
	};

	my @contents_json_decoded = JSON->new->utf8->decode($contents_json);

	if (defined $traceclass{'HTSP'} && ($traceclass{'HTSP'} & 0x00020000)) {
		print "TRACE : JSON contents DUMPER\n";
		print Dumper(@contents_json_decoded);
	};

	foreach my $key (@contents_json_decoded) {
		if (ref($key) ne "HASH") {
			print "WARN  : key=$key is not a hash reference - skip\n";
			next;
		};

		if (! defined $$key{'entries'}) {
			print "WARN  : key=$key is hash reference, but missing 'entries' key - skip\n";
			next;
		};

		foreach my $entry(@{$$key{'entries'}}) {
			my ($identifier, $name);

			if (! defined $$entry{'identifier'}) {
				# skip if not defined
				next;
			};

			$identifier = $$entry{'identifier'};

			# check: name
			if (defined $$entry{'name'}) {
				$name = $$entry{'name'};
			} else {
				# skip if no name
				next;
			};

			logging("DEBUG", "HTSP: found confignames name='" . $name . "'"
				. " identifier=" . $identifier
			);

			push @$confignames_ap, {
				'identifier' => $identifier,
				'name' => $name,
			};
		};
	};
};


################################################################################
################################################################################
# get configs via HTSP
# arg1: pointer to config array
# arg2: URL of config source
# arg3: optional file to write raw response
# return code: =0:ok !=0:problem
#
# JSON structure:
#          'dvrSettings' => [
#                             {
#                               'titleDirs' => 0,
#                               'whitespaceInTitle' => 0,
#                               'retention' => 31,
#                               'container' => 'matroska',
#                               'episodeInTitle' => 0,
#                               'channelDirs' => 0,
#                               'cleanTitle' => 0,
#                               'commSkip' => 1,
#                               'storage' => '/storage/recordings/',
#                               'postExtraTime' => 0,
#                               'preExtraTime' => 0,
#                               'channelInTitle' => 0,
#                               'tagFiles' => 1,
#                               'dayDirs' => 0,
#                               'dateInTitle' => 0,
#                               'timeInTitle' => 0
#                             }
#                           ]
#        };
#
# preExtraTime,postExtraTime: minutes
################################################################################
sub protocol_htsp_get_config($$;$) {
	my $configs_ap = $_[0];
	my $configs_source_url = $_[1];
	my $configs_file_write_raw = $_[2];

	my $contents_json;

	my $rc = protocol_htsp_get_generic(\$contents_json, $configs_source_url, $configs_file_write_raw);
	if ($rc != 0) {
		logging("FATAL", "protocol_htsp_get_generic returned an error");
		return(1);
	};

	if (defined $traceclass{'HTSP'} && ($traceclass{'HTSP'} & 0x00040000)) {
		print "TRACE : JSON contents RAW\n";
		print "$contents_json\n";
	};

	my @contents_json_decoded = JSON->new->utf8->decode($contents_json);

	if (defined $traceclass{'HTSP'} && ($traceclass{'HTSP'} & 0x00080000)) {
		print "TRACE : JSON contents DUMPER\n";
		print Dumper(@contents_json_decoded);
	};

	foreach my $key (@contents_json_decoded) {
		if (ref($key) ne "HASH") {
			print "WARN  : key=$key is not a hash reference - skip\n";
			next;
		};

		if (! defined $$key{'dvrSettings'}) {
			print "WARN  : key=$key is hash reference, but missing 'dvrSettings' key - skip\n";
			next;
		};

		foreach my $entry (@{$$key{'dvrSettings'}}) {
			if (! defined $$entry{'storage'}) {
				# skip if not defined
				next;
			};

			logging("DEBUG", "HTSP: found config with"
				. " storage="       . $$entry{'storage'}
				. " preExtraTime="  . $$entry{'preExtraTime'}
				. " postExtraTime=" . $$entry{'postExtraTime'}
				. " retention="     . $$entry{'retention'}
			);

			push @$configs_ap, {
				'storage'       => $$entry{'storage'},
				'preExtraTime'  => $$entry{'preExtraTime'},
				'postExtraTime' => $$entry{'postExtraTime'},
				'retention'     => $$entry{'retention'},
			};
		};
	};
};


################################################################################
################################################################################
# get timers via HTSP
# arg1: pointer to timers array
# arg2: URL of timers source
# debug
# trace:   print contents using Dumper
# 	 2=print raw contents
# return code: =0:ok !=0:problem
#        
# JSON structure:
#        {
#          'entries' => [
#                         {
#                           'description' => '.....',
#                           'title' => 'Raumschiff Enterprise',
#                           'channel' => 'neo/KiKA',
#                           'end' => 1414540800,
#                           'duration' => 3000,
#                           'id' => 3,
#                           'pri' => 'normal',
#                           'config_name' => '',
#                           'schedstate' => 'scheduled',
#                           'status' => 'Scheduled for recording',
#                           'creator' => 'XBMC',
#                           'start' => 1414537800
#                         }
#                       ]
#        };
################################################################################
sub protocol_htsp_get_timers($$;$) {
	my $timers_ap = $_[0];
	my $timers_source_url = $_[1];
	my $timers_file_write_raw = $_[2];

	logging("DEBUG", "HTSP: timers_source_url=$timers_source_url");

	$timers_source_url =~ /^(file|https?):\/\/(.*)$/o;

	if (! defined $1 || ! defined $2) {
		die "Unsupported timers_source_url=$timers_source_url - FIX CODE";
	};

	my $source = $1;
	my $location = $2;

	my $contents_json;

	if ($source eq "file") {
		logging("INFO", "HTSP: read raw contents from file: " . $location);
		if (!open(FILE, "<$location")) {
			logging("ERROR", "HTSP: can't read raw contents from file: " . $location . " (" . $! . ")");
			return(1);
		};
		$contents_json = <FILE>;
		close(FILE);
	} else {
		my $req = HTTP::Request->new(GET => $timers_source_url);

		if (defined $config{'dvr.credentials'}) {
			my ($user, $pass) = split ":",$config{'dvr.credentials'};
			$req->authorization_basic($user, $pass);
		};

		my $response = $htsp_client->request($req);

		if (! $response->is_success) {
			logging("ERROR", "Can't fetch timers via HTSP: " . $response->status_line);
			return(1);
		};

		$contents_json = $response->content;

		if (defined $timers_file_write_raw) {
			logging("NOTICE", "HTSP: write raw timer contents to file: " . $timers_file_write_raw);
			if (!open(FILE, ">$timers_file_write_raw")) {
				logging("ERROR", "HTSP: can't write raw contents to file: " . $timers_file_write_raw . " (" . $! . ")");
				return(1);
			};
			print FILE $contents_json;
			close(FILE);
			logging("NOTICE", "JSON raw contents of timers written to file written: " . $timers_file_write_raw);
		};
	};

	if (defined $traceclass{'HTSP'} && ($traceclass{'HTSP'} & 0x0100)) {
		print "TRACE : JSON contents RAW\n";
		print "$contents_json\n";
	};

	my @contents_json_decoded = JSON->new->utf8->decode($contents_json);

	if (defined $traceclass{'HTSP'} && ($traceclass{'HTSP'} & 0x0200)) {
		print "TRACE : JSON contents DUMPER\n";
		print Dumper(@contents_json_decoded);
	};

	foreach my $key (@contents_json_decoded) {
		if (ref($key) ne "HASH") {
			logging("WARN", "HTSP: key=$key is not a hash reference - skip");
			next;
		};

		if (! defined $$key{'entries'}) {
			logging("WARN", "HTSP: key=$key is hash reference, but missing 'entries' key - skip");
			next;
		};

		foreach my $entry (@{$$key{'entries'}}) {
			# map empty config_name to internal value
			$$entry{'config_name'} = "default" if ($$entry{'config_name'} eq "");

			logging("DEBUG", "HTSP: found timer"
				. " tid="    . $$entry{'id'}
				. " cid="    . $$entry{'channel'}
				. " start="  . strftime("%Y%m%d-%H%M", localtime($$entry{'start'}))
				. " end="    . strftime("%Y%m%d-%H%M", localtime($$entry{'end'}))
				. " title='" . $$entry{'title'} . "'"
				. " config_name='" . $$entry{'config_name'} . "'"
			);

			push @$timers_ap, {
				'tid'      => $$entry{'id'},
				'cid'      => $$entry{'channel'},
				'title'    => $$entry{'title'},
				'start_ut' => $$entry{'start'},
				'stop_ut'  => $$entry{'end'},
				'summary'  => $$entry{'description'},
				'config'   => $$entry{'config_name'},
			};
		};
	};
};


################################################################################
################################################################################
# delete/add timers/config via HTSP
# arg1: point to array of timer numbers to delete
# arg2: point to array of timer pointers to add
# arg3: point to array of configurations to add/update
# arg4: URL of destination of actions
# return code: =0:ok !=0:problem
#
# Delete (example):
#  POST /dvr HTTP/1.1
#   entryId=7&op=cancelEntry
#
# Add (example)
#  POST /dvr/addentry
#   op=createEntry&channelid=7&date=10%2F28%2F2014&starttime=01%3A20&stoptime=08%3A30&pri=Normal&title=Test&config_name=(default)
#
# Add config
#  POST /dvr
#   op=saveSettings&config_name=&storage=%2Fstorage%2Frecordings%2FPeter&container=matroska&retention=31&preExtraTime=0&postExtraTime=0&tagFiles=on&commSkip=on&postproc=
#
#        
################################################################################
sub protocol_htsp_delete_add_timers($$) {
	my $timers_num_delete_ap = $_[0];
	my $timers_add_ap = $_[1];
	my $config_add_update_ap = $_[2];
	my $timers_destination_url = $_[3];

	$timers_destination_url =~ /^(file|https?):\/\/(.*)$/o;

	if (! defined $1 || ! defined $2) {
		die "Unsupported timers_destination_url=$timers_destination_url - FIX CODE";
	};

	my $destination = $1;
	my $location = $2;

	my %counters;

	my $rc = 0; # ok

	## create HTSP command list
	my @commands_htsp;

	# create/update configs
	foreach my $config_hp (@$config_add_update_ap) {
		push @commands_htsp, "GET /dvr"
			. "?op=saveSettings"
			. "&config_name="   . $$config_hp{'identifier'}
			. "&storage="       . $$config_hp{'storage'}
			. "&preExtraTime="  . $$config_hp{'preExtraTime'}
			. "&postExtraTime=" . $$config_hp{'postExtraTime'}
			. "&retention="     . $$config_hp{'retention'}
			;
		$counters{'config'}++ if ($destination eq "file");
	};

	
	# delete timers
	foreach my $num (@$timers_num_delete_ap) {
		push @commands_htsp, "GET /dvr?entryId=" . $num . "&op=cancelEntry";
		$counters{'del'}++ if ($destination eq "file");
	};

	# add timers
	foreach my $timer_hp (@$timers_add_ap) {
		push @commands_htsp, "GET /dvr/addentry"
			. "?op=createEntry"
			. "&channelid="   . $$timer_hp{'cid'}
			# TODO: detect whether UTC or localtime is used according to tests at least on openelec timezone of tvheadend is UTC if system has UTC
			#. "&date="        . strftime("%m/%d/%Y", gmtime($$timer_hp{'start_ut'}))
			#. "&starttime="   . strftime("%H:%M"   , gmtime($$timer_hp{'start_ut'}))
			#. "&stoptime="    . strftime("%H:%M"   , gmtime($$timer_hp{'stop_ut'}))
			. "&date="        . strftime("%m/%d/%Y", localtime($$timer_hp{'start_ut'}))
			. "&starttime="   . strftime("%H:%M", localtime($$timer_hp{'start_ut'})) 
			. "&stoptime="    . strftime("%H:%M", localtime($$timer_hp{'stop_ut'}))
			. "&pri="         . $$timer_hp{'priority'}
			. "&config_name=" . $$timer_hp{'config'}
			. "&title="       . $$timer_hp{'title'}
			;
		$counters{'add'}++ if ($destination eq "file");
	};

	if ($destination eq "file") {
		if (!open(FILE, ">$location")) {
			logging("ERROR", "HTSP: can't open file for writing raw contents of timer actions: " . $location . " (" . $! . ")");
			return(1);
		};
		logging("DEBUG", "HTSP: write raw contents of timer actions to file: " . $location);
		foreach my $line (@commands_htsp) {
			print FILE $line . "\n";
		};
		close(FILE);
		logging("INFO", "HTSP: raw contents of timer actions written to file: " . $location);
	} else {
		logging("DEBUG", "HTSP: try to execute actions on location: $timers_destination_url");

		foreach my $line (@commands_htsp) {
			logging("DEBUG", "HTSP: send line: " . $line);

			my ($cmd, $uri, $options) = $line =~ /^([^ ]+) ([^?]+)\?(.*)$/o;

			my $req = HTTP::Request->new(GET => $timers_destination_url . $uri . "?" . $options);

			if (defined $config{'dvr.credentials'}) {
				my ($user, $pass) = split ":",$config{'dvr.credentials'};
				$req->authorization_basic($user, $pass);
			};

			my $response = $htsp_client->request($req);

			if (! $response->is_success) {
				logging("ERROR", "HTSP: problem configuring DVR via HTSP: " . $response->status_line . " (sent: " . $line . ")");
				$rc = 2; # problem
				continue;
			};

			my $result = $response->content;

			logging("DEBUG", "HTSP: received result: " . $result);

			if ($line =~ /op=cancelEntry/o) {
				if ($result =~ m/success/o) {
					logging("INFO", "HTSP: delete of timer was successful: " . $line);
					$counters{'del'}++;
				} else {
					logging("ERROR", "HTSP: delete of timer was not successful: " . $line . " (" . $result . ")");
					$counters{'delete-failed'}++;
					$rc = 1; # problem
				};
			} elsif ($line =~ /op=createEntry/o) {
				if ($result =~ m/success/o) {
					logging("INFO", "HTSP: successful programmed timer: " . $line);
					$counters{'add'}++;
				} else {
					logging("ERROR", "HTSP: problem programming new timer: " . $line . " (" . $result . ")");
					$counters{'add-failed'}++;
					$rc = 1; # problem
				};
			} elsif ($line =~ /op=saveSettings/o) {
				if ($result =~ m/success/o) {
					logging("INFO", "HTSP: successful created/updated configuration: " . $line);
					$counters{'config'}++;
				} else {
					logging("ERROR", "HTSP: problem creating/updating configuration: " . $line . " (" . $result . ")");
					$counters{'config-failed'}++;
					$rc = 1; # problem
				};
			} else {
				logging("ERROR", "HTSP: unsupported line for checking result: " . $line);
				$rc = 3; # problem
			};
		};
	};

	my $summary = "";
	foreach my $key (keys %counters) {
		$summary .= " " . $key . "=" . $counters{$key};
	};

END:
	logging("INFO", "HTSP: summary timers" . $summary) if ($summary ne "");
	return($rc);
};


#### END
return 1;
