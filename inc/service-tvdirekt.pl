# Support functions for timer service TVdirect
#
# (C) & (P) 2020 - 2022 by by Peter Bieringer <pb@bieringer.de>
#
# License: GPLv2
#
# Authors:
#  Peter Bieringer (bie)
#
# Changelog:
# 20200209/bie: takeover service-tvinfo.pl and adjust
# 20220719/bie: finalize initial implementation

use strict;
use warnings;
use utf8;

use Data::Dumper;
use LWP;
use HTTP::Request::Common;
use HTTP::Date;
use HTML::Parser;
use HTML::TreeBuilder;
use HTML::StripScripts::Parser;
use HTML::TokeParser::Simple;
use Encode;
use Text::CSV;

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
push @service_list_supported, "tvdirekt";
our %module_functions;
$module_functions{'service'}->{'tvdirekt'}->{'get_channels'} = \&service_tvdirekt_get_channels;
$module_functions{'service'}->{'tvdirekt'}->{'get_timers'} = \&service_tvdirekt_get_timers;

## preparation for web requests
my $user_agent = "Mozilla/4.0 ($progname $progversion)";
my $tvdirekt_client = LWP::UserAgent->new;
$tvdirekt_client->agent($user_agent);

if (defined $config{'proxy'}) {
	$tvdirekt_client->proxy('http', $config{'proxy'});
};

## local values
my %tvdirekt_channel_name_by_id;
my %tvdirekt_channel_id_by_name;


my $tvdirekt_url_login     = "https://www.tvdirekt.de/";
my $tvdirekt_view_calendar = "https://www.tvdirekt.de/component/pit_data/?view=calendar";

my $tvdirekt_auth_cookie;

my @timers_tvdirekt;
my $timers_tvdirekt_valid = 0;


################################################################################
################################################################################
# Helper functions
################################################################################

