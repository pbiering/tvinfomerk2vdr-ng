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
# 201411xx/pb: complete reorg, support now also DVR tvheadend via HTSP
# 20141129/pb: hibernate support of dedicated SYSTEM (currently not needed)

use strict; 
use warnings; 
use utf8;

use File::Basename;
use Getopt::Long;

binmode(STDOUT, ":utf8");
binmode(STDERR, ":utf8");

our $progname = "tvinfomerk2vdr-ng.pl";
our $progversion = "1.0.0";

## Requirements:
# Ubuntu: libxml-simple-perl libdate-calc-perl
# Fedora: perl-XML-Simple perl-Date-Calc perl-Sys-Syslog

## Extensions (in difference to original version):
# - Multi-SERVICE account capable
# - Only required timer changes are executed (no longer unconditional remove/add)
# - Optional definition of a folder for storing records (also covering multi-account capability)
# - sophisticated automagic SERVICE->DVR channel mapping
# - use strict/warnings for improving code quality
# - debugging/tracing/logging major improvement

## Removed features
# - HTML 'Merkliste' is no longer the master
# - manual channel mapping
# - support of 'tviwantgenrefolder' and 'tviwantseriesfolder' removed (for easier Multi-Account/Folder capability)

## TODO (in case of needed)
# - add option for custom channel map (in predecence of automatic channelmap)
#     dedicated txt file with SERVICE-CHANNEL-NAME=DVR-CHANNEL-NAME

## Setup
#
# Check channel mapping (-c)
# Display channel suggestions (--scs)

## Test
#
# - check for non-empty timer list on SERVICE
# - run script in dry-run mode
#    ./tvinfomerk2vdr-ng-wrapper.sh -N -U <service-user> -P <service-password>

## Workflow
# - retrieve channels from SERVICE
# - retrieve channels vrom DVR
# - perform a SERVICE to DVR channel mapping
# - retrieve timers from SERVICE
# - retrieve timers from DVR
# - run through SERVICE timers and check for match in existing DVR timers
#    skip timers in the past
#    take care about margins, channel mappings and whether created before by this tool
#    in case of missing, put on TODO-ADD list
# - run through DVR timers, check for left-overs
#    take care about margins, channel mappings and whether created before by this tool
#    in case of no longer matching SERVICE list, put on TODO-DELETE list
# - delete marked timers on DVR
# - add new timers on DVR (in case of tvheadend this can also lead to new configurations)

###############################################################################
#
# Initialization
#

our $dirname = dirname($0);

my $file_config = $dirname . "/config-ng.pl"; # old
my $file_properties = $dirname . "/tvinfomerk2vdr-ng.properties";

push (@INC, $dirname);
require ("inc/logging.pl");
require ("inc/support-dvr.pl");
require ("inc/support-channels.pl");
require ("inc/support-channelmap.pl");

my $result;

our $debug = 0;

our $foldername_max = 15;
our $titlename_max  = 40;


our %debug_class = (
	"XML"         => 0,
	"CORR"        => 0,
	"VDR-CH"      => 0,
	"MATCH"       => 0,
	"VDR"         => 0,
	"SVDRP"       => 0,
	"HTSP"        => 0,
	"CHANNELS"    => 0,
	"TVINFO"      => 0,
	"TVHEADEND"   => 0,
	"Channelmap"  => 0,
	"MeineSender" => 0,
	"AlleSender"  => 0,
);

#$SIG{'INT'}  = \&SIGhandler;
#my $http_timeout = 15;

# getopt
our ($opt_R, $opt_W, $opt_X, $opt_h, $opt_v, $opt_N, $opt_d, $opt_p, $opt_D, $opt_U, $opt_P, $opt_F, $opt_T, $opt_C, $opt_c, $opt_L, $opt_S, $opt_u, $opt_K, $opt_E);

## config-ng.pl
our $http_proxy;
our $username;
our $password;
our ($prio, $lifetime);
our $setupfile;			# no longer used
our $networktimeout;
our $skip_ca_channels;
our $whitelist_ca_groups;

# defaults
if (! defined $skip_ca_channels) { $skip_ca_channels = 1 };
if (! defined $whitelist_ca_groups) { $whitelist_ca_groups = "" };


###############################################################################
## New Structure
###############################################################################

## define defaults
my @service_modules = ("tvinfo");
my @dvr_modules     = ("vdr", "tvheadend");
#my @system_modules  = ("reelbox", "openelec");

our @service_list_supported;
our @dvr_list_supported    ;
#our @system_list_supported ;

our %module_functions;

## define configuration
our %config;

## define setup
my %setup;

## define debug/trace
our %debugclass;
our %traceclass;
our $verbose = 0;

$debugclass{'HTSP'} = 1;
$debugclass{'TVHEADEND'} = 1;
$debugclass{'TVINFO'} = 1;
$traceclass{'HTSP'} = 0;
	#$traceclass{'HTSP'} |= 0x00000002; # JSON dump adapters
	#$traceclass{'HTSP'} |= 0x00000020; # JSON dump stations
	#$traceclass{'HTSP'} |= 0x00000100; # JSON dump timers raw
	#$traceclass{'HTSP'} |= 0x00000200; # JSON dump timers
	#$traceclass{'HTSP'} |= 0x00001000; # JSON dump channels raw
	#$traceclass{'HTSP'} |= 0x00002000; # JSON dump channels
	#$traceclass{'HTSP'} |= 0x00010000; # JSON dump confignames raw
	#$traceclass{'HTSP'} |= 0x00020000; # JSON dump confignames
	#$traceclass{'HTSP'} |= 0x00040000; # JSON dump config raw
	#$traceclass{'HTSP'} |= 0x00080000; # JSON dump config
	# 0x0001: JSON raw dump adapters
	# 0x0010: JSON raw dump stations
	# 0x1000: skipped channels hardcoded blacklist
	# 0x2000: skipped channels (missing typestr)
	# 0x4000: skipped channels (not enabled)

$traceclass{'TVINFO'} = 0; # 0x01: XML raw dump stations
	#$traceclass{'TVINFO'} |= 0x0040; # XML Merkzettel (parsed)

## properties and their default
my %properties;
my %properties_default = (
	'dvr.service-user.default.folder'      => '.',
	'dvr.service-user.default.lifetime'    => 100 * 365, # 100 years
	'dvr.service-user.default.priority'    => 99, # 99: highest priority
	'dvr.host.default.margin.start'        => 10,
	'dvr.host.default.margin.stop'         => 35,
	'dvr.host.default.use-ca-channels'     => 0,  # use also CA channels
	'dvr.host.default.whitelist-ca-groups' => '', # whitelisted CA groups
);

my %properties_descriptions = (
	'dvr.service-user.default'	=> "DVR related default settings to SERVICE",
	'dvr.service-user'		=> "DVR related settings to SERVICE user",
	'dvr.host.default'		=> "DVR host related default settings",
	'dvr.host'			=> "DVR host related settings",
	'service.default'		=> "SERVICE related default settings",
	'service.tvinfo'		=> "SERVICE related settings",
);

## filled from properties (configuration) file
my @service_users;
my @dvr_hosts;

## Logging
my $syslog_status = 0;
my @logging_summary;
my $logging_highestlevel = 7;

###############################################################################
## Functions
###############################################################################

