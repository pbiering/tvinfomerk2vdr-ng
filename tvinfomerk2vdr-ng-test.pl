#!/usr/bin/perl -w
#
# Original (C) & (P) 2003 - 2007 by <macfly> / Friedhelm Büscher as "tvmovie2vdr"
#   last public release: http://rsync16.de.gentoo.org/files/tvmovie2vdr/tvmovie2vdr-0.5.13.tar.gz
#
# Major Refactoring (P) & (C) 2013-2014 by Peter Bieringer <pb@bieringer.de> as "tvinfomerk2vdr-ng"
#   for "tvinfo" only other code is removed
#
# License: GPLv2
#
# Authors:
#  Peter Bieringer (pb)
#  <macfly> / Friedhelm Büscher
#
# Changelog:
# 20130116/pb: initial release
# 20130128/pb: replace inflexible channels.pl handling by automatic channel mapping
# 20130203/pb: optional logging to syslog instead of stderr (-L), optional summary to stdout in case of action or log entry >= warn
# 20130207/pb: skip running/expired HTML entries, store XML entry also if no HTML entry was found (looks like TVinfo HTML can be buggy), e.g.
#                 XML:  start=2013-02-11 05:30:00 +0100  end=2013-02-11 06:00:00 +0100  channel=3sat title='Der Hochzeits-Profi
#                 HTML: day=10 month=02 start=05:30 end=06:00 channel=3sat title='Der Hochzeits-Profi' (BUGGY)
# 20130208/pb: use networktimeout from config-ng.pl
# 20130213/pb: TEMP fix: skip fetch of HTML Merkzettel, don't correlate
# 20130228/pb: convert recode already existing timers to match umlauts
# 20130707/pb: in case of multi-line titles use only first line
# 20130816/pb: don't proceed if Merkzettel is completly emtpy to avoid removing existing all TVinfo based VDR timers (seen on broken TVinfo interface, returning unexpectly empty list)
# 20130824/pb: remove EOL and unsupported HTML Merkzettel support
# 20130825/pb: add support for CA whitelist and fix broken CA channel config switch
# 20140102/pb: replace invalid loglevel FATAL with ALERT
# 20140115/pb: fix changed login URI on www.tvinfo.de
# 20140709/pb: fix broken handling in case of multiple users select same timer in folder mode
# 20140802/pb: use new Station XML URL instead of HTML "Meine Sender"
# 20140804/pb: add support for MD5 hashed password

use strict; 
use warnings; 
use utf8;
binmode(STDOUT, ":utf8");
binmode(STDERR, ":utf8");

my $progname = "tvinfomerk2vdr-ng";
my $progversion = "0.1.0";

## Requirements:
# Ubuntu: libxml-simple-perl libdate-calc-perl
# Fedora: perl-XML-Simple

## Extensions (in difference to original version):
# - Multi-tvinfo account capable
# - Only required timer changes are executed (no longer unconditional remove/add)
# - Optional definition of a folder for storing records (also covering multi-account capability)
# - VDR timer cache
# - sophisticated automagic TVinfo->VDR channel mapping
# - XML 'Merkliste' is now the only supported input (simplifies date/time handling)
# - use strict/warnings for improving code quality
# - debugging/tracing/logging major improvement

## Removed features
# - HTML 'Merkliste' is no longer the master
# - manual channel mapping
# - support of 'tviwantgenrefolder' and 'tviwantseriesfolder' removed (for easier Multi-Account/Folder capability)

## Testcases
# same timer configured in more than one account
# timer between 4:00-4:59 and 5:00-5:59 to check proper day wrapping

## TODO
# - check whether "Wintertimer->Summertime" and "Summertime->Wintertime" are proper catched
# - reintroduce support of 'tviwantgenrefolder' and 'tviwantseriesfolder' (must be stored also in summary somehow to be able to recreate title)
# - store original title also in summary (should help on some title matching problems)
# - add option for custom channel map (in predecence of automatic channelmap)
#     dedicated txt file with tvinfoname=VDRNAME|RFC-ID

## Setup
#
# Check station configuration (Meine Sender) match
#  ./tvinfomerk2vdr-ng-wrapper.sh -c -N -u USER (reported delta should be 0, otherwise the match alogrithm has an issue or too few or many stations are marked in TVinfo portal while not existing in VDR

## Test
#
# - check for non-empty 'Merkzettel'
# - run script in dry-run mode
#    ./tvinfomerk2vdr-ng-wrapper.sh -N -u USER

## Workflow
# - read channel list via SVDRP
# - read XML 'Sender'
# - perform a VDR to TVinfo station/channel alignment
# - read XML 'Merkliste'
# - retrive existing VDR timers created by tvinfo
# - run through candidate timers and check for match in existing VDR timers
#    in case of existing but not in Merkliste of given user, add related user/folder info and adjust folder
# - run through existing VDR timers, check against candidate status
#    mark "to-update" ones for deletion (and re-add) in case one of the user has deleted the entry in tvinfo while other still have included
#    mark no longer existing ones for deletion
# - delete marked existing timers
# - add list of new timers

###############################################################################
#
# Initialisierung
#
my $file_config = "config-ng.pl";

push (@INC, "./");
require ($file_config);

push (@INC, "./inc");
require ("helperfunc-ng.pl");
require ("channelmap-ng.pl");

use LWP;
use Date::Manip;
use Date::Calc qw(Add_Delta_Days);
&Date_Init("Language=German","DateFormat=non-US");

use Getopt::Std;
use IO::Socket;
use Digest::MD5 qw(md5_hex);
use XML::Simple;
use Data::Dumper;
use Storable;
use HTTP::Request::Common;
use Encode;
use Sys::Syslog;

our ($SOCKET,$SVDRP); 
our $please_exit = 0;
my $useragent = LWP::UserAgent->new;

my $today = UnixDate("heute", "%s");
my $MarginStart;
my $MarginStop;

my $request;
my $resonse;
my $url;

my $debug = 0;

my $foldername_max = 15;

my $http_timeout = 15;

my %debug_class = (
	"XML"         => 0,
	"CORR"        => 0,
	"VDR-CH"      => 0,
	"MATCH"       => 0,
	"VDR"         => 0,
	"Channelmap"  => 0,
	"MeineSender" => 0,
	"AlleSender"  => 0,
);

$SIG{'INT'}  = \&SIGhandler;

# getopt
our ($opt_R, $opt_W, $opt_X, $opt_h, $opt_v, $opt_N, $opt_s, $opt_d, $opt_p, $opt_D, $opt_U, $opt_P, $opt_F, $opt_T, $opt_C, $opt_c, $opt_L, $opt_S);

## config-ng.pl
our $http_proxy;
our $username;
our $password;
our $tvinfoprefix;
our $http_base;
our ($prio, $lifetime);
our $setupfile;
our $networktimeout;
our $skip_ca_channels;
our $whitelist_ca_groups;

# defaults
if (! defined $skip_ca_channels) { $skip_ca_channels = 1 };
if (! defined $whitelist_ca_groups) { $whitelist_ca_groups = "" };

# Cache for VDR timers
my %timers_cache;

# TVinfo Channel Name <-> ID
my %tvinfo_channel_name_by_id;
my %tvinfo_channel_id_by_name;

# TVinfo 'Meine Sender' ID List
my %tvinfo_MeineSender_id_list;

# TVinfo 'Alle Sender' ID List
my %tvinfo_AlleSender_id_list;

# Defaults for web access
$useragent->agent("Mozilla/4.0 ($progname $progversion)");
$useragent->timeout($networktimeout);

$useragent->proxy('http', $http_proxy);

## channelmap-ng.pl
our %match_methods;

###############################################################################
## Functions
###############################################################################

## Logging
my $syslog_status = 0;
my @logging_summary;
my $logging_highestlevel = 7;

