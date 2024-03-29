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
# 20230509/bie: add initial HTML login support
# 20230511/bie: add Merkzettel HTML parser
# 20230515/bie: add Sender HTML parser
# 20230516/bie: add support for service options
# 20231027/bie: remove MD5 password prefix on authentication

# supported:
#  --so use:xml
#  --so use:html

use strict;
use warnings;
use utf8;

use Data::Dumper;
use LWP;
use LWP::Protocol::https;
use HTTP::Request::Common;
use HTTP::Date;
use Encode;
#use Date::Manip;
use Digest::MD5 qw(md5_hex);

# XML parser
use XML::Simple;

# HTML parser
use HTML::Parser;
use HTML::TreeBuilder;
use HTML::StripScripts::Parser;
use HTML::TokeParser::Simple;


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
my $tvinfo_url_login     = $tvinfo_url_base . "/";
my $tvinfo_channels      = $tvinfo_url_base . "/sender";
my $tvinfo_timers        = $tvinfo_url_base . "/merkzettel";

my $tvinfo_login_cookie;
my $tvinfo_auth_cookie;
my $tvinfo_user_cookie;


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
	if ($_[0] !~ /^{MD5}(.*)/) {
		logging("NOTICE", "TVinfo password is not given as hash (conversion used for security reasons)");
		if (defined $_[1]) {
			return(md5_hex($_[0]));
		} else {
			return("{MD5}" . md5_hex($_[0]));
		};
	} else {
		if (defined $_[1]) {
			return($1);
		} else {
			return($_[0]);
		};
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
		$tvinfo_auth_cookie = $1 if $line =~ /< Set-Cookie: (tvuserhash=[^;]+)/io;
		$tvinfo_user_cookie = $1 if $line =~ /< Set-Cookie: (tvusername=[^;]+)/io;
		last if (defined $tvinfo_auth_cookie && defined $tvinfo_user_cookie);
	};

	if (defined $tvinfo_auth_cookie) {
		logging("DEBUG", "TVINFO: authentication cookie found in 'login response': " . $tvinfo_auth_cookie);
	} else {
		logging("ERROR", "TVINFO: authentication cookie not found in 'login response' (STOP)");
		return(1);
	};

	if (defined $tvinfo_user_cookie) {
		logging("DEBUG", "TVINFO: user           cookie found in 'login response': " . $tvinfo_user_cookie);
	} else {
		logging("ERROR", "TVINFO: user           cookie not found in 'login response' (STOP)");
		return(1);
	};

	return(0);
};


################################################################################
################################################################################
# get channels (aka stations/Sender) from TVinfo via legacy XML
# arg1: pointer to channel array
#
# $traceclass{'TVINFO'}:
#   0x01: XML dump stations raw
#   0x02: XML dump stations
#
# XML structure:
#    TODO
################################################################################
sub service_tvinfo_get_channels_xml($) {
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

	return(0);
};


