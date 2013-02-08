check_memcached_val
===================

nagios plugin for checking value in memcached 

usage
=====

    $ check_memcached_val.pl -H host -P port -w 0.1 -c 0.2 -t 10 -k getkey
    -H host
    -P port. default 11211
    -w Warning threshold ( alert if larger than this )
    -c Critical threshold
    -t Seconds before connection times out.
    -k key name for retrieve

LICENSE
=======

Copyright (C) Masahiro Nagano

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.
