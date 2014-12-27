# Logging functions for tvinfomerk2vdr-ng.pl
#
# (C) & (P) 2014 - 2014 by by Peter Bieringer <pb@bieringer.de>
#
# License: GPLv2
#
# Authors:
#  Peter Bieringer (bie)
#
# Changelog:
# 20141107/bie: extracted from tvinfomerk2vdr-ng.pl

use strict;
use warnings;
use utf8;

use Sys::Syslog;

binmode(STDOUT, ":utf8");
binmode(STDERR, ":utf8");

## debug/trace information
our %traceclass;
our %debugclass;

### global values
our $progname;
our $progversion;
our %config;

# TODO: migrate
our $debug;
our $opt_T;
our $opt_S;
our $opt_L;
our %debug_class;
our @logging_summary;
our $logging_highestlevel = 7;

## local variables
my %debug_suppressed;


###############################################################################
## Functions
###############################################################################

## Logging
my $syslog_status = 0;

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
			if ($_[1] =~ /^$key:/ && ($debug_class{$key} == 0)) {
				$debug_suppressed{$key}++;
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

		if ((defined $config{'service.user'}) && ($config{'service.user'} ne "<TODO>") && ($config{'service.user'} ne "")) {
			$message = $config{'service.user'} . ": " . $message;
		};	

		syslog($level, '%s', $message);
	} else {
		printf STDERR "%-6s: %s\n", $level, $message;
	};
};


sub logging_shutdown() {
	if ($debug != 0) {
		if (scalar (keys %debug_suppressed) > 0) {
			logging("DEBUG", "suppressed DEBUG/TRACE lines (enable with -C <class>[,<class>]):");
		};
		foreach my $key (sort keys %debug_suppressed) {
			logging("DEBUG", "suppressed lines of class: " . $key . ":" . $debug_suppressed{$key});
		};
	};
};
