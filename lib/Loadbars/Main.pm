package Loadbars::Main;

use strict;
use warnings;
use v5.14;
use autodie;

use SDL;
use SDL::Event;
use SDL::Events;
use SDL::Rect;
use SDL::Surface;
use SDL::TTF;
use SDL::TTF::Font;
use SDL::Video;
use SDLx::App;

use Time::HiRes qw(usleep gettimeofday);

use Proc::ProcessTable;

use threads;
use threads::shared;

use Loadbars::Config;
use Loadbars::Constants;
use Loadbars::Shared;
use Loadbars::Utils;

use Carp;
$SIG{__DIE__} = sub { Carp::confess(@_) };

$| = 1;

sub cpu_set_showcores_re () {
    $I{cpustring} = $C{showcores} ? 'cpu' : 'cpu ';
}

sub percentage ($$) {
    my ( $total, $part ) = @_;

    return int( null($part) / notnull( null($total) / 100 ) );
}

sub max_100 ($) {
    return $_[0] > 100 ? 100 : $_[0];
}

sub percentage_norm ($$$) {
    my ( $total, $part, $norm ) = @_;

    return int( null($part) / notnull( null($total) / 100 ) / notnull $norm);
}

sub norm ($) {
    my $n = shift;

    return $n > 100 ? 100 : ( $n < 0 ? 0 : $n );
}

sub cpu_parse_line ($) {
    my $line = shift;
    my ( $name, %load );

    ( $name, @load{qw(user nice system idle iowait irq softirq steal guest)} ) =
      split ' ', $line;

    # Not all kernels support this
    $load{steal} = 0 unless defined $load{steal};
    $load{guest} = 0 unless defined $load{guest};

    $load{TOTAL} =
      sum( @load{qw(user nice system idle iowait irq softirq steal guest)} );

    return ( $name, \%load );
}

sub threads_terminate_pids (@) {
    my @threads = @_;

    display_info 'Terminating sub-processes, hasta la vista!';
    $_->kill('TERM') for @threads;
    display_info_no_nl 'Terminating PIDs';
    for my $pid ( keys %PIDS ) {
        my $proc_table = Proc::ProcessTable->new();
        for my $proc ( @{ $proc_table->table() } ) {
            if ( $proc->ppid == $pid ) {
                print $proc->pid . ' ';
                kill 'TERM', $proc->pid if $proc->ppid == $pid;
            }
        }

        print $pid . ' ';
        kill 'TERM', $pid;
    }

    say '';

    display_info 'Terminating done. I\'ll be back!';
}

sub threads_stats ($;$) {
    my ( $host, $user ) = @_;
    $user = defined $user ? "-l $user" : '';

    my ( $sigusr1, $sigterm ) = ( 0, 0 );
    my $interval = Loadbars::Constants->INTERVAL;

    my $cpustring = $I{cpustring};

    # Precompile some regexp
    my @meminfo =
      map { [ $_, qr/^$_: *(\d+)/ ] }
      (qw(MemTotal MemFree Buffers Cached SwapTotal SwapFree));

    my $modeswitch_re = qr/^M /;

    until ($sigterm) {

        # UGLY!
        my $remotecode = <<"REMOTECODE";
            perl -le '
                use strict;
                use Time::HiRes qw(usleep);

                my \\\$whitespace_re = qr/ +/;
                my \\\$usleep = $interval * 100000;

                sub cat {
                    my \\\$file = shift;
                    open FH, \\\$file;
                    while (<FH>) {
                        print;
                    }
                    close FH;
                }

                sub load {
                    printf qq(M LOADAVG\n);
                    open FH, qq(/proc/loadavg);
                    printf qq(%s\n), join qq(;), (split qq( ), <FH>)[0..2];
                    close FH;
                }

                sub mem {
                    printf qq(M MEMSTATS\n);
                    cat(qq(/proc/meminfo));
                }

                sub net {
                    printf qq(M NETSTATS\n);
                    open FH, qq(/proc/net/dev);
                    <FH>; <FH>;
                    while (<FH>) {
                        next unless s/:/ /;
                        my (\\\$foo, \\\$int, \\\$bytes, \\\$packets, \\\$errs, \\\$drop, \\\$fifo, \\\$frame, \\\$compressed, \\\$multicast, \\\$tbytes, \\\$tpackets, \\\$terrs, \\\$tdrop, \\\$tfifo, \\\$tcolls, \\\$tcarrier, \\\$tcompressed) = split \\\$whitespace_re, \\\$_;
                        if (\\\$bytes || \\\$tbytes) {
                            printf qq(%s:b=%s;tb=%s;p=%s;tp=%s e=%s;te=%s;d=%s;td=%s\n), \\\$int, 
                               \\\$bytes, \\\$tbytes, 
                               \\\$packets, \\\$tpackets,
                                \\\$errs, \\\$terrs,
                                \\\$drop, \\\$tdrop
                                   ; 
                        }
                    }
                    close FH;
                }

                for (1..10000) {
                    load();
                    mem();
                    net();

                    printf qq(M CPUSTATS\n);
                    for (1..20) {
                        cat(qq(/proc/stat));
                        usleep(\\\$usleep);
                    }
                }
        '
REMOTECODE

        my $cmd =
          ( $host eq 'localhost' || $host eq '127.0.0.1' )
          ? "bash -c \"$remotecode\""
          : "ssh $user -o StrictHostKeyChecking=no $C{sshopts} $host \"$remotecode\"";

        my $pid = open my $pipe, "$cmd |" or do {
            say "Warning: $!";
            sleep 1;
            next;
        };

        $PIDS{$pid} = 1;

        # Toggle CPUs
        $SIG{USR1} = sub { $sigusr1 = 1 };
        $SIG{TERM} = sub { $sigterm = 1 };

        my $mode = 0;

        while (<$pipe>) {
            chomp;

            if ( $_ =~ $modeswitch_re ) {
                if ( $_ eq 'M CPUSTATS' ) {
                    $mode = 1;
                }
                elsif ( $_ eq 'M MEMSTATS' ) {
                    $mode = 2;
                }
                elsif ( $_ eq 'M NETSTATS' ) {
                    $mode = 3;
                }
                elsif ( $_ eq 'M LOADAVG' ) {
                    $mode = 0;
                }
                next;
            }

            if ( $mode == 0 ) {
                $AVGSTATS{$host}     = $_;
                $AVGSTATS_HAS{$host} = 1;
            }
            elsif ( $mode == 1 ) {
                if ( 0 == index $_, $cpustring ) {
                    my ( $name, $load ) = cpu_parse_line $_;
                    $CPUSTATS{"$host;$name"} = join ';',
                      map  { $_ . '=' . $load->{$_} }
                      grep { defined $load->{$_} } keys %$load;
                }
            }
            elsif ( $mode == 2 ) {
                for my $meminfo (@meminfo) {
                    if ( $_ =~ $meminfo->[1] ) {
                        $MEMSTATS{"$host;$meminfo->[0]"} = $1;
                        $MEMSTATS_HAS{$host} = 1
                          unless defined $MEMSTATS_HAS{$host};
                    }
                }
            }
            elsif ( $mode == 3 ) {
                my ( $int, @stats ) = split ':', $_;
                $NETSTATS{"$host;$int"}       = "@stats";
                $NETSTATS{"$host;$int;stamp"} = Time::HiRes::time();
                $NETSTATS_INT{$int}  = 1 unless defined $NETSTATS_INT{$int};
                $NETSTATS_HAS{$host} = 1 unless defined $NETSTATS_HAS{$host};
            }

            if ($sigusr1) {
                $cpustring = $I{cpustring};
                $sigusr1   = 0;

            }
            elsif ($sigterm) {
                close $pipe;
                last;
            }
        }

        delete $PIDS{$pid};
    }

    return undef;
}