my %loglevels = (
	"EMRG"     => 0,
	"ALERT"    => 1,
	"CRIT"     => 2,
	"ERR"      => 3,
	"ERROR"    => 3,
	"WARN"     => 4,
	"WARNING"  => 4,
	"NOTICE"   => 5,
	"INFO"     => 6,
	"DEBUG"    => 7,
	"TRACE"    => 7,
);


sub logging($$) {
	return if ($_[0] eq "DEBUG" && $debug == 0);
	return if ($_[0] eq "TRACE" && ! defined $opt_T);

	my $level = $_[0];
	my $message = $_[1];

	my $loglevel;

	if (! defined $loglevels{$level}) {
		# loglevel not supported
		$loglevel = 4;
	} else {
		$loglevel = $loglevels{$level};
	};

	if (($debug != 0) && ($level =~ /^(DEBUG|TRACE)$/o)) {
		# check for debug class
		for my $key (keys %debug_class) {
			if ($_[1] =~ /^$key/ && ($debug_class{$key} == 0)) {
				return;
			};
		};
	};

	if ((defined $opt_S) && ($level !~ /^(DEBUG|TRACE)$/o)) {
		push @logging_summary, $message;

		if ($loglevel < $logging_highestlevel) {
			# remember highest level
			$logging_highestlevel = $loglevel;
		};
	};

	if (defined $opt_L) {
		# use syslog
		if ($syslog_status != 1) {
			openlog($progname, undef, "LOG_USER");
			$syslog_status = 1;
		};

		# map log level
		if ($level eq "TRACE") {
			$level = "DEBUG";
		};
		if ($level eq "WARN") {
			$level = "WARNING";
		};
		if ($level eq "ERROR") {
			$level = "ERR";
		};

		if (defined $username) {
			$message = $username . ": " . $message;
		};	

		syslog($level, '%s', $message);
	} else {
		printf STDERR "%-6s: %s\n", $level, $message;
	};
};


## Create a combined folder name from list of folders
# if any of the given folder = ".", then the result is also "."
# if array is empty, also return "."
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
			$result = ".";
			last;
		};
		$result .= substr($folder, 0, $length_entry);
	};
	
	return ($result);
};

## replace tokens in request
sub request_replace_tokens($) {
	my $request = shift || return 1;

	logging("DEBUG", "request  original: " . $request);
	logging("DEBUG", "username         : " . $username);
	logging("DEBUG", "password         : " . $password);

	# replace username token
	my $passwordhash;
	if ($password =~ /^{MD5}(.*)/) {
		$passwordhash = $1;
	} else {
		$passwordhash = md5_hex($password);
	};

	$request =~ s/<USERNAME>/$username/;
	$request =~ s/<PASSWORDHASH>/$passwordhash/;

	logging("DEBUG", "request result   : " . $request);
	return($request)
};


###############################################################################
#
# Main
#
my $debug_class_string = join(" ", keys %debug_class);

my $Usage = qq{
Usage: $0 [options]

Options: -d <hostname>             VDR hostname (default: localhost)
         -p <port>                 SVDRP port number (default: 2001)
         -U <username>             TVinfo username (default: $username [config-ng.pl])
         -P <password>             TVinfo password (default: $password [config-ng.pl])
         -F <folder>               folder for VDR records (default: none)
         -c                        show Channel Map results (and stop)
         -L                        use syslog instead of stderr
         -S                        show summary to stdout in case of any changes or log messages > notice
         -h	                   Show this help text

Debug options:
         -v                        Show verbose messages
         -s	                   Simulation Mode (no SVDRP communication)
         -D	                   Debug Mode
         -T	                   Trace Mode
         -C class[,...]            Debug Classes: $debug_class_string
         -X	                   XML Debug Mode
         -N	                   No SVDRP change action (do not delete/add timers)
         -W <prefix>               Write XML raw responses to   files (suffices will be added automatically)
         -R <prefix>               Read  XML raw responses from files (suffices will be added automatically)
};

my $sim = 0;
my $get = 0;
my $verbose = 0;

die $Usage if (!getopts('W:R:d:p:U:P:F:hLvscDXNSTC:') || $opt_h);

$verbose = 1 if $opt_v;
$sim = 1 if $opt_s;
my $svdrp_ro = 0; $svdrp_ro = 1 if defined $opt_N;

$debug = 1 if $opt_D;
my $debug_xml = 0; $debug_xml = 1 if $opt_X;
my $Dest = $opt_d  || "localhost";
my $Port = $opt_p  || 2001;
my $WriteFileBase = $opt_W;
my $ReadFileBase = $opt_R;
my $folder = ""; $folder = $opt_F if $opt_F;

$username = $opt_U if $opt_U;
$password = $opt_P if $opt_P;

if (! defined $username || $username eq "<TODO>") {
	logging("ERROR", "TVinfo username not defined (use -U or specify in " . $file_config . ")");
	exit 1;
};

if (! defined $password || $password eq "<TODO>") {
	logging("ERROR", "TVinfo password not defined (use -P or specify in " . $file_config . ")");
	exit 1;
};

if ($password !~ /^{MD5}/) {
	logging("WARN", "TVinfo password is not given as hash (conversion recommended for security reasons)");
};


# Debug Class handling
if (defined $opt_C) {
	foreach my $entry (split ",", $opt_C) {
		if (defined $debug_class{$entry}) {
			$debug_class{$entry} = 1;
		} else {
			logging("ERROR", "Unsupported debug class: " . $entry);
			exit 1;
		};
	};
};

my ($WriteScheduleXML, $ReadScheduleXML, $WriteStationsXML, $ReadStationsXML, $WriteChannelsSvdrp, $WriteSetupConf, $ReadChannelsSvdrp, $ReadSetupConf);

if (defined $WriteFileBase) {
	$WriteScheduleXML         = $WriteFileBase . "-schedule.xml";
	$WriteStationsXML         = $WriteFileBase . "-stations.xml";
	$WriteChannelsSvdrp       = $WriteFileBase . "-channels.svdrp";
	$WriteSetupConf           = $WriteFileBase . "-setup.conf";
};

if (defined $ReadFileBase) {
	logging("DEBUG", "ReadFileBase=" . $ReadFileBase);
	$ReadScheduleXML          = $ReadFileBase  . "-schedule.xml";
	$ReadStationsXML          = $ReadFileBase  . "-stations.xml";
	$ReadChannelsSvdrp        = $ReadFileBase  . "-channels.svdrp";
	$ReadSetupConf            = $ReadFileBase  . "-setup.conf";
};

my @xml_list;
my $xml_raw;
my $data;
my $xml;

### read margins from VDR setup.conf
## Missing VDR feature: read such values via SVDRP

my @setup_conf_lines;

if (defined $ReadSetupConf) {
	$setupfile = $ReadSetupConf;
};

logging("DEBUG", "Try to read margins from VDR setup.conf file: " . $setupfile);

if(open(FILE, "<$setupfile")) {
	while(<FILE>) {
		push @setup_conf_lines, $_;

		chomp $_;

		logging("TRACE", "VDR setup.conf line: " . $_);

		next if ($_ !~ /^Margin(Start|Stop)\s*=\s*([0-9]+)$/o);
		if ($1 eq "Start") {
			$MarginStart = $2 * 60;
			logging("DEBUG", "VDR setup.conf provide MarginStart: " . $MarginStart);
		} elsif ($1 eq "Stop") {
			$MarginStop = $2 * 60;
			logging("DEBUG", "VDR setup.conf provide MarginStop : " . $MarginStop);
		};
	};
	close(FILE);

	if (defined $WriteSetupConf) {
		logging("NOTICE", "write setup.conf contents to file: " . $WriteSetupConf);
		open(FILE, ">$WriteSetupConf") || die;
		print FILE @setup_conf_lines;
		close(FILE);
		logging("NOTICE", "setup.conf contents to file written: " . $WriteSetupConf);
	};
} else {
	logging("ERROR", "Can't read VDR setup.conf file: " . $setupfile);
	exit 1;
};

