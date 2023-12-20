# Project: tvinfomerk2vdr-ng.pl
#
# Support functions for SVDRP backends like VDR API
#
# (C) & (P) 2014-2023 by by Peter Bieringer <pb@bieringer.de>
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
# 20141221/bie: improve split of raw channel line, fix bug in separating alternative names
# 20180921/bie: catch uninitialized "connected"
# 20190713/bie: fix UTF-8 conversion
# 20231220/bie: do not skip channel in case of group is missing, but set default "-"

use strict;
use warnings;
use utf8;

use Data::Dumper;
use POSIX qw(strftime);
use IO::Socket::INET;
use HTTP::Date;
use Date::Calc qw(Add_Delta_Days);

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

	$channels_source_url =~ /^(file|svdrp):\/\/(.*)$/o;

	if (! defined $1 || ! defined $2) {
		die "Unsupported channels_source_url=$channels_source_url - FIX CODE";
	};

	my $source = $1;
	my $location = $2;

	my @channels_raw;

	undef @$channels_ap;

	if ($source eq "file") {
		logging("DEBUG", "SVDRP: read raw contents of channels from file: " . $location);
		if(!open(FILE, "<$location")) {
			logging("ERROR", "SVDRP: can't read raw contents of channels from file: " . $location);
			return(1);
		};
		while(<FILE>) {
			chomp($_);
			push @channels_raw, $_ unless($_ =~ /^#/o);
		};
		close(FILE);
		logging("DEBUG", "SVDRP: amount of channels read from file: " . scalar(@channels_raw));
	} else {
		my ($Dest, $Port) = split /:/, $location;
		my $sim = 0;
		my $verbose = 0;

		logging("DEBUG", "SVDRP: try to read channels from host: $Dest:$Port");

		$SVDRP = SVDRP->new($Dest,$Port,$verbose,$sim);
		if (! defined $SVDRP) {
			logging("ERROR", "SVDRP: can't create handle");
			return(2);
		};

		$SVDRP->command("lstc");
		if ($SVDRP->connected() == 0) {
			logging("CRIT", "SVDRP: command not successful: lstc");
			return(1);
		};

		while($_ = $SVDRP->readoneline) {
			chomp;
			logging("TRACE", "SVDRP: received raw channel line: " . $_);
			push @channels_raw, $_;
		};

		$SVDRP->close;
		
		if (scalar(@channels_raw) == 0) {
			logging("ERROR", "SVDRP: no channels received");
			return(1);
		} else {
			logging("DEBUG", "SVDRP: amount of channels received: " . scalar(@channels_raw));
		};

		if (defined $channels_file_write_raw) {
			logging("NOTICE", "SVDRP write raw channels contents to file: " . $channels_file_write_raw);
			if (!open(FILE, ">$channels_file_write_raw")) {
				logging("ERROR", "SVDR: can't write raw contents of channels to file: ". $channels_file_write_raw . " (" . $! . ")");
				return(1);
			};
			foreach my $line (@channels_raw) {
				print FILE $line . "\n";
			};

			close(FILE);
			logging("NOTICE", "SVDR: raw contents of channels written to file written: " . $channels_file_write_raw);
		};
	};

	foreach my $line (@channels_raw) {
		# special char conversion
		$line =~ s/Ã¾/Ã¼/g;
		$line = encode("iso-8859-1", decode("utf8", $line));

		logging("TRACE", "SVDRP: parse raw channel line: " . $line);

		my ($vdr_id, $temp);
		if ($line =~ /^([0-9]+) (.*$)/o) {
			$vdr_id = $1;
			$temp = $2;
		} else {
			logging("WARN", "SVDRP: unsupported channel line format: " . $line);
			next;
		};

		my ($name, $frequency, $polarization, $source, $symbolrate, $vpid, $apid, $tpid, $ca, $service_id, $nid, $tid, $rid) = split(/\:/, $temp);

		logging("TRACE", "SVDRP: found name='" . $name . "'");

		my $type = "SD"; # default

		if (! defined $name) {
			# skip if not defined: name
			logging("TRACE", "SVDRP: skip channel(undefined name): " . sprintf("%4d", $vdr_id));
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
			logging("TRACE", "SVDRP: skip channel(radio): " . sprintf("%4d / %s", $vdr_id, $name));
			next;
		};

		# split name and group (aka provider)
		my $group;
		($name, $group) = split /;/, $name, 2;

		$group = "-" if (! defined $group);

		logging("TRACE", "SVDRP: splitted name='" . $name . "' group='" . $group . "'");

		if ($group eq "." || $group eq "") {
			logging("TRACE", "SVDRP: skip channel(group empty or dot): " . sprintf("%4d / %s", $vdr_id, $name));
			next;
		};

		if ($name eq "." || $name eq "") {
			logging("TRACE", "SVDRP: skip channel(name empty or dot): " . sprintf("%4d / %s", $vdr_id, $name));
			next;
		};

		my @altnames;
		if ($name =~ /^([^,]+),(.*)/o) {
			# name has alternatives included
			$name = $1;
			@altnames = split /,/, $2;
			logging("TRACE", "SVDRP: channel name has alternatives included: name='" . $name . "' altnames='" . join("|", @altnames) . "'");
		};

		# skip channel names which have only numbers
		if ($name =~ /^[0-9]+$/o) {
			logging("TRACE", "SVDRP: skip channel(only containing numbers): " . sprintf("%4d / %s", $vdr_id, $name));

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
		die "Unsupported timers_source_url=$timers_source_url - FIX CODE";
	};

	my $source = $1;
	my $location = $2;

	my @timers_raw;

	undef @$timers_ap;

	if ($source eq "file") {
		logging("DEBUG", "SVDRP: read raw contents of timers from file: " . $location);
		if(!open(FILE, "<$location")) {
			logging("ERROR", "SVDRP: can't read raw contents of timers from file: " . $location . " (" . $! . ")");
			return(1);
		};
		while(<FILE>) {
			chomp($_);
			push @timers_raw, $_ unless($_ =~ /^#/o);
		};
		close(FILE);
		logging("DEBUG", "SVDRP: amount of timers read from file: " . scalar(@timers_raw));
	} else {
		my ($Dest, $Port) = split /:/, $location;
		my $sim = 0;
		my $verbose = 0;

		logging("DEBUG", "SVDRP: try to read timers from host: $Dest:$Port");

		my $SVDRP = SVDRP->new($Dest,$Port,$verbose,$sim);
		if (! defined $SVDRP) {
			logging("ERROR", "SVDRP: can't create handle");
			return(2);
		};

		$SVDRP->command("lstt");
		if ($SVDRP->connected() == 0) {
			logging("CRIT", "SVDRP: command not successful: lstt");
			return(1);
		};

		while($_ = $SVDRP->readoneline) {
			chomp;
			push @timers_raw, $_;
		};

		$SVDRP->close;

		if (scalar(@timers_raw) == 0) {
			logging("ERROR", "SVDRP: no timers received");
			return(1);
		} else {
			logging("DEBUG", "SVDRP: amount of timers received: " . scalar(@timers_raw));
		};

		
		if (defined $timers_file_write_raw) {
			logging("NOTICE", "SVDRP write raw timers contents to file: " . $timers_file_write_raw);
			if (! open(FILE, ">$timers_file_write_raw")) {
				logging("ERROR", "SVDRP: can't open file for writing raw contents of timers: " . $timers_file_write_raw . " (" . $! . ")");
				return(1);
			};
			foreach my $line (@timers_raw) {
				print FILE $line . "\n";
			};

			close(FILE);
			logging("NOTICE", "SVDRP raw contents of timers written to file written: " . $timers_file_write_raw);
		};
	};

	foreach my $line (@timers_raw) {
		$line = encode("iso-8859-1", decode("utf8", $line));

		logging("TRACE", "SVDRP: parse raw timer line: " . $line);

		last if($line =~ /^No timers defined/o);

		my ($id, $temp) = split(/ /, $line, 2);
		my ($tmstatus, $vdr_id, $dor, $start, $stop, $prio, $lft, $title, $summary) = split(/\:/, $temp, 9);

		# check for supported day format
		if ($dor !~ /^([0-9]{4})-([0-9]{2})-([0-9]{2})$/o) {
			logging("NOTICE", "SVDRP: unsupported day format - skip tid=" . $id . " (" . $dor . ")");
			next;
		};

		# check timer status
		if ($tmstatus == 9) {
			#timers which are currently recording -> don't skip for now
			#logging("DEBUG", "SVDRP: timer is currently recording, skip tid=" . $id . " (tmstatus=" . $tmstatus . ")");
			#next;
		} elsif ($tmstatus != 1) {
			logging("DEBUG", "SVDRP: timer is not active/waiting for recording, skip tid=" . $id . " (tmstatus=" . $tmstatus . ")");
			next;
		};

		# convert dor,start,end to unixtime
		my $start_ut = str2time($dor . " " . substr($start, 0, 2) . ":" . substr($start, 2, 2) . ":00");

		my $stop_ut;

		if ($stop > $start) {
			$stop_ut  = str2time($dor . " " . substr($stop, 0, 2) . ":" . substr($stop, 2, 2) . ":00");
		} else {
			# shift to next day but same hh:mm
			$dor =~ /^([0-9]{4})-([0-9]{2})-([0-9]{2})$/o;
			my ($year,$month,$day) = Add_Delta_Days($1, $2, $3, 1);
			my $dor_stop = sprintf("%4d%02d%02d", $year, $month, $day);
			$stop_ut  = str2time($dor_stop . " " . substr($stop, 0, 2) . ":" . substr($stop, 2, 2) . ":00");
		};

		logging("DEBUG", "SVDRP: found timer"
			. " tid="          . sprintf("%3d", $id)
			. " cid="          . sprintf("%3d", $vdr_id)
			. " date="         . $dor
			. " start="        . $start . " (" . strftime("%Y%m%d-%H%M", localtime($start_ut)) . ")"
			. " end="          . $stop  . " (" . strftime("%Y%m%d-%H%M", localtime($stop_ut)) . ")"
			. " prio="  	   . $prio
			. " lft="	   . $lft
			. " title='"       . $title . "'"
			. " summary='"     . $summary . "'"
		);

		push @$timers_ap, {
			'tid'          => $id,
			'cid'          => $vdr_id,
			'start_ut'     => $start_ut,
			'stop_ut'      => $stop_ut,
			'priority'     => $prio,
			'lifetime'     => $lft,
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
#  arg1: point to array of timer numbers to delete
#  arg2: point to array of timer pointers to add
#  arg3: URL of destination of actions
################################################################################
sub protocol_svdrp_delete_add_timers($$;$) {
	my $timers_num_delete_ap = $_[0];
	my $timers_add_ap = $_[1];
	my $timers_destination_url = $_[2];

	$timers_destination_url =~ /^(file|svdrp):\/\/(.*)$/o;

	if (! defined $1 || ! defined $2) {
		die "Unsupported timers_destination_url=$timers_destination_url - FIX CODE";
	};

	my $destination = $1;
	my $location = $2;

	my %counters;

	my $rc = 0; # ok

	## create SVDRP command list
	my @commands_svdrp;

	# delete timers (highest first, otherwise sequence is destroyed)
	foreach my $num (sort {$b <=> $a} @$timers_num_delete_ap) {
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
			. ":" . $$timer_hp{'priority'}
			. ":" . $$timer_hp{'lifetime'}
			. ":" . $$timer_hp{'title'}
			. ":" . $$timer_hp{'summary'};
		$counters{'add'}++ if ($destination eq "file");
	};

	if ($destination eq "file") {
		if (!open(FILE, ">$location")) {
			logging("ERROR", "SVDRP: can't open file for writing raw contents of timer actions: " . $location . " (" . $! . ")");
			return(1);
		};
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
		if (! defined $SVDRP) {
			logging("ERROR", "SVDRP: can't create handle");
			$rc = 2; # problem
		};

		foreach my $line (@commands_svdrp) {
			logging("DEBUG", "SVDRP: send line: " . $line);
			my ($result) = $SVDRP->SendCMD($line);
			if ($SVDRP->connected() == 0) {
				logging("CRIT", "SVDRP: SendCMD not successful: " . $line);
				return(1);
			};
			logging("DEBUG", "SVDRP: received result: " . $result);

			if ($line =~ /^delt /o) {
				if ($result =~ m/^Timer "(\d+)" deleted$/o) {
					logging("INFO", "SVDRP: delete of timer was successful: " . $result);
					$counters{'del'}++;
				} else {
					logging("ERROR", "SVDRP: delete of timer was not successful: " . $result);
					$counters{'delete-failed'}++;
					$rc = 1; # problem
				};
			} elsif ($line =~ /^newt /o) {
				if ($result =~ m/^(\d+)\s+1:/o) {
					logging("INFO", "SVDRP: successful programmed timer: #$1 $line");
					$counters{'add'}++;
				} else {
					logging("ERROR", "SVDRP: problem programming new timer: $result");
					$counters{'add-failed'}++;
					$rc = 1; # problem
				}
			} else {
				logging("ERROR", "SVDRP: unsupported line for checking result: " . $line);
				$rc = 3; # problem
			};
		};

		$SVDRP->close;
	};

	my $summary = "";
	foreach my $key (keys %counters) {
		$summary .= " " . $key . "=" . $counters{$key};
	};

	logging("INFO", "SVDRP: summary timers" . $summary);
	return($rc);
};


###############################################################################
# BEGIN OF IMPORTED CODE - with some cleanups
###############################################################################
# Original (C) & (P) 2003 - 2007 by <macfly> / Friedhelm Büscher as inc/helperfunc in "tvmovie2vdr"
#   last public release: http://rsync16.de.gentoo.org/files/tvmovie2vdr/tvmovie2vdr-0.5.13.tar.gz
#

my ($Dest, $Port);

my($SOCKET, $EPGSOCKET, $query, $connected);

sub SVDRP::new {
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

sub SVDRP::myconnect {
	my $this = shift;

	logging("TRACE", "SVDRP: create socket to PeerAddr=" . $Dest . " PeerPort=" . $Port);

	$connected = 0;

	$SOCKET = IO::Socket::INET->new(
		PeerAddr => $Dest, 
		PeerPort => $Port, 
		Proto => 'tcp'
	);
	if (! defined $SOCKET) {
		logging("CRIT", "SVDRP: socket creation failed to PeerAddr=" . $Dest . " PeerPort=" . $Port . " (" . $! . ")");
		return(1);
	};

	my $line;
	$line = <$SOCKET>;
	$connected = 1;
}

sub SVDRP::close {
	my $this = shift;
	if(defined $connected && $connected == 1) {
		SVDRP::command($this, "quit");
		SVDRP::readoneline($this);
		close $SOCKET if $SOCKET;
		$connected = 0;
	}
}

sub SVDRP::connected {
	my $this = shift;
	return($connected);
};


sub SVDRP::command {
	my $this = shift;
	my $cmd = join("", @_);

	logging("TRACE", "SVDRP: send command: " . $cmd);

	if((!defined $connected) || ($connected == 0)) {
		SVDRP::myconnect($this) || return(1);
	}
	
	$cmd = $cmd . "\n\r";
	if($SOCKET) {
		use bytes;
		my $result = send($SOCKET, $cmd, 0);
		if($result != length($cmd)) {
		} else {
			$query = 1;
		}
		no bytes;
	};
};

sub SVDRP::readoneline {
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

sub SVDRP::SendCMD {
	my $this = shift;
	my $cmd = join("", @_); 
	my @output;

	SVDRP::command($this, $cmd) || return(1);
	while($_ = SVDRP::readoneline($this)) {
		push(@output, $_);
	}
	return(@output);
}

###############################################################################
# END OF IMPORTED CODE
###############################################################################

#### END
return 1;
