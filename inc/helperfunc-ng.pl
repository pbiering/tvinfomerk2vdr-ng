# Original (C) & (P) 2003 - 2007 by <macfly> / Friedhelm Büscher as inc/helperfunc in "tvmovie2vdr"
#   last public release: http://rsync16.de.gentoo.org/files/tvmovie2vdr/tvmovie2vdr-0.5.13.tar.gz
#
# extension and cleanup (P) & (C) 2013-2014 by Peter Bieringer <pb@bieringer.de> as "inc/helperfunc-ng.pl"
#
# License: GPLv2
#
# Authors:
#  Peter Bieringer (bie)
#  <macfly> / Friedhelm Büscher
#
# Changelog:
# 20130116/pb: add timer cache feature, replace German Umlauts
# 20140803/pb: major cleanup, remove unused code


################################################################################
# Constants
################################################################################
sub true           () { 1 };
sub false          () { 0 };
sub CRLF           () { "\r\n" };

################################################################################
# Unpack active-state from timer
################################################################################
sub UnpackActive {
  my($tmstatus) = @_;
  # strip the first 16 bit
  return ($tmstatus & 0xFFFF);
}

################################################################################
# Unpack event_id from timer
################################################################################
sub UnpackEvent_id {
  my($tmstatus) = @_;
  # remove the lower 16 bit by shifting the value 16 bits to the right
  return $tmstatus >> 16;
}

################################################################################
# read timers for given provider
################################################################################
sub gettimers($;$) {
	my $prefix = $_[0];
	my $timer_cache_p = $_[1] || undef;

	undef @oldtimers;
	#Timer holen
	# per SVDRP verbinden
	$SVDRP->command("lstt");
	while($_ = $SVDRP->readoneline) {
		doexit() if $please_exit;
		chomp;
		last if(/^No timers defined/);
		my($id, $temp) = split(/ /, $_, 2);
		my($tmstatus, $vdr_id, $dor, $start, $stop, $prio, $lft, $title, $summary) = split(/\:/, $temp, 9);
		my($active, $event_id);
		$active = UnpackActive($tmstatus);
		$event_id = UnpackEvent_id($tmstatus);

		if (defined $timer_cache_p) {
			#print "gettimers: push to cache: $id\n";
			$$timer_cache_p{$id}->{'status'}     = "valid";
			$$timer_cache_p{$id}->{'channel_id'} = $vdr_id;
			$$timer_cache_p{$id}->{'timer_day'}  = $dor;
			$$timer_cache_p{$id}->{'anfang'}     = $start;
			$$timer_cache_p{$id}->{'ende'}       = $stop;
			$$timer_cache_p{$id}->{'title'}      = $title;
			$$timer_cache_p{$id}->{'tmstatus'}   = $tmstatus;
			$$timer_cache_p{$id}->{'summary'}    = $summary;
		};

		if ($summary =~ /$prefix/) {
			push @oldtimers, $id;
		}
	}
	return (@oldtimers);
}

################################################################################
# delete timers
################################################################################
sub deltimers {
	my (@timers) = @_;
	foreach $timer (reverse @timers) {
		doexit() if $please_exit;
		my($result) = $SVDRP->SendCMD("delt $timer");
		}
}

################################################################################
# read channels.conf via svdrp into memory
################################################################################
sub getchan {
	undef(@chan);
	$SVDRP->command("lstc");
	while($_ = $SVDRP->readoneline) {
		doexit() if $please_exit;
		chomp;
		my($vdr_id, $temp) = split(/ /, $_, 2);	
		my($name, $frequency, $polarization, $source, $symbolrate, $vpid, $apid,
		  $tpid, $ca, $service_id, $nid, $tid, $rid) = split(/\:/, $temp);

		if ( $source eq 'T' ) { 
			$frequency=substr($frequency, 0, 3);
		}

		$data = $nid>0 ? $tid : $frequency;
		$rfc2838 = "";
		foreach $sender (keys(%chan)) {
			if ($chan{$sender}[0] eq "$source-$nid-$data-$service_id") {
			$rfc2838 = $sender;
			last;
			}	  
		}
		push(@chan, {
			vdr_id       => $vdr_id,
			name         => $name,
			frequency    => $frequency,
			polarization => $polarization,
			source       => $source,
			symbolrate   => $symbolrate,
			vpid         => $vpid,
			apid         => $apid,
			tpid         => $tpid,
			ca           => $ca,
			service_id   => $service_id,
			nid          => $nid,
			tid          => $tid,
			epg_id       => "$source-$nid-$data-$service_id",
			rid          => $rid,
			rfc2838      => $rfc2838
		}); 
	}
	return(@chan);
}