sub help() {
	my $debug_class_string = join(" ", sort keys %debug_class);
	my $service_list_supported_string = join(" ", @service_list_supported);
	my $dvr_list_supported_string     = join(" ", @dvr_list_supported);
	#my $system_list_supported_string  = join(" ", @system_list_supported);

#System related
#         --system <type>           define SYSTEM type
#                                     default/configured: $setup{'system'}
#                                     supported         : $system_list_supported_string


	print qq{$progname/$progversion : SERVICE to DVR timer synchronization tool

Usage:
	SERVICE/DVR channel map (configuration)
         $progname -U <service-user> -P <service-password> -c
         $progname -U <service-user> -P <service-password> --scs

	SERVICE/DVR timer synchronization (regular usage)
         $progname -U <service-user> -P <service-password> [-F <folder>]

Options: 
         -L                        use syslog instead of stderr
         -S                        show summary to stdout in case of any changes or log messages > notice
         -h	                   Show this help text
         --pp	                   Print Properties (and stop)
         --properties|rp <FILE>    Read Properties from FILE (default: $file_properties)
         --srp                     Skip Read Properties from FILE

Service related
         --service <name>          define SERVICE name
                                     default/configured: $setup{'service'}
                                     supported         : $service_list_supported_string
         -U <username>             SERVICE username (default: $username [config-ng.pl])
         -P <password>             SERVICE password (default: $password [config-ng.pl])

DVR related
         --dvr <type>              define DVR type
                                     default/configured: $setup{'dvr'}
                                     supported         : $dvr_list_supported_string
         -d|--host <hostname>      DVR hostname (default: $config{'dvr.host'})
         -p <port>                 SVDRP/HTSP port number (default: 2001/9981)
         -F|--folder <folder>      folder for DVR records (default: none)

Channel Mapping
         -c|--scm                  Show Channel Map results (and stop)
         -u                        show unfiltered Channel Map results (and stop)
         --scs                     Show Channelmap Suggestions
         --ucc                     Use CA Channels (default: no use)
         --wcg <group>             Whitelist-Ca-Group (can be used more than one time)

Debug options:
         -v                        Show verbose messages
         -D	                   Debug Mode
         -T	                   Trace Mode
         -C class[,...]            Debug Classes: $debug_class_string
         -X	                   XML Debug Mode
         -N	                   No real DVR change action (do not delete/add timers but write an action fike)
         -W                        Write (all)  raw responses to files
         --wstf                    Write (only) Service raw responses To File(s)
         --wdtf                    Write (only) Dvr raw responses To File(s)
         -R                        Read  (all)  raw responses from files
         --rsff                    Read  (only) SERVICE raw responses from file(s)
         --rdff                    Read  (only) DVR raw responses from file(s)
         -K|--sdt <list>           skip DVR timer entries with number from comma separated list
         -E|--sst <list>           skip SERVICE timer entries with number from comma separated list
         -O|--property key=value   define a config property
         --prefix <prefix> Prefix for read/write files (raw responses)
         --pic	                   Print Internal Config (and stop)
};
	print "\n";
};

###############################################################################
###############################################################################
# Main
###############################################################################
###############################################################################

###############################################################################
# Load SERVICE/DVR/SYSTEM modules
###############################################################################

# generate list of modules
my @modules;

foreach my $service_module (@service_modules) {
	push @modules, "inc/service-" . $service_module . ".pl";
};

foreach my $dvr_module (@dvr_modules) {
	push @modules, "inc/dvr-" . $dvr_module . ".pl";
};

#foreach my $system_module (@system_modules) {
#	push @modules, "inc/system-" . $system_module . ".pl";
#};

# load modules if existing
foreach my $module (@modules) {
	if (-e $dirname . "/" . $module) {
		require($module);
		logging("DEBUG", "load module: " . $module);
	} else {
		logging("WARN", "module not existing: " . $module);
	};
};

###############################################################################
# Defaults (partially by autodetection)
###############################################################################

$setup{'service.default'} = "tvinfo"; # default (only one supported so far)

# Try to autodetect SYSTEM
#foreach my $system (@system_list_supported) {
#	if (defined $module_functions{'system'}->{$system}->{'autodetect'}) {
#		if ($module_functions{'system'}->{$system}->{'autodetect'}()) {
#			logging("INFO", "autodetected SYSTEM : " . $system);
#			$setup{'system'} = $system;
#			last;
#		};
#	};
#};

$username = "" if (! defined $username);
$password = "" if (! defined $password);

###############################################################################
# Options parsing
###############################################################################
my ($opt_service, $opt_system, $opt_dvr, @opt_properties);
my ($opt_read_service_from_file, $opt_read_dvr_from_file);
my ($opt_write_service_to_file, $opt_write_dvr_to_file);
my ($opt_show_channelmap_suggestions);
my ($opt_prefix);
my ($opt_print_properties, $opt_properties, $opt_skip_read_properties);
my ($opt_print_internal_config);
my ($opt_use_ca_channels, @opt_whitelist_ca_group);


Getopt::Long::config('bundling');

my $options_result = GetOptions (
	"L"		=> \$opt_L,
	"v"		=> \$opt_v,
	"S"		=> \$opt_S,

	# properties file
	"properties|rp=s"	=> \$opt_properties,
	"pp"			=> \$opt_print_properties,
	"srp"			=> \$opt_skip_read_properties,

	# DVR
	"dvr=s"		=> \$opt_dvr,
	"d=s" 		=> \$opt_d,
	"p=i"		=> \$opt_p,
	"F|folder=s"	=> \$opt_F,
	"K|sdt:s"	=> \$opt_K,

	# SERVICE
	"service=s"	=> \$opt_service,
	"U=s"		=> \$opt_U,
	"P=s"		=> \$opt_P,
	"E|sst:s"	=> \$opt_E,

	#"system=s"	=> \$opt_system,

	# Channelmap
	"c|scm"		=> \$opt_c,
	"u"		=> \$opt_u,
	"scs"		=> \$opt_show_channelmap_suggestions,
	"ucc"		=> \$opt_use_ca_channels,
	"wcg"		=> \@opt_whitelist_ca_group,

	# general debug
	"C:s"		=> \$opt_C,
	"T"		=> \$opt_T,

	# debug (read/write from/to file)
	"D"		=> \$opt_D,
	"X"		=> \$opt_X,
	"N"		=> \$opt_N,
	"W"		=> \$opt_W,
	"R"		=> \$opt_R,
	"rsff"		=> \$opt_read_service_from_file,
	"rdff"		=> \$opt_read_dvr_from_file,
	"wstf"		=> \$opt_write_service_to_file,
	"wdtf"		=> \$opt_write_dvr_to_file,
	"prefix"	=> \$opt_prefix,
	"pic"		=> \$opt_print_internal_config,

	"O|property=s@"	=> \@opt_properties,
	"h|help|\?"	=> \$opt_h,
);

if ($options_result != 1) {
	print "Error in command line arguments (see -h|help|?)\n";
	exit 1;
};

if (defined $opt_h) {
	help();
	exit 1;
};

## Debug/verbose options
$verbose = 1 if (defined $opt_v || defined $opt_D || defined $opt_T);
$debug = 1 if $opt_D;


###############################################################################
# Basic information
###############################################################################
logging("DEBUG", "list of supported SERVICEs: " . join(" ", @service_list_supported));
logging("DEBUG", "list of supported DVRs    : " . join(" ", @dvr_list_supported));
#logging("INFO", "list of supported SYSTEMs : " . join(" ", @system_list_supported));


