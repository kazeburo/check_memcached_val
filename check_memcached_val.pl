#!/usr/bin/perl

use strict;
use warnings;
use 5.008005;
use File::Temp qw/tempfile/;
use File::Spec;
use File::Path qw/make_path/;
use File::Copy;
use Data::Dumper;
use Digest::MD5 qw/md5_hex/;
use IO::Socket::INET;
use POSIX qw(EINTR EAGAIN EWOULDBLOCK);
use Socket qw(IPPROTO_TCP TCP_NODELAY);
use Scalar::Util qw/ looks_like_number /;
use Pod::Usage qw/pod2usage/;
use Getopt::Long;
Getopt::Long::Configure ("no_ignore_case");

use constant OUTSIDE => 0;
use constant INSIDE => 1;
use constant OK => 0;
use constant WARNING => 1;
use constant CRITICAL => 2;
use constant UNKNOWN => 3;

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
my $rate_multiplier = 1;

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
    "R|eregi=s" => \$regexi,
    "invert-search" => \my $invert_search,
    "rate" => \my $rate,
    "rate-multiplier=i" => \$rate_multiplier
) or pod2usage(-verbose=>1,-exitval=>UNKNOWN);
pod2usage(-verbose=>1,-exitval=>CRITICAL) if !$host || !$key;
pod2usage(-verbose=>2,-exitval=>OK) if $help;

my $warning = parse_range_string($warning_arg);
if ( !$warning ) {
    print "CRITICAL: invalid range definition '$warning_arg'\n";
    exit CRITICAL;    
}
my $critical = parse_range_string($critical_arg);
if ( !$critical ) {
    print "CRITICAL: invalid range definition '$critical_arg'\n";
    exit CRITICAL;    
}

my $tmpdir = File::Spec->catdir(File::Spec->tmpdir(),'check_memcached_val');
my $prevfile = md5_hex(Dumper(
    [$host,$port,$warning_arg,$critical_arg,$key,$timeout,$estring,$regex,$regexi,$invert_search,$rate]
));
if ($rate) {
    make_path($tmpdir);
}

my $client;
eval {
    $client = new_client($host, $port, $timeout);
};

if ( $@ ) {
    print "CRITICAL: $@";
    exit CRITICAL;
}

my $write_len = write_all($client, "get $key\r\n", $timeout);
if ( ! defined $write_len ) {
    print "CRITICAL: Failed to request\n";
    exit CRITICAL;
}
my $buf = '';
while (1) {
    my $read_len = read_timeout($client, \$buf, 1024 - length($buf), length($buf), $timeout)
        or return;
    $buf =~ m!(?:END|ERROR)\r\n$!mos and last;
}

if ( !$buf ) {
    print "CRITICAL: could not retrieve any data from server\n";
    exit CRITICAL;
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
    exit UNKNOWN;
}
else {
    # not found
    print "CRITICAL: Key:$key is not found on this server\n";
    exit CRITICAL;
}

# string check
if ( defined $estring ) {
    my $ret = ($val eq $estring);
    $ret = !$ret if $invert_search;
    if ( $ret ) {
        printf "MEMCACHED_VAL MATCH OK: *%s\n", $val;
        exit OK;
    }
    else {
        printf "MEMCACHED_VAL MATCH CRITICAL: *%s\n", $val;
        exit CRITICAL;
    }
}
# regex check
if ( defined $regex ) {
    my $ret = ($val =~ m!$regex!);
    $ret = !$ret if $invert_search;
    if ( $ret ) {
        printf "MEMCACHED_VAL MATCH OK: *%s\n", $val;
        exit OK;
    }
    else {
        printf "MEMCACHED_VAL MATCH CRITICAL: *%s\n", $val;
        exit CRITICAL;
    }
}
# incase regex check
if ( defined $regexi ) {
    my $ret = ($val =~ m!$regexi!i);
    $ret = !$ret if $invert_search;
    if ( $ret ) {
        printf "MEMCACHED_VAL MATCH OK: *%s\n", $val;
        exit OK;
    }
    else {
        printf "MEMCACHED_VAL MATCH CRITICAL: *%s\n", $val;
        exit CRITICAL;
    }
}

