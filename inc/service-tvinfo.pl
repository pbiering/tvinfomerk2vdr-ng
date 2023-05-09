# Support functions for timer service TVinfo
#
# (C) & (P) 2014-2023 by by Peter Bieringer <pb@bieringer.de>
#
# License: GPLv2
#
# Authors:
#  Peter Bieringer (bie)
#
# Changelog:
# 20141031/bie: takeover code from main tvinfomerk2vdr-ng.pl
# 20150201/bie: cut title if \r was found
# 20150516/bie: remove trailing spaces from title
# 20151101/bie: round start/stop time down to full minutes
# 20170802/bie: skip timer if channel_id can't be retrieved (inconsistency between station.php and schedule.php)
# 20170902/bie: honor service_login_state to decide between login problem and empty timer list
# 20171018/bie: remove comments in XML before parsing
# 20180921/bie: remove unexpected content before XML starts (server side intermediate? bug), move XML comment remover from before storing to before parsing
# 20190126/bie: add retry mechanism around web requests, add 'curl' fallback
# 20190129/bie: use only curl for web requests for now
# 20190713/bie: fix UTF-8 conversion
# 20200519/bie: ignore older duplicated timers
# 20220428/bie: enable retry again because pool members behind loadbalancer on TVinfo side are not equally configured (but luckily round-robin is configured on loadbalancer)
# 20220428/bie: add for troubleshooting toggle for switch between 'LWP' and 'curl', switch back to use of 'LWP' (supporting proxy)
# 20220622/bie: skip entry in schedule in case of entry has broken start/end time
# 20230419/bie: change channel parser as XML format changed from name based tree to array
# 20230422/bie: detect empty title and display a notice
# 20230509/bie: add initial html login support

use strict;
use warnings;
use utf8;

use Data::Dumper;
use LWP;
use LWP::Protocol::https;
use HTTP::Request::Common;
use HTTP::Date;
use XML::Simple;
use Encode;
#use Date::Manip;
use Digest::MD5 qw(md5_hex);

## debug/trace information
our %traceclass;
our %debugclass;

## global values
our $progname;
our $progversion;
our %config;
our $service_login_state;

## activate module
our  @service_list_supported;
push @service_list_supported, "tvinfo";
our %module_functions;
$module_functions{'service'}->{'tvinfo'}->{'get_channels'} = \&service_tvinfo_get_channels;
$module_functions{'service'}->{'tvinfo'}->{'get_timers'} = \&service_tvinfo_get_timers;

## preparation for web requests
my $user_agent = "Mozilla/4.0 ($progname $progversion)";
my $tvinfo_client = LWP::UserAgent->new;
$tvinfo_client->agent($user_agent);

if (defined $config{'proxy'}) {
	$tvinfo_client->proxy('http', $config{'proxy'});
};

my $tvinfo_url_base      = "https://www.tvinfo.de";
my $tvinfo_url_login     = "https://www.tvinfo.de/";
my $tvinfo_view_calendar = "https://www.tvinfo.de/component/pit_data/?view=calendar";

my $tvinfo_login_cookie;
my $tvinfo_auth_cookie;


## local values
my %tvinfo_AlleSender_id_list;
my %tvinfo_MeineSender_id_list;
my %tvinfo_channel_name_by_id;
my %tvinfo_channel_id_by_name;

## local internal toggles
my $use_curl = 0;

################################################################################
################################################################################
# Helper functions
################################################################################
## convert password
# $1: password $2: flag (if defined, do not add prefix)
sub service_tvinfo_convert_password($;$) {
	if ($_[0] !~ /^{MD5}/) {
		logging("NOTICE", "TVinfo password is not given as hash (conversion used for security reasons)");
		if (defined $_[1]) {
			return(md5_hex($_[0]));
		} else {
			return("{MD5}" . md5_hex($_[0]));
		};
	} else {
		return($_[0]);
	};
};