################################################################################
# read channels.conf into memory
################################################################################
sub ReadChannels {
	my $channelsfile = shift;
	# Now open the VDR channel file
	open(CHANNELS, "$channelsfile") or die "cannot open $channelsfile file: $!";
	while(<CHANNELS>) {

		doexit() if $please_exit;
		# Kategorien überspringen
		next if (/^:/);

		chomp;
		my($name, $frequency, $polarization, $source, $symbolrate, $vpid, $apid,
		$tpid, $ca, $service_id, $nid, $tid, $rid) = split(/\:/, $_);

		if ( $source eq 'T' or $source eq 'C' ) {
			if ( length($frequency) > 3) {
				$frequency=substr($frequency, 0, length($frequency)-3);
				}
			if ( length($frequency) > 3) {
				$frequency=substr($frequency, 0, length($frequency)-3);
				}
			}

		$data = $nid>0 ? $tid : $frequency;
		$rfc2838 = "";
		foreach $sender (keys(%chan)) {
			if ($chan{$sender}[0] eq "$source-$nid-$data-$service_id") {
			$rfc2838 = $sender;
			last;
			}	  
		}
		next if $rfc2838 eq "";
		# Channel ins Array aufnehmen
		push(@chan, {
			name         => $name,
			polarization => $polarization,
			source       => $source,
			symbolrate   => $symbolrate,
			vpid         => $vpid,
			apid         => $apid,
			tpid         => $tpid,
			ca           => $ca,
			service_id   => $service_id,
			nid          => $nid,
			tid          => $tid,
			rid          => $rid,
			epg_id		 => "$source-$nid-$data-$service_id",
			rfc2838      => $rfc2838
			}); 
	}
	return(@chan);
}


sub SIGhandler {    
	my($sig) = @_;
	$please_exit=1;
}

sub doexit {
	print "exiting ... \n";
	$SVDRP->close;
	exit;
}



sub singlesvdrp {
my $svdrpline = shift;
my $SVDRP = SVDRP->new($Dest,$Port,$verbose,$sim) unless $novdr;
my $return = $SVDRP->SendCMD($svdrpline);
$SVDRP->close;
return $return;
}


###############################################################################
#
# package SVDRP
#
package SVDRP;

sub true       () { main::true(); }
sub false      () { main::false(); };
sub CRLF       () { main::CRLF(); };

my($SOCKET, $EPGSOCKET, $query, $connected, $epg);

sub new {
	my $invocant = shift;
	$Dest = shift;
	$Port = shift;
	$verbose = shift;
	$sim = shift;
	my $class = ref($invocant) || $invocant;
	my $self = { };
	bless($self, $class);
	$connected = false;
	$query = false;
	$epg = false;
	return $self;
}

sub myconnect {
	my $this = shift;

	if ($sim == 0) {
		$SOCKET = IO::Socket::INET->new(
			PeerAddr => $Dest, 
			PeerPort => $Port, 
			Proto => 'tcp'
		) or die;

		my $line;
		$line = <$SOCKET>;
		$connected = true;
	}
}

sub close {
	my $this = shift;
	if($connected) {
		command($this, "quit");
		readoneline($this);
		close $SOCKET if $SOCKET;
		$connected = false;
	}
}

sub command {
	my $this = shift;
	my $cmd = join("", @_);

	if ($verbose == 1) {
		print "$cmd\n";
	}

	if ($sim == 1) {
		return;
	}

	if(!$connected ) {
		myconnect($this);
	}
	
	$cmd = $cmd . CRLF;
	if($SOCKET) {
		use bytes;
		my $result = send($SOCKET, $cmd, 0);
		if($result != length($cmd)) {
		} else {
			$query = true;
		}
		no bytes;
	}
}

sub readoneline {
	my $this = shift;
	my $line;

	if ($sim == 1) {
		return undef;
	}

	if($connected and $query) {
		$line = <$SOCKET>;
		$line =~ s/\r\n$//;
		if(substr($line, 3, 1) ne "-") {
			$query = 0;
		}
		$line = substr($line, 4, length($line));

		if ($verbose == 1) {
			print "< $line\n";
		}

		return($line);
	} else { 
		return undef; 
	}
}

sub SendCMD {
	my $this = shift;
	my $cmd = join("", @_); 
	my @output;

	if ($sim == 1) {
		print "$cmd \n";
		return (@output);
	}

	command($this, $cmd);
	while($_ = readoneline($this)) {
		push(@output, $_);
	}
  return(@output);
}

return 1;
