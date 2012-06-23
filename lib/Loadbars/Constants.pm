package Loadbars::Constants;

use strict;
use warnings;

use SDL::Color;

use constant {
    COPYRIGHT          => '2010-2012 (c) Paul Buetow <loadbars@mx.buetow.org>',
    CONFFILE           => $ENV{HOME} . '/.loadbarsrc',
    CSSH_CONFFILE      => '/etc/clusters',
    CSSH_MAX_RECURSION => 10,
    COLOR_DEPTH        => 8,
    BLACK              => SDL::Color->new( -r => 0x00, -g => 0x00, -b => 0x00 ),
    BLUE0              => SDL::Color->new( -r => 0x00, -g => 0x00, -b => 0xff ),
    BLUE               => SDL::Color->new( -r => 0x00, -g => 0x00, -b => 0x88 ),
    GREEN              => SDL::Color->new( -r => 0x00, -g => 0x90, -b => 0x00 ),
    ORANGE             => SDL::Color->new( -r => 0xff, -g => 0x70, -b => 0x00 ),
    PURPLE             => SDL::Color->new( -r => 0xa0, -g => 0x20, -b => 0xf0 ),
    RED                => SDL::Color->new( -r => 0xff, -g => 0x00, -b => 0x00 ),
    WHITE              => SDL::Color->new( -r => 0xff, -g => 0xff, -b => 0xff ),
    GREY0              => SDL::Color->new( -r => 0x11, -g => 0x11, -b => 0x11 ),
    GREY               => SDL::Color->new( -r => 0xaa, -g => 0xaa, -b => 0xaa ),
    DARK_GREY          => SDL::Color->new( -r => 0x15, -g => 0x15, -b => 0x15 ),
    YELLOW0            => SDL::Color->new( -r => 0xff, -g => 0xa0, -b => 0x00 ),
    YELLOW             => SDL::Color->new( -r => 0xff, -g => 0xc0, -b => 0x00 ),
    SYSTEM_BLUE0       => 30,
    USER_ORANGE        => 70,
    USER_YELLOW0       => 50,
    INTERVAL           => 0.125,
    INTERVAL_WARN      => 1.0,
    SUCCESS            => 0,
    E_UNKNOWN          => 1,
    E_NOHOST           => 2,
};

1;