if (! defined $MarginStart) {
	logging("NOTICE", "can't retrieve MarginStart from VDR setup.conf file, take default");
	$MarginStart = 10 * 60;
};
if (! defined $MarginStop) {
	logging("ERROR", "can't retrieve MarginStop from VDR setup.conf file, take default");
	$MarginStop = 10 * 60;
};



### cleanup log files
our $cleanupoldfiles;

if ($cleanupoldfiles) {
	logging("DEBUG", "Cleanup old files");
	cleanup();
}


#############################################################
## VDR: retrieve channels via SVDRP
#############################################################

my @channels;

if (defined $ReadChannelsSvdrp) {
	if (! -e $ReadChannelsSvdrp) {
		logging("ERROR", "file for VDR channels is missing (forget -W before?): " . $ReadChannelsSvdrp);
		exit(1);
	};
	# load VDR channnels from file
	logging("INFO", "Read VDR channels from file: " . $ReadChannelsSvdrp);
	my $channel_p = retrieve($ReadChannelsSvdrp);
	for my $entry (@$channel_p) {
		push @channels, $entry;
	};
	logging("INFO", "VDR channels read from file (skip fetch from VDR): " . $ReadChannelsSvdrp . " (entries:" . $#channels . ")");
} else {
	logging("DEBUG", "VDR: try to read channels via SVDRP from host (simulation=$sim): $Dest:$Port");

	$SVDRP = SVDRP->new($Dest,$Port,$verbose,$sim);
	@channels = getchan();
	if (scalar(@channels) == 0) {
		logging("ERROR", "VDR: no channels received via SVDRP");
		exit 1;
	} else {
		logging("DEBUG", "VDR: amount of channels received via SVDRP: " . scalar(@channels));
	};

	$SVDRP->close;

	if (defined $WriteChannelsSvdrp) {
		logging("NOTICE", "write channels from SVDRP to file: " . $WriteChannelsSvdrp);
		store \@channels,  $WriteChannelsSvdrp;
		logging("NOTICE", "channels from SVDRP contents to file written: " . $WriteChannelsSvdrp);
	};
};


#######################################
## XML 'Sender' handling (stations)
#######################################

undef @xml_list;
undef $xml_raw;

if (defined $ReadStationsXML) {
	if (! -e $ReadStationsXML) {
		logging("ERROR", "XML file for 'Sender' is missing (forget -W before?): " . $ReadStationsXML);
		exit(1);
	};
	# load 'Sender' (stations) from file
	logging("INFO", "Read XML contents 'Sender' from file: " . $ReadStationsXML);
	if(!open(FILE, "<$ReadStationsXML")) {
		logging("ERROR", "can't read XML contents 'Sender' from file: " . $ReadStationsXML);
		exit(1);
	};
	binmode(FILE);
	while(<FILE>) {
		$xml_raw .= $_;
	};
	close(FILE);
	logging("INFO", "XML contents 'Sender' read from file (skip fetch from Internet): " . $ReadStationsXML);
} else {
	# Fetch 'Sender' via XML interface
	logging ("INFO", "Fetch 'Sender' via XML interface");

	my $request = request_replace_tokens("http://www.tvinfo.de/external/openCal/stations.php?username=<USERNAME>&password=<PASSWORDHASH>");

	logging("DEBUG", "start request: " . $request);

	my $response = $useragent->request(GET "$request");
	if (! $response->is_success) {
		logging("ERROR", "Can't fetch 'XML Merkzettel'  from tvinfo: " . $response->status_line);
		exit 1;
	};

	$xml_raw = $response->content;

	if (defined $WriteStationsXML) {
		logging("NOTICE", "write XML contents 'Sender' to file: " . $WriteStationsXML);
		open(FILE, ">$WriteStationsXML") || die;
		print FILE $xml_raw;
		close(FILE);
		logging("NOTICE", "XML contents 'Sender' to file written: " . $WriteStationsXML);
	};

	if ($xml_raw =~ /encoding="UTF-8"/) {
		logging ("DEBUG", "XML 'Sender' UTF-8 conversion");
		$xml_raw = encode("utf-8", $xml_raw);
	};
};

if ($opt_X) {
	print "#### XML NATIVE RESPONSE BEGIN ####\n";
	print $xml_raw;
	print "#### XML NATIVE RESPONSE END   ####\n";
};

# Parse XML content
$xml = new XML::Simple;

$data = $xml->XMLin($xml_raw);

if ($opt_X) {
	print "#### XML PARSED RESPONSE BEGIN ####\n";
	print Dumper($data);
	print "#### XML PARSED RESPONSE END   ####\n";
};

# Version currently missing
#if ($$data{'version'} ne "1.0") {
#	logging ("ALERT", "XML 'Sender' has not supported version: " . $$data{'version'} . " please check for latest version and contact asap script development");
#	exit 1;
#};

if ($xml_raw !~ /stations/) {
	logging ("ERROR", "XML 'Sender' empty or username/passwort not proper, can't proceed");
	exit 1;
} else {
	my $xml_list_p = @$data{'station'};

	logging ("INFO", "XML 'Sender' has entries: " . scalar(keys %$xml_list_p));
};

my $xml_root_p = @$data{'station'};

foreach my $name (sort keys %$xml_root_p) {
	my $id = $$xml_root_p{$name}->{'id'};

	my $altnames_p = $$xml_root_p{$name}->{'altnames'}->{'altname'};

	my $altnames;

	if (ref($altnames_p) eq "ARRAY") {
		$altnames = join("|", @$altnames_p);
	} else {
		$altnames = $altnames_p;
	};

	$tvinfo_AlleSender_id_list{$id}->{'name'} = $name;
	$tvinfo_AlleSender_id_list{$id}->{'altnames'} = $altnames;

	my $selected = 0;
	if (defined $$xml_root_p{$name}->{'selected'} && $$xml_root_p{$name}->{'selected'} eq "selected") {
		$selected = 1;
		$tvinfo_MeineSender_id_list{$id}->{'name'} = $name;
		$tvinfo_MeineSender_id_list{$id}->{'altnames'} = $altnames;
	};

	logging("DEBUG", "XML Sender: " . sprintf("%4d: %s (%s) %d", $id, $name, $altnames, $selected));

	$tvinfo_channel_name_by_id{$id} = $name;
	$tvinfo_channel_id_by_name{$name} = $id;
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
	logging("DEBUG", "XML MeineSender List: " . sprintf("%4d: %4d %s", $c, $id, $name));
};


###############################
## Channel Check 'Meine Sender'
###############################

my %flags_channelmap;
my $rc;

# call external (universal) function channel check for channel mapping
%flags_channelmap = (
	'skip_ca_channels'     => $skip_ca_channels,
	'force_hd_channels'    => 1,
	'source_precedence'    => "CST",
	'quiet'                => 0,
	'whitelist_ca_groups'  => $whitelist_ca_groups,
);

$rc = channelmap("tvinfo", \@channels, \%tvinfo_MeineSender_id_list, \%flags_channelmap);

logging("INFO", "MeineSender: VDR Channel mapping result (TVinfo-Name -> VDR-ID VDR-Name") if (defined $opt_c);

foreach my $id (sort { lc($tvinfo_MeineSender_id_list{$a}->{'name'}) cmp lc($tvinfo_MeineSender_id_list{$b}->{'name'}) } keys %tvinfo_MeineSender_id_list) {
	my $vdr_id   = $tvinfo_MeineSender_id_list{$id}->{'vdr_id'};
	my $name     = $tvinfo_MeineSender_id_list{$id}->{'name'};
	my $match_method = $tvinfo_MeineSender_id_list{$id}->{'match_method'};

	if (! defined $vdr_id || $vdr_id == 0) {
		logging("WARN", "MeineSender: no VDR Channel found: " . sprintf("%-20s", $name));
		next;
	};

	my ($vdr_name, $vdr_bouquet) = split /;/, encode("iso-8859-1", decode("utf8", ${$channels[$vdr_id - 1]}{'name'}));
	$vdr_name =~ s/,.*$//o; # remove additional name

	my $loglevel = "DEBUG";
	$loglevel = "INFO" if (defined $opt_c);

	logging($loglevel, "MeineSender: VDR Channel mapping : " . sprintf("%-20s => %4d  %-20s", $name, $vdr_id, $vdr_name));
};

my $MeineSender_count = scalar(keys %tvinfo_MeineSender_id_list);
logging("INFO", "MeineSender amount (summary): " . $MeineSender_count);


##############################
## Channel Check 'Alle Sender'
##############################

# call external (universal) function channel check for channel mapping
%flags_channelmap = (
	'skip_ca_channels'     => $skip_ca_channels,
	'force_hd_channels'    => 0,
	'source_precedence'    => "CST",
	'quiet'                => 1,
	'whitelist_ca_groups'  => $whitelist_ca_groups,
);

if (defined $opt_c) {
	$flags_channelmap{'skip_ca_channels'} = 0;
	$flags_channelmap{'whitelist_ca_groups'} = "*";
};

$rc = channelmap("tvinfo", \@channels, \%tvinfo_AlleSender_id_list, \%flags_channelmap);

my $format_string = "%-25s %3s %3s %2s %2s %2s %-30s %-15s";

my $loglevel = "DEBUG";
$loglevel = "INFO" if (defined $opt_c);

logging("INFO", "AlleSender: VDR Channel mapping result: TID:TVinfo-ID VID:VDR-ID MM:MatchMethod MS:MeineSender") if (defined $opt_c);
logging("INFO", "AlleSender: VDR Channel mapping: " . sprintf($format_string, "TVinfo-Name", "TID", "VID", "MM", "CA", "MS", "VDR-Name", "VDR-Bouquet")) if (defined $opt_c);
logging("INFO", "AlleSender: VDR Channel mapping: " . "-" x 90) if (defined $opt_c);

my $AlleSender_count = 0;
my $AlleSender_count_nomatch = 0;
my %match_method_stats;

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

	my $checked = ""; my $ca = ""; my $match_method;

	if (defined $tvinfo_AlleSender_id_list{$id}->{'match_method'}) {
		$match_method = $tvinfo_AlleSender_id_list{$id}->{'match_method'};
		$match_method_stats{$match_method}++;
	};

	if (defined $tvinfo_MeineSender_id_list{$id}->{'vdr_id'}) {
		$checked = "*";
	};

	$ca = "CA" if (${$channels[$vdr_id - 1]}{'ca'} ne "0");

	logging($loglevel, "AlleSender: VDR Channel mapping: " . sprintf($format_string, $name, $id, $vdr_id, $match_method, $ca,  $checked, $vdr_name, $vdr_bouquet));
};

