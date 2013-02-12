#!/usr/bin/perl

use strict;
use warnings;
use IO::Socket::INET;
use POSIX qw(EINTR EAGAIN EWOULDBLOCK);
use Socket qw(IPPROTO_TCP TCP_NODELAY);
use Scalar::Util qw/ looks_like_number /;
use Getopt::Long;
Getopt::Long::Configure ("no_ignore_case");

use constant OUTSIDE => 0;
use constant INSIDE => 1;

# copy from Nagios::Plugin
my $value_n = qr/[-+]?[\d\.]+/;
my $value_re = qr/$value_n(?:e$value_n)?/;

my $host;
my $port = 11211;
my $warning_arg = 0;
my $critical_arg = 0;
my $key;
my $timeout = 10;
my $regex;
my $regexi;
my $estring;

sub usage {
    print <<EOF;
usage: $0 -H host -P port -w 0.1 -c 0.2 -t 10 -k getkey
    -H host
    -P port. default 11211
    -s Return OK state if STRING is an exact match
    -r Return OK state if extended regular expression REGEX matches
    -R Return OK state if case-insensitive extended REGEX matches
    -w Warning threshold range(s)
    -c Critical threshold range(s)
    -t Seconds before connection times out.
    -k key name for retrieve
EOF
    exit 3;
}

GetOptions(
    "h|help"   => \my $help,
    "H|hostname=s" => \$host,
    "P|port=i" => \$port,
    "w|warning=s" => \$warning_arg,
    "c|critical=s" => \$critical_arg,
    "k|key=s" => \$key,
    "t|timeout=i" => \$timeout,
    "s|string=s" => \$estring,
    "r|ereg=s" => \$regex,
    "R|eregi=s" => \$regexi
) or usage();
usage() if !$host || !$key;
usage() if $help;

my $warning = parse_range_string($warning_arg);
if ( !$warning ) {
    print "CRITICAL: invalid range definition '$warning_arg'\n";
    exit 2;    
}
my $critical = parse_range_string($critical_arg);
if ( !$critical ) {
    print "CRITICAL: invalid range definition '$critical_arg'\n";
    exit 2;    
}


my $client;
eval {
    $client = new_client($host, $port, $timeout);
};

if ( $@ ) {
    print "CRITICAL: $@";
    exit 2;
}

my $write_len = write_all($client, "get $key\r\n", $timeout);
if ( ! defined $write_len ) {
    print "CRITICAL: Failed to request\n";
    exit 2;
}
my $buf = '';
while (1) {
    my $read_len = read_timeout($client, \$buf, 1024 - length($buf), length($buf), $timeout)
        or return;
    $buf =~ m!(?:END|ERROR)\r\n$!mos and last;
}

if ( !$buf ) {
    print "CRITICAL: could not retrieve any data from server\n";
    exit 2;
}

my $val;
if ( $buf =~ m!
  ^VALUE\x20
  $key\x20
  (?:[^\x20]+)\x20
  (?:[^\x20]+)\r\n
  (.+)\r\n
  END\r\n$
!mosx
) {
    $val = $1;
}
elsif ( $buf =~ m!ERROR\r\n$!mos ) {
    # error?
    print "UNKNOWN: server returns error\n";
    exit 3;
}
else {
    # not found
    print "CRITICAL: Key:$key is not found on this server \n";
    exit 2;
}

# string check
if ( defined $estring ) {
    if ( $val eq $estring ) {
        printf "OK MATCH: *%s\n", $val;
        exit 0;
    }
    else {
        printf "CRTICAL NOT MATCH: *%s\n", $val;
        exit 2;
    }
}
# regex check
if ( defined $regex ) {
    if ( $val =~ m!$regex! ) {
        printf "OK MATCH: *%s\n", $val;
        exit 0;
    }
    else {
        printf "CRTICAL NOT MATCH: *%s\n", $val;
        exit 2;
    }
}
# incase regex check
if ( defined $regexi ) {
    if ( $val =~ m!$regexi!i ) {
        printf "OK MATCH: *%s\n", $val;
        exit 0;
    }
    else {
        printf "CRTICAL NOT MATCH: *%s\n", $val;
        exit 2;
    }
}


# range check
if ( ! looks_like_number($val) ) {
    printf "UNKNOWN: Key:%s *%s was not look like number \n", $key, $val;
    exit 3;    
}

if ( check_range($critical, $val) ) {
    printf "CRITICAL: Key:%s *%d\n", $key, $val;
    exit 2;
}

if ( check_range($warning, $val) ) {
    printf "WARNING: Key:%s *%d\n", $key, $val;
    exit 1;
}

printf "OK: *%d\n", $val;
exit 0;