# number check
if ( ! looks_like_number($val) ) {
    printf "MEMCACHED_VAL UNKNOWN: Key:%s *%s is not like a number\n", $key, $val;
    exit UNKNOWN;    
}

if ( uc($val) eq "0E0" ) {
    printf "MEMCACHED_VAL MAYBE OK: Key:%s is zero but true - assume okay. *%s\n", $key, $val;
    exit OK;
}

# calc rate
if ( $rate ) {
    my $path = File::Spec->catfile($tmpdir, $prevfile);
    if ( ! -s $path ) {
        printf "MEMCACHED_VAL MAYBE OK: No previous data to calculate rate - assume okay. Key:%s\n", $key;
        atomic_write($path, $val);
        exit OK;
    }
    my $prev_time = [stat $path]->[9]; #mtime
    my $elapsed = time - $prev_time;
    if ( !$elapsed ) {
        print "MEMCACHED_VAL UNKNOWN: Time duration between plugin calls is invalid. Key:%s\n", $key;
        exit UNKNOWN;
    }
    open( my $fh, '<', $path);
    my $prev = do { local $/; <$fh> };
    chomp $prev;chomp $prev;
    my $rate  = ($val - $prev) / $elapsed;
    atomic_write($path, $val);
    $val = $rate * $rate_multiplier;
}

# range check
if ( check_range($critical, $val) ) {
    printf "MEMCACHED_VAL CRITICAL: Key:%s *%s\n", $key, $val;
    exit CRITICAL;
}

if ( check_range($warning, $val) ) {
    printf "MEMCACHED_VAL WARNING: Key:%s *%s\n", $key, $val;
    exit WARNING;
}

printf "MEMCACHED_VAL OK: *%s\n", $val;
exit OK;

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

sub atomic_write {
    my ($writefile, $body) = @_;
    my ($tmpfh,$tmpfile) = tempfile(UNLINK=>0,TEMPLATE=>$writefile.".XXXXX");
    print $tmpfh $body;
    close($tmpfh);
    move( $tmpfile, $writefile);
}


__END__

=encoding utf8

=head1 NAME

check_memcached_val.pl - nagios plugin for checking value in a memcached server.

=head1 SYNOPSIS

  usage: check_memcached_val.pl -H host -P port -w 0.1 -c 0.2 -t 10 -k getkey

=head1 DESCRIPTION

check_memcached_val is nagios plugin to retrieve a value from memcached server and check status

=head1 ARGUMENTS

=over 4

=item -h, --help

Display help message

=item -H, --hostname=STRING

Host name or IP Address

=item -P, --port=INTEGER

Port number (default 11211)

=item -k, --key=STRING

key name to get

=item -s, --string=STRING

Return OK state if STRING is an exact match

=item -r, --ereg=REGEX

Return OK state if extended regular expression REGEX matches

=item -R, --eregi=REGEX

Return OK state if case-insensitive extended REGEX matches

=item --invert-search

Invert search result (CRITICAL if found)

=item -w, --warning=THRESHOLD

Warning threshold range

See L<http://nagiosplug.sourceforge.net/developer-guidelines.html#THRESHOLDFORMAT> for THRESHOLD format and examples

=item -c, --critical=THRESHOLD

Critical threshold range

=item -t, --timeout=INTEGER

Seconds before connection times out.

=item --rate

Enable rate calculation. See 'Rate Calculation' below

=item --rate-multiplier=INTEGER

Converts rate per second. For example, set to 60 to convert to per minute

=back

=head1 Rate Calculation

check_memcached_val can rate calculation like a check_snmp plugin.
check_memcached_val stores previous data in a file and calculate rate per second.
This is useful when combination with the memcached incr.

On the first run, there will be no prior state - this will return with OK.
The state is uniquely determined by the arguments to the plugin, so
changing the arguments will create a new state file


=head1 INSTALL

just copy this script to nagios's libexec directory.

  $ curl https://raw.github.com/kazeburo/check_memcached_val/master/check_memcached_val.pl > check_memcached_val.pl
  $ chmod +x check_memcached_val.pl
  $ cp check_memcached_val.pl /path/to/nagios/libexec

=head1 AUTHOR

Masahiro Nagano E<lt>kazeburo@gmail.comE<gt>

=head1 LICENSE

Copyright (C) Masahiro Nagano

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