sub sdl_get_rect ($$) {
    my ( $rects, $name ) = @_;

    return $rects->{$name} if exists $rects->{$name};
    return $rects->{$name} = SDL::Rect->new( 0, 0, 0, 0 );
}

sub cpu_normalize_loads ($) {
    my $cpu_loads_r = shift;

    return $cpu_loads_r unless exists $cpu_loads_r->{TOTAL};

    my $total = $cpu_loads_r->{TOTAL} == 0 ? 1 : $cpu_loads_r->{TOTAL};
    my %cpu_loads =
      map { $_ => $cpu_loads_r->{$_} / ( $total / 100 ) } keys %$cpu_loads_r;
    return \%cpu_loads;
}

sub cpu_parse ($) {
    my ($line_r) = shift;

    my %stat = map {
        my ( $k, $v ) = split '=';
        $k => $v
    } split ';', $$line_r;

    return \%stat;
}

sub net_link () {
    my $key = "bytes_$C{netlink}";

    my $linkspeed = do {
        if ( defined $I{$key} ) {
            $I{$key};

        }
        else {
            int $C{netlink} * $I{bytes_mbit};
        }
    };

    my $mbit = $linkspeed / $I{bytes_mbit};

    display_warn "$mbit mbit/s is no valid reference link speed"
      unless $mbit > 0;

    display_info "Setting reference linkspeed to $mbit mbit/s";

    return $linkspeed;
}

sub net_next_int ($;$) {
    my ( $num, $initial_device_flag ) = @_;

    return $C{netint} if defined $initial_device_flag && $C{netint} ne '';

    my $int = undef;

    for ( ; ; ) {
        my @ints = sort keys %NETSTATS_INT;
        $int = $ints[ int( $num % @ints ) ] if @ints;

        unless ( defined $int ) {
            sleep 0.1;
            next;
        }

        # On startup dont show a loopback device net interface
        if ( defined $initial_device_flag && $int =~ /^lo/ ) {
            $num++;
            sleep 0.1;
            next;
        }

        last;
    }

    return $int;
}

sub net_parse ($) {
    my ($line_r) = shift;
    my ( $a, $b ) = split ' ', $$line_r;

    my %a = map {
        my ( $k, $v ) = split '=', $_;
        $k => $v;

    } split ';', $a;

    my %b = map {
        my ( $k, $v ) = split '=', $_;
        $k => $v;

    } split ';', $b;

    return [ \%a, \%b ];
}

sub net_diff ($$) {
    my ( $a_r, $b_r ) = @_;
    my %diff = map { $_ => ( $a_r->{$_} - $b_r->{$_} ) } keys %$a_r;

    return \%diff;
}