sub new_client {
    my ($host, $port, $timeout) = @_;

    my $sock = IO::Socket::INET->new(
        PeerHost => $host,
        PeerPort => $port,
        Timeout  => $timeout, 
        Proto    => 'tcp',
    ) or die "Cannot open client socket: $!\n";

    setsockopt($sock, IPPROTO_TCP, TCP_NODELAY, pack("l", 1)) or die;
    $sock->autoflush(1);
    $sock;
}

# returns (positive) number of bytes read, or undef if the socket is to be closed
sub read_timeout {
    my ($sock, $buf, $len, $off, $timeout) = @_;
    do_io(undef, $sock, $buf, $len, $off, $timeout);
}

# returns (positive) number of bytes written, or undef if the socket is to be closed
sub write_timeout {
    my ($sock, $buf, $len, $off, $timeout) = @_;
    do_io(1, $sock, $buf, $len, $off, $timeout);
}

# writes all data in buf and returns number of bytes written or undef if failed
sub write_all {
    my ($sock, $buf, $timeout) = @_;
    my $off = 0;
    while (my $len = length($buf) - $off) {
        my $ret = write_timeout($sock, $buf, $len, $off, $timeout)
            or return;
        $off += $ret;
    }
    return length $buf;
}

# returns value returned by $cb, or undef on timeout or network error
sub do_io {
    my ($is_write, $sock, $buf, $len, $off, $timeout) = @_;
    my $ret;
 DO_READWRITE:
    # try to do the IO
    if ($is_write) {
        $ret = syswrite $sock, $buf, $len, $off
            and return $ret;
    } else {
        $ret = sysread $sock, $$buf, $len, $off
            and return $ret;
    }
    unless ((! defined($ret)
                 && ($! == EINTR || $! == EAGAIN || $! == EWOULDBLOCK))) {
        return;
    }
    # wait for data
 DO_SELECT:
    while (1) {
        my ($rfd, $wfd);
        my $efd = '';
        vec($efd, fileno($sock), 1) = 1;
        if ($is_write) {
            ($rfd, $wfd) = ('', $efd);
        } else {
            ($rfd, $wfd) = ($efd, '');
        }
        my $start_at = time;
        my $nfound = select($rfd, $wfd, $efd, $timeout);
        $timeout -= (time - $start_at);
        last if $nfound;
        return if $timeout <= 0;
    }
    goto DO_READWRITE;
}

# copy from Nagios::Plugin
sub parse_range_string {
    my ($string) = @_;
    my $valid = 0;
    my %range = (
        start => 0, 
        start_infinity => 0,
        end => 0,
        end_infinity => 1,
        alert_on => OUTSIDE
    );
    $string =~ s/\s//g;  # strip out any whitespace
    # check for valid range definition
    unless ( $string =~ /[\d~]/ && $string =~ m/^\@?($value_re|~)?(:($value_re)?)?$/ ) {
        return;
    }

    if ($string =~ s/^\@//) {
        $range{alert_on} = INSIDE;
    }

    if ($string =~ s/^~//) {  # '~:x'
        $range{start_infinity} = 1;
    }
    if ( $string =~ m/^($value_re)?:/ ) {     # '10:'
       my $start = $1;
       if ( defined $start ) {
           $range{start} = $start + 0;
           $range{start_infinity} = 0;
       }
       $range{end_infinity} = 1;  # overridden below if there's an end specified
       $string =~ s/^($value_re)?://;
       $valid++;
   }
    if ($string =~ /^($value_re)$/) {   # 'x:10' or '10'
        $range{end} = $string + 0;
        $range{end_infinity} = 0;
        $valid++;
    }

    if ($valid && ( $range{start_infinity} == 1 
                 || $range{end_infinity} == 1 
                 || $range{start} <= $range{end}
                 )) {
        return \%range;
    }

    return;
}

# Returns 1 if an alert should be raised, otherwise 0
sub check_range {
    my ($range, $value) = @_;
    my $false = 0;
    my $true = 1;
    if ($range->{alert_on} == INSIDE) {
        $false = 1;
        $true = 0;
    }
    if ($range->{end_infinity} == 0 && $range->{start_infinity} == 0) {
        if ($range->{start} <= $value && $value <= $range->{end}) {
            return $false;
        }
        else {
            return $true;
        }
    }
    elsif ($range->{start_infinity} == 0 && $range->{end_infinity} == 1) {
        if ( $value >= $range->{start} ) {
            return $false;
        }
        else {
            return $true;
        }
    }
    elsif ($range->{start_infinity} == 1 && $range->{end_infinity} == 0) {
        if ($value <= $range->{end}) {
            return $false;
        }
        else {
            return $true;
        }
    }
    return $false;
}

