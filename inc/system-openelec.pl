# Project: tvinfomerk2vdr-ng.pl
#
# Support functions for system OPENELEC
#
# (C) & (P) 2014 - 2014 by by Peter Bieringer <pb@bieringer.de>
#
# License: GPLv2
#
# Authors:
#  Peter Bieringer (bie)
#
# Changelog:
# 20141029/bie: new

use strict;
use warnings;
use utf8;

## global variables
our $progname;
our $progversion;
our %config;

## activate module
our  @system_list_supported;
push @system_list_supported, "openelec";
our %module_functions;
$module_functions{'system'}->{'openelec'}->{'autodetect'} = \&system_openelec_autodetect;

## debug/trace information
our %traceclass;
our %debugclass;

###############################################################################
#### Autodetection
#################################################################################
sub system_openelec_autodetect() {
	return 0;
};


#### END
return 1;
