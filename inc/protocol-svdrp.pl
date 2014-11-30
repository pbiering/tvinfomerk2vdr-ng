# Project: tvinfomerk2vdr-ng.pl
#
# Support functions for SVDRP backends like VDR API
#
# (C) & (P) 2014 - 2014 by by Peter Bieringer <pb@bieringer.de>
#
# SVDRP related code taken from file: inc/helperfunc
#   Original (C) & (P) 2003 - 2007 by <macfly> / Friedhelm Büscher in "tvmovie2vdr"
#   last public release: http://rsync16.de.gentoo.org/files/tvmovie2vdr/tvmovie2vdr-0.5.13.tar.gz
#
# License: GPLv2
#
# Authors:
#  Peter Bieringer (bie)
#  <macfly> / Friedhelm Büscher (SVDRP related code) from inc/helperfunc
#
# Changelog:
# 20141106/bie: partially takeover from tvinfomerk2vdr-ng.pl, more abstraction
# 20141122/bie: import SVDRP related code from inc/helperfunc, minor cleanup

use strict;
use warnings;
use utf8;

use Data::Dumper;
use POSIX qw(strftime);
use IO::Socket::INET;

binmode(STDOUT, ":utf8");
binmode(STDERR, ":utf8");

## debug/trace information
our %traceclass;
our %debugclass;

## global variables
our $progname;
our $progversion;
our %setup;

# todo: replace by config
our $prio;
our $lifetime;

## local variables
my $SVDRP;


