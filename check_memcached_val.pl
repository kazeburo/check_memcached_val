#!/usr/bin/perl

use strict;
use warnings;
use IO::Socket::INET;
use POSIX qw(EINTR EAGAIN EWOULDBLOCK);
use Socket qw(IPPROTO_TCP TCP_NODELAY);
use Scalar::Util qw/ looks_like_number /;
use Getopt::Long;
Getopt::Long::Configure ("no_ignore_case");

my $host;
my $port = 11211;
my $warning = 0;
my $critical = 0;
my $key;
my $timeout = 10;

sub usage {
    print <<EOF;
usage: $0 -H host -P port -w 0.1 -c 0.2 -t 10 -k getkey
    -H host
    -P port. default 11211
    -w Warning threshold ( alert if larger than this )
    -c Critical threshold
    -t Seconds before connection times out.
    -k key name for retrieve
EOF
    exit 3;
}

GetOptions(
    "h"   => \my $help,
    "H=s" => \$host,
    "P=i" => \$port,
    "w=i" => \$warning,
    "c=i" => \$critical,
    "k=s" => \$key,
    "t=i" => \$timeout,
) or usage();
usage() if !$host || !$key;
usage() if $help;

my $client;
eval {
    $client = new_client($host, $port, $timeout);
};

if ( $@ ) {
    print "Critical: $@";
    exit 2;
}

my $write_len = write_all($client, "get $key\r\n", $timeout);
if ( ! defined $write_len ) {
    print "Critical: Failed to request\n";
    exit 2;
}
my $buf = '';
while (1) {
    my $read_len = read_timeout($client, \$buf, 1024 - length($buf), length($buf), $timeout)
        or return;
    $buf =~ m!(?:END|ERROR)\r\n$!mos and last;
}

if ( !$buf ) {
    print "Critical: could not retrieve any data from server\n";
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
    print "Unkown: server returns error\n";
    exit 3;
}
else {
    # not found
    print "Critical: Key:$key is not found on this server \n";
    exit 2;
}

if ( ! looks_like_number($val) ) {
    printf "Unkown: Key:%s Value:%s was not look like number \n", $key, $val;
    exit 3;    
}

if ( $val > $critical ) {
    printf "Critical: Key:%s Value:%d was larger than %s \n", $key, $val, $critical;
    exit 2;
}

if ( $val > $warning ) {
    printf "Warning: Key:%s Value:%d was larger than %s \n", $key, $val, $warning;
    exit 1;
}

printf "OK: Value:%d\n", $val;
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