###############################################################################
# Autodetection
###############################################################################
# Try to autodetect DVR
logging("DEBUG", "try to autodetect DVR from list: " . join(" ", @dvr_list_supported));
foreach my $dvr (@dvr_list_supported) {
	if (defined $module_functions{'dvr'}->{$dvr}->{'autodetect'}) {
		logging("DEBUG", "try to autodetect DVR: " . $dvr);
		if ($module_functions{'dvr'}->{$dvr}->{'autodetect'}()) {
			logging("NOTICE", "autodetected DVR: " . $dvr);
			$setup{'dvr'} = $dvr;
			$config{'dvr.host'} = "localhost";
			last;
		};
	};
};


###############################################################################
# Read configuration from file
###############################################################################

logging("INFO", "try reading configuration from file (OLD FORMAT): " . $file_config);
if (! -e $file_config) {
	logging("NOTICE", "given config file (OLD FORMAT) is not existing: " . $file_config);
} else {
	require ($file_config) || die;
	logging("INFO", "read configuration from file (OLD FORMAT): " . $file_config);

	# map old options to new properties
	$config{'service.user'}     = $username if (defined $username);
	$config{'service.password'} = $password if (defined $password);
};

if (defined $opt_properties) {
	if (! -e $opt_properties) {
		logging("ERROR", "given config file is not existing: " . $opt_properties);
		exit 1;
	};
	$file_properties = $opt_properties;
} elsif (! -e $file_properties) {
	logging("NOTICE", "default properties file is not existing: " . $file_properties);
	$file_properties = undef;
};