## login to get session cookie
#
# step 1: run through HTML and retrieve the form tokens, example:
#
# <form action="https://www.tvdirekt.de/?option=com_pit_user&amp;task=login" method="post" name="com-login" id="com-form-login">
#  <input name="username" id="username" type="text" class="inputbox" alt="username" size="18" />
#  <input type="password" id="passwd" name="passwd" class="inputbox" size="18" alt="password" />
#  <input type="hidden" name="option" value="com_pit_user" />
#  <input type="hidden" name="task" value="login" />
#  <input type="hidden" name="return" value="aW5kZXgucGhw" />
#  <input type="hidden" name="cc52ff400c8c8532d3db967958610385" value="1" />
# </form>
#
# $traceclass{'TVDIREKT'}:
# $traceclass{'TVDIREKT'} |= 0x01; # HTML login content
# $traceclass{'TVDIREKT'} |= 0x02; # HTML login post response
#
sub service_tvdirekt_login() {
	return(0) if (defined $tvdirekt_auth_cookie);

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

	logging("DEBUG", "TVDIREKT: username         : " . $config{'service.user'});
	logging("DEBUG", "TVDIREKT: password         : *******");

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
			logging("ERROR", "TVDIREKT: given raw file for 'login' is missing (forget -W before?): " . $ReadLoginHTML);
			return(1);
		};
		# load 'login' from file
		logging("INFO", "TVDIREKT: read HTML contents of 'login' from file: " . $ReadLoginHTML);
		if(!open(FILE, "<$ReadLoginHTML")) {
			logging("ERROR", "TVDIREKT: can't read HTML contents of 'login' from file: " . $ReadLoginHTML);
			return(1);
		};
		binmode(FILE);
		while(<FILE>) {
			$html_raw .= $_;
		};
		close(FILE);
		logging("INFO", "TVDIREKT: HTML contents of 'login' read from file: " . $ReadLoginHTML);
	} else {
		logging ("INFO", "TVDIREKT: fetch 'login' via HTML interface");

		my $request = $tvdirekt_url_login;
		$html_raw = `curl -A '$user_agent' -k '$request' 2>/dev/null`;

		if (defined $WriteLoginHTML) {
			logging("NOTICE", "TVDIREKT: write HTML contents of 'login' to file: " . $WriteLoginHTML);
			if(! open(FILE, ">$WriteLoginHTML")) {
				logging("ERROR", "TVDIREKT: can't write HTML contents of 'login' to file: " . $WriteLoginHTML . " (" . $! . ")");
			} else {
				print FILE $html_raw;
				close(FILE);
				logging("NOTICE", "TVDIREKT: HTML contents of 'login' written to file: " . $WriteLoginHTML);
			};
		};

		if ($html_raw !~ /\"username\"/io) {
			logging("ERROR", "TVDIREKT: 'login' page fetched from 'tvdirekt' is missing 'username' (\"$request\"): " . substr($html_raw, 0, 320) . "...");
			return(1);
		};
	};

	$html_raw = decode("utf-8", $html_raw);

	if (defined $traceclass{'TVDIREKT'} && ($traceclass{'TVDIREKT'} & 0x01)) {
		print "#### TVDIREKT/login CONTENT BEGIN ####\n";
		print $html_raw;
		print "#### TVDIREKT/login CONTENT END   ####\n";
	};

	my $parser= HTML::TokeParser::Simple->new(\$html_raw);
	my %form_data;
	my $form_url;
	my $found_username = 0;
	my $found_password = 0;

	# look for tag 'form'
	while (my $anchor = $parser->get_tag('form')) {
		# look for attr 'action'
		my $action = $anchor->get_attr('action');
		next unless defined($action);
		next unless ($action =~ /login/io);

		# look for attr 'method'
		my $method = lc($anchor->get_attr('method'));
		next unless defined($method);
		next unless ($method =~ /^(get|post)$/o);

		logging("TRACE", "TVDIREKT: 'login' form found: method=" . $method . " action=" . $action);
		$form_url = $action;

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
			logging("TRACE", "TVDIREKT: 'login' form input line found: name=" . $name);

			if ($name =~ /username/oi) {
				# input field for 'username'
				$form_data{$name} = $config{'service.user'};
				logging("TRACE", "TVDIREKT: 'login' form 'username' input found: " . $name);
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
					logging("TRACE", "TVDIREKT: 'login' form hidden input found: " . $name . "=" . $value);
				} elsif ($type eq "password") {
					# input field for 'password'
					$form_data{$name} = $config{'service.password'};
					logging("TRACE", "TVDIREKT: 'login' form 'password' input found: " . $name);
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

	$post_data = join("\n", @post_array);

	if (defined $traceclass{'TVDIREKT'} && ($traceclass{'TVDIREKT'} & 0x02)) {
		print "#### TVDIREKT/login POST RESPONSE BEGIN ####\n";
		print "#### URL\n";
		printf "%s\n", $form_url;
		print "#### FORM OPTION\n";
		printf "%s\n", $form_option;
		print "#### data\n";
		printf "%s\n", $post_data;
		print "#### TVDIREKT/login POST RESPONSE END   ####\n";
	};

	if (defined $ReadLoginResponseHTML) {
		if (! -e $ReadLoginResponseHTML) {
			logging("ERROR", "TVDIREKT: given raw file for 'login response' is missing (forget -W before?): " . $ReadLoginResponseHTML);
			return(1);
		};
		# load 'login' from file
		logging("INFO", "TVDIREKT: read HTML contents of 'login response' from file: " . $ReadLoginResponseHTML);
		if(!open(FILE, "<$ReadLoginResponseHTML")) {
			logging("ERROR", "TVDIREKT: can't read HTML contents of 'login response' from file: " . $ReadLoginResponseHTML);
			return(1);
		};
		binmode(FILE);
		while(<FILE>) {
			$html_raw .= $_;
		};
		close(FILE);
		logging("INFO", "TVDIREKT: HTML contents of 'login response' read from file: " . $ReadLoginResponseHTML);
	} else {
		logging ("INFO", "TVDIREKT: fetch 'login response' via HTML interface");

		# create curl request (-s: silent, -v: display header)
		$html_raw = `curl -s -v -A '$user_agent' -k $form_option '$form_url' 2>&1`;

		if (defined $WriteLoginResponseHTML) {
			logging("NOTICE", "TVDIREKT: write HTML contents of 'login response' to file: " . $WriteLoginResponseHTML);
			if(! open(FILE, ">$WriteLoginResponseHTML")) {
				logging("ERROR", "TVDIREKT: can't write HTML contents of 'login repsonse' to file: " . $WriteLoginResponseHTML . " (" . $! . ")");
			} else {
				print FILE $html_raw;
				close(FILE);
				logging("NOTICE", "TVDIREKT: HTML contents of 'login response' written to file: " . $WriteLoginResponseHTML);
			};
		};

		if ($html_raw !~ /< Set-Cookie:/io) {
			logging("ERROR", "TVDIREKT: 'login repsonse' page fetched from 'tvdirekt' is missing 'Set-Cookie:' (\"$form_url\"): " . substr($html_raw, 0, 320) . "...");
			return(1);
		};
	};

	# extract authentication cookie
	for my $line (split("\n", $html_raw)) {
		# skip not-response header lines
		next if $line !~ /^< /o;
		next if $line !~ /< Set-Cookie: ([^;]+)/io;
		$tvdirekt_auth_cookie = $1;
		last;
	};

	if (defined $tvdirekt_auth_cookie) {
		logging("DEBUG", "TVDIREKT: authentication cookie found in 'login response': " . $tvdirekt_auth_cookie);
	} else {
		logging("ERROR", "TVDIREKT: authentication cookie not found in 'login response' (STOP)");
		return(1);
	};

	return(0);
};


################################################################################
################################################################################
# get channels (aka stations/Sender) from TVdirect
# arg1: pointer to channel array
# arg2: pointer to config
# debug
#
# $traceclass{'TVDIREKT'}:
#   n/a
#
# data structure:
#   n/a
#
# CURRENTLY NOT SUPPORTED DIRECTLY VIA API, therefore indirect via timer list
################################################################################
sub service_tvdirekt_get_channels($$;$) {
	my $channels_ap = $_[0];

	logging ("DEBUG", "TVDIREKT: fetch timers to get channels");

	my $rc = service_tvdirekt_get_timers(\@timers_tvdirekt);
	if ($rc != 0) {
		return($rc);
	};

	foreach my $name (sort keys %tvdirekt_channel_id_by_name) {
		push @$channels_ap, {
			'cid'      => $tvdirekt_channel_id_by_name{$name},
			'name'     => $name,
			'altnames' => '',
			'enabled'  => 1,
		};
	};

	return(0);
};


################################################################################
################################################################################
# get timers (aka TV-Planer) from TVdirect
# arg1: pointer to channel array
# arg2: pointer to config
# debug
#
# $traceclass{'TVDIREKT'}:
# $traceclass{'TVDIREKT'} |= 0x10; # CALENDAR/CSV native response
# $traceclass{'TVDIREKT'} |= 0x20; # CALENDAR/CSV raw line
# $traceclass{'TVDIREKT'} |= 0x40; # CALENDAR/CSV parsed entry
#
# return values
# 0: ok
# 1: error
# 2: list empty
#
# URLs:
# CSV/Calendar: https://www.tvdirekt.de/component/pit_data/?view=calendar
#
# data structure:
# "Betreff","Beginnt am","Beginnt um","Endet am","Endet um","Beschreibung","Kategorien"
# "ZDF: heute - Wetter","24.07.2022","19:0:00","24.07.2022","19:10:00","Nachrichten, D 2022
#  Laufzeit: 10 Minuten
#
#  Die Nachrichtensendung des Zweiten Deutschen Fernsehens versorgt die Zuschauer mit aktuellen Meldungen des Tages aus den Bereichen Politik, Wirtschaft, Kultur, Gesellschaft, Sport und Wetter.","TV-GUIDE"
################################################################################
sub service_tvdirekt_get_timers($) {
	my $timers_ap = $_[0];

	if ($timers_tvdirekt_valid == 1) {
		logging ("DEBUG", "TVDIREKT: return already fetched timers");
		# already retrieved, copy, return
		for my $entry (@timers_tvdirekt) {
			push @$timers_ap, $entry;
		};
		return 0;
	};

	logging ("DEBUG", "TVDIREKT: fetch timers");

	my $csv_raw;

	my $ReadScheduleCSV = undef;
	my $WriteScheduleCSV = undef;

	if ($config{'service.source.type'} eq "file") {
		$ReadScheduleCSV = $config{'service.source.file.prefix'} . "-calendar.csv";
	} elsif ($config{'service.source.type'} eq "network+store") {
		$WriteScheduleCSV = $config{'service.source.file.prefix'} . "-calendar.csv";
	} elsif ($config{'service.source.type'} eq "network") {
	} else {
		die "service.source.type is not supported: " . $config{'service.source.type'} . " - FIX CODE";
	};

	if (defined $ReadScheduleCSV) {
		if (! -e $ReadScheduleCSV) {
			logging("ERROR", "TVDIREKT: given raw file for timers is missing (forget -W before?): " . $ReadScheduleCSV);
			return(1);
		};
		# load 'TV-Planer/RSS' from file
		logging("INFO", "TVDIREKT: read CALENDAR/CSV contents of timers from file: " . $ReadScheduleCSV);
		if(!open(FILE, "<$ReadScheduleCSV")) {
			logging("ERROR", "TVDIREKT: can't read CALENDAR/CSV contents of timers from file: " . $ReadScheduleCSV);
			return(1);
		};
		binmode(FILE);
		while(<FILE>) {
			$csv_raw .= $_;
		};
		close(FILE);
		logging("INFO", "TVDIREKT: CALENDAR/CSV contents of timers read from file: " . $ReadScheduleCSV);
	} else {
		# Fetch 'TV-Planer/RSS'
		logging ("INFO", "TVDIREKT: fetch timers via CALENDAR/CSV interface");

		my $rc = service_tvdirekt_login();
		return (1) if ($rc != 0);

		my $request = $tvdirekt_view_calendar;
		logging("TRACE", "TVDIREKT: execute: curl -H 'Cookie: $tvdirekt_auth_cookie' -A '$user_agent' -k '$request'");
		$csv_raw = `curl -H 'Cookie: $tvdirekt_auth_cookie' -A '$user_agent' -k '$request' 2>/dev/null`;

		if (defined $WriteScheduleCSV) {
			logging("NOTICE", "TVDIREKT: write CALENDAR/CSV contents of timers to file: " . $WriteScheduleCSV);
			if (! open(FILE, ">$WriteScheduleCSV")) {
				logging("ERROR", "TVDIREKT: can't write CALENDAR/CSV contents of timers to file: " . $WriteScheduleCSV . " (" . $! . ")");
				return(1);
			};
			print FILE $csv_raw;
			close(FILE);
			logging("NOTICE", "TVDIREKT: CALENDAR/CSV contents of timers written to file: " . $WriteScheduleCSV);
		};
	};

	if (defined $traceclass{'TVDIREKT'} && ($traceclass{'TVDIREKT'} & 0x10)) {
		print "#### TVDIREKT/timers CALENDAR/CSV NATIVE RESPONSE BEGIN ####\n";
		print $csv_raw;
		print "#### TVDIREKT/timers CALENDAR/CSV NATIVE RESPONSE END   ####\n";
	};

	if ($csv_raw !~ /"Betreff","Beginnt am","Beginnt um","Endet am","Endet um","Beschreibung","Kategorien"/o) {
		logging ("ALERT", "TVDIREKT: CALENDAR/CSV of timer has not supported header please check for latest version and contact asap script development");
		return(1);
	};


	####################################
	## CALENDAR/CSV timer (aka 'TV-Planer') analysis
	####################################

	logging("DEBUG", "TVDIREKT: start CALENDAR/CSV timer analysis");

	# Run through entries of CALENDAR/CSV contents of 'TV-Planer'
	my $csv = Text::CSV->new ({ binary => 1, auto_diag => 1, always_quote => 1, quote_space => 0 });

	foreach my $line (split("\r", $csv_raw)) {
		$line =~ s/\n/|/g; # replace newline by |
		$line =~ s/^\|//g; # remove trailing |

		# print "LINE: " . $line . "\n";

		next if (length($line) == 0);

		if (defined $traceclass{'TVDIREKT'} && ($traceclass{'TVDIREKT'} & 0x20)) {
			print "####CALENDAR/CSV RAW LINE ENTRY BEGIN####\n";
			print $line . "\n";
			print "####CALENDAR/CSV RAW LINE ENTRY END####\n";
		};

		my $row = $csv->parse($line);

		my @fields = $csv->fields();

		if (defined $traceclass{'TVDIREKT'} && ($traceclass{'TVDIREKT'} & 0x40)) {
			print "####CALENDAR/CSV PARSED ENTRY BEGIN####\n";
			print Dumper(@fields);
			print "####CALENDAR/CSV PARSED ENTRY END####\n";
		};


		if ($fields[0] eq "Betreff") {
			logging("DEBUG", "TVDIREKT: SKIP CSV header: $line");
			next;
		};

		my $csv_starttime = reformat_date_time($fields[1], $fields[2]);
		my $csv_endtime   = reformat_date_time($fields[3], $fields[4]);

		my $csv_channel;
		my $csv_title;

		# split channel/title
		if ($fields[0] =~ /^([^:]+): (.*)$/o) {
			$csv_channel   = $1;
			$csv_title     = $2;
		} else {
			logging("DEBUG", "TVDIREKT: SKIP not-parsable CSV row: " . $fields[0]);
			next;
		};

		my $start_ut = str2time($csv_starttime);
		my $stop_ut  = str2time($csv_endtime  );

		# round-down minute based (in case CSV contains seconds != 00)
		$start_ut = int($start_ut / 60) * 60;
		$stop_ut  = int($stop_ut  / 60) * 60;

		# generate cid and fill hashes
		my $cid = unpack('l', pack('L', hex(substr(md5_hex($csv_channel), 0, 7))));
		$tvdirekt_channel_name_by_id{$cid} = $csv_channel;
		$tvdirekt_channel_id_by_name{$csv_channel} = $cid;

		# generate tid
		my $tid = substr(md5_hex($csv_starttime . $csv_endtime . $csv_channel), 0, 16);

		if ($csv_title =~ /^([^\r]+)[\r]/o) {
			$csv_title = $1;
			logging("DEBUG", "TVDIREKT: '\\r' char found in title, reduce to: '" . $csv_title . "'");
		};

		if ($csv_title =~ / +$/o) {
			$csv_title =~ s/ +$//o;
			logging("DEBUG", "TVDIREKT: trailing spaces found in title, reduce to: '" . $csv_title . "'");
		};

		push @$timers_ap, {
			'tid'          => $tid,
			'start_ut'     => $start_ut,
			'stop_ut'      => $stop_ut,
			'cid'          => $tvdirekt_channel_id_by_name{$csv_channel},
			'title'        => $csv_title,
			'genre'        => $fields[6],
			'service_data' => "tvdirekt:" . $config{'service.user'}
		};

		logging("DEBUG", "TVDIREKT: found timer:"
			. " tid="      . $tid
			. " start="    . $csv_starttime . " (" . strftime("%Y%m%d-%H%M", localtime($start_ut)) . ")"
			. " end="      . $csv_endtime   . " (" . strftime("%Y%m%d-%H%M", localtime($stop_ut)) . ")"
			. " channel='" . $csv_channel . "' (" . $tvdirekt_channel_id_by_name{$csv_channel} . ")"
			. " title='"   . $csv_title . "'"
                        . " s_d="      . "tvdirekt:" . $config{'service.user'}
		);

	};

	logging("DEBUG", "TVDIREKT: finish CALENDAR/CSV timer analysis");

	$timers_tvdirekt_valid = 1; # mark successful retrieve

	return(0);
};


#### END
return 1;