sub sdl_fill_rect {
    my ( $app, $rect, $color ) = @_;

    my $mapped_color = SDL::Video::map_RGB( $app->format(), @$color );
    SDL::Video::fill_rect( $app, $rect, $mapped_color );

    return undef;
}

sub sdl_draw_background ($$) {
    my ( $app, $rects ) = @_;
    my $rect = sdl_get_rect $rects, 'background';

    $rect->w( $C{width} );
    $rect->h( $C{height} );
    sdl_fill_rect( $app, $rect, Loadbars::Constants->BLACK );

    return undef;
}

sub threads_create (@) {
    return map { $_->detach(); $_ }
      map { threads->create( 'threads_stats', split ':' ) } @_;
}

sub auto_off_text ($) {
    my ($barwidth) = @_;

    if ( $barwidth < $C{barwidth} - 1 && $I{showtextoff} == 0 ) {
        return unless $C{showtext};
        display_warn
'Disabling text display, text does not fit into window. Press t to re-enable.';
        $I{showtextoff} = 1;
        $C{showtext}    = 0;

    }
    elsif ( $I{showtextoff} == 1 && $barwidth >= $C{barwidth} - 1 ) {
        display_info 'Re-enabling text display, text fits into window now.';
        $C{showtext}    = 1;
        $I{showtextoff} = 0;
    }

    return undef;
}

sub set_dimensions ($$) {
    my ( $width, $height ) = @_;
    my $display_info = 0;

    if ( $width < 1 ) {
        $C{width} = 1 if $C{width} != 1;

    }
    elsif ( $width > $C{maxwidth} ) {
        $C{width} = $C{maxwidth} if $C{width} != $C{maxwidth};

    }
    elsif ( $C{width} != $width ) {
        $C{width} = $width;
    }

    if ( $height < 1 ) {
        $C{height} = 1 if $C{height} != 1;

    }
    elsif ( $C{height} != $height ) {
        $C{height} = $height;
    }
}