# print statistics
for my $key (sort keys %match_method_stats) {
	logging("DEBUG", "AlleSender: VDR Channel mapping match statistics: " . sprintf("%-20s (%s): %3s", $match_methods{$key}, $key, $match_method_stats{$key}));
};

logging("INFO", "AlleSender: VDR Channel mapping: " . "=" x 90) if (defined $opt_c);
logging("INFO", "AlleSender: VDR Channel mapping missing (either deselect in TVinfo 'Meine Sender' or rescan VDR channels or improve channel matcher code)") if (defined $opt_c);

foreach my $id (sort { lc($tvinfo_AlleSender_id_list{$a}->{'name'}) cmp lc($tvinfo_AlleSender_id_list{$b}->{'name'}) } keys %tvinfo_AlleSender_id_list) {
	my $vdr_id = $tvinfo_AlleSender_id_list{$id}->{'vdr_id'};

	if (defined $vdr_id) {
		next;
	};

	my $name = $tvinfo_AlleSender_id_list{$id}->{'name'};

	logging($loglevel, "AlleSender: VDR Channel mapping missing TVinfo->VDR: " . sprintf("%-20s", $name));
};

logging("INFO", "AlleSender: VDR Channel mapping: " . "=" x 90) if (defined $opt_c);
logging("INFO", "AlleSender: VDR Channels without mapping to TVinfo (candidates for improvemente channel matcher code)") if (defined $opt_c);

foreach my $channel_hp (@channels) {
	my $vdr_id = $$channel_hp{'vdr_id'};

	foreach my $id (keys %tvinfo_AlleSender_id_list) {
		if (defined $tvinfo_AlleSender_id_list{$id}->{'vdr_id'} && $vdr_id == $tvinfo_AlleSender_id_list{$id}->{'vdr_id'}) {
			next;
		};
	};

	my $name = $$channel_hp{'name'};

	logging($loglevel, "AlleSender: VDR Channel mapping missing VDR->TVinfo: " . sprintf("%-20s", $name));
};

logging("INFO", "AlleSender: VDR Channel mapping: " . "=" x 90) if (defined $opt_c);

logging("INFO", "AlleSender: VDR Channel mapping cross-check summary: " . $AlleSender_count . " (delta=" . ($AlleSender_count - $MeineSender_count) . " [should be 0] nomatch=" . $AlleSender_count_nomatch ." [stations without matching VDR channels])");

if (defined $opt_c) {
	logging("NOTICE", "End of Channel Map results (stop here on request)");
	exit 0;
};


#######################################
## XML 'Merkzettel' handling (schedule)
#######################################

undef @xml_list;
undef $xml_raw;

if (defined $ReadScheduleXML) {
	if (! -e $ReadScheduleXML) {
		logging("ERROR", "XML file for 'Merkzettel' is missing (forget -W before?): " . $ReadScheduleXML);
		exit(1);
	};
	# load 'Merkliste' from file
	logging("INFO", "Read XML contents 'Merkliste' from file: " . $ReadScheduleXML);
	if(!open(FILE, "<$ReadScheduleXML")) {
		logging("ERROR", "can't read XML contents 'Merkliste' from file: " . $ReadScheduleXML);
		exit(1);
	};
	binmode(FILE);
	while(<FILE>) {
		$xml_raw .= $_;
	};
	close(FILE);
	logging("INFO", "XML contents 'Merkzettel' read from file (skip fetch from Internet): " . $ReadScheduleXML);
} else {
	# Fetch 'Merkliste' via XML interface
	logging ("INFO", "Fetch 'Merkzettel' via XML interface");

	my $request = request_replace_tokens("http://www.tvinfo.de/share/openepg/schedule.php?username=<USERNAME>&password=<PASSWORDHASH>");

	logging("DEBUG", "start request: " . $request);

	my $response = $useragent->request(GET "$request");
	if (! $response->is_success) {
		logging("ERROR", "Can't fetch 'XML Merkzettel'  from tvinfo: " . $response->status_line);
		exit 1;
	};

	$xml_raw = $response->content;

	if (defined $WriteScheduleXML) {
		logging("NOTICE", "write XML contents 'Merkliste' to file: " . $WriteScheduleXML);
		open(FILE, ">$WriteScheduleXML") || die;
		print FILE $xml_raw;
		close(FILE);
		logging("NOTICE", "XML contents 'Merkliste' to file written: " . $WriteScheduleXML);
		# note: continue to write also HTML file later
	};
};


if ($opt_X) {
	print "#### XML NATIVE RESPONSE BEGIN ####\n";
	print $xml_raw;
	print "#### XML NATIVE RESPONSE END   ####\n";
};

# Replace encoding from -15 to -1, otherwise XML parser stops
$xml_raw =~ s/(encoding="ISO-8859)-15(")/$1-1$2/;