## replace tokens in request
sub request_replace_tokens($) {
	my $request = shift || return 1;

	if (! defined $config{'service.user'} || $config{'service.user'} eq "") {
		logging("ERROR", "service.user empty or undefined - FIX CODE");
		exit 2;
	};
	if (! defined $config{'service.password'} || $config{'service.password'} eq "") {
		logging("ERROR", "service.password empty or undefined - FIX CODE");
		exit 2;
	};

	logging("DEBUG", "TVINFO: request  original: " . $request);
	logging("DEBUG", "TVINFO: username         : " . $config{'service.user'});
	logging("DEBUG", "TVINFO: password         : " . substr($config{'service.password'}, 0, 3) . "*****");

	# replace username token
	my $passwordhash = service_tvinfo_convert_password($config{'service.password'}, 1);

	$request =~ s/<USERNAME>/$config{'service.user'}/;
	$request =~ s/<PASSWORDHASH>/$passwordhash/;

	# logging("DEBUG", "request result   : " . $request); # disabled, showing hashed password
	return($request)
};


## login to get session cookie
#
# step 1: run through HTML and retrieve the form tokens
#
# $traceclass{'TVINFO'}:
# $traceclass{'TVINFO'} |= 0x01; # HTML login content
# $traceclass{'TVINFO'} |= 0x02; # HTML login post response
#
sub service_tvinfo_login() {
	return(0) if (defined $tvinfo_auth_cookie);

	my $ReadLoginHTML = undef;
	my $ReadLoginResponseHTML = undef;
	my $WriteLoginHTML = undef;
	my $WriteLoginResponseHTML = undef;
	my $html_raw;

	if (! defined $config{'service.user'} || $config{'service.user'} eq "") {
		logging("ERROR", "service.user empty or undefined - FIX CODE");
		exit 2;
	};
	if (! defined $config{'service.password'} || $config{'service.password'} eq "") {
		logging("ERROR", "service.password empty or undefined - FIX CODE");
		exit 2;
	};

	logging("DEBUG", "TVINFO: username         : " . $config{'service.user'});
	logging("DEBUG", "TVINFO: password         : " . substr($config{'service.password'}, 0, 3) . "*****");

	if ($config{'service.source.type'} eq "file") {
		$ReadLoginHTML = $config{'service.source.file.prefix'} . "-login.html";
		$ReadLoginResponseHTML = $config{'service.source.file.prefix'} . "-loginresponse.html";
	} elsif ($config{'service.source.type'} eq "network+store") {
		$WriteLoginHTML = $config{'service.source.file.prefix'} . "-login.html";
		$WriteLoginResponseHTML = $config{'service.source.file.prefix'} . "-loginresponse.html";
	} elsif ($config{'service.source.type'} eq "network") {
	} else {
		die "service.source.type is not supported: " . $config{'service.source.type'} . " - FIX CODE";
	};

	if (defined $ReadLoginHTML) {
		if (! -e $ReadLoginHTML) {
			logging("ERROR", "TVINFO: given raw file for 'login' is missing (forget -W before?): " . $ReadLoginHTML);
			return(1);
		};
		# load 'login' from file
		logging("INFO", "TVINFO: read HTML contents of 'login' from file: " . $ReadLoginHTML);
		if(!open(FILE, "<$ReadLoginHTML")) {
			logging("ERROR", "TVINFO: can't read HTML contents of 'login' from file: " . $ReadLoginHTML);
			return(1);
		};
		binmode(FILE);
		while(<FILE>) {
			$html_raw .= $_;
		};
		close(FILE);
		logging("INFO", "TVINFO: HTML contents of 'login' read from file: " . $ReadLoginHTML);
	} else {
		logging ("INFO", "TVINFO: fetch 'login' via HTML interface");

		my $request = $tvinfo_url_login;

		# create curl request (-s: silent, -v: display header)
		$html_raw = `curl -s -v -A '$user_agent' -k '$request' 2>&1`;

		if (defined $WriteLoginHTML) {
			logging("NOTICE", "TVINFO: write HTML contents of 'login' to file: " . $WriteLoginHTML);
			if(! open(FILE, ">$WriteLoginHTML")) {
				logging("ERROR", "TVINFO: can't write HTML contents of 'login' to file: " . $WriteLoginHTML . " (" . $! . ")");
			} else {
				print FILE $html_raw;
				close(FILE);
				logging("NOTICE", "TVINFO: HTML contents of 'login' written to file: " . $WriteLoginHTML);
			};
		};

		if ($html_raw !~ /name=\"user\"/o) {
			logging("ERROR", "TVINFO: 'login' page fetched from 'tvinfo' is missing 'user' (\"$request\"): " . substr($html_raw, 0, 320) . "...");
			return(1);
		};
	};

	# extract login cookie
	for my $line (split("\n", $html_raw)) {
		# skip not-response header lines
		next if $line !~ /^< /o;
		next if $line !~ /< Set-Cookie: ([^;]+)/io;
		next if $line !~ /< Set-Cookie: (TVinfo=[^;]+)/io;
		$tvinfo_login_cookie = $1;
		last;
	};

	if (defined $tvinfo_login_cookie) {
		logging("DEBUG", "TVINFO: login cookie found in 'login response': " . $tvinfo_login_cookie);
	} else {
		logging("ERROR", "TVINFO: login cookie not found in 'login response' (STOP)");
		return(1);
	};


	$html_raw = decode("utf-8", $html_raw);

	if (defined $traceclass{'TVINFO'} && ($traceclass{'TVINFO'} & 0x01)) {
		print "#### TVINFO/login CONTENT BEGIN ####\n";
		print $html_raw;
		print "#### TVINFO/login CONTENT END   ####\n";
	};

	my $parser= HTML::TokeParser::Simple->new(\$html_raw);
	my %form_data;
	my $form_url;
	my $found_username = 0;
	my $found_password = 0;

	# look for tag 'form'
	while (my $anchor = $parser->get_tag('form')) {
		# look for attr 'action'
		my $id = $anchor->get_attr('id');
		next unless defined($id);
		next unless ($id =~ /^loginForm$/io);

		my $action = $anchor->get_attr('action');
		next unless defined($action);
		next unless ($action =~ /\//o);

		# look for attr 'method'
		my $method = lc($anchor->get_attr('method'));
		next unless defined($method);
		next unless ($method =~ /^(post)$/io);

		logging("TRACE", "TVINFO: 'login' form found: method=" . $method . " action=" . $action . "id=" . $id);
		if ($action =~ /^https?:/oi) {
			$form_url = $action;
		} else {
			$form_url = $tvinfo_url_base . $action;
		};

		# look for tag 'input'
		while (my $anchor = $parser->get_tag("input", "/form")) {
			if ($anchor->is_end_tag('/form')) {
				# end of form
				last;
			};

			my ($name, $value, $type);

			# look for attr 'name'
			$name = $anchor->get_attr('name');
			next unless defined($name);
			logging("TRACE", "TVINFO: 'login' form input line found: name=" . $name);

			if ($name =~ /user/oi) {
				# input field for 'username'
				$form_data{$name} = $config{'service.user'};
				logging("TRACE", "TVINFO: 'login' form 'username' input found: " . $name);
				$found_username = 1;
				next;
			};

			# look for attr 'type'
			$type = lc($anchor->get_attr('type'));
			if (defined($type)) {
				if ($type eq "hidden") {
					# hidden input field, overtake value
					$value = lc($anchor->get_attr('value'));
					next unless defined($value);
					$form_data{$name} = $value;
					logging("TRACE", "TVINFO: 'login' form hidden input found: " . $name . "=" . $value);
				} elsif ($type eq "password") {
					if ($config{'service.password'} =~ /^{MD5}/) {
						logging("ERROR", "TVINFO: login password not provided in clear text, cannot continue");
						return(1);
					};
					# input field for 'password'
					$form_data{$name} = $config{'service.password'};
					logging("TRACE", "TVINFO: 'login' form 'password' input found: " . $name);
					$found_password = 1;
				} else {
					next;
				};
			} else {
				# don't care
				next;
			};
		};

		# check form contents
		if ($found_username == 1 && $found_password == 1 && defined $form_url) {
			last;
		} else {
			# clear form data
			undef %form_data;
			undef $form_url;
			$found_username = 0;
			$found_password = 0;
		};
	};

	# create post request
	my (@post_array, $form_option, $post_data);
	for my $key (keys %form_data) {
		$form_option .= " -F '" . $key . "=" . $form_data{$key} . "'";
		push @post_array, $key . "=" . $form_data{$key};
	};

	$form_option .=  " -F keeplogin=off";
	push @post_array, "keeplogin=off";

	$form_option .=  " -F loginbutton=ANMELDEN";
	push @post_array, "loginbutton=ANMELDEN";

	$post_data = join("\n", @post_array);

	if (defined $traceclass{'TVINFO'} && ($traceclass{'TVINFO'} & 0x02)) {
		print "#### TVINFO/login POST RESPONSE BEGIN ####\n";
		print "#### URL\n";
		printf "%s\n", $form_url;
		print "#### FORM OPTION\n";
		printf "%s\n", $form_option;
		print "#### data\n";
		printf "%s\n", $post_data;
		print "#### TVINFO/login POST RESPONSE END   ####\n";
	};

	if (defined $ReadLoginResponseHTML) {
		if (! -e $ReadLoginResponseHTML) {
			logging("ERROR", "TVINFO: given raw file for 'login response' is missing (forget -W before?): " . $ReadLoginResponseHTML);
			return(1);
		};
		# load 'login' from file
		logging("INFO", "TVINFO: read HTML contents of 'login response' from file: " . $ReadLoginResponseHTML);
		if(!open(FILE, "<$ReadLoginResponseHTML")) {
			logging("ERROR", "TVINFO: can't read HTML contents of 'login response' from file: " . $ReadLoginResponseHTML);
			return(1);
		};
		binmode(FILE);
		while(<FILE>) {
			$html_raw .= $_;
		};
		close(FILE);
		logging("INFO", "TVINFO: HTML contents of 'login response' read from file: " . $ReadLoginResponseHTML);
	} else {
		logging ("INFO", "TVINFO: fetch 'login response' via HTML interface");

		# create curl request (-s: silent, -v: display header)
		$html_raw = `curl -s -v --cookie '$tvinfo_login_cookie'  -A '$user_agent' -k $form_option '$form_url' 2>&1`;

		if (defined $WriteLoginResponseHTML) {
			logging("NOTICE", "TVINFO: write HTML contents of 'login response' to file: " . $WriteLoginResponseHTML);
			if(! open(FILE, ">$WriteLoginResponseHTML")) {
				logging("ERROR", "TVINFO: can't write HTML contents of 'login repsonse' to file: " . $WriteLoginResponseHTML . " (" . $! . ")");
			} else {
				print FILE $html_raw;
				close(FILE);
				logging("NOTICE", "TVINFO: HTML contents of 'login response' written to file: " . $WriteLoginResponseHTML);
			};
		};

		if ($html_raw !~ /< Set-Cookie:/io) {
			logging("ERROR", "TVINFO: 'login repsonse' page fetched from 'tvinfo' is missing 'Set-Cookie:' (\"$form_url\"): " . substr($html_raw, 0, 320) . "...");
			return(1);
		};
	};

	# extract authentication cookie
	for my $line (split("\n", $html_raw)) {
		# skip not-response header lines
		next if $line !~ /^< /o;
		next if $line !~ /< Set-Cookie: ([^;]+)/io;
		next if $line !~ /< Set-Cookie: (tvuserhash=[^;]+)/io;
		$tvinfo_auth_cookie = $1;
		last;
	};

	if (defined $tvinfo_auth_cookie) {
		logging("DEBUG", "TVINFO: authentication cookie found in 'login response': " . $tvinfo_auth_cookie);
	} else {
		logging("ERROR", "TVINFO: authentication cookie not found in 'login response' (STOP)");
		return(1);
	};

	die;

	return(0);
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
		die "service.source.type is not defined - FIX CODE";
	};

	if ($config{'service.source.type'} eq "file") {
		$ReadStationsXML = $config{'service.source.file.prefix'} . "-stations.xml";
	} elsif ($config{'service.source.type'} eq "network+store") {
		$WriteStationsXML = $config{'service.source.file.prefix'} . "-stations.xml";
	} elsif ($config{'service.source.type'} eq "network") {
	} else {
		die "service.source.type is not supported: " . $config{'service.source.type'} . " - FIX CODE";
	};

	if (defined $ReadStationsXML) {
		if (! -e $ReadStationsXML) {
			logging("ERROR", "TVINFO: given raw file for stations is missing (forget -W before?): " . $ReadStationsXML);
			return(1);
		};
		# load 'Sender' (stations) from file
		logging("INFO", "TVINFO: read XML contents of stations from file: " . $ReadStationsXML);
		if(!open(FILE, "<$ReadStationsXML")) {
			logging("ERROR", "TVINFO: can't read XML contents of stations from file: " . $ReadStationsXML);
			return(1);
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

		my $rc = service_tvinfo_login();
		return (1) if ($rc != 0);

		my $request = request_replace_tokens("https://www.tvinfo.de/external/openCal/stations.php?username=<USERNAME>&password=<PASSWORDHASH>");

		logging("DEBUG", "TVINFO: start request: " . $request);

		my $retry_max = 3;
		my $retry = 0;
		my $response;
		my $interval = 10;

		while ($retry < $retry_max) {
			$retry++;
			unless (defined $use_curl && $use_curl eq "1") {
				logging("DEBUG", "TVINFO: fetch XML stations via 'LWP': " . $request);
				$response = $tvinfo_client->request(GET "$request");
				if ($response->is_success) {
					$xml_raw = $response->content;
					last;
				};
				logging("NOTICE", "TVINFO: can't fetch XML stations via 'LWP' (retry in $interval seconds $retry/$retry_max): " . $response->status_line);
			} else {
				logging("DEBUG", "TVINFO: fetch stations via 'curl': " . $request);
				$xml_raw = `curl -A '$user_agent' -k '$request' 2>/dev/null`;
				if ($xml_raw =~ /^<\?xml /o) {
					last;
				};
				logging("NOTICE", "TVINFO: can't fetch XML stations via 'curl' (retry in $interval seconds $retry/$retry_max): " . substr($xml_raw, 0, 320) . "...");
			};
			sleep($interval);
		};

		$xml_raw = "(empty)" if (! defined $xml_raw);

		if ($xml_raw !~ /^<\?xml /o) {
			logging("ERROR", "TVINFO: can't fetch XML stations: " . substr($xml_raw, 0, 320) . "...");
			return(1);
		};

		logging("INFO", "TVINFO: successful fetch XML stations after try: " . $retry);

		if (defined $WriteStationsXML) {
			logging("NOTICE", "TVINFO: write XML contents of stations to file: " . $WriteStationsXML);
			if(! open(FILE, ">$WriteStationsXML")) {
				logging("ERROR", "TVINFO: can't write XML contents of stations to file: " . $WriteStationsXML . " (" . $! . ")");
			} else {
				print FILE $xml_raw;
				close(FILE);
				logging("NOTICE", "TVINFO: XML contents of stations written to file: " . $WriteStationsXML);
			};
		};
	};

	if (defined $traceclass{'TVINFO'}  && ($traceclass{'TVINFO'} & 0x01)) {
		print "#### TVINFO/stations XML NATIVE RESPONSE BEGIN ####\n";
		print $xml_raw;
		print "#### TVINFO/stations XML NATIVE RESPONSE END   ####\n";
	};

	if ($xml_raw =~ /<!-- (.*) -->/o) {
		logging("NOTICE", "TVINFO: stations XML contains comment, remove it");
		$xml_raw =~ s/<!-- (.*) -->//;
	};

	if ($xml_raw =~ /^(.+)<\?xml.*/o) {
		logging("NOTICE", "TVINFO: stations XML contains unexpected chars before XML starts, remove it: $1");
		$xml_raw =~ s/$1//;
	};

	if ($xml_raw =~ /encoding="UTF-8"/o) {
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
	if ($$data{'version'} ne "1.0") {
		logging ("ALERT", "XML 'Sender' has not supported version: " . $$data{'version'} . " please check for latest version and contact asap script development");
		return(1);
	};

	if ($xml_raw !~ /stations/) {
		logging ("ERROR", "TVINFO: XML don't contain any stations, empty or username/passwort not proper, can't proceed");
		return(1);
	} else {
		my $xml_list_p = @$data{'station'};

		logging ("INFO", "TVINFO: XML contains amount of stations: " . scalar(keys @$xml_list_p));
	};

	my $xml_root_p = @$data{'station'};
	if (defined $traceclass{'TVINFO'} && ($traceclass{'TVINFO'} & 0x04)) {
		print "#### TVINFO/stations xml_root_p RESPONSE BEGIN ####\n";
		print Dumper($xml_root_p);
		print "#### TVINFO/stations xml_root_p RESPONSE END   ####\n";
	};

	foreach my $entry (@$xml_root_p) {
		my $name = $entry->{'name'};
		my $id = $entry->{'id'};

		my $altnames_p = $entry->{'altnames'}->{'altname'};

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

		# add name without " (HD|SD)" also to altnames
		if ($name =~ /(.*) (HD|SD)$/o) {
			$altnames .= "|" if ($altnames ne "");
			$altnames .= $1;
		};

		$tvinfo_AlleSender_id_list{$id}->{'name'} = $name;
		$tvinfo_AlleSender_id_list{$id}->{'altnames'} = $altnames;

		my $selected = 0;
		if (defined $entry->{'selected'} && $entry->{'selected'} eq "selected") {
			$selected = 1;
			$tvinfo_MeineSender_id_list{$id}->{'name'} = $name;
			$tvinfo_MeineSender_id_list{$id}->{'altnames'} = $altnames;
		};

		logging("DEBUG", "TVINFO: station: " . sprintf("%4d: %s (%s) %d", $id, $name, $altnames, $selected));

		$tvinfo_channel_name_by_id{$id} = $name;
		$tvinfo_channel_id_by_name{$name} = $id;

		if ((defined $ENV{'LANG'}) && ($ENV{'LANG'} =~ /utf-?8/io)) {
			# recode
			$name = encode("iso-8859-1", decode("utf8", $name));
			$altnames = encode("iso-8859-1", decode("utf8", $altnames));
		};

		push @$channels_ap, {
			'cid'      => $id,
			'name'     => $name,
			'altnames' => $altnames,
			'enabled'  => $selected,
		};
	};


	if (scalar(keys %tvinfo_channel_id_by_name) == 0) {
		logging("ALERT", "No entry found for 'Alle Sender' - please check for latest version and contact asap script development");
		return(1);
	};

	if (scalar(keys %tvinfo_MeineSender_id_list) == 0) {
		logging("ALERT", "TVINFO: no entry found for 'Meine Sender' - please check for latest version and contact asap script development");
		return(1);
	};

	# print 'Meine Sender'
	my $c = -1;
	foreach my $id (keys %tvinfo_MeineSender_id_list) {
		$c++;

		my $name = "MISSING";
		if (defined $tvinfo_channel_name_by_id{$id}) {
			$name = $tvinfo_channel_name_by_id{$id};
		};
		logging("DEBUG", "TVINFO: selected station: " . sprintf("%4d: %4d %s", $c, $id, $name));
	};

	return(0);
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
# return values
# 0: ok
# 1: error
# 2: list empty
#
# XML structure:
#$VAR1 = {
#          'uid' => '795006859',
#          'title' => 'Tagesschau',
#          'cast_director' => {},
#          'starttime' => '2014-12-06 20:00:00 +0100',
#          'eventtype' => 'rec',
#          'cast_actors' => {},
#          'nature' => 'Nachrichten',
#          'endtime' => '2014-12-06 20:15:00 +0100',
#          'channel' => 'ARD',
#          'format' => 'Nachrichten'
#        };
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
		die "service.source.type is not supported: " . $config{'service.source.type'} . " - FIX CODE";
	};

	if (defined $ReadScheduleXML) {
		if (! -e $ReadScheduleXML) {
			logging("ERROR", "TVINFO: given raw file for timers is missing (forget -W before?): " . $ReadScheduleXML);
			return(1);
		};
		# load 'Merkzettel' from file
		logging("INFO", "TVINFO: read XML contents of timers from file: " . $ReadScheduleXML);
		if(!open(FILE, "<$ReadScheduleXML")) {
			logging("ERROR", "TVINFO: can't read XML contents of timers from file: " . $ReadScheduleXML);
			return(1);
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

		my $request = request_replace_tokens("https://www.tvinfo.de/share/openepg/schedule.php?username=<USERNAME>&password=<PASSWORDHASH>");

		logging("DEBUG", "TVINFO: start request: " . $request);

		my $retry_max = 3;
		my $retry = 0;
		my $response;
		my $interval = 10;

		while ($retry < $retry_max) {
			$retry++;
			unless (defined $use_curl && $use_curl eq "1") {
				logging("DEBUG", "TVINFO: fetch XML timers via 'LWP' now: " . $request);
				$response = $tvinfo_client->request(GET "$request");
				if ($response->is_success) {
					$xml_raw = $response->content;
					last;
				};
				logging("NOTICE", "TVINFO: can't fetch XML timers via 'LWP' (retry in $interval seconds $retry/$retry_max): " . $response->status_line);
			} else {
				logging("DEBUG", "TVINFO: fetch XML timers via 'curl' now: " . $request);
				$xml_raw = `curl -A '$user_agent' -k '$request' 2>/dev/null`;
				if ($xml_raw =~ /^<\?xml /o) {
					last;
				};
				logging("NOTICE", "TVINFO: can't fetch XML timers via 'curl' (retry in $interval seconds $retry/$retry_max): " . substr($xml_raw, 0, 320) . "...");
			};
			sleep($interval);
		};

		$xml_raw = "(empty)" if (! defined $xml_raw);

		if ($xml_raw !~ /^<\?xml /o) {
			logging("ERROR", "TVINFO: can't fetch XML timers: " . substr($xml_raw, 0, 320) . "...");
			return(1);
		};

		logging("INFO", "TVINFO: successful fetch XML timers after try: " . $retry);

		if (defined $WriteScheduleXML) {
			logging("NOTICE", "TVINFO: write XML contents of timers to file: " . $WriteScheduleXML);
			if (! open(FILE, ">$WriteScheduleXML")) {
				logging("ERROR", "TVINFO: can't write XML contents of timers to file: " . $WriteScheduleXML . " (" . $! . ")");
				return(1);
			};
			print FILE $xml_raw;
			close(FILE);
			logging("NOTICE", "TVINFO: XML contents of timers written to file: " . $WriteScheduleXML);
		};
	};

	if (defined $traceclass{'TVINFO'} && ($traceclass{'TVINFO'} & 0x10)) {
		print "#### TVINFO/timers XML NATIVE RESPONSE BEGIN ####\n";
		print $xml_raw;
		print "#### TVINFO/timers XML NATIVE RESPONSE END   ####\n";
	};

	if ($xml_raw =~ /<!-- (.*) -->/o) {
		logging("NOTICE", "TVINFO: schedule XML contains comment, remove it");
		$xml_raw =~ s/<!-- (.*) -->//;
	};

	if ($xml_raw =~ /^(.+)<\?xml.*/o) {
		logging("NOTICE", "TVINFO: schedule XML contains unexpected chars before XML starts, remove it: $1");
		$xml_raw =~ s/$1//;
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
		return(1);
	};

	if ($xml_raw !~ /epg_schedule_entry/) {
		if ($service_login_state == 1) {
			logging("NOTICE", "TVINFO: XML timer list is empty (assumed, because login worked before)");
			return(2);
		} else {
			logging ("ERROR", "TVINFO: XML timer is empty or username/passwort not proper, can't proceed");
			return(1);
		};
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

	foreach my $xml_entry_p (sort { $b->{'uid'} <=> $a->{'uid'} } @xml_list) {
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

		my $start_ut = str2time($xml_starttime);
		my $stop_ut  = str2time($xml_endtime  );

		if ((ref($xml_title) eq 'HASH') || (ref($xml_title) eq 'ARRAY')) {
			$xml_title = "TITLE_EMPTY_OR_UNSUPPORTED";
			logging("NOTICE", "TVINFO: no valid title: start='$xml_starttime' end='$xml_endtime' channel='$xml_channel' uid='$$xml_entry_p{'uid'}");
		};

		if (! defined $start_ut) {
			logging("WARN", "TVINFO: SKIP ('start' broken): start='$xml_starttime' end='$xml_endtime' channel='$xml_channel' title='$xml_title'");
			next;
		};

		if (! defined $stop_ut) {
			logging("WARN", "TVINFO: SKIP ('end' broken): start='$xml_starttime' end='$xml_endtime' channel='$xml_channel' title='$xml_title'");
			next;
		};

		# round-down minute based (sometimes, XML contains seconds <> 00)
		$start_ut = int($start_ut / 60) * 60;
		$stop_ut  = int($stop_ut  / 60) * 60;

		if ($$xml_entry_p{'eventtype'} ne "rec") {
			logging("DEBUG", "TVINFO: SKIP (eventtype!=rec): start='$xml_starttime' end='$xml_endtime' channel='$xml_channel' title='$xml_title'");
			next;
		};

		if ($xml_title =~ /^([^\r]+)[\r]/o) {
			$xml_title = $1;
			logging("DEBUG", "TVINFO: '\\r' char found in title, reduce to: '" . $xml_title . "'");
		};

		if ($xml_title =~ / +$/o) {
			$xml_title =~ s/ +$//o;
			logging("DEBUG", "TVINFO: trailing spaces found in title, reduce to: '" . $xml_title . "'");
		};

		if (!defined $tvinfo_channel_id_by_name{$xml_channel}) {
			logging("WARN", "TVINFO: SKIP (channel_id not defined): start='$xml_starttime' end='$xml_endtime' channel='$xml_channel' title='$xml_title'");
			next;
		};

		# check for existing timer
		my $duplicate = 0;
		for my $timer_p (@$timers_ap) {
			if (($timer_p->{'start_ut'} eq $start_ut)
			    && ($timer_p->{'stop_ut'} eq $stop_ut)
			    && ($timer_p->{'cid'} eq $tvinfo_channel_id_by_name{$xml_channel})) {
				logging("WARN", "TVINFO: SKIP (duplicate found to tid=$timer_p->{'tid'}): tid=$$xml_entry_p{'uid'} start='$xml_starttime' end='$xml_endtime' channel='$xml_channel' title='$xml_title'");
				$duplicate = 1;
			};
		};
		next if ($duplicate == 1);

		push @$timers_ap, {
			'tid'          => $$xml_entry_p{'uid'},
			'start_ut'     => $start_ut,
			'stop_ut'      => $stop_ut,
			'cid'          => $tvinfo_channel_id_by_name{$xml_channel},
			'title'        => $xml_title,
			'genre'        => $$xml_entry_p{'nature'},
			'service_data' => "tvinfo:" . $config{'service.user'}
		};

		logging("DEBUG", "TVINFO: found timer:"
			. " tid="      . $$xml_entry_p{'uid'}
			. " start="    . $xml_starttime . " (" . strftime("%Y%m%d-%H%M", localtime($start_ut)) . ")"
			. " end="      . $xml_endtime   . " (" . strftime("%Y%m%d-%H%M", localtime($stop_ut)) . ")"
			. " channel='" . $xml_channel . "' (" . $tvinfo_channel_id_by_name{$xml_channel} . ")"
			. " title='"   . $xml_title . "'"
                        . " s_d="      . "tvinfo:" . $config{'service.user'}
		);

	};

	logging("DEBUG", "TVINFO: finish XML timer analysis");

	return(0);
};


#### END
return 1;