if (defined $file_properties) {
	if (defined $opt_skip_read_properties) {
		logging("NOTICE", "read of properties file is disabled by option");
	} else {
		logging("INFO", "try reading configuration from file: " . $file_properties);
		if(!open(FILE, "<$file_properties")) {
		logging("ERROR", "can't read configuration from file: " . $file_properties);
			exit(1);
		};

		my $lc = 0;
		while(<FILE>) {
			$lc++;
			chomp($_);
			next if ($_ =~ /^#/o); # skip comments
			next if ($_ =~ /^$/o); # skip empty lines

			if ($_ =~ /^\s*([^\s]+)\s*=\s*([^\s]*)\s*$/o) {
				my ($key, $value) = ($1, $2);
				logging("DEBUG", "read from config file: " . $key . "=" . $value);

				if ($value eq "") {
					$properties{$key} = undef;
				} else {
					$properties{$key} = $value;
				};
			} else {
				logging("WARN", "skip unparsable line in config file[" . $lc . "]: " . $_);
			};
		};
		logging("INFO", "finished reading configuration from file: " . $file_properties);

		# check for service_users
		foreach my $entry (grep /^service\.tvinfo\.user\./o, keys %properties) {
			#logging("DEBUG", $entry);
			if ($entry =~ /^service\.tvinfo\.user\.([^.]+)\.password$/o) {
				push @service_users, $1;
			};
		};

		# check for dvr_hosts
		foreach my $entry (grep /^dvr\.host\./o, keys %properties) {
			#logging("DEBUG", $entry);
			if ($entry =~ /^dvr\.host\.([^.]+)\.type$/o) {
				push @dvr_hosts, $1;
			};
		};
	};
};


###############################################################################
# Apply default values
###############################################################################
# apply default values to properties if not already defined via option or properties file
foreach my $key (keys %properties_default) {
	if (! defined $properties{$key}) {
		$properties{$key} = $properties_default{$key};
	};
};


###############################################################################
# Options validation
###############################################################################

## --property
if (scalar (@opt_properties) > 0) {
	foreach my $keyvalue (@opt_properties) {
		my ($key, $value) = split("=", $keyvalue, 2);
		if ((! defined $key) || (! defined $value)) {
			logging("ERROR", "unsupported property: " . $keyvalue);
			exit 2;
		};
		$config{$key} = $value;
	};
};

## --service
if (defined $opt_service) {
	if (! grep(/^$opt_service$/, @service_list_supported)) {
		logging("ERROR", "unsupported SERVICE: " . $opt_service);
		exit 2;
	};
	$setup{'service'} = $opt_service;
} else {
	$setup{'service'} = $setup{'service.default'};
	logging("NOTICE", "autoselected SERVICE: " . $setup{'service'});
};

## --dvr
if (defined $opt_dvr) {
	if (! grep(/^$opt_dvr$/, @dvr_list_supported)) {
		logging("ERROR", "unsupported DVR: " . $opt_dvr);
		exit 2;
	};
	$setup{'dvr'} = $opt_dvr;
};

## --system
#if (defined $opt_system) {
#	if (! grep(/^$opt_system$/, @system_list_supported)) {
#		print "ERROR : unsupported SYSTEM: " . $opt_system . "\n";
#		exit 2;
#	};
#	$setup{'system'} = $opt_system;
#};

## --host
if (defined $opt_d) {
	$config{'dvr.host'} = $opt_d;

	# define property
	if (defined $opt_dvr) {
		$properties{"dvr.host." . $config{'dvr.host'} . ".type"} = $setup{'dvr'};
	};
};

if (! defined $config{'dvr.host'}) {
	my $info = "";
	if (scalar(@dvr_hosts) > 0) {
		$info = " - potential DVR hosts found in properties: " . join(" ", @dvr_hosts);
	};
	logging("ERROR", "DVR host not given (use -d)" .  $info);
	exit 1;
};

## --port
if (defined $opt_p) {
	if ($opt_p =~ /^[0-9]{3,5}$/o) {
		$config{'dvr.port'} = $opt_p;

		# define property
		if (defined $opt_dvr) {
			$properties{"dvr.host." . $config{'dvr.host'} . ".port"} = $config{'dvr.port'};
		};
	} else {
		logging("ERROR", "unsupported port: " . $opt_p);
		exit 2;
	};
} else {
	if (defined $properties{"dvr.host." . $config{'dvr.host'} . ".port"}) {
		$config{'dvr.port'} = $properties{"dvr.host." . $config{'dvr.host'} . ".port"};
		logging("INFO", "take DVR port from properties: " . $config{'dvr.port'});
	};
};

## map old config-ng.pl values to new structure
if (defined $setupfile) {
	logging("WARN", "parameter 'setupfile' in config-ng.pl is no longer supported");
};

# migration from config-ng.pl
$properties{'service.default.proxy'} = $http_proxy if defined ($http_proxy);
$properties{'dvr.service-user.default.priority'} = $prio if defined ($prio);
$properties{'dvr.service-user.default.lifetime'} = $lifetime if defined ($lifetime);

## debug: raw file read/write handling
# -R is covering all
$opt_read_service_from_file = 1 if (defined $opt_R);
$opt_read_dvr_from_file     = 1 if (defined $opt_R);

# -W is covering all
$opt_write_service_to_file  = 1 if (defined $opt_W);
$opt_write_dvr_to_file      = 1 if (defined $opt_W);

if (defined $opt_read_service_from_file && $opt_write_service_to_file) {
	die "read from and write to file for SERVICE can't be used at the same time";
};
if (defined $opt_read_dvr_from_file && $opt_write_dvr_to_file) {
	die "read from and write to file for DVR can't be used at the same time";
};

# defaults
$config{'service.source.type'} = "network";
$config{'dvr.source.type'}     = "network";

# define properties according to options
$config{'dvr.source.type'}     = "file" if (defined $opt_read_dvr_from_file);
$config{'service.source.type'} = "file" if (defined $opt_read_service_from_file);

$config{'dvr.source.type'}     = "network+store" if defined ($opt_write_dvr_to_file);;
$config{'service.source.type'} = "network+store" if defined ($opt_write_service_to_file);

## debug: action handling
if (defined $opt_N) {
	$config{'dvr.destination.type'} = "file";
} else {
	$config{'dvr.destination.type'} = "network";
};

## SERVICE user handling
if ($opt_U) {
	$config{'service.user'} = $opt_U;
};

if (! defined $config{'service.user'}) {
	my $info = "";
	if (scalar(@service_users) > 0) {
		$info = " potential users found in properties: " . join(" ", @service_users);
	};
	logging("ERROR", "SERVICE username not defined (use -U)" .  $info);
	exit 1;
} elsif ($config{'service.user'} eq "<TODO>") {
	logging("ERROR", "SERVICE username not explicitly given, still default: " . $config{'service.user'});
	exit 1;
};

## SERVICE password handling
if ($opt_P) {
	$config{'service.password'} = $opt_P;
};

if (defined $properties{'service.' . $setup{'service'} . ".user." . $config{'service.user'} . ".password"}) {
	$config{'service.password'} = $properties{'service.' . $setup{'service'} . ".user." . $config{'service.user'} . ".password"};
	logging("DEBUG", "found SERVICE password for username in properties: " . $config{'service.password'});
};

if ($config{'service.source.type'} ne "file") {
	if ((! defined $config{'service.password'}) || ($config{'service.password'} eq "")) {
		logging("ERROR", "SERVICE password not defined (use -P or specify in properties file for user: ". $config{'service.user'} . ")");
		exit 1;
	} elsif ($config{'service.password'} eq "<TODO>") {
		logging("ERROR", "SERVICE password not explicitly given, still default: " . $config{'service.password'});
		exit 1;
	};

	if ($setup{'service'} eq "tvinfo") {
		# TODO: move such option checks in service module
		if ($config{'service.password'} !~ /^{MD5}/) {
			logging("WARN", "TVinfo password is not given as hash (conversion recommended for security reasons)");
			$config{'service.password'} = service_tvinfo_convert_password($config{'service.password'});
		};
	};
};

# fill user/pass into properties
if ((defined $opt_U) && (defined $opt_P) &&
    (! defined $properties{'service.' . $setup{'service'} . ".user." . $config{'service.user'} . ".password"})) {
	$properties{'service.' . $setup{'service'} . ".user." . $opt_U . ".password"} = $config{'service.password'};
};


## -F/--folder
if (defined $opt_F) {
	if ($opt_F =~ /^[0-9a-z]+$/io) {
		$config{'dvr.folder'} = $opt_F;

		# fill also into properties
		$properties{'dvr.service-user.' . $config{'service.user'} . ".folder"} = $config{'dvr.folder'};
	} else {
		print "ERROR : unsupported folder: " . $opt_F . "\n";
		exit 2;
	};
};


## --prefix
# defaults for read/write raw files
$config{'service.source.file.prefix'}  = $dirname . "/" . "service-" . $setup{'service'} . "-" . $config{'service.user'};
$config{'dvr.source.file.prefix'} = $dirname . "/" . "dvrhost-" . $config{'dvr.host'};
if (defined $opt_prefix) {
	$config{'dvr.source.file.prefix'} = $opt_prefix . "-" . $config{'dvr.source.file.prefix'};
	$config{'service.source.file.prefix'} = $opt_prefix. "-" . $config{'service.source.file.prefix'};
};

if (! defined $config{'dvr.host'}) {
	logging("ERROR : DVR host not specified (and unable to autodetect)");
	exit 2;
};

## CA channels related options
if (defined $opt_use_ca_channels) {
	$skip_ca_channels = 0;
	$properties{"dvr.host." . $config{'dvr.host'} . ".use-ca-channels"} = (1 - $skip_ca_channels);
} elsif (defined $properties{"dvr.host." . $config{'dvr.host'} . ".use-ca-channels"}) {
	$skip_ca_channels = 1 - $properties{"dvr.host." . $config{'dvr.host'} . ".use-ca-channels"};
};

if (scalar(@opt_whitelist_ca_group) > 0) {
	$whitelist_ca_groups = join(",", @opt_whitelist_ca_group);
	$properties{"dvr.host." . $config{'dvr.host'} . ".whitelist-ca-groups"} = $whitelist_ca_groups;
} elsif (defined $properties{"dvr.host." . $config{'dvr.host'} . ".whitelist-ca-groups"}) {
	$whitelist_ca_groups = $properties{"dvr.host." . $config{'dvr.host'} . ".whitelist-ca-groups"};
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

## Final checks
if (! defined $setup{'dvr'}) {
	if (defined $properties{"dvr.host." . $config{'dvr.host'} . ".type"}) {
		$setup{'dvr'} = $properties{"dvr.host." . $config{'dvr.host'} . ".type"};
		logging("INFO", "take type of DVR from properties: " . $setup{'dvr'} . " (DVR host: " . $config{'dvr.host'} . ")");
	} else {
		logging("ERROR", "DVR not autodeteced and not specified (--dvr): " . join(" ", @dvr_list_supported));
		exit 2;
	};
};

#if (! defined $setup{'system'}) {
#	logging("ERROR", "SYSTEM not autodeteced and not specified (--system): " . join(" ", @system_list_supported));
#	exit 2;
#};

###############################################################################
# Applying default properties
###############################################################################
## priority
if (! defined $properties{'dvr.service-user.' . $config{'service.user'} . '.priority'}) {
	$config{'dvr.priority'} = $properties{'dvr.service-user.default.priority'};
} else {
	$config{'dvr.priority'} = $properties{'dvr.service-user.' . $config{'service.user'} . '.priority'};
};

## lifetime
if (! defined $properties{'dvr.service-user.' . $config{'service.user'} . '.lifetime'}) {
	$config{'dvr.lifetime'} = $properties{'dvr.service-user.default.lifetime'};
} else {
	$config{'dvr.lifetime'} = $properties{'dvr.service-user.' . $config{'service.user'} . '.lifetime'};
};

## folder
if (! defined $properties{'dvr.service-user.' . $config{'service.user'} . '.folder'}) {
	$config{'dvr.folder'} = $properties{'dvr.service-user.default.folder'};
} else {
	$config{'dvr.folder'} = $properties{'dvr.service-user.' . $config{'service.user'} . '.folder'};
};



###############################################################################
# Reading external values
###############################################################################

$module_functions{'dvr'}->{$setup{'dvr'}}->{'init'}() || die "Problem with dvr_init";

if (! defined $config{"dvr.margin.start"}) {
	$config{"dvr.margin.start"} = $properties{'dvr.host.default.margin.start'};
	logging("NOTICE", "DVR: no default MarginStart provided, take default: " . $config{"dvr.margin.start"} . " (dvr.host.default.margin.start)");
};

if (! defined $config{"dvr.margin.stop"}) {
	$config{"dvr.margin.stop"} = $properties{'dvr.host.default.margin.stop'};
	logging("NOTICE", "DVR: no default MarginStop provided, take default: " . $config{"dvr.margin.stop"} . " (dvr.host.default.margin.stop)");
};


###############################################################################
# Print Properties / internal configuration
###############################################################################
if (defined $opt_print_properties) {
	logging("NOTICE", "=" x5 . "print of properties (configuration) begin");
	print "### $progname/$progversion configuration\n";
	print "###  created " . strftime("%Y%m%d-%H%M%S-%Z", localtime()) . "\n";

	my $description = "";
	my $description_old = "";
	for my $property (sort keys %properties) {
		# find best matching description text
		my $key_desc_length = 0;
		for my $key_desc_candidate (sort keys %properties_descriptions) {
			if (($property =~ /^$key_desc_candidate/) && (length($key_desc_candidate) > $key_desc_length)) {
				$key_desc_length = length($key_desc_candidate);
				$description = $properties_descriptions{$key_desc_candidate};
			};
		};

		if ((defined $description) && ($description_old ne $description) && ($description ne "")) {
			$description_old = $description;
			printf "\n";
			printf "## %s\n", $description;
		};

		my $value = $properties{$property};
		$value = "" if (! defined $properties{$property});
		printf "%s=%s\n", $property, $value;
	};

	logging("NOTICE", "=" x5 . "print of properties (configuration) end");
};

if (defined $opt_print_internal_config) {
	logging("NOTICE", "print of internal config begin");

	for my $key (sort keys %setup) {
		printf "#SETUP.%s=%s\n", $key, $setup{$key};
	};

	for my $key (sort keys %config) {
		my $value = $config{$key};
		$value = "" if (! defined $config{$key});
		printf "#CONFIG.%s=%s\n", $key, $value;
	};

	logging("NOTICE", "print of internal config end");
};

if ((defined $opt_print_properties) || (defined $opt_print_internal_config)) {
	exit(0);
};

#############################################################
#############################################################
## Channel management
#############################################################
#############################################################

#############################################################
## Define channel related variables
#############################################################
my @channels_dvr;
my @channels_dvr_filtered;

my @channels_service;
my @channels_service_filtered;


######################################################
## Define some shortcut functions
######################################################
sub get_dvr_channel_name_by_cid($) {
	return get_channel_name_by_cid(\@channels_dvr, $_[0]);
};

sub get_service_channel_name_by_cid($) {
	return get_channel_name_by_cid(\@channels_service, $_[0]);
};


#######################################
## Retrieve channnels from service
#######################################
$result = $module_functions{'service'}->{$setup{'service'}}->{'get_channels'}(\@channels_service);

if (scalar(@channels_service) == 0) {
	logging("CRIT", "SERVICE amount of channels is ZERO - STOP");
	exit 1;
};

#logging("DEBUG", "SERVICE channels before filtering/expanding (amount: " . scalar(@channels_service) . "):");
#print_service_channels(\@channels_service);

my %service_channel_filter = (
	'skip_not_enabled' => 1
);

filter_service_channels(\@channels_service, \@channels_service_filtered, \%service_channel_filter);

logging("INFO", "SERVICE channels after filtering/expanding (amount: " . scalar(@channels_service_filtered) . "):") if ($verbose > 0);
print_service_channels(\@channels_service_filtered);


#############################################################
## Retrieve channels from DVR
#############################################################
$result = $module_functions{'dvr'}->{$setup{'dvr'}}->{'get_channels'}(\@channels_dvr);

if (scalar(@channels_dvr) == 0) {
	logging("CRIT", "DVR amount of channels is ZERO - STOP");
	exit 1;
};

expand_dvr_channels(\@channels_dvr);

my %dvr_channel_filter = (
	'skip_ca_channels'     => $skip_ca_channels,
	'whitelist_ca_groups'  => $whitelist_ca_groups
);

filter_dvr_channels(\@channels_dvr, \@channels_dvr_filtered, \%dvr_channel_filter);

logging("INFO", "DVR channels after filtering/expanding (amount: " . scalar(@channels_dvr_filtered) . "):") if ($verbose > 0);
print_dvr_channels(\@channels_dvr_filtered);


###################################################
## Map service(filtered) and dvr(filtered) channels
# display warnings if service has more channels
#  than dvr
###################################################

my %service_cid_to_dvr_cid_map;

my %flags_channelmap;

# call external (universal) function channel check for channel mapping
%flags_channelmap = (
	'force_hd_channels'    => 1,
	'source_precedence'    => "CST",
	'quiet'                => 1,
);

my $rc = channelmap(\%service_cid_to_dvr_cid_map, \@channels_dvr_filtered, \@channels_service_filtered, \%flags_channelmap);

print_service_dvr_channel_map(\%service_cid_to_dvr_cid_map, \@channels_dvr_filtered, $opt_c);


######################################################
## Map service(unfiltered and dvr(filtered) channels
# display suggestions
######################################################
my %service_cid_to_dvr_cid_map_unfiltered;
%flags_channelmap = (
	'force_hd_channels'    => 0,
	'source_precedence'    => "CST",
	'quiet'                => 1,
);

if (defined $opt_show_channelmap_suggestions) {
	$rc = channelmap(\%service_cid_to_dvr_cid_map_unfiltered, \@channels_dvr_filtered, \@channels_service, \%flags_channelmap);

	print_service_dvr_channel_map(\%service_cid_to_dvr_cid_map_unfiltered, \@channels_dvr_filtered) if ($verbose > 0);

	my $hint = 0;

	# search for missing mapping (means DVR has channel, but SERVICE has not enabled)
	foreach my $s_cid (keys %service_cid_to_dvr_cid_map_unfiltered) {
		if (defined $service_cid_to_dvr_cid_map{$s_cid}->{'cid'}) {
			# found in filtered/filtered map
			next;
		};

		if (! defined $service_cid_to_dvr_cid_map_unfiltered{$s_cid}->{'cid'}) {
			# not found in unfiltered/filtered map
			next;
		};

		$hint = 1;
		logging("NOTICE", "SERVICE: channel candidate to enable: " . $service_cid_to_dvr_cid_map_unfiltered{$s_cid}->{'name'} . "  =>  " . get_dvr_channel_name_by_cid($service_cid_to_dvr_cid_map_unfiltered{$s_cid}->{'cid'}));
	};

	if ($hint == 0) {
		logging("NOTICE", "SERVICE: no channel candidates found to enable - looks like all possible channels are configured");
	};

	exit 0;
};


######################################################
## Map service(unfiltered and dvr(unfiltered) channels
######################################################

if (defined $opt_u) {
	my %service_cid_to_dvr_cid_map_unfiltered2;
	%flags_channelmap = (
		'force_hd_channels'    => 0,
		'source_precedence'    => "CST",
		'quiet'                => 1,
	);

	$rc = channelmap(\%service_cid_to_dvr_cid_map_unfiltered2, \@channels_dvr, \@channels_service, \%flags_channelmap);

	logging("INFO", "SERVICE(unfiltered) => DVR(unfiltered) mapping result");
	print_service_dvr_channel_map(\%service_cid_to_dvr_cid_map_unfiltered2, \@channels_dvr);

	exit 0;
};

if (defined $opt_c) {
	exit 0;
};


#############################################################
#############################################################
## Timer management
#############################################################
#############################################################

#######################################
## Get timers from service
#######################################
my @timers_service;

$rc = $module_functions{'service'}->{$setup{'service'}}->{'get_timers'}(\@timers_service);


#######################################
## Get timers from DVR
#######################################
my @timers_dvr;

$rc = $module_functions{'dvr'}->{$setup{'dvr'}}->{'get_timers'}(\@timers_dvr);

# convert channels if necessary
$rc = dvr_convert_timers_channels(\@timers_dvr, \@channels_dvr);


#######################################
## Pre start processing
#######################################
if ((defined $opt_write_service_to_file) || (defined $opt_write_dvr_to_file)) {
	logging("NOTICE", "Stop here because debug options for writing response files selected");
	exit 0;
};


##################################################################################
### Check existing DVR timer list and check against list retrieved from SERVICE
##################################################################################

my @s_timers_num = ();
my %s_timers_entries = (); # hash with SERVICE timer pointers (key: number)

# timer num = 0 means skip
my @d_timers_num     = (); # list of numbers of existing timer numbers matching SERVICE token
my %d_timers_entries = (); # hash with DVR timer pointers (key: number)

my %d_timers_action  = (); # hash with DVR timer actions
my @d_timers_new     = (); # hash with timer_hp to add
my %s_timers_action  = (); # hash with SERVICE timer actions

## Create existing DVR timer list
for (my $a = 0; $a < scalar(@timers_dvr); $a++) {
	my $entry_hp = $timers_dvr[$a];

	# debugging/blacklist
	if (defined $opt_K) {
		if (grep /^$$entry_hp{'tid'}$/, split(",", $opt_K)) {
			logging("NOTICE", "SERVICE/DVR: skip DVR timer (blacklisted by option -K): " . $$entry_hp{'tid'});
			next;
		};
	};

	push @d_timers_num, $$entry_hp{'tid'};
	$d_timers_entries{$$entry_hp{'tid'}} = $timers_dvr[$a];
};

if (scalar(@d_timers_num) > 0) {
	logging("DEBUG", "SERVICE/DVR: following DVR timers found matching SERVICE token (amount: " . scalar(@d_timers_num) . "): " . join(" ", @d_timers_num));
};


## create SERVICE timer list to check/add
for (my $a = 0; $a < scalar(@timers_service); $a++) {
	my $entry_hp = $timers_service[$a];

	# debugging/blacklist
	if (defined $opt_E) {
		if (grep /^$$entry_hp{'tid'}$/, split(",", $opt_E)) {
			logging("NOTICE", "SERVICE/DVR: skip SERVICE timer (blacklisted by option -E): " . $$entry_hp{'tid'});
			next;
		};
	};

	push @s_timers_num, $$entry_hp{'tid'};
	$s_timers_entries{$$entry_hp{'tid'}} = $timers_service[$a];
};

if (scalar(@s_timers_num) > 0) {
	logging("DEBUG", "SERVICE/DVR: following SERVICE timers need to check/add (amount: " . scalar(@s_timers_num) . "): " . join(" ", @s_timers_num));
};

## check timers from DVR
my @d_timers_num_skipped;
foreach my $d_timer_num (sort { $d_timers_entries{$a}->{'start_ut'} <=> $d_timers_entries{$b}->{'start_ut'}} @d_timers_num) {
	my $d_timer_hp = $d_timers_entries{$d_timer_num};

	# skip DVR timers in the past
	if ($$d_timer_hp{'stop_ut'} < time()) {
		logging("DEBUG", "SERVICE/DVR: skip DVR timer - stop time in the past: tid=" . $$d_timer_hp{'tid'});
		push @d_timers_num_skipped, $d_timer_num;
		next;
	} elsif ($$d_timer_hp{'start_ut'} < time()) {
		logging("DEBUG", "SERVICE/DVR: skip DVR timer - start time in the past: tid=" . $$d_timer_hp{'tid'});
		push @d_timers_num_skipped, $d_timer_num;
		next;
	};

	logging("DEBUG", "SERVICE/DVR: existing DVR timer"
		. " tid="    . sprintf("%-2d", $d_timer_num)
		. " cid="    . sprintf("%-3d",$$d_timer_hp{'cid'})
		. " start="  . strftime("%Y%m%d-%H%M", localtime($$d_timer_hp{'start_ut'}))
		. " stop="   . strftime("%Y%m%d-%H%M", localtime($$d_timer_hp{'stop_ut'}))
		. " title='" . $$d_timer_hp{'title'} . "'"
		. " cname='" . get_dvr_channel_name_by_cid($$d_timer_hp{'cid'}) . "'"
		. " s_d="    . $$d_timer_hp{'service_data'}
		. " d_d="    . $$d_timer_hp{'dvr_data'}
	);
};

## check timers from SERVICE against existing DVR timers
my @s_timers_num_found;
my @d_timers_num_found;

foreach my $s_timer_num (sort { $s_timers_entries{$a}->{'start_ut'} <=> $s_timers_entries{$b}->{'start_ut'} } @s_timers_num) {
	my $s_timer_hp = $s_timers_entries{$s_timer_num};

	# skip SERVICE timers in the past
	if ($$s_timer_hp{'stop_ut'} < time()) {
		$s_timers_action{$s_timer_num} = "skip/stop-in-past";
		logging("DEBUG", "SERVICE/DVR: skip SERVICE timer - stop time in the past: tid=" . $$s_timer_hp{'tid'});
		next;
	} elsif ($$s_timer_hp{'start_ut'} < time()) {
		$s_timers_action{$s_timer_num} = "skip/start-in-past";
		logging("DEBUG", "SERVICE/DVR: skip SERVICE timer - start time in the past: tid=" . $$s_timer_hp{'tid'});
		next;
	};

	logging("DEBUG", "SERVICE/DVR: possible new timer tid=" . $s_timer_num . ":"
		. " s_cid="  . $$s_timer_hp{'cid'}
		. " d_cid="  . $service_cid_to_dvr_cid_map{$$s_timer_hp{'cid'}}->{'cid'} 
		. " start="  . strftime("%Y%m%d-%H%M", localtime($$s_timer_hp{'start_ut'}))
		. " stop="   . strftime("%H%M", localtime($$s_timer_hp{'stop_ut'}))
		. " title='" . $$s_timer_hp{'title'} . "'"
	);

	foreach my $d_timer_num (sort { $d_timers_entries{$a}->{'start_ut'} <=> $d_timers_entries{$b}->{'start_ut'} } @d_timers_num) {
		next if (grep /^$d_timer_num$/, @d_timers_num_found); # already found
		next if (grep /^$d_timer_num$/, @d_timers_num_skipped); # already 

		my $d_timer_hp = $d_timers_entries{$d_timer_num};

		logging("TRACE", "MATCH: Check against existing timer #$d_timer_num:"
			. " d_cid="        . $$d_timer_hp{'cid'} 
			. " start="        . strftime("%Y%m%d-%H%M%S", localtime($$d_timer_hp{'start_ut'}))
			. " stop="         . strftime("%Y%m%d-%H%M%S", localtime($$d_timer_hp{'stop_ut'}))
			. " title='"       . $$d_timer_hp{'title'} . "'"
			. " service_data=" . $$d_timer_hp{'service_data'}
		);

		if (	($$d_timer_hp{'start_ut'} == $$s_timer_hp{'start_ut'})
		     &&	($$d_timer_hp{'stop_ut'}  == $$s_timer_hp{'stop_ut'})
		     && ($service_cid_to_dvr_cid_map{$$s_timer_hp{'cid'}}->{'cid'} == $$d_timer_hp{'cid'})
			) {

			push @s_timers_num_found, $s_timer_num;
			push @d_timers_num_found, $d_timer_num;

			if ($$s_timer_hp{'service_data'} eq $$d_timer_hp{'service_data'}) {
				logging("DEBUG", "MATCH(channel/time/s_d) SERVICE"
					. " tid=" . $$s_timer_hp{'tid'}
					. " cid=" . $$s_timer_hp{'cid'}
					. " s_d=" . $$s_timer_hp{'service_data'}
					. " <=> DVR"
					. " tid=" . $$d_timer_hp{'tid'}
					. " cid=" . $$d_timer_hp{'cid'}
					. " s_d=" . $$d_timer_hp{'service_data'}
				);
			} elsif (grep /^$$s_timer_hp{'service_data'}$/, split(",", $$d_timer_hp{'service_data'})) { 
				logging("DEBUG", "MATCH(channel/time/s_d-included) SERVICE"
					. " tid=" . $$s_timer_hp{'tid'}
					. " cid=" . $$s_timer_hp{'cid'}
					. " s_d=" . $$s_timer_hp{'service_data'}
					. " <=> DVR"
					. " tid=" . $$d_timer_hp{'tid'}
					. " cid=" . $$d_timer_hp{'cid'}
					. " s_d=" . $$d_timer_hp{'service_data'}
				);
			} else {
				logging("INFO", "MATCH(channel/time) NO-MATCH(su) SERVICE"
					. " tid=" . $$s_timer_hp{'tid'}
					. " cid=" . $$s_timer_hp{'cid'}
					. " s_d=" . $$s_timer_hp{'service_data'}
					. " <=> DVR"
					. " tid=" . $$d_timer_hp{'tid'}
					. " cid=" . $$d_timer_hp{'cid'}
					. " s_d=" . $$d_timer_hp{'service_data'}
					. " UPDATE_REQUIRED (add s_d/d_d)"
				);
				# extend service_data & dvr_data
				$d_timers_action{$d_timer_num}->{'modify'}->{'service_data'} = join(",", sort split(",", $$s_timer_hp{'service_data'} . "," . $$d_timer_hp{'service_data'}));
				$d_timers_action{$d_timer_num}->{'modify'}->{'dvr_data'} = join(",", sort split(",", $config{'service.user'} . ":folder:" . $config{'dvr.folder'} . "," . $$d_timer_hp{'dvr_data'}));
			};
			last;
		};
	};
};

## check for timers provided by SERVICE not found in DVR
# create helper hash
my %channels_lookup_by_cid;
foreach my $channel_hp (@channels_dvr) {
	$channels_lookup_by_cid{$$channel_hp{'cid'}}->{'timerange'} = $$channel_hp{'timerange'};
};

if (scalar(@s_timers_num) > scalar(@s_timers_num_found)) {
	foreach my $s_timer_num (@s_timers_num) {
		next if (grep /^$s_timer_num$/, @s_timers_num_found); # skip if already in found list

		if ((defined $s_timers_action{$s_timer_num}) && ($s_timers_action{$s_timer_num} =~ /^skip/o)) {
			# skip if marked with skip
		};

		my $s_timer_hp = $s_timers_entries{$s_timer_num};

		my $loglevel;
		my $action_text;

		if (defined $service_cid_to_dvr_cid_map{$$s_timer_hp{'cid'}}->{'cid'}) {
			$loglevel = "INFO";

			# default
			$action_text = "TODO-ADD";
			$s_timers_action{$s_timer_num} = "add";

			my $timer_start = strftime("%H%M", localtime($$s_timer_hp{'start_ut'}));
			my $timer_stop  = strftime("%H%M", localtime($$s_timer_hp{'stop_ut'}));

			my $d_timer_cid = $service_cid_to_dvr_cid_map{$$s_timer_hp{'cid'}}->{'cid'};

			## check whether channel is only available in a timerange
			if (defined $channels_lookup_by_cid{$d_timer_cid}->{'timerange'}) {
				logging("DEBUG", "SERVICE/DVR: timer found with expanded channel:"
					. " tid="   . $$s_timer_hp{'tid'}
					. " cid="   . $$s_timer_hp{'cid'}
					. " start=" . $timer_start
					. " stop="  . $timer_stop
				);

				my $match = 0;
				my ($channel_start, $channel_stop) = split("-", $channels_lookup_by_cid{$d_timer_cid}->{'timerange'}, 2);

				if ($channel_stop > $channel_start) {
					# e.g. 0600-2059
					if (($timer_start >= $channel_start) && ($timer_start <= $channel_stop)) {
						if ($timer_stop <= $channel_stop) {
							$match = 1; #ok
						} else {
							$match = 2; # stop is out-of-range
						};
					};
				} else {
					# e.g. 2100-0559
					if (($timer_start >= $channel_start) || ($timer_start <= $channel_stop)) {
						if (($timer_stop >= $channel_start) || ($timer_stop <= $channel_stop)) {
							$match = 1; #ok
						} else {
							$match = 2; # stop is out-of-range
						};
					};
				};

				# remove sub-channel number
				my $d_timer_cid_main = $d_timer_cid;
				$d_timer_cid_main =~  s/#.*$//o;

				if ($match == 1) {
					logging("DEBUG", "SERVICE/DVR: selected channel of timer is included in timerange");
				} elsif ($match == 2) {
					logging("DEBUG", "SERVICE/DVR: stop time of timer out of expanded channel timerange");
				} else {
					logging("DEBUG", "SERVICE/DVR: start time of timer out of expanded channel timerange");
					$loglevel = "WARN";
					$s_timers_action{$s_timer_num} = "skip/out-of-channel-timerange";
					$action_text = "SKIP - CHANNEL-MISSING-IN-DVR:NOT-IN-TIMERANGE:";
					$action_text .= " " . get_service_channel_name_by_cid($$s_timer_hp{'cid'});
					$action_text .= " <=> " . get_dvr_channel_name_by_cid($d_timer_cid_main);
					$action_text .= " " . $channels_lookup_by_cid{$d_timer_cid}->{'timerange'};
				};
			};
		} else {
			$loglevel = "WARN";
			$action_text = "SKIP - CHANNEL-MISSING-IN-DVR:";
			$action_text .= get_service_channel_name_by_cid($$s_timer_hp{'cid'});
			$s_timers_action{$s_timer_num} = "skip/missing-channel";
		};

		logging($loglevel, "SERVICE/DVR: SERVICE timer not found in DVR:"
			. " tid="    . $$s_timer_hp{'tid'} 
			. " cid="    . $$s_timer_hp{'cid'} . "(" . get_service_channel_name_by_cid($$s_timer_hp{'cid'}) . ")"
			. " start="  . strftime("%Y%m%d-%H%M", localtime($$s_timer_hp{'start_ut'}))
			. " stop="   . strftime("%H%M", localtime($$s_timer_hp{'stop_ut'}))
			. " title='" . $$s_timer_hp{'title'} . "'"
			. " s_d="    . $$s_timer_hp{'service_data'}
			. " " . $action_text
		) if ($verbose > 0);
	};
} else {
	logging("DEBUG", "MATCH: all SERVICE timers found in DVR: " . $setup{'service'} . ":" . $config{'service.user'});
};

## check for timers found in DVR but not provided by SERVICE
if (scalar(@d_timers_num) > scalar(@d_timers_num_found)) {
	my $service_data = $setup{'service'} . ":" . $config{'service.user'};
	my $dvr_data_prefix = $config{'service.user'} . ":";

	foreach my $d_timer_num (@d_timers_num) {
		# already found?
		next if (grep /^$d_timer_num$/, @d_timers_num_found); 
		next if (grep /^$d_timer_num$/, @d_timers_num_skipped); 

		my $d_timer_hp = $d_timers_entries{$d_timer_num};

		logging("DEBUG", "SERVICE/DVR: DVR timer not found in SERVICE:"
			. " tid="    . $d_timer_num 
			. " cid="    . $$d_timer_hp{'cid'} 
			. " start="  . strftime("%Y%m%d-%H%M", localtime($$d_timer_hp{'start_ut'}))
			. " stop="   . strftime("%H%M", localtime($$d_timer_hp{'stop_ut'}))
			. " title='" . $$d_timer_hp{'title'} . "'"
			. " s_d="    . $$d_timer_hp{'service_data'}
		) if ($verbose > 0);

		if ($service_data eq $$d_timer_hp{'service_data'}) {
			logging("INFO", "SERVICE/DVR: DVR timer belongs only to " . $service_data . ":"
				. " tid=" . $$d_timer_hp{'tid'}
				. " cid=" . $$d_timer_hp{'cid'}
				. " s_d=" . $$d_timer_hp{'service_data'}
				. " TODO-DELETE"
			) if ($verbose > 0);
			$d_timers_action{$d_timer_num}->{'delete'} = 1;
		} elsif (grep /^$service_data$/, split(",", $$d_timer_hp{'service_data'})) { 
			logging("INFO", "SERVICE/DVR: DVR timer belongs also to " . $service_data . ":"
				. " tid=" . $$d_timer_hp{'tid'}
				. " cid=" . $$d_timer_hp{'cid'}
				. " s_d=" . $$d_timer_hp{'service_data'}
				. " TODO-REMOVE-FROM-SERVICE-DATA"
			);
			# remove from service_data
			$d_timers_action{$d_timer_num}->{'modify'}->{'service_data'} = join(",", sort (grep (!/^$service_data$/, split(",", $$d_timer_hp{'service_data'}))));
			# remove entries related to user from dvr_data
			$d_timers_action{$d_timer_num}->{'modify'}->{'dvr_data'} = join(",", sort (grep (!/^$dvr_data_prefix/, split(",", $$d_timer_hp{'dvr_data'}))));
		} else {
			logging("DEBUG", "SERVICE/DVR: DVR timer do not belong to " . $service_data . ":"
				. " tid=" . $$d_timer_hp{'tid'}
				. " cid=" . $$d_timer_hp{'cid'}
				. " s_d=" . $$d_timer_hp{'service_data'}
				. " NO-ACTION"
			);
		};
	};
} else {
	logging("DEBUG", "MATCH: all DVR timers found in SERVICE");
};

## display DVR actions
if (scalar(keys %d_timers_action) > 0) {
	foreach my $d_timer_num (sort { $a <=> $b } keys %d_timers_action) {
		my $d_timer_hp = $d_timers_entries{$d_timer_num};

		logging("INFO", "DVR-ACTION:"
			. " tid=" . $d_timer_num
			. " action=" . (keys(%{$d_timers_action{$d_timer_num}}))[0]
			. " start="  . strftime("%Y%m%d-%H%M", localtime($$d_timer_hp{'start_ut'}))
			. " stop="   . strftime("%H%M", localtime($$d_timer_hp{'stop_ut'}))
			. " cid="  . $$d_timer_hp{'cid'} . "(" . get_dvr_channel_name_by_cid($$d_timer_hp{'cid'}) . ")"
			. " title='" . $$d_timer_hp{'title'} . "'"
		);
	};
} else {
	logging("INFO", "DVR-ACTION: no actions found - nothing to do");
};

## final preparation of SERVICE actions
my $timers_skipped = 0;
if (scalar(keys %s_timers_action) > 0) {
	foreach my $s_timer_num (sort { $s_timers_action{$a} cmp $s_timers_action{$b} } sort { $a cmp $b } keys %s_timers_action) {
		my $loglevel;
		my $s_timer_hp = $s_timers_entries{$s_timer_num};

		if ($s_timers_action{$s_timer_num} eq "add") {
			$loglevel = "INFO";

			# copy timer
			my $serialized = freeze($s_timer_hp);
			my %d_timer = %{ thaw($serialized) };

			# add folder
			$d_timer{'dvr_data'} = $config{'service.user'} . ":folder:" . $config{'dvr.folder'};

			# change channel ID from SERVICE to DVR
			$d_timer{'cid'} = $service_cid_to_dvr_cid_map{$$s_timer_hp{'cid'}}->{'cid'};

			# remove sub-channel token
			$d_timer{'cid'} =~ s/#.*$//o;

			# add priority/lifetime
			$d_timer{'priority'} = $config{'dvr.priority'};
			$d_timer{'lifetime'} = $config{'dvr.lifetime'};

			push @d_timers_new, \%d_timer;

			logging($loglevel, "SERVICE-ACTION:"
				. " tid="     . $s_timer_num
				. " action="  . $s_timers_action{$s_timer_num}
				. " start="   . strftime("%Y%m%d-%H%M", localtime($$s_timer_hp{'start_ut'}))
				. " stop="    . strftime("%H%M", localtime($$s_timer_hp{'stop_ut'}))
				. " cid="     . $$s_timer_hp{'cid'} . "(" . get_service_channel_name_by_cid($$s_timer_hp{'cid'}) . ")"
				. " d_cid="     . $d_timer{'cid'} . "(" . get_dvr_channel_name_by_cid($d_timer{'cid'}) . ")"
				. " prio="    . $d_timer{'priority'}
				. " lft="     . $d_timer{'lifetime'}
				. " title='"  . shorten_titlename($$s_timer_hp{'title'}) . "'"
			);
		} else {
			$loglevel = "NOTICE";

			logging($loglevel, "SERVICE-ACTION:"
				. " tid="     . $s_timer_num
				. " action="  . $s_timers_action{$s_timer_num}
				. " start="   . strftime("%Y%m%d-%H%M", localtime($$s_timer_hp{'start_ut'}))
				. " stop="    . strftime("%H%M", localtime($$s_timer_hp{'stop_ut'}))
				. " cid="     . $$s_timer_hp{'cid'} . "(" . get_service_channel_name_by_cid($$s_timer_hp{'cid'}) . ")"
				. " title='"  . shorten_titlename($$s_timer_hp{'title'}) . "'"
			);

			if ($s_timers_action{$s_timer_num} =~ /^skip/o) {
				$timers_skipped++;
			};
		};
	};
} else {
	logging("INFO", "SERVICE-ACTION: no actions found - nothing to do");
};

if ((scalar(keys %d_timers_action) > 0) || (scalar(keys %s_timers_action) > 0)) {
	$rc = $module_functions{'dvr'}->{$setup{'dvr'}}->{'create_update_delete_timers'}(\@timers_dvr, \%d_timers_action, \@d_timers_new);
	logging(($rc > 0) ? "WARN" : "INFO", "result of DVR create/update/delete: " . $rc);
	logging("WARN", "timers skipped: " . $timers_skipped) if ($timers_skipped > 0);
} else {
	logging("INFO", "finally nothing to do");
};

exit(0);