# Parse XML content
$xml = new XML::Simple;
$data = $xml->XMLin($xml_raw);

if ($opt_X) {
	print "#### XML PARSED RESPONSE BEGIN ####\n";
	print Dumper($data);
	print "#### XML PARSED RESPONSE END   ####\n";
};

if ($$data{'version'} ne "1.0") {
	logging ("ALERT", "XML 'Merkliste' has not supported version: " . $$data{'version'} . " please check for latest version and contact asap script development");
	exit 1;
};

if ($xml_raw !~ /epg_schedule_entry/) {
	logging ("ERROR", "XML 'Merkliste' empty or username/passwort not proper, can't proceed");
	exit 1;
} else {
	my $xml_list_p = @$data{'epg_schedule_entry'};

	if (ref($xml_list_p) eq "HASH") {
		logging ("INFO", "XML 'Merkliste' has only 1 entry");
		push @xml_list, $xml_list_p;
	} else {
		logging ("INFO", "XML 'Merkliste' has entries: " . scalar(@$xml_list_p));

		# copy entries
		foreach my $xml_entry_p (@$xml_list_p) {
			push @xml_list, $xml_entry_p;
		};
	};
};


####################################
## XML 'Merkzettel' analysis
####################################

logging("DEBUG", "Start XML 'Merkzettel' analysis");

# Run through entries of XML contents of 'Merkliste'

my %xml_valid_map;
my $xml_entry = -1;

foreach my $xml_entry_p (@xml_list) {
	$xml_entry++;

	if ($opt_X) {
		print "####XML PARSED ENTRY BEGIN####\n";
		print Dumper($xml_entry_p);
		print "####XML PARSED ENTRY END####\n";
	};
	# logging ("DEBUG", "entry uid: " . $$entry_p{'uid'});

	my $xml_starttime = $$xml_entry_p{'starttime'};
	my $xml_endtime   = $$xml_entry_p{'endtime'};
	my $xml_title     = $$xml_entry_p{'title'};
	my $xml_channel   = $$xml_entry_p{'channel'};

	my $xml_startime_epoch = UnixDate(ParseDate($xml_starttime), "%s");
	my $xml_endtime_epoch  = UnixDate(ParseDate($xml_endtime  ), "%s");

	$xml_starttime =~ /^([0-9]{4})-([0-9]{2})-([0-9]{2}) ([012][0-9]:[0-5][0-9]):[0-5][0-9] /;
	my $xml_starttime_year    = $1;
	my $xml_starttime_month   = $2;
	my $xml_starttime_day     = $3;
	my $xml_starttime_hourmin = $4;

	$xml_endtime =~ /^([0-9]{4})-([0-9]{2})-([0-9]{2}) ([012][0-9]:[0-5][0-9]):[0-5][0-9] /;
	my $xml_endtime_hourmin = $4;

	if ($xml_startime_epoch < time) {
		logging("DEBUG", "XML: start is in the past (SKIP): xml_starttime=$xml_starttime channel=$xml_channel xml_title='$xml_title'");
		$xml_valid_map{$xml_entry} = -1;
		next;
	};

	if ($$xml_entry_p{'eventtype'} ne "rec") {
		logging("DEBUG", "XML SKIP (eventtype!=rec): start=$xml_starttime (day=$xml_starttime_day month=$xml_starttime_month hourmin=$xml_starttime_hourmin)  end=$xml_endtime (hourmin=$xml_endtime_hourmin)  channel=$xml_channel title='$xml_title'");
		$xml_valid_map{$xml_entry} = -2;
		next;
	};

	logging("TRACE", "XML: start=$xml_starttime (day=$xml_starttime_day month=$xml_starttime_month hourmin=$xml_starttime_hourmin) end=$xml_endtime (hourmin=$xml_endtime_hourmin) channel=$xml_channel title='$xml_title'");

	$xml_valid_map{$xml_entry} = 1;
};


if (defined $opt_W) {
	logging("NOTICE", "Stop here because option used: -W");
	exit 0;
};


#######################################################
### Create timer list of Merkliste based on XML entries
#######################################################

my @newtimers;

$xml_entry = -1;
foreach my $xml_entry_p (@xml_list) {
	$xml_entry++;

	if ($xml_valid_map{$xml_entry} != 1) {
		next;
	};

	logging("DEBUG", "XML: Analyse timer from XML entry #$xml_entry: start=$$xml_entry_p{'starttime'}  end=$$xml_entry_p{'endtime'}  channel=$$xml_entry_p{'channel'} title='$$xml_entry_p{'title'}'");

	my $xml_startime_epoch = UnixDate(ParseDate($$xml_entry_p{'starttime'}), "%s");
	my $xml_endtime_epoch  = UnixDate(ParseDate($$xml_entry_p{'endtime'}), "%s");

	# Apply margins	
	my $timer_starttime_epoch = $xml_startime_epoch - $MarginStart;
	my $timer_endtime_epoch   = $xml_endtime_epoch + $MarginStop;

	# Check for timer in the past
	if ($timer_starttime_epoch < time()) {
		# starttime already in the past
		if ($timer_endtime_epoch <time()) {
			logging("DEBUG", "XML: Start/end in the past (SKIP) entry #$xml_entry: start=$$xml_entry_p{'starttime'}  end=$$xml_entry_p{'endtime'}  channel=$$xml_entry_p{'channel'} title='$$xml_entry_p{'title'}'");

		} else {
			logging("DEBUG", "XML: Start in the past (SKIP) entry #$xml_entry: start=$$xml_entry_p{'starttime'}  end=$$xml_entry_p{'endtime'}  channel=$$xml_entry_p{'channel'} title='$$xml_entry_p{'title'}'");
		};
		next;
	};

	# Convert start/end to VDR notation
	my $timer_starttime = &ParseDateString("epoch $timer_starttime_epoch");
	my $timer_starttime_ymd = UnixDate($timer_starttime, "%Y-%m-%d");
	my $timer_starttime_hourmin = UnixDate($timer_starttime, "%H%M");

	my $timer_endtime = &ParseDateString("epoch $timer_endtime_epoch");
	my $timer_endtime_hourmin = UnixDate($timer_endtime, "%H%M");

	## Convert channel name to id
	my $channel_name = $$xml_entry_p{'channel'};

	my $channel_id = undef;

	if (defined $tvinfo_channel_id_by_name{$channel_name}) {
		my $id = $tvinfo_channel_id_by_name{$channel_name};
		if (defined $tvinfo_MeineSender_id_list{$id}->{'vdr_id'}) {
			$channel_id = $tvinfo_MeineSender_id_list{$id}->{'vdr_id'};
			logging("DEBUG", "XML: successful convert sender to channel using list retrieved via SVDRP and automatic channel map: $channel_name (" . ${$channels[$channel_id - 1]}{'name'} . ")");
		};
	};

	if (! defined $channel_id) {
		logging("ERROR", "XML: Can't convert sender to channel using list retrieved via SVDRP: $channel_name");
		next;
	};

	logging("DEBUG", "XML: Candidate timer from XML 'Merkliste' entry #$xml_entry: start=$timer_starttime_ymd $timer_starttime_hourmin ($$xml_entry_p{'starttime'})  end=$timer_endtime_hourmin ($$xml_entry_p{'endtime'})  channel=$$xml_entry_p{'channel'} channel_id=$channel_id title='$$xml_entry_p{'title'}'");
	
	# Create entry
	my $title    = $$xml_entry_p{'title'};
	$title =~ s/\r\n.*$//mgo; # skip everything after a potential new line

	my $subtitle = "";
	my $summary  = "";
	my $genre    = $$xml_entry_p{'nature'};

	my $tvinfo_folder = ".";
	$tvinfo_folder = $folder if (defined $folder && $folder ne "");

	push(@newtimers, {
		channel_id    => $channel_id,
		timer_day     => $timer_starttime_ymd,
		anfang        => $timer_starttime_hourmin,
		ende          => $timer_endtime_hourmin,
		genre         => $genre,
		title         => $title,
		summary       => $summary,
		subtitle      => $subtitle,
		tvinfo_user   => $username,
		tvinfo_folder => $tvinfo_folder
	});
};


