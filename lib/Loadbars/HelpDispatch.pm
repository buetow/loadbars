package Loadbars::HelpDispatch;

use strict;
use warnings;

use Loadbars::Constants;
use Loadbars::Shared;

sub create () {
    my $hosts = '';

    my $textdesc = <<END;
For more help please consult the manual page or press the 'h' hotkey during program execution and watch this terminal window. 
END

 # mode 1: Option is shown in the online help menu (stdout not sdl)
 # mode 2: Option is shown in the 'usage' screen from the command line
 # mode 4: Option is used to generate the GetOptions parameters for Getopt::Long
 # Combinations: Like chmod(1)

    my %d = (
        cpuaverage => {
            menupos => 3,
            help    => 'Num of cpu samples for avg. (more fluent animations)',
            mode    => 6,
            type    => 'i'
        },
        cpuaverage_hot_up => {
            menupos => 4,
            cmd     => 'a',
            help => 'Increases number of cpu samples for calculating avg. by 1',
            mode => 1
        },
        cpuaverage_hot_dn => {
            menupos => 5,
            cmd     => 'y',
            help => 'Decreases number of cpu samples for calculating avg. by 1',
            mode => 1
        },

        netaverage => {
            menupos => 6,
            help    => 'Num of net samples for avg. (more fluent animations)',
            mode    => 6,
            type    => 'i'
        },
        netaverage_hot_up => {
            menupos => 7,
            cmd     => 'd',
            help => 'Increases number of net samples for calculating avg. by 1',
            mode => 1
        },
        netaverage_hot_dn => {
            menupos => 8,
            cmd     => 'c',
            help => 'Decreases number of net samples for calculating avg. by 1',
            mode => 1
        },

        netint => {
            menupos => 6,
            help    => 'Interface to show netstats for (default: eth0)',
            mode    => 6,
            type    => 's'
        },
        netint_hot => {
            menupos => 17,
            cmd     => 'n',
            help    => 'Iterate to next net interface',
            mode    => 1
        },

        netlink => {
            menupos => 6,
            help =>
'Force interface link speed (mbit, 10mbit, 100mbit, gbit, 10gbit or a mbytes/s number e.g. 3 for 3mbit)',
            mode => 6,
            type => 's'
        },
        netlink_hot_up => {
            menupos => 9,
            cmd     => 'f',
            help => 'Increases net interface link speed reference by factor 10',
            mode => 1
        },
        netlink_hot_dn => {
            menupos => 10,
            cmd     => 'v',
            help => 'Decreases net interface link speed reference by factor 10',
            mode => 1
        },

        barwidth => {
            menupos => 11,
            help    => 'Set bar width',
            mode    => 6,
            type    => 'i'
        },
        windowwidth_hot_up => {
            menupos => 90,
            help    => 'Increase window width by 100px',
            cmd     => 'right',
            mode    => 1,
        },
        windowwidth_hot_dn => {
            menupos => 91,
            help    => 'Decrease window width by 100px',
            cmd     => 'left',
            mode    => 1,
        },
        windowheight_hot_up => {
            menupos => 92,
            help    => 'Increase window height by 100px',
            cmd     => 'down',
            mode    => 1,
        },
        windowheight_hot_dn => {
            menupos => 93,
            help    => 'Decrease window height by 100px',
            cmd     => 'up',
            mode    => 1,
        },

        cluster => {
            menupos => 6,
            help    => 'Cluster name from /etc/clusters',
            var     => \$C{cluster},
            mode    => 6,
            type    => 's'
        },
        configuration => {
            menupos => 6,
            cmd     => 'c',
            help    => 'Show current configuration',
            mode    => 4
        },

        extended => {
            menupos => 6,
            help    => 'Toggle extended display (0 or 1)',
            mode    => 7,
            type    => 'i'
        },
        extended_hot => {
            menupos => 23,
            cmd     => 'e',
            help    => 'Toggle extended mode',
            mode    => 1
        },

        hasagent => {
            menupos => 10,
            help    => 'SSH key is already known by the SSH agent (0 or 1)',
            mode    => 6,
            type    => 'i'
        },
        height => {
            menupos => 10,
            help    => 'Set windows height',
            mode    => 6,
            type    => 'i'
        },

        help_hot => {
            menupos => 11,
            cmd     => 'h',
            help    => 'Prints this help screen',
            mode    => 1
        },

        hosts => {
            menupos => 12,
            help =>
              'Comma sep. list of hosts; optional: user@ in front to each host',
            var  => \$hosts,
            mode => 6,
            type => 's'
        },

        maxwidth => {
            menupos => 16,
            help    => 'Set max width',
            mode    => 6,
            type    => 'i'
        },

        quit_hot => { menupos => 16, cmd => 'q', help => 'Quits', mode => 1 },
        writeconfig_hot => {
            menupos => 16,
            cmd     => 'w',
            help    => 'Write config to config file',
            mode    => 1
        },

        showcores => {
            menupos => 17,
            help    => 'Toggle core display (0 or 1)',
            mode    => 7,
            type    => 'i'
        },
        showcores_hot =>
          { menupos => 17, cmd => '1', help => 'Toggle show cores', mode => 1 },

        showmem => {
            menupos => 17,
            help    => 'Toggle mem display (0 or 1)',
            mode    => 7,
            type    => 'i'
        },
        showmem_hot =>
          { menupos => 17, cmd => '2', help => 'Toggle show mem', mode => 1 },

        shownet => {
            menupos => 17,
            help    => 'Toggle net display (0 or 1)',
            mode    => 7,
            type    => 'i'
        },
        shownet_hot =>
          { menupos => 17, cmd => '3', help => 'Toggle show net', mode => 1 },

        sshopts =>
          { menupos => 20, help => 'Set SSH options', mode => 6, type => 's' },

        title => {
            menupos => 21,
            help    => 'Set title bar text',
            mode    => 6,
            type    => 's'
        },
    );

    my %d_by_short = map {
        $d{$_}{cmd} => $d{$_}

      } grep {
        exists $d{$_}{cmd}

      } keys %d;

    my $closure = sub ($;$) {
        my ( $arg, @rest ) = @_;

        if ( $arg eq 'command' ) {
            my ( $cmd, @args ) = @rest;

            my $cb = $d{$cmd};
            $cb = $d_by_short{$cmd} unless defined $cb;

            unless ( defined $cb ) {
                system $cmd;
                return 0;
            }

            if ( length $cmd == 1 ) {
                for my $key ( grep { exists $d{$_}{cmd} } keys %d ) {
                    do { $cmd = $key; last } if $d{$key}{cmd} eq $cmd;
                }
            }

        }
        elsif ( $arg eq 'hotkeys' ) {
            $textdesc . "Hotkeys:\n" . (
                join "\n",
                map {
                    "$_ - $d_by_short{$_}{help}"

                  } grep {
                    $d_by_short{$_}{mode} & 1 and exists $d_by_short{$_}{help};

                  } sort { $d_by_short{$a}{menupos} <=> $d_by_short{$b}{menupos} }
                  sort keys %d_by_short
            );

        }
        elsif ( $arg eq 'usage' ) {
            $textdesc . (
                join "\n",
                map {
                    if ( $_ eq 'help' )
                    {
                        "--$_ - $d{$_}{help}";
                    }
                    else {
                        "--$_ <ARG> - $d{$_}{help}";
                    }

                  } grep {
                    $d{$_}{mode} & 2
                      and exists $d{$_}{help}

                  } sort { $d{$a}{menupos} <=> $d{$b}{menupos} } sort keys %d
            );

        }
        elsif ( $arg eq 'options' ) {
            map {
                "$_="
                  . $d{$_}{type} => (
                    defined $d{$_}{var}
                    ? $d{$_}{var}
                    : \$C{$_}
                  );

              } grep {
                $d{$_}{mode} & 4 and exists $d{$_}{type};

              } sort keys %d;
        }
    };

    $d{configuration}{cb} = sub {
        Loadbars::Main::say sort map {
            "$_->[0] = $_->[1]"

          } grep {
            defined $_->[1]

          } map {
            [
                $_ => exists $d{$_}{var}
                ? ${ $d{$_}{var} }
                : $C{$_}
            ]

          } keys %d;
    };

    return ( \$hosts, $closure );
}

1;
