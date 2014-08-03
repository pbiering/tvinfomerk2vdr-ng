#### Settings for tvinfomerk2vdr-ng.pl

### VDR related

## VDR setup.conf
our $setupfile = "/etc/vdr/setup.conf";

## VDR timer options for TVinfo
our $tvinfoprefix = "(Timer von TVInfo)"; # Not recommended to change
our $prio = "99";
our $lifetime = "99";

#our $MarginStart = 10; # taken from VDR setup.conf
#our $MarginStop = 10; # taken from VDR setup.conf

### TVinfo related

## Internet access
our $http_proxy = "";                   # example: http://172.16.1.1:3128/
our $networktimeout = 30;		# networktimeout in seconds.

## TVinfo related
our $http_base = "http://www.tvinfo.de/"; # Not recommended to change

## TVinfo credentials (see also tvinfomerk2vdr-ng-wrapper.sh)
our $username = "<TODO>"; # can be also provided via option (-u ...)
our $password = "<TODO>"; # can be also provided via option (-p ...)

### TVinfo->VDR Channel Mapping

## Channel mapping
our $skip_ca_channels = 1;		# 0=check also CA channels, 1=exclude CA channels from mapping
our $whitelist_ca_groups = "";		# CA groups separated by "," which are whitelisted

# example:
#our $skip_ca_channels = 0;		# 0=check also CA channels, 1=exclude CA channels from mapping
#our $whitelist_ca_groups = "KabelKiosk,Sky";	# CA groups separated by "," which are whitelisted
						# also known: MTV Networks Europe,ProSiebenSat.1,Eutelsat,TVP,CV Osteuropa
						# see also:  .... -C Channelmap 2>&1 |grep "not in whitelist"

return 1; # required for proper loading