#################################################################################
### Retrieve existing VDR timer list and check against list retrieved from tvinfo
#################################################################################
# timer num = 0 means skip
my @oldtimers_num     = (); # list of numbers of existing timer numbers matching tvinfo token
my %oldtimers_entries = (); # hash with timer pointers (key: number)
my %oldtimers_action  = (); # hash with timer actions
my @oldtimers_delete  = (); # list of number of existing timers which needs to be deleted

$SVDRP = SVDRP->new($Dest,$Port,$verbose,$sim);
logging("DEBUG", "Reading timers via SVDRP with flag '$tvinfoprefix' (simulation=$sim)");
@oldtimers_num = gettimers($tvinfoprefix, \%timers_cache);

if (scalar(@oldtimers_num) > 0) {
	logging("DEBUG", "VDR: following timers found matching tvinfo token (amount: " . scalar(@oldtimers_num) . ") : @oldtimers_num");
};

foreach my $oldtimer_num (@oldtimers_num) {
	my $timer_p = $timers_cache{$oldtimer_num};

	if ($$timer_p{'summary'} =~ /\(tvinfo-user=([^)]*)\)/o) {
		$$timer_p{'tvinfo_user'} = $1;
	};

	if ($$timer_p{'summary'} =~ /\(tvinfo-folder=([^)]*)\)/o) {
		$$timer_p{'tvinfo_folder'} = $1;
	};

	# recode title
	$$timer_p{'title'} = encode("iso-8859-1", decode("utf8", $$timer_p{'title'}));

	logging("DEBUG", "VDR: existing timer #$oldtimer_num: channel_id=" . $$timer_p{'channel_id'} . " timer_day=" . $$timer_p{'timer_day'} . " anfang=" . $$timer_p{'anfang'} . " ende=" . $$timer_p{'ende'} . " title='" . $$timer_p{'title'} . "'");
	$oldtimers_entries{$oldtimer_num} = $timer_p;
	$oldtimers_action{$oldtimer_num} = "unknown";
};