################################################################################
################################################################################
# get channels (aka stations/Sender) from TVinfo via HTML
# arg1: pointer to channel array
#
# $traceclass{'TVINFO'}:
#   0x101: HTML dump channels raw
#   0x102: HTML dump channels
#
# return values
# 0: ok
# 1: error
# 2: list empty
#
# HTML structure:
# <div class="w100"><a href="/tv-programm/ard" title="TV Sender: ARD - Das Erste">ARD - Das Erste</a></div>
# <div id="aBut37" class="but37 adbt"><a href="javascript:_addDelSID(37,0);" class="but_s_dBlue" title="Sender ARD - Das Erste aus Meine Sender entfernen">&ndash;</a></div>
################################################################################
sub service_tvinfo_get_channels_html($) {
	my $channels_ap = $_[0];

	logging ("DEBUG", "TVINFO: fetch channels");

	my $html_raw;

	my $ReadStationHTML = undef;
	my $WriteStationHTML = undef;

	if ($config{'service.source.type'} eq "file") {
		$ReadStationHTML = $config{'service.source.file.prefix'} . "-sender.html";
	} elsif ($config{'service.source.type'} eq "network+store") {
		$WriteStationHTML = $config{'service.source.file.prefix'} . "-sender.html";
	} elsif ($config{'service.source.type'} eq "network") {
	} else {
		die "service.source.type is not supported: " . $config{'service.source.type'} . " - FIX CODE";
	};

	if (defined $ReadStationHTML) {
		if (! -e $ReadStationHTML) {
			logging("ERROR", "TVINFO: given raw file for channels is missing (forget -W before?): " . $ReadStationHTML);
			return(1);
		};
		# load 'SENDER' from file
		logging("INFO", "TVINFO: read SENDER/HTML contents of channels from file: " . $ReadStationHTML);
		if(!open(FILE, "<$ReadStationHTML")) {
			logging("ERROR", "TVINFO: can't read SENDER/HTML contents of channels from file: " . $ReadStationHTML);
			return(1);
		};
		binmode(FILE);
		while(<FILE>) {
			$html_raw .= $_;
		};
		close(FILE);
		logging("INFO", "TVINFO: SENDER/HTML contents of channels read from file: " . $ReadStationHTML);
	} else {
		# Fetch 'SENDER'
		logging ("INFO", "TVINFO: fetch channels via SENDER/HTML interface");

		my $rc = service_tvinfo_login();
		return (1) if ($rc != 0);

		my $request = $tvinfo_channels;
		logging("TRACE", "TVINFO: execute: curl -b '$tvinfo_auth_cookie' -b '$tvinfo_user_cookie' -A '$user_agent' -k '$request'");
		$html_raw = `curl -b '$tvinfo_auth_cookie' -b '$tvinfo_user_cookie' -A '$user_agent' -k '$request' 2>/dev/null`;

		if (defined $WriteStationHTML) {
			logging("NOTICE", "TVINFO: write SENDER/HTML contents of channels to file: " . $WriteStationHTML);
			if (! open(FILE, ">$WriteStationHTML")) {
				logging("ERROR", "TVINFO: can't write SENDER/HTML contents of channels to file: " . $WriteStationHTML . " (" . $! . ")");
				return(1);
			};
			print FILE $html_raw;
			close(FILE);
			logging("NOTICE", "TVINFO: SENDER/HTML contents of channels written to file: " . $WriteStationHTML);
		};
	};

	if (defined $traceclass{'TVINFO'} && ($traceclass{'TVINFO'} & 0x110)) {
		print "#### TVINFO/channels SENDER/HTML NATIVE RESPONSE BEGIN ####\n";
		print $html_raw;
		print "#### TVINFO/channels SENDER/HTML NATIVE RESPONSE END   ####\n";
	};

	if ($html_raw !~ /Meine Sender/o) {
		logging ("ALERT", "TVINFO: SENDER/HTML of channel has not supported content, please check for latest version and contact asap script development");
		return(1);
	};


	####################################
	## SENDER/HTML channel analysis
	####################################

	logging("DEBUG", "TVINFO: start SENDER/HTML channel analysis");

	$html_raw = decode("utf-8", $html_raw);

	# Run through entries of SENDER/HTML
	my $parser= HTML::TokeParser::Simple->new(\$html_raw);

	my $name = undef;
	my $id;
	my $flag;
	while (my $anchor = $parser->get_token) {
		next unless ($anchor->is_start_tag('a'));

		my $href = $anchor->get_attr('href');
		next unless defined($href);

		unless (defined($name)) {
			my $class = $anchor->get_attr('class');
			next if defined($class);

			my $title = $anchor->get_attr('title');
			next unless defined($title);
			next unless ($title =~ /^TV Sender: (.*)$/o);
			$name = $1;
		} else {
			next unless ($href =~ /^javascript:_addDelSID\((\d+),(\d+)\);$/o);
			$id = $1;
			$flag = $2;

			my $selected = 0;

			if ($flag == 0) {
				$selected = 1;
				$tvinfo_MeineSender_id_list{$id}->{'name'} = $name;
			};

			$tvinfo_channel_name_by_id{$id} = $name;
			$tvinfo_channel_id_by_name{$name} = $id;

			push @$channels_ap, {
				'cid'      => $id,
				'name'     => $name,
				'enabled'  => $selected,
			};

			logging ("DEBUG", "TVINFO: SENDER/HTML found: >" . $name . "< id=" . $id . " selected=" . $selected);

			undef $name;
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

	logging("DEBUG", "TVINFO: SENDER/HTML finish channel analysis");

	return(0);
};

################################################################################
################################################################################
# get timers (aka schedules/Merkzettel) from TVinfo via legacy XML interface
# arg1: pointer to timers array
#
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
sub service_tvinfo_get_timers_xml($) {
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


################################################################################
################################################################################
# get timers (aka schedules/Merkzettel) from TVinfo via HTML interface
# arg1: pointer to timers array
#
# $traceclass{'TVINFO'}:
#   0x110: HTML dump schedules raw
#   0x120: HTML dump schedules
#   0x140: HTML dump each schedules
#
# return values
# 0: ok
# 1: error
# 2: list empty
#
# HTML structure:
# <form action="/merkzettel" method="post" name="rList" target="ctrlFrame">
#   <table class="list" id="reminderList">
#   	  <tr class="lightBlue sh_w_v">
#   	  <th class="t1">Sender</th>
#	  <th class="t2">Datum</th>
#	  <th class="t3">Uhrzeit</th>
#	  <th class="t4">bis</th>
#	  ...
#	  </tr>
#      <tr class="lightBlue sh_w_v" id="TR1677653580">
#	<td class="t1"><em class="SD_bfs slogo"  title="TV Sender: BR"><span>BR</span></em></td>
#	<td class="t2">DO 11.5.</td>
#	<td class="t3"><span class="tvTime">20:15</span></td>
#	<td class="t4">21:00</td>
#	<td class="t5"><input type="hidden" name="sidnr[1677653580]" value="1677653580" /><a href="/fernsehprogramm/1677653580-quer" class="bold">quer</a> <i>... durch die Woche mit Christoph Süß&nbsp;</i></td>
#	  ...
#      </tr>
################################################################################
sub service_tvinfo_get_timers_html($) {
	my $timers_ap = $_[0];

	logging ("DEBUG", "TVINFO: fetch timers");

	my $html_raw;

	my $ReadScheduleHTML = undef;
	my $WriteScheduleHTML = undef;

	if ($config{'service.source.type'} eq "file") {
		$ReadScheduleHTML = $config{'service.source.file.prefix'} . "-merkzettel.html";
	} elsif ($config{'service.source.type'} eq "network+store") {
		$WriteScheduleHTML = $config{'service.source.file.prefix'} . "-merkzettel.html";
	} elsif ($config{'service.source.type'} eq "network") {
	} else {
		die "service.source.type is not supported: " . $config{'service.source.type'} . " - FIX CODE";
	};

	if (defined $ReadScheduleHTML) {
		if (! -e $ReadScheduleHTML) {
			logging("ERROR", "TVINFO: given raw file for timers is missing (forget -W before?): " . $ReadScheduleHTML);
			return(1);
		};
		# load 'MERKZETTEL' from file
		logging("INFO", "TVINFO: read MERKZETTEL/HTML contents of timers from file: " . $ReadScheduleHTML);
		if(!open(FILE, "<$ReadScheduleHTML")) {
			logging("ERROR", "TVINFO: can't read MERKZETTEL/HTML contents of timers from file: " . $ReadScheduleHTML);
			return(1);
		};
		binmode(FILE);
		while(<FILE>) {
			$html_raw .= $_;
		};
		close(FILE);
		logging("INFO", "TVINFO: MERKZETTEL/HTML contents of timers read from file: " . $ReadScheduleHTML);
	} else {
		# Fetch 'MERKZETTEL'
		logging ("INFO", "TVINFO: fetch timers via MERKZETTEL/HTML interface");

		my $rc = service_tvinfo_login();
		return (1) if ($rc != 0);

		my $request = $tvinfo_timers;
		logging("TRACE", "TVINFO: execute: curl -b '$tvinfo_auth_cookie' -b '$tvinfo_user_cookie' -A '$user_agent' -k '$request'");
		$html_raw = `curl -b '$tvinfo_auth_cookie' -b '$tvinfo_user_cookie' -A '$user_agent' -k '$request' 2>/dev/null`;

		if (defined $WriteScheduleHTML) {
			logging("NOTICE", "TVINFO: write MERKZETTEL/HTML contents of timers to file: " . $WriteScheduleHTML);
			if (! open(FILE, ">$WriteScheduleHTML")) {
				logging("ERROR", "TVINFO: can't write MERKZETTEL/HTML contents of timers to file: " . $WriteScheduleHTML . " (" . $! . ")");
				return(1);
			};
			print FILE $html_raw;
			close(FILE);
			logging("NOTICE", "TVINFO: MERKZETTEL/HTML contents of timers written to file: " . $WriteScheduleHTML);
		};
	};

	if (defined $traceclass{'TVINFO'} && ($traceclass{'TVINFO'} & 0x110)) {
		print "#### TVINFO/timers MERKZETTEL/HTML NATIVE RESPONSE BEGIN ####\n";
		print $html_raw;
		print "#### TVINFO/timers MERKZETTEL/HTML NATIVE RESPONSE END   ####\n";
	};

	if ($html_raw !~ /"Merkzettel"/o) {
		logging ("ALERT", "TVINFO: MERKZETTEL/HTML of timer has not supported content, please check for latest version and contact asap script development");
		return(1);
	};


	####################################
	## MERKZETTEL/HTML timer analysis
	####################################

	logging("DEBUG", "TVINFO: start MERKZETTEL/HTML timer analysis");

	$html_raw = decode("utf-8", $html_raw);

	# Run through entries of MERKZETTEL/HTML
	my $parser= HTML::TokeParser::Simple->new(\$html_raw);

	## look for "form" around timers
	my $timer_start_found = 0;
	while (my $anchor = $parser->get_tag('form')) {
		# look for attr 'action'
		my $action = $anchor->get_attr('action');
		next unless defined($action);
		next unless ($action eq "/merkzettel");
		$timer_start_found = 1;
		last;
	};

	if ($timer_start_found != 1) {
		logging ("WARN", "TVINFO: MERKZETTEL/HTML found no timer section, please check for latest version and contact asap script development");
		return(1);
	};

	logging("DEBUG", "TVINFO: found MERKZETTEL/HTML timer section");


	## look for table header
	my $timer_header_found = 0;
	while (my $anchor = $parser->get_tag('table')) {
		# look for attr 'id'
		my $id = $anchor->get_attr('id');
		next unless defined($id);
		next unless ($id eq "reminderList");
		$timer_header_found = 1;
		last;
	};

	if ($timer_header_found != 1) {
		logging ("WARN", "TVINFO: MERKZETTEL/HTML found no timer header, please check for latest version and contact asap script development");
		return(1);
	};

	logging("DEBUG", "TVINFO: found MERKZETTEL/HTML timer header");

	## run through rows
	my %timer_columns;
	my $id;

	my $timer_complete = 0;
	my %timer_entry;
	my %timer_input;
	while (my $anchor = $parser->get_token) {
		if ($anchor->is_start_tag('tr')) {
			# look for attr 'id'
			$id = $anchor->get_attr('id');
			next unless (defined $id);
			# strip leading chars
			$id = $1 if ($id =~ /^[A-Za-z]+([0-9]+)/);
			next;
		};

		if ($anchor->is_start_tag('th')) {
			## parse for table header
			# look for attr 'class'
			my $class = $anchor->get_attr('class');
			next unless defined($class);
			next unless ($class =~ /^t/o);
			my $text = $parser->get_text();
			if ($text =~ /^[a-z]+/io) {
				# all good
			} elsif ($class eq "t5") {
				# assume t5 <-> "title"
				$text = "Titel";
			} else {
				next;
			};
			$timer_columns{$class} =  $text;
			logging("DEBUG", "TVINFO: MERKZETTEL/HTML timer header column found: " . $class . "='" . $text . "'");
		};

		if ($anchor->is_start_tag('td')) {
			# look for attr 'class'
			my $class = $anchor->get_attr('class');
			next unless defined($class);
			next unless (defined $timer_columns{$class}); # td/class was not found in header before
			my $text;
			if ($timer_columns{$class} eq "Sender") {
				# <td class="t1"><em class="SD_bfs slogo"  title="TV Sender: BR"><span>BR</span></em></td>
				$anchor = $parser->get_tag('span');
				$text = $parser->get_text();
				next if (! defined $text); 

			} elsif ($timer_columns{$class} eq "Uhrzeit") {
				# <td class="t3"><span class="tvTime">00:20</span></td>
				$anchor = $parser->get_tag('span');
				$text = $parser->get_text();
				next if (! defined $text); 

			} elsif ($timer_columns{$class} eq "Datum") {
				# <td class="t2">DO 25.5.</td>
				$text = $parser->get_text();
				next if (! defined $text); 
				$text = $1 if ($text =~ /^.* ([0-9]+\.[0-9]+\.)$/o); # strip leading weekday

			} elsif ($timer_columns{$class} eq "Titel") {
				# td class="t5"><input type="hidden" name="sidnr[1677653586]" value="1677653586" /><a href="/fernsehprogramm/1677653586-ringlstetter" class="bold">Ringlstetter</a> <i>&nbsp;</i></td>
				$anchor = $parser->get_tag('a');
				$text = $parser->get_text();
				$text =~ s/‘/\'/g;  # convert special chars
				$text =~ s/\"/\'/g; # convert special chars
				$text =~ s/ +$//o;  # remove trailing spaces
				next if (! defined $text); 

				# timer complete
				$timer_complete = 1;
			} else {
				$text = $parser->get_text();
			};

			$timer_input{$timer_columns{$class}} = $text;

			logging("DEBUG", "TVINFO: MERKZETTEL/HTML timer data found: id=" . $id . " => " . $timer_columns{$class} . ": >" . $text . "<");

			if ($timer_complete == 1) {
				# get current year
				my $year = strftime("%Y", localtime);
				my $ut = strftime("%s", localtime);
				my $year_last = $year - 1;

				my $html_starttime = reformat_date_time($timer_input{'Datum'} . $year, $timer_input{'Uhrzeit'} . ":00");
				my $start_ut = str2time($html_starttime);
				if ($start_ut > $ut + (6 * 30 *86400)) {
					# catch rollover (timers in the past)
					$html_starttime = reformat_date_time($timer_input{'Datum'} . $year_last, $timer_input{'Uhrzeit'} . ":00");
					$start_ut = str2time($html_starttime);
				};

				my $html_endtime = reformat_date_time($timer_input{'Datum'} . $year, $timer_input{'bis'} . ":00");
				my $stop_ut = str2time($html_endtime);
				if ($stop_ut > $ut + (6 * 30 *86400)) {
					# catch rollover (timers in the past)
					$html_endtime = reformat_date_time($timer_input{'Datum'} . $year_last, $timer_input{'bis'} . ":00");
					$stop_ut = str2time($html_endtime);
				};

				if ($start_ut > $stop_ut) {
					# timer end next day
					$stop_ut += 86400; # this is not daylight saving safe
				};

				$timer_entry{'tid'} = $id;
				$timer_entry{'start_ut'} = $start_ut;
				$timer_entry{'stop_ut'} = $stop_ut;
				$timer_entry{'title'} = $timer_input{'Titel'};
				$timer_entry{'service_data'} = "tvinfo:" . $config{'service.user'};
				$timer_entry{'cid'} = $tvinfo_channel_id_by_name{$timer_input{'Sender'}};

				logging("DEBUG", "TVINFO: found timer:"
					. " tid="      . $timer_entry{'tid'}
					. " start="    . $html_starttime . " (" . strftime("%Y%m%d-%H%M", localtime($start_ut)) . ")"
					. " end="      . $html_endtime   . " (" . strftime("%Y%m%d-%H%M", localtime($stop_ut)) . ")"
					. " channel='" . $timer_input{'Sender'} . "' (" . $timer_entry{'cid'} . ")"
					. " title='"   . $timer_entry{'title'} . "'"
					. " s_d="      . $timer_entry{'service_data'}
				);

				push @$timers_ap, \%timer_entry;

				$timer_complete = 0; # reset
			};
		};
	};

	logging("DEBUG", "TVINFO: MERKZETTEL/HTML finish timer analysis");

	return(0);
};


################################################################################
################################################################################
# get timers (aka schedules/Merkzettel) from TVinfo
# arg1: pointer to timers array
#
################################################################################
sub service_tvinfo_get_timers($) {
	my $rc;

	if (defined ($config{'service.options'}) && (grep /use:html/, $config{'service.options'})) {
		# via HTML
		$rc = service_tvinfo_get_timers_html($_[0]);
	} else {
		# via legacy XML
		$rc = service_tvinfo_get_timers_xml($_[0]);
	};

	return($rc);
};


################################################################################
################################################################################
# get channels (aka stations/Sender) from TVinfo
# arg1: pointer to channel array
# arg2: pointer to config
# debug
################################################################################
sub service_tvinfo_get_channels($) {
	my $rc;

	if (defined ($config{'service.options'}) && (grep /use:html/, $config{'service.options'})) {
		# via HTML
		$rc = service_tvinfo_get_channels_html($_[0]);
	} else {
		# via legacy XML
		$rc = service_tvinfo_get_channels_xml($_[0]);
	};

	if ($rc == 0)  {
		# print 'Meine Sender'
		my $c = -1;
		foreach my $id (keys %tvinfo_MeineSender_id_list) {
			$c++;

			my $name = "MISSING";
			my $altnames = "";
			if (defined $tvinfo_channel_name_by_id{$id}) {
				$name = $tvinfo_channel_name_by_id{$id};
			};
			if (defined $tvinfo_AlleSender_id_list{$id}->{'altnames'}) {
				$altnames = " (" . $tvinfo_AlleSender_id_list{$id}->{'altnames'} .  ")";
			};
			logging("DEBUG", "TVINFO: selected station: " . sprintf("%4d: %4d %s%s", $c, $id, $name, $altnames));
		};
	};

	return($rc);
};


#### END
return 1;
