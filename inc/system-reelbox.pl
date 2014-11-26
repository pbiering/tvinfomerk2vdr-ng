# Project: tvinfomerk2vdr-ng.pl
#
# Support functions for system REELBOX
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
use utf8;
use warnings;

## global variables
our $progname;
our $progversion;
our %config;

### activate module
our  @system_list_supported;
push @system_list_supported, "reelbox";
our %module_functions;
$module_functions{'system'}->{'reelbox'}->{'autodetect'} = \&system_reelbox_autodetect;

## debug/trace information
our %traceclass;
our %debugclass;

###############################################################################
### Autodetection
################################################################################
sub system_reelbox_autodetect() {
	return 0;
};

#### END
return 1;
