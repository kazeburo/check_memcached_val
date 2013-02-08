check_memcached_val
===================

nagios plugin for checking value in memcached 

usage
=====

    $ check_memcached_val.pl -H host -P port -w 1000 -c 360 -t 10 -k getkey
    -H host
    -P port. default 11211
    -w Warning threshold
    -c Critical threshold
    -t Seconds before connection times out. defined 11211
    -k key name for retrieve