sub loop ($@) {
    my ( $dispatch, @threads ) = @_;

    my $num_stats = 1;
    $C{width} = $C{barwidth};

    my $title = do {
        if ( defined $C{title} ) {
            $C{title};
        }
        else {
            'Loadbars ' . get_version . ' (press h for help on stdout)';
        }
    };

    my $app = SDLx::App->new(
        title      => $title,
        icon_title => Loadbars::Constants->VERSION,
        width      => $C{width},
        height     => $C{height},
        depth      => Loadbars::Constants->COLOR_DEPTH,
        resizeable => 1,
    );

=cut
    my $font = do {
        my $fontbase = 'fonts/font.png';

        if ( -f "./$fontbase" ) {
            "./$fontbase";
        }
        elsif ( -f "/usr/share/loadbars/$fontbase" ) {
            "/usr/share/loadbars/$fontbase";
        }
    };
=cut

    my ($font_name, $font_size) = ('DroidSans.ttf', 8);
    die "Could not init SDL::TTF" if SDL::TTF::init();
    my $font = SDL::TTF::open_font($font_name, $font_size);
    die "Could not open font $font_name" unless $font;

    my $rects = {};
    my %cpu_history;
    my %cpu_max;

    my %net_history;
    my %net_history_stamps;
    my %net_last_value;
    my $net_int_number = 0;
    my $net_int = net_next_int $net_int_number, 1;

    my $net_max_bytes = net_link;

    my $sdl_redraw_background = 0;
    my $sdl_font_height       = 14;

    my $infotxt : shared       = '';
    my $quit : shared          = 0;
    my $resize_window : shared = 0;
    my %newsize : shared;
    my $event = SDL::Event->new();

    my ( $t1, $t2 ) = ( Time::HiRes::time(), undef );

    # Closure for event handling
    my $event_handler = sub {

        # While there are events to poll, poll them all!
        while ( SDL::Events::poll_event($event) ) {
            next if $event->type() != 2;
            my $key_sym = $event->key_sym();

            if ( $key_sym == 49 ) {

                # 1 pressed
                $C{showcores} = !$C{showcores};
                cpu_set_showcores_re;
                $_->kill('USR1') for @threads;
                $sdl_redraw_background = 1;
                display_info "Toggled CPUs $C{showcores}";

            }
            elsif ( $key_sym == 50 ) {

                # 2 pressed
                $C{showmem} = !$C{showmem};
                display_info "Toggled show mem";

            }
            elsif ( $key_sym == 51 ) {

                # 3 pressed
                $C{shownet} = !$C{shownet};
                display_info "Toggled show net $C{shownet}";
                display_info "Net interface speed reference is "
                  . ( $net_max_bytes / $I{bytes_mbit} )
                  . "mbit/s. Press f/v to scale"
                  if $C{shownet};
            }

            elsif ( $key_sym == 101 ) {

                # e pressed
                $C{extended} = !$C{extended};
                $sdl_redraw_background = 1;
                display_info "Toggled extended display $C{extended}";

            }
            elsif ( $key_sym == 104 ) {

                # h pressed
                say '=> Hotkeys to use in the SDL interface';
                say $dispatch->('hotkeys');
                display_info 'Hotkeys help printed on terminal stdout';

            }
            elsif ( $key_sym == 109 ) {

                # m pressed
                display_warn
"Toggled show mem hotkey m is deprecated. Press 2 hotkey instead";

            }
            elsif ( $key_sym == 110 ) {

                # n pressed
                if ( $C{shownet} ) {
                    $net_int               = net_next_int ++$net_int_number;
                    $sdl_redraw_background = 1;
                    display_info "Using net interface which is $net_int";
                }
                else {
                    display_warn
"Net stats are not activated. Press 3 hotkey to activate first";
                }

            }
            elsif ( $key_sym == 116 ) {

                # t pressed
                $C{showtext} = !$C{showtext};
                $sdl_redraw_background = 1;
                display_info "Toggled text display $C{showtext}";

            }
            elsif ( $key_sym == 117 ) {

                # u pressed
                $C{showtexthost} = !$C{showtexthost};
                $sdl_redraw_background = 1;
                display_info "Toggled number/hostname display $C{showtexthost}";

            }
            elsif ( $key_sym == 113 ) {

                # q pressed
                threads_terminate_pids @threads;
                $quit = 1;
                return;

            }
            elsif ( $key_sym == 119 ) {

                # w pressed
                Loadbars::Config::write;

            }
            elsif ( $key_sym == 97 ) {

                # a pressed
                ++$C{cpuaverage};
                display_info "Set sample cpu average $C{cpuaverage}";
            }
            elsif ( $key_sym == 121 or $key_sym == 122 ) {

                # y or z pressed
                my $avg = $C{cpuaverage};
                --$avg;
                $C{cpuaverage} = $avg > 1 ? $avg : 2;
                display_info "Set sample cpu average $C{cpuaverage}";

            }
            elsif ( $key_sym == 100 ) {

                # d pressed
                ++$C{netaverage};
                display_info "Set sample net average $C{netaverage}";
            }
            elsif ( $key_sym == 99 ) {

                # c pressed
                my $avg = $C{netaverage};
                --$avg;
                $C{netaverage} = $avg > 1 ? $avg : 2;
                display_info "Set sample net average $C{netaverage}";

            }
            elsif ( $key_sym == 102 ) {

                # f pressed
                $net_max_bytes *= 10;
                display_info "Set net interface speed reference to "
                  . ( $net_max_bytes / $I{bytes_mbit} )
                  . 'mbit/s';
            }
            elsif ( $key_sym == 118 ) {

                # v pressed
                $net_max_bytes = int( $net_max_bytes / 10 );
                $net_max_bytes = $I{bytes_mbit}
                  if $net_max_bytes < $I{bytes_mbit};
                display_info "Set net interface speed reference to "
                  . int( $net_max_bytes / $I{bytes_mbit} )
                  . 'mbit/s';

            }
            elsif ( $key_sym == 276 ) {

                # left pressed
                $newsize{width}  = $C{width} - 100;
                $newsize{height} = $C{height};
                $resize_window   = 1;
            }
            elsif ( $key_sym == 275 ) {

                # right pressed
                $newsize{width}  = $C{width} + 100;
                $newsize{height} = $C{height};
                $resize_window   = 1;

            }
            elsif ( $key_sym == 273 ) {

                # up pressed
                $newsize{width}  = $C{width};
                $newsize{height} = $C{height} - 100;
                $resize_window   = 1;
            }
            elsif ( $key_sym == 274 ) {

                # down pressed
                $newsize{width}  = $C{width};
                $newsize{height} = $C{height} + 100;
                $resize_window   = 1;
            }
        }
    };

    do {
        my ( $x, $y ) = ( 0, 0 );

        # Also substract 1 (each bar is followed by an 1px separator bar)
        my $width = $C{width} / notnull($num_stats) - 1;

        my ( $current_barnum, $current_corenum ) = ( -1, -1 );

        for my $key ( sort keys %CPUSTATS ) {
            last if ( ++$current_barnum > $num_stats );
            ++$current_corenum;
            my ( $host, $name ) = split ';', $key;

            next unless defined $CPUSTATS{$key};

            $cpu_history{$key} = [ cpu_parse \$CPUSTATS{$key} ]
              unless exists $cpu_history{$key} && exists $CPUSTATS{$key};

            my $now_stat_r  = cpu_parse \$CPUSTATS{$key};
            my $prev_stat_r = $cpu_history{$key}[0];

            push @{ $cpu_history{$key} }, $now_stat_r;
            shift @{ $cpu_history{$key} }
              while $C{cpuaverage} < @{ $cpu_history{$key} };

            my %cpu_loads =
              null $now_stat_r->{TOTAL} == null $prev_stat_r->{TOTAL}
              ? %$now_stat_r
              : map { $_ => $now_stat_r->{$_} - $prev_stat_r->{$_} }
              keys %$now_stat_r;

            my $cpu_loads_r = cpu_normalize_loads \%cpu_loads;

            my %heights = map {
                    $_ => defined $cpu_loads_r->{$_}
                  ? $cpu_loads_r->{$_} * ( $C{height} / 100 )
                  : 1
            } keys %$cpu_loads_r;

            push @{ $cpu_max{$key} }, $cpu_loads_r;
            shift @{ $cpu_max{$key} }
              while $C{cpuaverage} < @{ $cpu_max{$key} };

            my $is_host_summary = $name eq 'cpu' ? 1 : 0;

            my $rect_separator = undef;

            my $rect_idle    = sdl_get_rect $rects, "$key;idle";
            my $rect_steal   = sdl_get_rect $rects, "$key;steal";
            my $rect_guest   = sdl_get_rect $rects, "$key;guest";
            my $rect_irq     = sdl_get_rect $rects, "$key;irq";
            my $rect_softirq = sdl_get_rect $rects, "$key;softirq";
            my $rect_nice    = sdl_get_rect $rects, "$key;nice";
            my $rect_iowait  = sdl_get_rect $rects, "$key;iowait";
            my $rect_user    = sdl_get_rect $rects, "$key;user";
            my $rect_system  = sdl_get_rect $rects, "$key;system";

            my $rect_peak;

            $y = $C{height} - $heights{system};
            $rect_system->w($width);
            $rect_system->h( $heights{system} );
            $rect_system->x($x);
            $rect_system->y($y);

            $y -= $heights{user};
            $rect_user->w($width);
            $rect_user->h( $heights{user} );
            $rect_user->x($x);
            $rect_user->y($y);

            $y -= $heights{nice};
            $rect_nice->w($width);
            $rect_nice->h( $heights{nice} );
            $rect_nice->x($x);
            $rect_nice->y($y);

            $y -= $heights{idle};
            $rect_idle->w($width);
            $rect_idle->h( $heights{idle} );
            $rect_idle->x($x);
            $rect_idle->y($y);

            $y -= $heights{iowait};
            $rect_iowait->w($width);
            $rect_iowait->h( $heights{iowait} );
            $rect_iowait->x($x);
            $rect_iowait->y($y);

            $y -= $heights{irq};
            $rect_irq->w($width);
            $rect_irq->h( $heights{irq} );
            $rect_irq->x($x);
            $rect_irq->y($y);

            $y -= $heights{softirq};
            $rect_softirq->w($width);
            $rect_softirq->h( $heights{softirq} );
            $rect_softirq->x($x);
            $rect_softirq->y($y);

            $y -= $heights{guest};
            $rect_guest->w($width);
            $rect_guest->h( $heights{guest} );
            $rect_guest->x($x);
            $rect_guest->y($y);

            $y -= $heights{steal};
            $rect_steal->w($width);
            $rect_steal->h( $heights{steal} );
            $rect_steal->x($x);
            $rect_steal->y($y);

            my $all     = 100 - $cpu_loads_r->{idle};
            my $max_all = 0;

            sdl_fill_rect( $app, $rect_idle,    Loadbars::Constants->BLACK );
            sdl_fill_rect( $app, $rect_steal,   Loadbars::Constants->RED );
            sdl_fill_rect( $app, $rect_guest,   Loadbars::Constants->RED );
            sdl_fill_rect( $app, $rect_irq,     Loadbars::Constants->WHITE );
            sdl_fill_rect( $app, $rect_softirq, Loadbars::Constants->WHITE );
            sdl_fill_rect( $app, $rect_nice,    Loadbars::Constants->GREEN );
            sdl_fill_rect( $app, $rect_iowait,  Loadbars::Constants->PURPLE );

            my $rect_memused = sdl_get_rect $rects, "$host;memused";
            my $rect_memfree = sdl_get_rect $rects, "$host;memfree";

            #my $rect_buffers  = sdl_get_rect $rects, "$host;buffers";
            #my $rect_cached   = sdl_get_rect $rects, "$host;cached";
            my $rect_swapused = sdl_get_rect $rects, "$host;swapused";
            my $rect_swapfree = sdl_get_rect $rects, "$host;swapfree";

            my $rect_netused = sdl_get_rect $rects, "$host;netused";
            my $rect_netfree = sdl_get_rect $rects, "$host;netfree";

            my $rect_tnetused = sdl_get_rect $rects, "$host;tnetused";
            my $rect_tnetfree = sdl_get_rect $rects, "$host;tnetfree";

            my $add_x      = 0;
            my $half_width = $width / 2;

            my %meminfo;
            if ($is_host_summary) {
                if ( $C{showmem} ) {
                    $add_x += $width + 1;

                    my $ram_per = percentage $MEMSTATS{"$host;MemTotal"},
                      $MEMSTATS{"$host;MemFree"};
                    my $swap_per = percentage $MEMSTATS{"$host;SwapTotal"},
                      $MEMSTATS{"$host;SwapFree"};

                    %meminfo = (
                        ram_per  => $ram_per,
                        swap_per => $swap_per,
                    );

                    my %heights = (
                        MemFree => $ram_per * ( $C{height} / 100 ),
                        MemUsed => ( 100 - $ram_per ) * ( $C{height} / 100 ),
                        SwapFree => $swap_per * ( $C{height} / 100 ),
                        SwapUsed => ( 100 - $swap_per ) * ( $C{height} / 100 ),
                    );

                    $y = $C{height} - $heights{MemUsed};
                    $rect_memused->w($half_width);
                    $rect_memused->h( $heights{MemUsed} );
                    $rect_memused->x( $x + $add_x );
                    $rect_memused->y($y);

                    $y -= $heights{MemFree};
                    $rect_memfree->w($half_width);
                    $rect_memfree->h( $heights{MemFree} );
                    $rect_memfree->x( $x + $add_x );
                    $rect_memfree->y($y);

                    $y = $C{height} - $heights{SwapUsed};
                    $rect_swapused->w($half_width);
                    $rect_swapused->h( $heights{SwapUsed} );
                    $rect_swapused->x( $x + $add_x + $half_width );
                    $rect_swapused->y($y);

                    $y -= $heights{SwapFree};
                    $rect_swapfree->w($half_width);
                    $rect_swapfree->h( $heights{SwapFree} );
                    $rect_swapfree->x( $x + $add_x + $half_width );
                    $rect_swapfree->y($y);

                    sdl_fill_rect( $app, $rect_memused,
                        Loadbars::Constants->DARK_GREY );
                    sdl_fill_rect( $app, $rect_memfree,
                        Loadbars::Constants->BLACK );

                    sdl_fill_rect( $app, $rect_swapused,
                        Loadbars::Constants->GREY );
                    sdl_fill_rect( $app, $rect_swapfree,
                        Loadbars::Constants->BLACK );

                    if ( $C{showtext} ) {
                        my $y_ = 5;
                        #SDLx::SFont::print_text( $app, $x + $add_x,
                        #    $y_, 'Ram:' );
                        #SDLx::SFont::print_text(
                        #    $app,
                        #    $x + $add_x,
                        #    $y_ += $sdl_font_height,
                        #    sprintf '%02d',
                        #    ( 100 - $meminfo{ram_per} )
                        #);
                        #SDLx::SFont::print_text(
                        #    $app,
                        #    $x + $add_x,
                        #    $y_ += $sdl_font_height, 'Swp:'
                        #);
                        #SDLx::SFont::print_text(
                        #    $app,
                        #    $x + $add_x,
                        #    $y_ += $sdl_font_height,
                        #    sprintf '%02d',
                        #    ( 100 - $meminfo{swap_per} )
                        #);
                    }
                }

                if ( $C{shownet} && exists $NETSTATS_HAS{$host} ) {
                    $add_x += $width + 1;

                    my $key = "$host;$net_int";
                    my %heights;

                    if ( exists $NETSTATS{$key} ) {

                        unless ( exists $net_history{$key} ) {
                            $net_history{$key} = [ net_parse \$NETSTATS{$key} ];
                            $net_history_stamps{$key} =
                              [ $NETSTATS{"$key;stamp"} ];
                        }

                        my $now_stat_stamp = $NETSTATS{"$key;stamp"};
                        my $now_stat_r     = net_parse \$NETSTATS{$key};

                        my $prev_stat_stamp = $net_history_stamps{$key}[0];

                        my $net_factor = $net_max_bytes *
                          ( $now_stat_stamp - $prev_stat_stamp );

                        push @{ $net_history_stamps{$key} }, $now_stat_stamp;
                        shift @{ $net_history_stamps{$key} }
                          while $C{netaverage} < @{ $net_history_stamps{$key} };

                        my $prev_stat_r = $net_history{$key}[0];

                        push @{ $net_history{$key} }, $now_stat_r;
                        shift @{ $net_history{$key} }
                          while $C{netaverage} < @{ $net_history{$key} };

                        my $diff_stat_r = net_diff $now_stat_r->[0],
                          $prev_stat_r->[0];

                        my $net_per =
                          percentage( $net_factor, $diff_stat_r->{b} );
                        my $tnet_per =
                          percentage( $net_factor, $diff_stat_r->{tb} );

                        if ( $net_per < 0 ) {
                            $net_per = $net_last_value{"$key;per"};
                        }
                        else {
                            $net_last_value{"$key;per"} = $net_per;
                        }

                        if ( $tnet_per < 0 ) {
                            $tnet_per = $net_last_value{"$key;tper"};
                        }
                        else {
                            $net_last_value{"$key;tper"} = $tnet_per;
                        }

                        my $net_per_100  = max_100 $net_per;
                        my $tnet_per_100 = max_100 $tnet_per;

                        %heights = (
                            NetUsed => $net_per_100 * ( $C{height} / 100 ),
                            NetFree => ( 100 - $net_per_100 ) *
                              ( $C{height} / 100 ),
                            TNetFree => $tnet_per_100 * ( $C{height} / 100 ),
                            TNetUsed => ( 100 - $tnet_per_100 ) *
                              ( $C{height} / 100 ),
                        );

                        $y = $C{height} - $heights{NetFree};
                        $rect_netused->w($half_width);
                        $rect_netused->h( $heights{NetFree} );
                        $rect_netused->x( $x + $add_x );
                        $rect_netused->y($y);

                        $y -= $heights{NetUsed};
                        $rect_netfree->w($half_width);
                        $rect_netfree->h( $heights{NetUsed} );
                        $rect_netfree->x( $x + $add_x );
                        $rect_netfree->y($y);

                        $y = $C{height} - $heights{TNetFree};
                        $rect_tnetused->w($half_width);
                        $rect_tnetused->h( $heights{TNetFree} );
                        $rect_tnetused->x( $x + $add_x + $half_width );
                        $rect_tnetused->y($y);

                        $y -= $heights{TNetUsed};
                        $rect_tnetfree->w($half_width);
                        $rect_tnetfree->h( $heights{TNetUsed} );
                        $rect_tnetfree->x( $x + $add_x + $half_width );
                        $rect_tnetfree->y($y);

                        sdl_fill_rect( $app, $rect_netused,
                            Loadbars::Constants->BLACK );
                        sdl_fill_rect( $app, $rect_netfree,
                            $net_per > 100
                            ? Loadbars::Constants->GREEN
                            : Loadbars::Constants->LIGHT_GREEN );

                        sdl_fill_rect( $app, $rect_tnetused,
                            $tnet_per > 100
                            ? Loadbars::Constants->GREEN
                            : Loadbars::Constants->LIGHT_GREEN );
                        sdl_fill_rect( $app, $rect_tnetfree,
                            Loadbars::Constants->BLACK );

                        if ( $C{showtext} ) {
                            my $y_ = 5;
                            #SDLx::SFont::print_text( $app, $x + $add_x,
                            #    $y_, $net_int );
                            #SDLx::SFont::print_text(
                            #    $app,
                            #    $x + $add_x,
                            #    $y_ += $sdl_font_height, 'Rxb:'
                            #);
                            #SDLx::SFont::print_text(
                            #    $app,
                            #    $x + $add_x,
                            #    $y_ += $sdl_font_height,
                            #    sprintf '%02d',
                            #    ($net_per)
                            #);
                            #SDLx::SFont::print_text(
                            #    $app,
                            #    $x + $add_x,
                            #    $y_ += $sdl_font_height, 'Trb:'
                            #);
                            #SDLx::SFont::print_text(
                            #    $app,
                            #    $x + $add_x,
                            #    $y_ += $sdl_font_height,
                            #    sprintf '%02d',
                            #    ($tnet_per)
                            #);
                        }

                        # No netstats available for this host;device pair.
                    }
                    else {
                        $rect_netused->w($width);
                        $rect_netused->h( $C{height} );
                        $rect_netused->x( $x + $add_x );
                        $rect_netused->y($y);

                        sdl_fill_rect( $app, $rect_netused,
                            Loadbars::Constants->RED );
                        sdl_fill_rect( $app, $rect_tnetused,
                            Loadbars::Constants->RED );
                        sdl_fill_rect( $app, $rect_netfree,
                            Loadbars::Constants->RED );
                        sdl_fill_rect( $app, $rect_tnetfree,
                            Loadbars::Constants->RED );

                        if ( $C{showtext} ) {
                            my $y_ = 5;
                            #SDLx::SFont::print_text( $app, $x + $add_x,
                            #    $y_, $net_int );
                            #SDLx::SFont::print_text(
                            #    $app,
                            #    $x + $add_x,
                            #    $y_ += $sdl_font_height, 'n/a'
                            #);
                        }
                    }

                }

                if ( $C{showcores} ) {
                    $current_corenum = 0;
                    $rect_separator = sdl_get_rect $rects, "$key;separator";
                    $rect_separator->w(1);
                    $rect_separator->h( $C{height} );
                    $rect_separator->x( $x - 1 );
                    $rect_separator->y(0);
                    sdl_fill_rect( $app, $rect_separator,
                        Loadbars::Constants->GREY );
                }
            }

            if ( $C{extended} ) {
                my $max_val = 0;

                for ( @{ $cpu_max{$key} } ) {
                    my $new_val = sum @{$_}{qw{system user}};
                    $max_val = $new_val if $max_val < $new_val;
                }

                my $maxheight = $max_val * ( $C{height} / 100 );

                $rect_peak = sdl_get_rect $rects, "$key;max";
                $rect_peak->w($width);
                $rect_peak->h(1);
                $rect_peak->x($x);
                $rect_peak->y( $C{height} - $maxheight );

                sdl_fill_rect(
                    $app,
                    $rect_peak,
                    $max_val > Loadbars::Constants->USER_ORANGE
                    ? Loadbars::Constants->ORANGE
                    : (
                        $max_val > Loadbars::Constants->USER_YELLOW0
                        ? Loadbars::Constants->YELLOW0
                        : ( Loadbars::Constants->YELLOW )
                    )
                );
            }

            sdl_fill_rect(
                $app,
                $rect_user,
                $all > Loadbars::Constants->USER_ORANGE
                ? Loadbars::Constants->ORANGE
                : (
                    $all > Loadbars::Constants->USER_YELLOW0
                    ? Loadbars::Constants->YELLOW0
                    : ( Loadbars::Constants->YELLOW )
                )
            );
            sdl_fill_rect( $app, $rect_system,
                $cpu_loads_r->{system} > Loadbars::Constants->SYSTEM_BLUE0
                ? Loadbars::Constants->BLUE0
                : Loadbars::Constants->BLUE );

            my $y = 5;

            my @loadavg = do {
                if ( defined $AVGSTATS_HAS{$host} ) {
                    split ';', $AVGSTATS{$host};
                }
                else {
                    ( undef, undef, undef );
                }
            };

#            my $font_surface = SDL::TTF::render_text_solid($font, "Hello!", Loadbars::Constants->COLOR_WHITE);
#            SDL::Video::blit_surface($font_surface, 
            if ( $C{showtext} ) {
=cut
                if ( $C{showtexthost} && $is_host_summary ) {

                    # If hostname is printed don't use FQDN
                    # because of its length.
                    $host =~ /([^\.]*)/;
                    #SDLx::SFont::print_text( $app, $x, $y, sprintf '%s:', $1 );

                }
                else {
                  #SDLx::SFont::print_text( $app, $x, $y, sprintf '%i:',
                  #      $C{showcores}
                  #    ? $current_corenum
                  #    : $current_barnum + 1 );
                }

                if ( $C{extended} ) {
                    SDLx::SFont::print_text(
                        $app, $x,
                        $y += $sdl_font_height,
                        sprintf '%02d%s',
                        norm $cpu_loads_r->{steal}, 'st'
                    );
                    SDLx::SFont::print_text(
                        $app, $x,
                        $y += $sdl_font_height,
                        sprintf '%02d%s',
                        norm $cpu_loads_r->{guest}, 'gt'
                    );
                    SDLx::SFont::print_text(
                        $app, $x,
                        $y += $sdl_font_height,
                        sprintf '%02d%s',
                        norm $cpu_loads_r->{softirq}, 'sr'
                    );
                    SDLx::SFont::print_text(
                        $app, $x,
                        $y += $sdl_font_height,
                        sprintf '%02d%s',
                        norm $cpu_loads_r->{irq}, 'ir'
                    );

                }

                SDLx::SFont::print_text(
                    $app, $x,
                    $y += $sdl_font_height,
                    sprintf '%02d%s',
                    norm $cpu_loads_r->{iowait}, 'io'
                );

                SDLx::SFont::print_text(
                    $app, $x,
                    $y += $sdl_font_height,
                    sprintf '%02d%s',
                    norm $cpu_loads_r->{idle}, 'id'
                ) if $C{extended};

                SDLx::SFont::print_text(
                    $app, $x,
                    $y += $sdl_font_height,
                    sprintf '%02d%s',
                    norm $cpu_loads_r->{nice}, 'ni'
                );
                SDLx::SFont::print_text(
                    $app, $x,
                    $y += $sdl_font_height,
                    sprintf '%02d%s',
                    norm $cpu_loads_r->{user}, 'us'
                );
                SDLx::SFont::print_text(
                    $app, $x,
                    $y += $sdl_font_height,
                    sprintf '%02d%s',
                    norm $cpu_loads_r->{system}, 'sy'
                );
                SDLx::SFont::print_text(
                    $app, $x,
                    $y += $sdl_font_height,
                    sprintf '%02d%s',
                    norm $all, 'to'
                );

                SDLx::SFont::print_text(
                    $app, $x,
                    $y += $sdl_font_height,
                    sprintf '%02d%s',
                    norm $max_all, 'pk'
                ) if $C{extended};


                if ($is_host_summary) {
                    if ( defined $loadavg[2] ) {
                        SDLx::SFont::print_text( $app, $x,
                            $y += $sdl_font_height, 'Avg:' );
                        SDLx::SFont::print_text(
                            $app, $x,
                            $y += $sdl_font_height,
                            sprintf "%.2f",
                            $loadavg[0]
                        );
                        SDLx::SFont::print_text(
                            $app, $x,
                            $y += $sdl_font_height,
                            sprintf "%.2f",
                            $loadavg[1]
                        );
                        SDLx::SFont::print_text(
                            $app, $x,
                            $y += $sdl_font_height,
                            sprintf "%.2f",
                            $loadavg[2]
                        );
                    }
                }
=cut
            }
            $app->sync();
            $x += $width + 1 + $add_x;
        }

      TIMEKEEPER:
        $t2 = Time::HiRes::time();
        my $t_diff = $t2 - $t1;

        if ( Loadbars::Constants->INTERVAL_SDL > $t_diff ) {
            usleep 10000;

            # Goto is OK as long you don't produce spaghetti code
            goto TIMEKEEPER;

        }
        elsif ( Loadbars::Constants->INTERVAL_SDL_WARN < $t_diff ) {
            display_warn
"WARN: Loop is behind $t_diff seconds, your computer may be too slow";
        }

        $t1 = $t2;
        $event_handler->();

        my $new_num_stats = keys %CPUSTATS;
        $new_num_stats += keys %MEMSTATS_HAS if $C{showmem};
        $new_num_stats += keys %NETSTATS_HAS if $C{shownet};

        if ( $new_num_stats != $num_stats ) {
            %cpu_history = ();
            %net_history = ();

            $num_stats       = $new_num_stats;
            $newsize{width}  = $C{barwidth} * $num_stats;
            $newsize{height} = $C{height};
            $resize_window   = 1;
        }

        if ($resize_window) {
            set_dimensions $newsize{width}, $newsize{height};
            $app->resize( $C{width}, $C{height} );
            $resize_window         = 0;
            $sdl_redraw_background = 1;
        }

        if ($sdl_redraw_background) {
            sdl_draw_background $app, $rects;
            $sdl_redraw_background = 0;
            %AVGSTATS              = ();
            %AVGSTATS_HAS          = ();
            %CPUSTATS              = ();
        }

        auto_off_text $width;

    } until $quit;

    say "Good bye";

    SDL::TTF::quit();
    exit Loadbars::Constants->SUCCESS;
}

1;