# check timers from tvinfo against existing VDR timers
my $flag_found = 0;
my $timerevent_entry = -1;
foreach my $timerevent (@newtimers) {
	$timerevent_entry++;

	my $timerevent_text = "channel_id=" . $$timerevent{'channel_id'} . " timer_day=" . $$timerevent{'timer_day'} . " start=" . $$timerevent{'anfang'} . " end=" . $$timerevent{'ende'} . " title='" . $$timerevent{'title'} . "'" . " tvinfo-user=" . $$timerevent{'tvinfo_user'} . " tvinfo-folder=" . $$timerevent{'tvinfo_folder'};

	logging("DEBUG", "Possible new timer #" . sprintf("%3d     ", $timerevent_entry) . ": " . $timerevent_text);

	$flag_found = 0;
	my $oldtimer_change = -1;
	foreach my $oldtimer_num (@oldtimers_num) {
		next if ($oldtimers_action{$oldtimer_num} eq "match");

		my $timer_p = $oldtimers_entries{$oldtimer_num};

		# extract existing usernames and folders
		my @tvinfo_user_entries = split /,/, $$timer_p{'tvinfo_user'};
		my @tvinfo_folder_entries = split /,/, $$timer_p{'tvinfo_folder'};
		my %tvinfo_user_folder_entries;

		# check for totally empty folder entries and store default (migration issue)
		my $c = -1;
		for my $user (@tvinfo_user_entries) {
			$c++;
			if ((defined $tvinfo_folder_entries[$c]) && ($tvinfo_folder_entries[$c] ne "")) {
				if (($user eq $username) && ($tvinfo_folder_entries[$c] ne $$timerevent{'tvinfo_folder'})) {
					# overwrite old folder
					$tvinfo_folder_entries[$c] = $$timerevent{'tvinfo_folder'};
				};
			} else {
				# fill with default
				$tvinfo_folder_entries[$c] = $user;
			};	
		};

		# convert folder array to hash
		my $d = 0;
		foreach my $user (@tvinfo_user_entries) {
			$tvinfo_user_folder_entries{$user} = $tvinfo_folder_entries[$d];
			$d++;
		};

		logging("TRACE", "MATCH: user        entries: " . join(" ", @tvinfo_user_entries));
		logging("TRACE", "MATCH: user folder entries: " . join(" ", @tvinfo_folder_entries));

		logging("TRACE", "MATCH: Check against existing timer    #$oldtimer_num: channel_id=" . $$timer_p{'channel_id'} . " timer_day=" . $$timer_p{'timer_day'} . " start=" . $$timer_p{'anfang'} . " end=" . $$timer_p{'ende'} . " title='" . $$timer_p{'title'} . "' tvinfo-user=" . join(",", @tvinfo_user_entries) . " tvinfo-folder=" . join(",", @tvinfo_folder_entries));

		if (($$timerevent{'channel_id'} == $$timer_p{'channel_id'}) && ($$timerevent{'timer_day'} eq $$timer_p{'timer_day'}) && ($$timerevent{'anfang'} eq $$timer_p{'anfang'}) && ($$timerevent{'ende'} eq $$timer_p{'ende'})) {
			logging("DEBUG", "MATCH: channel_id,timer_day,begin,end equal/check title of existing timer   #$oldtimer_num: channel_id=" . $$timer_p{'channel_id'} . " timer_day=" . $$timer_p{'timer_day'} . " start=" . $$timer_p{'anfang'} . " end=" . $$timer_p{'ende'} . " title='" . $$timer_p{'title'} . "' tvinfo-user=" . join(",", @tvinfo_user_entries) . " tvinfo-folder=" . join(",", @tvinfo_folder_entries) . " username=" . $username);

			# adjust title
			logging("TRACE", "MATCH: timerevent->tvinfo_folder=" . $$timerevent{'tvinfo_folder'} . "");
			my $folder = createfoldername(split /,/, $$timerevent{'tvinfo_folder'});
			my $title = $$timerevent{'title'};
			if ($folder ne ".") {
				# prepend folder
				$title = $folder . "~" . $title;
			};

			# Check title match
			my $match = 0;

			logging("TRACE", "MATCH: compare     title='" . $title . "'");
			logging("TRACE", "MATCH: with title(timer)='" . $$timer_p{'title'} . "'");

			if ($title eq $$timer_p{'title'}) {
				# fully equal
				$match = 1;
			} elsif (($folder ne "") && ($$timerevent{'title'} eq $$timer_p{'title'})) {
				# missing folder
				$match = 11;
			} else {
				my $timer_p_title_length    = length($$timer_p{'title'});
				my $timerevent_title_length = length($$timerevent{'title'});

				if (substr($$timerevent{'title'}, 0, $timer_p_title_length) eq $$timer_p{'title'}) {
					# start from first char
					$match = 2;
				} elsif (substr($$timer_p{'title'}, 0, $timerevent_title_length) eq $$timerevent{'title'}) {
					# start from first char
					$match = 3;
				} elsif (substr($title, 0, $timer_p_title_length) eq $$timer_p{'title'}) {
					# start from first char (with folder)
					$match = 4;
				} else {
					my $timer_title = $$timer_p{'title'};
					if ($$timer_p{'title'} =~ /^.*~(.*)/) {
						$timer_title = $1;
						logging("TRACE", "MATCH: title(timer) contains folder (remove): '" . $$timer_p{'title'} . "'");
					};

					logging("TRACE", "MATCH: compare     title='" . $$timerevent{'title'} . "'");
					logging("TRACE", "MATCH: with title(timer)='" . $timer_title . "'");

					if ((index($timer_title, $$timerevent{'title'}) > -1) || (index($$timerevent{'title'}, $timer_title) > -1)) {
						logging("DEBUG", "MATCH: substring match title(vdr)='" . $timer_title . "' title(new)='" . $$timerevent{'title'} . "'");
						my $user_folder_list = "";
						for my $user (keys %tvinfo_user_folder_entries) {
							$user_folder_list .= " " if ($user_folder_list ne "");
							$user_folder_list = $user . "=" . $tvinfo_user_folder_entries{$user};
						};
						logging("TRACE", "MATCH: user folder entries: " . $user_folder_list);
						logging("TRACE", "MATCH: tvinfo_user_folder_entry: " . $tvinfo_user_folder_entries{$username} . " username=" . $username) if (defined $tvinfo_user_folder_entries{$username});

						if (defined $tvinfo_user_folder_entries{$username}) {
							# user already in the list
							$match = 4;

							# Check folder entries
							if ($tvinfo_user_folder_entries{$username} eq $folder) {
								# existing, check generated folder name (below)
								$match = 19;
							} else {
								$tvinfo_user_folder_entries{$username} = $folder;
								# Timer must be changed
								$match = 18;
							};
						} else {
							# Timer must be changed
							$match = 17;
						};
					} else {
						logging("DEBUG", "MATCH: NO-MATCH");
					};
				};
			};

			logging("TRACE", "MATCH: result: " . $match);

			if ($match > 10) {
				logging("DEBUG", "MATCH: Timer already exists (poss update req) #" . sprintf("%-2d", $oldtimer_num). ": channel_id=" . sprintf("%-3d", $$timerevent{'channel_id'}) . " timer_day=" . $$timerevent{'timer_day'} . " start=" . $$timerevent{'anfang'} . " end=" . $$timerevent{'ende'} . " title='" . $$timerevent{'title'} . "' matchmethod=" . $match);

				if ($match == 11) {
					$oldtimers_action{$oldtimer_num} = "update";
					$oldtimer_change = $oldtimer_num;

					$flag_found = 2;
					last;
				};

				if ($match == 17) {
					# add new username/folder
					push @tvinfo_user_entries, $username;
					$tvinfo_user_folder_entries{$username} = $folder;
				};

				# recreate array from hash
				@tvinfo_folder_entries = ();
				foreach my $user (@tvinfo_user_entries) {
					logging("TRACE", "MATCH: add user_folder for user: " . $user . " -> " . $tvinfo_user_folder_entries{$user});
					push @tvinfo_folder_entries, $tvinfo_user_folder_entries{$user};
				};

				$$timerevent{'tvinfo_user'} = join(",", @tvinfo_user_entries);
				$$timerevent{'tvinfo_folder'} = join(",", @tvinfo_folder_entries);

				logging("TRACE", "MATCH: tvinfo_user(new)=" . $$timerevent{'tvinfo_user'} . " tvinfo_folder(new)=" . $$timerevent{'tvinfo_folder'});

				# adjust title
				my $folder_new = createfoldername(split /,/, $$timerevent{'tvinfo_folder'});
				my $title = $$timerevent{'title'};
				if ($folder_new ne ".") {
					# prepend folder
					$title = $folder_new . "~" . $title;
				};

				logging("TRACE", "MATCH: title(existing)='" . $$timer_p{'title'} . "' title(new)='" . $title . "'");

				#if (($$timer_p{'title'} eq $title) && ($match != 18) && ($match != 19)) {
				if ($match == 19) {
					if ($$timer_p{'title'} eq $title) {
						# nothing to do
						logging("TRACE", "MATCH: identical title (existing)='" . $$timer_p{'title'} . "' title(new)='" . $title . "'");
						$oldtimers_action{$oldtimer_num} = "match";
						$newtimers[$timerevent_entry] = undef;
						$flag_found = 1;
						last;
					} elsif (index($title, $$timer_p{'title'}) == 0) {
						# nothing to do (length limit)
						logging("TRACE", "MATCH: fully included title (existing)='" . $$timer_p{'title'} . "' title(new)='" . $title . "'");
						$oldtimers_action{$oldtimer_num} = "match";
						$newtimers[$timerevent_entry] = undef;
						$flag_found = 1;
						last;
					};
				};

				$oldtimers_action{$oldtimer_num} = "update";
				$oldtimer_change = $oldtimer_num;

				$flag_found = 2;
				last;

			} elsif ($match > 0) {
				logging("DEBUG", "MATCH: Timer already exists (skip delete/add) #" . sprintf("%-2d", $oldtimer_num) . ": channel_id=" . sprintf("%-3d", $$timerevent{'channel_id'}) . " timer_day=" . $$timerevent{'timer_day'} . " start=" . $$timerevent{'anfang'} . " end=" . $$timerevent{'ende'} . " title='" . $$timerevent{'title'} . "' matchmethod=" . $match);
				$oldtimers_action{$oldtimer_num} = "match";
				$newtimers[$timerevent_entry] = undef;
				$flag_found = 1;
				last;
			};
		};
	};

	if ($flag_found == 0) {
		logging("INFO",  "Timer needs to be added     : " . $timerevent_text);
	} elsif ($flag_found == 1) {
		logging("DEBUG", "Timer need no change        : " . $timerevent_text);
	} elsif ($flag_found == 2) {
		$timerevent_text = "channel_id=" . $$timerevent{'channel_id'} . " timer_day=" . $$timerevent{'timer_day'} . " start=" . $$timerevent{'anfang'} . " end=" . $$timerevent{'ende'} . " title='" . $$timerevent{'title'} . "'" . " tvinfo-user=" . $$timerevent{'tvinfo_user'} . " tvinfo-folder=" . $$timerevent{'tvinfo_folder'};
		logging("INFO", "Timer needs to be changed #" . $oldtimer_change . ": " . $timerevent_text);
	};
};

