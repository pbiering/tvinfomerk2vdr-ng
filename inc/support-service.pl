# Project: tvinfomerk2vdr-ng.pl
#
# Support functions for service
#
# (C) & (P) 2020-2023 by by Peter Bieringer <pb@bieringer.de>
#
# License: GPLv2
#
# Authors:
#  Peter Bieringer (bie)
#
# Changelog:
# 20201205/bie: new
# 20230515/bie: add reformat_date_time

use strict;
use warnings;
use utf8;

binmode(STDOUT, ":utf8");
binmode(STDERR, ":utf8");

our $debug;
our %debug_class;
our %traceclass;

###############################################################################
## Functions
###############################################################################

###############################################################################
## fix double UTF-8 encoding
###############################################################################
sub fix_utf8_encoding($) {
	my $text_input = $_[0];

	#my $text_output = encode("iso-8859-1", decode("utf8", $text_input));
	my $text_output = $text_input;

	if (defined $traceclass{'SUPPORT'} && ($traceclass{'SUPPORT'} & 0x01)) {
		print "#### DATA BEGIN ####\n";
		print Dumper($text_input);
		print "#### IN -> OUT  ####\n";
		print Dumper($text_output);
		print "#### DATA END   ####\n";
	};

	return($text_output);
};


###############################################################################
## reformat date/time
###############################################################################
sub reformat_date_time($$) {
	# %d.%d.%d -> %Y-%m-%d
	$_[0] =~ /^(\d+)\.(\d+)\.(\d+)$/o;
	my $date = sprintf("%04d-%02d-%02d", $3, $2, $1);

	# %d:%d:%d -> %H:%M:%S
	$_[1] =~ /^(\d+):(\d+):(\d+)$/o;
	my $time = sprintf("%02d:%02d:%02d", $1, $2, $3);

	return $date . " " . $time;
};


#### END
return 1;
