# Support functions for timer service TVinfo
#
# (C) & (P) 2014 - 2014 by by Peter Bieringer <pb@bieringer.de>
#
# License: GPLv2
#
# Authors:
#  Peter Bieringer (bie)
#
# Changelog:
# 20141031/bie: takeover code from main tvinfomerk2vdr-ng.pl

use strict;
use warnings;
use utf8;

use Data::Dumper;
use LWP;
use HTTP::Request::Common;
use XML::Simple;
use Encode;
use Date::Manip;
use Digest::MD5 qw(md5_hex);

## debug/trace information
our %traceclass;
our %debugclass;

## global values
our $progname;
our $progversion;
our %config;

## activate module
our  @service_list_supported;
push @service_list_supported, "tvinfo";
our %module_functions;
$module_functions{'service'}->{'tvinfo'}->{'get_channels'} = \&service_tvinfo_get_channels;
$module_functions{'service'}->{'tvinfo'}->{'get_timers'} = \&service_tvinfo_get_timers;

## preparation for web requests
my $tvinfo_client = LWP::UserAgent->new;
$tvinfo_client->agent("Mozilla/4.0 ($progname $progversion)");

if (defined $config{'proxy'}) {
	$tvinfo_client->proxy('http', $config{'proxy'});
};

## local values
my %tvinfo_AlleSender_id_list;
my %tvinfo_MeineSender_id_list;
my %tvinfo_channel_name_by_id;
my %tvinfo_channel_id_by_name;



## replace tokens in request
sub request_replace_tokens($) {
	my $request = shift || return 1;

	logging("DEBUG", "request  original: " . $request);
	logging("DEBUG", "username         : " . $config{'service.tvinfo.user'});
	logging("DEBUG", "password         : " . $config{'service.tvinfo.password'});

	# replace username token
	my $passwordhash;
	if ($config{'service.tvinfo.password'} =~ /^{MD5}(.*)/) {
		$passwordhash = $1;
	} else {
		$passwordhash = md5_hex($config{'service.tvinfo.password'});
	};

	$request =~ s/<USERNAME>/$config{'service.tvinfo.user'}/;
	$request =~ s/<PASSWORDHASH>/$passwordhash/;

	logging("DEBUG", "request result   : " . $request);
	return($request)
};