################################################################################
################################################################################
# get channels via SVDRP
# arg1: pointer to channel array
# arg2: URL of channels source
# debug
# trace:   print contents using Dumper
# 	 2=print raw contents
#        
################################################################################
sub protocol_svdrp_get_channels($$;$) {
	my $channels_ap = $_[0];
	my $channels_source_url = $_[1];
	my $channels_file_write_raw = $_[2];

	#print "DEBUG : channels_source_url=$channels_source_url channels_file_write_raw=$channels_file_write_raw\n" if defined ($debugclass{'HTSP'});

	$channels_source_url =~ /^(file|svdrp):\/\/(.*)$/o;

	if (! defined $1 || ! defined $2) {
		die "Unsupported channels_source_url=$channels_source_url";
	};

	my $source = $1;
	my $location = $2;

	my @channels_raw;

	undef @$channels_ap;

	if ($source eq "file") {
		logging("DEBUG", "read SVDRP raw contents of channels from file: " . $location);
		if(!open(FILE, "<$location")) {
			logging("ERROR", "can't read SVDR raw contents of channels from file: " . $location);
			exit(1);
		};
		while(<FILE>) {
			chomp($_);
			push @channels_raw, $_ unless($_ =~ /^#/o);
		};
		close(FILE);
		logging("DEBUG", "VDR: amount of channels read from file: " . scalar(@channels_raw));
	} else {
		my ($Dest, $Port) = split /:/, $location;
		my $sim = 0;
		my $verbose = 0;

		logging("DEBUG", "VDR: try to read channels via SVDRP from host: $Dest:$Port");

		$SVDRP = SVDRP->new($Dest,$Port,$verbose,$sim);

		$SVDRP->command("lstc");

		while($_ = $SVDRP->readoneline) {
			chomp;
			logging("TRACE", "received raw channel line: " . $_);
			push @channels_raw, $_;
		};

		$SVDRP->close;
		
		if (scalar(@channels_raw) == 0) {
			logging("ERROR", "VDR: no channels received via SVDRP");
			exit 1;
		} else {
			logging("DEBUG", "VDR: amount of channels received via SVDRP: " . scalar(@channels_raw));
		};

		if (defined $channels_file_write_raw) {
			logging("NOTICE", "SVDRP write raw channels contents to file: " . $channels_file_write_raw);
			open(FILE, ">$channels_file_write_raw") || die;

			foreach my $line (@channels_raw) {
				print FILE $line . "\n";
			};

			close(FILE);
			logging("NOTICE", "SVDR raw contents of channels written to file written: " . $channels_file_write_raw);
		};
	};

	foreach my $line (@channels_raw) {
		logging("DEBUG", "SVDRP: parse raw channel line: " . $line);

		my ($vdr_id, $temp) = split(/ /, $line, 2);
		my ($name, $frequency, $polarization, $source, $symbolrate, $vpid, $apid, $tpid, $ca, $service_id, $nid, $tid, $rid) = split(/\:/, $temp);

		my $type = "SD"; # default

		if (! defined $name) {
			# skip if not defined: name
			next;
		};

		my $vpid_extracted;

		if ($vpid =~ /^([0-9]+)(\+[^=]+)?=([0-9]+)$/) {
			$vpid_extracted = $1;
			if ($3 != 2) {
				$type = "HD";
			}
		} elsif ($vpid =~ /^([0-9]+)$/) {
			# fallback
			$vpid_extracted = $1;
		};

		if ($vpid_extracted eq "0" || $vpid_extracted eq "1") {
			# skip (encrypted) radio channels
			logging("TRACE", "ChannelPrep: skip VDR channel(radio): " . sprintf("%4d / %s", $vdr_id, $name));
			next;
		};

		# split name and group (aka provider)
		my $group;
		($name, $group) = split /;/, encode("iso-8859-1", decode("utf8", $name)), 2;

		if (! defined $group) {
			next;
		};

		if ($name eq "." || $name eq "" || $group eq "." || $group eq "") {
			next;
		};

		my @altnames;
		$name =~ /^([^,]+),(.*)/o;
		if (defined $2) {
			# name has alternatives included
			$name = $1;
			@altnames = split /,/, $2;
		};

		# skip channel names which have only numbers
		if ($name =~ /^[0-9]+$/o) {
			next;
		};

		# convert CA
		if ($ca ne "0") {
			$ca = 1;
		};

		logging("DEBUG", "SVDRP: found channel"
		. " name='"  . $name . "'"
		. " altnames='"  . join("|", @altnames) . "'"
		. " group='" . $group . "'"
		. " type="   . $type
		. " ca="     . $ca
		. " sid="    . $service_id
		. " cid="    . $vdr_id
		);

		push @$channels_ap, {
			'name'     => $name,
			'altnames' => join("|", @altnames),
			'group'    => $group,
			'type'     => $type,
			'ca'       => $ca,
			'source'   => substr($source, 0, 1),
			'sid'      => $service_id,
			'cid'      => $vdr_id,
		};
	};
};


################################################################################
################################################################################
# get timers via SVDRP
# arg1: pointer to timer array
# arg2: URL of timer source
# debug
# trace:   print contents using Dumper
# 	 2=print raw contents
#        
################################################################################
sub protocol_svdrp_get_timers($$;$) {
	my $timers_ap = $_[0];
	my $timers_source_url = $_[1];
	my $timers_file_write_raw = $_[2];

	#print "DEBUG : timers_source_url=$timers_source_url timers_file_write_raw=$timers_file_write_raw\n" if defined ($debugclass{'HTSP'});

	$timers_source_url =~ /^(file|svdrp):\/\/(.*)$/o;

	if (! defined $1 || ! defined $2) {
		die "Unsupported timers_source_url=$timers_source_url";
	};

	my $source = $1;
	my $location = $2;

	my @timers_raw;

	undef @$timers_ap;

	if ($source eq "file") {
		logging("DEBUG", "read SVDRP raw contents of timers from file: " . $location);
		if(!open(FILE, "<$location")) {
			logging("ERROR", "can't read SVDR raw contents of timers from file: " . $location);
			exit(1);
		};
		while(<FILE>) {
			chomp($_);
			push @timers_raw, $_ unless($_ =~ /^#/o);
		};
		close(FILE);
		logging("DEBUG", "VDR: amount of timers read from file: " . scalar(@timers_raw));
	} else {
		my ($Dest, $Port) = split /:/, $location;
		my $sim = 0;
		my $verbose = 0;

		logging("DEBUG", "VDR: try to read timers via SVDRP from host: $Dest:$Port");

		my $SVDRP = SVDRP->new($Dest,$Port,$verbose,$sim);

		$SVDRP->command("lstt");

		while($_ = $SVDRP->readoneline) {
			chomp;
			push @timers_raw, $_;
		};

		$SVDRP->close;

		if (scalar(@timers_raw) == 0) {
			logging("ERROR", "VDR: no timers received via SVDRP");
			exit 1;
		} else {
			logging("DEBUG", "VDR: amount of timers received via SVDRP: " . scalar(@timers_raw));
		};

		
		if (defined $timers_file_write_raw) {
			logging("NOTICE", "SVDRP write raw timers contents to file: " . $timers_file_write_raw);
			open(FILE, ">$timers_file_write_raw") || die;

			foreach my $line (@timers_raw) {
				print FILE $line . "\n";
			};

			close(FILE);
			logging("NOTICE", "SVDR raw contents of timers written to file written: " . $timers_file_write_raw);
		};
	};

	foreach my $line (@timers_raw) {
		$line = encode("iso-8859-1", decode("utf8", $line));

		logging("TRACE", "parse raw timer line: " . $line);

		last if($line =~ /^No timers defined/o);

		my ($id, $temp) = split(/ /, $line, 2);
		my ($tmstatus, $vdr_id, $dor, $start, $stop, $prio, $lft, $title, $summary) = split(/\:/, $temp, 9);

		# convert dor,start,end to unixtime
		my $start_ut = UnixDate(ParseDate($dor . " " . substr($start, 0, 2) . ":" . substr($start, 2, 2)), "%s");

		my $stop_ut;

		if ($stop > $start) {
			$stop_ut  = UnixDate(ParseDate($dor . " " . substr($stop, 0, 2) . ":" . substr($stop, 2, 2)), "%s");
		} else {
			# shift to next day but same hh:mm
			my $dor_stop = strftime("%Y%m%d", localtime(UnixDate(ParseDate($dor . " " . substr($stop, 0, 2) . ":" . substr($stop, 2, 2)), "%s") + 23*60*60)); # add 23 hours to catch DST
			$stop_ut  = UnixDate(ParseDate($dor_stop . " " . substr($stop, 0, 2) . ":" . substr($stop, 2, 2)), "%s");
		};

		logging("DEBUG", "SVDRP: found timer"
			. " tid="          . sprintf("%3d", $id)
			. " cid="          . sprintf("%3d", $vdr_id)
			. " date="         . $dor
			. " start="        . $start . " (" . strftime("%Y%m%d-%H%M", localtime($start_ut)) . ")"
			. " end="          . $stop  . " (" . strftime("%Y%m%d-%H%M", localtime($stop_ut)) . ")"
			. " title='"       . $title . "'"
			. " summary='"     . $summary . "'"
		);

		push @$timers_ap, {
			'tid'          => $id,
			'cid'          => $vdr_id,
			'start_ut'     => $start_ut,
			'stop_ut'      => $stop_ut,
			'title'        => $title,
			'summary'      => $summary,
		};
	};

	logging("DEBUG", "SVDR: amount of timers parsed: " . scalar(@$timers_ap));
	return 0;
};


################################################################################
################################################################################
# delete timer via SVDRP
# arg1: point to array of timer numbers to delete
# arg2: point to array of timer pointers to add
# arg3: URL of destination of actions
#        
################################################################################
sub protocol_svdrp_delete_add_timers($$) {
	my $timers_num_delete_ap = $_[0];
	my $timers_add_ap = $_[1];
	my $timers_destination_url = $_[2];

	$timers_destination_url =~ /^(file|svdrp):\/\/(.*)$/o;

	if (! defined $1 || ! defined $2) {
		die "Unsupported timers_destinatino_url=$timers_destination_url";
	};

	my $destination = $1;
	my $location = $2;

	my %counters;

	## create SVDRP command list
	my @commands_svdrp;

	# delete timers
	foreach my $num (@$timers_num_delete_ap) {
		push @commands_svdrp, "delt $num";
		$counters{'del'}++ if ($destination eq "file");
	};

	# add timers
	foreach my $timer_hp (@$timers_add_ap) {
		push @commands_svdrp, "newt 1"
			. ":" . $$timer_hp{'cid'}
			. ":" . strftime("%Y-%m-%d", localtime($$timer_hp{'start_ut'}))
			. ":" . strftime("%H%M", localtime($$timer_hp{'start_ut'}))
			. ":" . strftime("%H%M", localtime($$timer_hp{'stop_ut'}))
			. ":" . $prio
			. ":" . $lifetime
			. ":" . $$timer_hp{'title'}
			. ":" . $$timer_hp{'summary'};
		$counters{'add'}++ if ($destination eq "file");
	};

	if ($destination eq "file") {
		open(FILE, ">$location") || die;
		logging("DEBUG", "SVDRP: write raw contents of timer actions to file: " . $location);
		foreach my $line (@commands_svdrp) {
			print FILE $line . "\n";
		};
		close(FILE);
		logging("INFO", "SVDRP: raw contents of timer actions written to file: " . $location);
	} else {
		my ($Dest, $Port) = split /:/, $location;
		my $sim = 0;
		my $verbose = 0;

		logging("DEBUG", "SVDRP: try to execute actions on host: $Dest:$Port");

		my $SVDRP = SVDRP->new($Dest,$Port,$verbose,$sim);

		foreach my $line (@commands_svdrp) {
			logging("DEBUG", "SVDRP: send line: " . $line);
			my ($result) = $SVDRP->SendCMD($line);
			logging("DEBUG", "SVDRP: received result: " . $result);

			if ($line =~ /^delt /o) {
				if ($result =~ m/^Timer "(\d+)" deleted$/o) {
					logging("INFO", "SVDRP: delete of timer was successful: " . $result);
					$counters{'del'}++;
				} else {
					logging("ERROR", "SVDRP: delete of timer was not successful: " . $result);
					$counters{'delete-failed'}++;
				};
			} elsif ($line =~ /^newt /o) {
				if ($result =~ m/^(\d+)\s+1:/o) {
					logging("INFO", "SVDRP: successful programmed timer: #$1 $line");
					$counters{'add'}++;
				} else {
					logging("ERROR", "SVDRP: problem programming new timer: $result");
					$counters{'add-failed'}++;
				}
			} else {
				die "Unsupported line: $line";
			};
		};

		$SVDRP->close;
	};

	my $summary = "";
	foreach my $key (keys %counters) {
		$summary .= " " . $key . "=" . $counters{$key};
	};

	logging("INFO", "SVDRP: summary timers" . $summary);
	return 0;
};


###############################################################################
# BEGIN OF IMPORTED CODE - with some cleanups
###############################################################################
# Original (C) & (P) 2003 - 2007 by <macfly> / Friedhelm Büscher as inc/helperfunc in "tvmovie2vdr"
#   last public release: http://rsync16.de.gentoo.org/files/tvmovie2vdr/tvmovie2vdr-0.5.13.tar.gz
#
package SVDRP;

my ($Dest, $Port);

sub CRLF       () { main::CRLF(); };

my($SOCKET, $EPGSOCKET, $query, $connected);

sub new {
	my $invocant = shift;
	$Dest = shift;
	$Port = shift;
	my $verbose = shift;
	my $sim = shift;
	my $class = ref($invocant) || $invocant;
	my $self = { };
	bless($self, $class);
	my $connected = 0;
	my $query = 0;
	return $self;
}

sub myconnect {
	my $this = shift;

		$SOCKET = IO::Socket::INET->new(
			PeerAddr => $Dest, 
			PeerPort => $Port, 
			Proto => 'tcp'
		) or die;

		my $line;
		$line = <$SOCKET>;
		$connected = 1;
}

sub close {
	my $this = shift;
	if($connected == 1) {
		command($this, "quit");
		readoneline($this);
		close $SOCKET if $SOCKET;
		$connected = 0;
	}
}

sub command {
	my $this = shift;
	my $cmd = join("", @_);

	if((!defined $connected) || ($connected == 0)) {
		myconnect($this);
	}
	
	$cmd = $cmd . CRLF;
	if($SOCKET) {
		use bytes;
		my $result = send($SOCKET, $cmd, 0);
		if($result != length($cmd)) {
		} else {
			$query = 1;
		}
		no bytes;
	}
}

sub readoneline {
	my $this = shift;
	my $line;

	if(($connected == 1) and ($query == 1)) {
		$line = <$SOCKET>;
		$line =~ s/\r\n$//;
		if(substr($line, 3, 1) ne "-") {
			$query = 0;
		}
		$line = substr($line, 4, length($line));

		return($line);
	} else { 
		return undef; 
	}
}

sub SendCMD {
	my $this = shift;
	my $cmd = join("", @_); 
	my @output;

	command($this, $cmd);
	while($_ = readoneline($this)) {
		push(@output, $_);
	}
	return(@output);
}

###############################################################################
# END OF IMPORTED CODE
###############################################################################

#### END
return 1;