# copy still defined oldtimers to array of timers which must be deleted
logging("DEBUG", "VDR: check existing timers against results (skip/update/delete)");
foreach my $oldtimer_num (@oldtimers_num) {
	if ($oldtimers_action{$oldtimer_num} ne "match") {
		my $timer_p = $oldtimers_entries{$oldtimer_num};

		if (($$timer_p{'tmstatus'} & 0x8) == 0x8) {
			logging("DEBUG", "VDR: Skip recording timer #$oldtimer_num: channel_id=" . $$timer_p{'channel_id'} . " timer_day=" . $$timer_p{'timer_day'} . " anfang=" . $$timer_p{'anfang'} . " ende=" . $$timer_p{'ende'} . " title='" . $$timer_p{'title'} . "'");
			next;
		};

		my $summary_extract = "";
		$summary_extract = " summary='..." . substr($$timer_p{'summary'}, length($$timer_p{'summary'}) - 37, 40) . "'" if $opt_T;

		# update timer
		if ($oldtimers_action{$oldtimer_num} eq "update") {
			logging("NOTICE", "VDR: remove existing timer for update #$oldtimer_num: channel_id=" . $$timer_p{'channel_id'} . " timer_day=" . $$timer_p{'timer_day'} . " anfang=" . $$timer_p{'anfang'} . " ende=" . $$timer_p{'ende'} . " title='" . $$timer_p{'title'} . "'" . $summary_extract);
			push @oldtimers_delete, $oldtimer_num; # delete -> add
			next;
		};

		# tvinfo-user line (delete username because no longer defined)
		if (grep { $_ eq $username } (split /,/, $$timer_p{'tvinfo_user'})) {
			logging("DEBUG", "VDR: still matching username ($username) timer #$oldtimer_num: channel_id=" . $$timer_p{'channel_id'} . " timer_day=" . $$timer_p{'timer_day'} . " anfang=" . $$timer_p{'anfang'} . " ende=" . $$timer_p{'ende'} . " title='" . $$timer_p{'title'} . "'" . $summary_extract);

			# remove username/folder
			my $c = 0;
			my @user_entries;
			my @folder_entries;
			my @tvinfo_folder_entries = split /,/, $$timer_p{'tvinfo_folder'};
			foreach my $user (split /,/, $$timer_p{'tvinfo_user'}) {
				if ($user ne $username) {
					push @user_entries, $user;
					push @folder_entries, $tvinfo_folder_entries[$c];
					$c++;
				};
			};
			$$timer_p{'tvinfo_user'}   = join ",", @user_entries;
			$$timer_p{'tvinfo_folder'} = join ",", @folder_entries;

			if ($$timer_p{'tvinfo_user'} eq "") {
				logging("NOTICE", "VDR: remove timer having no longer a user: timer #$oldtimer_num: channel_id=" . $$timer_p{'channel_id'} . " timer_day=" . $$timer_p{'timer_day'} . " anfang=" . $$timer_p{'anfang'} . " ende=" . $$timer_p{'ende'} . " title='" . $$timer_p{'title'} . "'" . $summary_extract);
				push @oldtimers_delete, $oldtimer_num; # delete
				next;
			};

			logging("NOTICE", "VDR: update timer after removing users ($username): timer #$oldtimer_num: channel_id=" . $$timer_p{'channel_id'} . " timer_day=" . $$timer_p{'timer_day'} . " anfang=" . $$timer_p{'anfang'} . " ende=" . $$timer_p{'ende'} . " title='" . $$timer_p{'title'} . "'" . $summary_extract);
			$oldtimers_action{$oldtimer_num} = "update";

			# strip folder from title
			my $folder = createfoldername(@tvinfo_folder_entries);
			if ($$timer_p{'title'} =~ /^$folder~/) {
				$$timer_p{'title'} =~ s/^$folder~//;
			};

			# strip tvinfo from summary
			$$timer_p{'summary'} =~ s/\(tvinfo-user=([^)]*)\)//o;
			$$timer_p{'summary'} =~ s/\(tvinfo-folder=([^)]*)\)//o;
			my $prefix_escaped = $tvinfoprefix;
			$prefix_escaped =~ s/([()])/\\$1/g;
			$$timer_p{'summary'} =~ s/\|$prefix_escaped//o;

			# create new timer by copy
			push(@newtimers, {
				channel_id    => $$timer_p{'channel_id'},
				timer_day     => $$timer_p{'timer_day'},
				anfang        => $$timer_p{'anfang'},
				ende          => $$timer_p{'ende'},
				title         => $$timer_p{'title'},
				summary       => $$timer_p{'summary'},
				tvinfo_user   => $$timer_p{'tvinfo_user'},
				tvinfo_folder => $$timer_p{'tvinfo_folder'}
			});
			next;
		};

		if (! (grep { $_ eq $username } (split /,/, $$timer_p{'tvinfo_user'}))) {
			logging("DEBUG", "VDR: skip not matching username ($username) timer #$oldtimer_num: channel_id=" . $$timer_p{'channel_id'} . " timer_day=" . $$timer_p{'timer_day'} . " anfang=" . $$timer_p{'anfang'} . " ende=" . $$timer_p{'ende'} . " title='" . $$timer_p{'title'} . "'" . $summary_extract);
			next;
		};

		logging("NOTICE", "VDR: remove obsolete existing timer #$oldtimer_num: channel_id=" . $$timer_p{'channel_id'} . " timer_day=" . $$timer_p{'timer_day'} . " anfang=" . $$timer_p{'anfang'} . " ende=" . $$timer_p{'ende'} . " title='" . $$timer_p{'title'} . "'" . $summary_extract);

		$oldtimers_action{$oldtimer_num} = "delete";
		push @oldtimers_delete, $oldtimer_num;

	} else {
		logging("DEBUG", "VDR: existing timer stays untouched #$oldtimer_num");
	};
};

# remove undef in newtimers
my @newtimers_cleaned = ();
$timerevent_entry = 0;
foreach my $newtimer (@newtimers) {
	$timerevent_entry++;
	if (defined $newtimer) {
		push @newtimers_cleaned, $newtimer;
		#logging("DEBUG", "new timer still defined     #$timerevent_entry");
	} else {
		#logging("DEBUG", "new timer no longer defined #$timerevent_entry");
	};
};

if (scalar(@oldtimers_delete) > 0) {
	logging("DEBUG", "Following existing timers found which need to be removed (amount: " . scalar(@oldtimers_delete) . ") : @oldtimers_delete");

	if ($svdrp_ro == 1) {
		logging("NOTICE", "Do not delete old timers via SVDRP (read-only mode): " . scalar(@oldtimers_delete));
	} else {
		foreach my $num (reverse @oldtimers_delete) {
			logging("INFO", "Delete old timer via SVDRP (simulation=$sim): " . $num);

			# clean cache
			undef %timers_cache;
			$timers_cache{'cachestatus'} = "valid";

                	my $result = $SVDRP->SendCMD("delt $num");
			if ($result ne "1") {
				logging("ERROR", "Delete of old timer was not successful: " . $result);
			};
                };
	};
} else {
	logging("INFO", "No existing timers need to be removed");
};

if (scalar(@newtimers_cleaned) > 0) {
	logging("DEBUG", "Following amount of new timers will be added: " . scalar(@newtimers_cleaned));

	# und neue Timer eintragen
	foreach my $timerevent (@newtimers_cleaned) {
		my $text = "$timerevent->{timer_day} $timerevent->{anfang}-$timerevent->{ende} '";
		my $summary = $$timerevent{'summary'};
		my $title   = $$timerevent{'title'};
		my $folder  = createfoldername(split /,/, $$timerevent{'tvinfo_folder'});
		if ($folder ne ".") {
			$title = $folder . "~" . $title;
		};

		if (length($title) > 40) {
			$text .= substr($title, 0, 40-3) . "...'";
		} else {
			$text .= $title . "'";
		};

		# Add tokens
		$summary .= "|" . $tvinfoprefix; # extend summary with tvinfo informations
		$summary .= "(tvinfo-user=" . $$timerevent{'tvinfo_user'} . ")";
		$summary .= "(tvinfo-folder=" . $$timerevent{'tvinfo_folder'} . ")";

		$text .= " summary='..." . substr($summary, length($summary) - 80, 80) . "'" if ($debug == 1);

		if ($svdrp_ro == 1) {
			logging("NOTICE", "Do not program timer via SVDRP (read-only mode): $text");
		} else {  
			logging("DEBUG", "Try to program timer via SVDRP (simulation=$sim): $text");

			# clean cache
			undef %timers_cache;
			$timers_cache{'cachestatus'} = "valid";

			my($result) = $SVDRP->SendCMD("newt 1:" . $$timerevent{'channel_id'} . ":" . $$timerevent{'timer_day'} . ":" . $$timerevent{'anfang'} . ":" . $$timerevent{'ende'} . ":$prio:$lifetime:$title:$summary");
			if ($result =~ m/^(\d+)\s+1:/) {
				logging("INFO", "Successful programmed timer via SVDRP (simulation=$sim): #$1 $text");
			} else {
				logging("ERROR", "Problem programming new timer via SVDRP (simulation=$sim): $result $text");
			}
		};
	}
} else {
	logging("INFO", "No new timers need to be added");
};

$SVDRP->close;

if ($opt_S) {
	if ((scalar(@oldtimers_delete) == 0) && (scalar(@newtimers_cleaned) == 0) && $logging_highestlevel > 4) {
		# nothing to do
	} else {
		# print messages
		for my $line (@logging_summary) {
			print STDOUT $line . "\n";
		};
	};
};

exit(0);