################################################################################
################################################################################
# get channels (aka stations/Sender) from TVinfo
# arg1: pointer to channel array
# arg2: pointer to config
# debug
#
# $traceclass{'TVINFO'}:
#   0x01: XML dump stations raw
#   0x02: XML dump stations
#
# XML structure:
#    TODO
################################################################################
sub service_tvinfo_get_channels($$;$) {
	my $channels_ap = $_[0];

	my @xml_list;
	my $xml_raw;
	my $xml;

	my $ReadStationsXML = undef;
	my $WriteStationsXML = undef;

	if (! defined $config{'service.source.type'}) {
		die "service.source.type is not defined";
	};

	if ($config{'service.source.type'} eq "file") {
		$ReadStationsXML = $config{'service.source.file.prefix'} . "-stations.xml";
	} elsif ($config{'service.source.type'} eq "network+store") {
		$WriteStationsXML = $config{'service.source.file.prefix'} . "-stations.xml";
	} elsif ($config{'service.source.type'} eq "network") {
	} else {
		die "service.source.type is not supported: " . $config{'service.source.type'};
	};

	if (defined $ReadStationsXML) {
		if (! -e $ReadStationsXML) {
			logging("ERROR", "TVINFO: given raw file for stations is missing (forget -W before?): " . $ReadStationsXML);
			exit(1);
		};
		# load 'Sender' (stations) from file
		logging("INFO", "TVINFO: read XML contents of stations from file: " . $ReadStationsXML);
		if(!open(FILE, "<$ReadStationsXML")) {
			logging("ERROR", "TVINFO: can't read XML contents of stations from file: " . $ReadStationsXML);
			exit(1);
		};
		binmode(FILE);
		while(<FILE>) {
			$xml_raw .= $_;
		};
		close(FILE);
		logging("INFO", "TVINFO: XML contents of stations read from file: " . $ReadStationsXML);
	} else {
		# Fetch 'Sender' via XML interface
		logging ("INFO", "TVINFO: fetch stations via XML interface");

		my $request = request_replace_tokens("http://www.tvinfo.de/external/openCal/stations.php?username=<USERNAME>&password=<PASSWORDHASH>");

		logging("DEBUG", "TVINFO: start request: " . $request);

		my $response = $tvinfo_client->request(GET "$request");
		if (! $response->is_success) {
			logging("ERROR", "TVINFO: can't fetch stations: " . $response->status_line);
			exit 1;
		};

		$xml_raw = $response->content;

		if (defined $WriteStationsXML) {
			logging("NOTICE", "TVINFO: write XML contents of stations to file: " . $WriteStationsXML);
			open(FILE, ">$WriteStationsXML") || die;
			print FILE $xml_raw;
			close(FILE);
			logging("NOTICE", "TVINFO: XML contents of stations written to file: " . $WriteStationsXML);
		};
	};

	if (defined $traceclass{'TVINFO'}  && ($traceclass{'TVINFO'} & 0x01)) {
		print "#### TVINFO/stations XML NATIVE RESPONSE BEGIN ####\n";
		print $xml_raw;
		print "#### TVINFO/stations XML NATIVE RESPONSE END   ####\n";
	};

	if ($xml_raw =~ /encoding="UTF-8"/) {
		$xml_raw = encode("utf-8", $xml_raw);
	};

	# Parse XML content
	$xml = new XML::Simple;

	my $data = $xml->XMLin($xml_raw);

	if (defined $traceclass{'TVINFO'} && ($traceclass{'TVINFO'} & 0x02)) {
		print "#### TVINFO/stations XML PARSED RESPONSE BEGIN ####\n";
		print Dumper($data);
		print "#### TVINFO/stations XML PARSED RESPONSE END   ####\n";
	};

	# Version currently missing
	#if ($$data{'version'} ne "1.0") {
	#	logging ("ALERT", "XML 'Sender' has not supported version: " . $$data{'version'} . " please check for latest version and contact asap script development");
	#	exit 1;
	#};

	if ($xml_raw !~ /stations/) {
		logging ("ERROR", "TVINFO: XML don't contain any stations, empty or username/passwort not proper, can't proceed");
		exit 1;
	} else {
		my $xml_list_p = @$data{'station'};

		logging ("INFO", "TVINFO: XML contains amount of stations: " . scalar(keys %$xml_list_p));
	};

	my $xml_root_p = @$data{'station'};

	foreach my $name (sort keys %$xml_root_p) {
		my $id = $$xml_root_p{$name}->{'id'};

		my $altnames_p = $$xml_root_p{$name}->{'altnames'}->{'altname'};

		my $altnames = "";

		if (ref($altnames_p) eq "ARRAY") {
			# more than one entry
			$altnames = join("|", grep(!/^$name$/, @$altnames_p));
		} else {
			if ($name ne $altnames_p) {
				# add alternative name only if different to name
				$altnames = $altnames_p;
			};
		};

		$tvinfo_AlleSender_id_list{$id}->{'name'} = $name;
		$tvinfo_AlleSender_id_list{$id}->{'altnames'} = $altnames;

		my $selected = 0;
		if (defined $$xml_root_p{$name}->{'selected'} && $$xml_root_p{$name}->{'selected'} eq "selected") {
			$selected = 1;
			$tvinfo_MeineSender_id_list{$id}->{'name'} = $name;
			$tvinfo_MeineSender_id_list{$id}->{'altnames'} = $altnames;
		};

		logging("DEBUG", "TVINFO: station: " . sprintf("%4d: %s (%s) %d", $id, $name, $altnames, $selected));

		$tvinfo_channel_name_by_id{$id} = $name;
		$tvinfo_channel_id_by_name{$name} = $id;

		push @$channels_ap, {
			'cid'      => $id,
			'name'     => encode("iso-8859-1", decode("utf8", $name)),
			'altnames' => encode("iso-8859-1", decode("utf8", $altnames)),
			'enabled'  => $selected,
		};
	};


	if (scalar(keys %tvinfo_channel_id_by_name) == 0) {
		logging("ALERT", "No entry found for 'Alle Sender' - please check for latest version and contact asap script development");
		exit 1;
	};

	if (scalar(keys %tvinfo_MeineSender_id_list) == 0) {
		logging("ALERT", "No entry found for 'Meine Sender' - please check for latest version and contact asap script development");
		exit 1;
	};

	# print 'Meine Sender'
	my $c = -1;
	foreach my $id (keys %tvinfo_MeineSender_id_list) {
		$c++;

		my $name = "MISSING";
		if (defined $tvinfo_channel_name_by_id{$id}) {
			$name = $tvinfo_channel_name_by_id{$id};
		};
		logging("DEBUG", "TVINFO selected station: " . sprintf("%4d: %4d %s", $c, $id, $name));
	};
};

