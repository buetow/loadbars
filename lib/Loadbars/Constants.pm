package Loadbars::Constants;

use strict;
use warnings;

use SDL::Color;

use constant {
    COPYRIGHT          => '2010-2013 (c) Paul Buetow <loadbars@mx.buetow.org>',
    CONFFILE           => $ENV{HOME} . '/.loadbarsrc',
    CSSH_CONFFILE      => '/etc/clusters',
    CSSH_MAX_RECURSION => 10,
    COLOR_DEPTH        => 32,
    BLACK              => [ 0x00, 0x00, 0x00 ],
    BLUE0              => [ 0x00, 0x00, 0xff ],
    LIGHT_BLUE         => [ 0x00, 0x00, 0xdd ],
    LIGHT_BLUE0        => [ 0x00, 0x00, 0xcc ],
    BLUE               => [ 0x00, 0x00, 0x88 ],
    GREEN              => [ 0x00, 0x90, 0x00 ],
    LIGHT_GREEN        => [ 0x00, 0xf0, 0x00 ],
    ORANGE             => [ 0xff, 0x70, 0x00 ],
    PURPLE             => [ 0xa0, 0x20, 0xf0 ],
    RED                => [ 0xff, 0x00, 0x00 ],
    WHITE              => [ 0xff, 0xff, 0xff ],
    GREY0              => [ 0x11, 0x11, 0x11 ],
    GREY               => [ 0xaa, 0xaa, 0xaa ],
    DARK_GREY          => [ 0x15, 0x15, 0x15 ],
    YELLOW0            => [ 0xff, 0xa0, 0x00 ],
    YELLOW             => [ 0xff, 0xc0, 0x00 ],
    COLOR_WHITE        => SDL::Color->new( 0xff, 0xff, 0xff ),
    SYSTEM_BLUE0       => 30,
    USER_ORANGE        => 70,
    USER_YELLOW0       => 50,
    INTERVAL           => 0.14,
    INTERVAL_NET       => 3.0,
    INTERVAL_MEM       => 1.0,
    INTERVAL_SDL       => 0.14,
    INTERVAL_SDL_WARN  => 1.0,
    SUCCESS            => 0,
    E_UNKNOWN          => 1,
    E_NOHOST           => 2,
};

1;