################################################################################
################################################################################
# get timers (aka schedules/Merkzettel) from TVinfo
# arg1: pointer to channel array
# arg2: pointer to config
# debug
#
# $traceclass{'TVINFO'}:
#   0x10: XML dump schedules raw
#   0x20: XML dump schedules
#   0x40: XML dump each schedules
#
# XML structure:
#    TODO
################################################################################
sub service_tvinfo_get_timers($) {
	my $timers_ap = $_[0];

	my @xml_list;
	my $xml_raw;

	my $ReadScheduleXML = undef;
	my $WriteScheduleXML = undef;

	if ($config{'service.source.type'} eq "file") {
		$ReadScheduleXML = $config{'service.source.file.prefix'} . "-schedule.xml";
	} elsif ($config{'service.source.type'} eq "network+store") {
		$WriteScheduleXML = $config{'service.source.file.prefix'} . "-schedule.xml";
	} elsif ($config{'service.source.type'} eq "network") {
	} else {
		die "service.source.type is not supported: " . $config{'service.source.type'};
	};

	if (defined $ReadScheduleXML) {
		if (! -e $ReadScheduleXML) {
			logging("ERROR", "TVINFO: given raw file for timers is missing (forget -W before?): " . $ReadScheduleXML);
			exit(1);
		};
		# load 'Merkzettel' from file
		logging("INFO", "TVINFO: read XML contents of timers from file: " . $ReadScheduleXML);
		if(!open(FILE, "<$ReadScheduleXML")) {
			logging("ERROR", "TVINFO: can't read XML contents of timers from file: " . $ReadScheduleXML);
			exit(1);
		};
		binmode(FILE);
		while(<FILE>) {
			$xml_raw .= $_;
		};
		close(FILE);
		logging("INFO", "TVINFO: XML contents of timers read from file: " . $ReadScheduleXML);
	} else {
		# Fetch 'Merkliste' via XML interface
		logging ("INFO", "TVINFO: fetch timers via XML interface");

		my $request = request_replace_tokens("http://www.tvinfo.de/share/openepg/schedule.php?username=<USERNAME>&password=<PASSWORDHASH>");

		logging("DEBUG", "TVINFO: start request: " . $request);

		my $response = $tvinfo_client->request(GET "$request");
		if (! $response->is_success) {
			logging("ERROR", "TVINFO: can't fetch XML timers from tvinfo: " . $response->status_line);
			exit 1;
		};

		$xml_raw = $response->content;

		if (defined $WriteScheduleXML) {
			logging("NOTICE", "TVINFO: write XML contents of timers to file: " . $WriteScheduleXML);
			open(FILE, ">$WriteScheduleXML") || die;
			print FILE $xml_raw;
			close(FILE);
			logging("NOTICE", "TVINFO: XML contents of timers written to file: " . $WriteScheduleXML);
			# note: continue to write also HTML file later
		};
	};

	if (defined $traceclass{'TVINFO'} && ($traceclass{'TVINFO'} & 0x10)) {
		print "#### TVINFO/timers XML NATIVE RESPONSE BEGIN ####\n";
		print $xml_raw;
		print "#### TVINFO/timers XML NATIVE RESPONSE END   ####\n";
	};

	# Replace encoding from -15 to -1, otherwise XML parser stops
	$xml_raw =~ s/(encoding="ISO-8859)-15(")/$1-1$2/;

	# Parse XML content
	my $xml = new XML::Simple;
	my $data = $xml->XMLin($xml_raw);

	if (defined $traceclass{'TVINFO'} && ($traceclass{'TVINFO'} & 0x20)) {
		print "#### TVINFO/timers XML PARSED RESPONSE BEGIN ####\n";
		print Dumper($data);
		print "#### TVINOF/timers XML PARSED RESPONSE END   ####\n";
	};

	if ($$data{'version'} ne "1.0") {
		logging ("ALERT", "TVINFO: XML of timer has not supported version: " . $$data{'version'} . " please check for latest version and contact asap script development");
		exit 1;
	};

	if ($xml_raw !~ /epg_schedule_entry/) {
		logging ("ERROR", "TVINFO: XML timer is empty or username/passwort not proper, can't proceed");
		exit 1;
	} else {
		my $xml_list_p = @$data{'epg_schedule_entry'};

		if (ref($xml_list_p) eq "HASH") {
			logging ("INFO", "TVINFO: 'Merkliste' has only 1 entry");
			push @xml_list, $xml_list_p;
		} else {
			logging ("INFO", "TVINFO: 'Merkliste' has entries: " . scalar(@$xml_list_p));

			# copy entries
			foreach my $xml_entry_p (@$xml_list_p) {
				push @xml_list, $xml_entry_p;
			};
		};
	};


	####################################
	## XML timer (aka 'Merkzettel') analysis
	####################################

	logging("DEBUG", "TVINFO: start XML timer analysis");

	# Run through entries of XML contents of 'Merkliste'

	foreach my $xml_entry_p (@xml_list) {
		if (defined $traceclass{'TVINFO'} && ($traceclass{'TVINFO'} & 0x40)) {
			print "####XML PARSED ENTRY BEGIN####\n";
			print Dumper($xml_entry_p);
			print "####XML PARSED ENTRY END####\n";
		};
		# logging ("DEBUG", "entry uid: " . $$entry_p{'uid'});

		my $xml_starttime = $$xml_entry_p{'starttime'};
		my $xml_endtime   = $$xml_entry_p{'endtime'};
		my $xml_title     = $$xml_entry_p{'title'};
		my $xml_channel   = $$xml_entry_p{'channel'};

		my $start_ut = UnixDate(ParseDate($xml_starttime), "%s");
		my $stop_ut  = UnixDate(ParseDate($xml_endtime  ), "%s");

		if ($$xml_entry_p{'eventtype'} ne "rec") {
			logging("DEBUG", "TVINFO: SKIP (eventtype!=rec): start=$xml_starttime end=$xml_endtime channel=$xml_channel title='$xml_title'");
			next;
		};

		push @$timers_ap, {
			'tid'          => $$xml_entry_p{'uid'},
			'start_ut'     => $start_ut,
			'stop_ut'      => $stop_ut,
			'cid'          => $tvinfo_channel_id_by_name{$xml_channel},
			'title'        => $xml_title,
			'genre'        => $$xml_entry_p{'nature'},
			'service_data' => "tvinfo:" . $config{'service.tvinfo.user'}
		};

		logging("DEBUG", "TVINFO: found timer:"
			. " tid="      . $$xml_entry_p{'uid'}
			. " start="    . $xml_starttime . " (" . strftime("%Y%m%d-%H%M", localtime($start_ut)) . ")"
			. " end="      . $xml_endtime   . " (" . strftime("%Y%m%d-%H%M", localtime($stop_ut)) . ")"
			. " channel='" . $xml_channel . "' (" . $tvinfo_channel_id_by_name{$xml_channel} . ")"
			. " title='"   . $xml_title . "'"
                        . " s_d="      . "tvinfo:" . $config{'service.tvinfo.user'}
		);

	};

	logging("DEBUG", "TVINFO: finish XML timer analysis");
};


#### END
return 1;
