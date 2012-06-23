
package Loadbars::Main;

use strict;
use warnings;

use SDL;
use SDL::App;
use SDL::Rect;
use SDL::Event;

use SDL::Surface;
use SDL::Font;

use Time::HiRes qw(usleep gettimeofday);

use Proc::ProcessTable;

use threads;
use threads::shared;

use Loadbars::Config;
use Loadbars::Constants;
use Loadbars::Shared;
use Loadbars::Utils;

$| = 1;

sub set_showcores_regexp () {
    $I{cpustring} = $C{showcores} ? 'cpu' : 'cpu ';
}

sub percentage ($$) {
    my ( $total, $part ) = @_;

    return int( null($part) / notnull( null($total) / 100 ) );
}

sub norm ($) {
    my $n = shift;

    return $n if $C{factor} != 1;
    return $n > 100 ? 100 : ( $n < 0 ? 0 : $n );
}

sub parse_cpu_line ($) {
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

sub terminate_pids (@) {
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

sub stats_thread ($;$) {
    my ( $host, $user ) = @_;
    $user = defined $user ? "-l $user" : '';

    my ( $sigusr1, $sigterm ) = ( 0, 0 );
    my $inter      = Loadbars::Constants->INTERVAL;

    my $cpustring = $I{cpustring};

    # Precompile some regexp
    my $loadavg_re = qr/^(\d+\.\d{2}) (\d+\.\d{2}) (\d+\.\d{2})/;
    my @meminfo = 
        map { [$_, qr/^$_: *(\d+)/] } 
        (qw(MemTotal MemFree Buffers Cached SwapTotal SwapFree));
    my $whitespace_re = qr/ +/;

    until ($sigterm) {
        my $remotecode = <<"REMOTECODE";
            perl -le '
                use strict;

                my \\\$whitespace_re = qr/ +/;

                sub cat {
                    my \\\$file = shift;
                    open FH, \\\$file;
                    while (<FH>) {
                        print;
                    }
                    close FH;
                }

                sub load {
                    printf qq(LOADAVG\n);
                    open FH, qq(/proc/loadavg);
                    printf qq(%s\n), join qq(;), (split qq( ), <FH>)[0..2];
                    close FH;
                }

                sub net {
                    printf qq(NETSTATS\n);
                    open FH, qq(/proc/net/dev);
                    <FH>; <FH>;
                    while (<FH>) {
                        s/://;
                        my (\\\$foo, \\\$int, \\\$bytes, \\\$packets, \\\$errs, \\\$drop, \\\$fifo, \\\$frame, \\\$compressed, \\\$multicast, \\\$tbytes, \\\$tpackets, \\\$terrs, \\\$tdrop, \\\$tfifo, \\\$tcolls, \\\$tcarrier, \\\$tcompressed) = split \\\$whitespace_re, \\\$_;
                        printf qq(%s;b:%s\n), \\\$int, \\\$bytes;
                        printf qq(%s;tb:%s\n), \\\$int, \\\$tbytes;
                        printf qq(%s;p:%s\n), \\\$int, \\\$packets;
                        printf qq(%s;tp:%s\n), \\\$int, \\\$tpackets;
                        printf qq(%s;d:%s\n), \\\$int, \\\$drop;
                        printf qq(%s;td:%s\n), \\\$int, \\\$tdrop;
                    }
                    close FH;
                }

                for (0..$C{samples}) {
                    load();
                    printf qq(CPUSTATS\n);
                    cat(qq(/proc/stat));
                    printf qq(MEMSTATS\n);
                    cat(qq(/proc/meminfo));
                    net();

                    sleep $inter;
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

        # 0=loadavg, 1=cpu, 2=mem, 3=net
        my $mode = 0;

        while (<$pipe>) {
            chomp;

            if ( $mode == 0 ) {
                if ( $_ eq 'CPUSTATS' ) {
                    $mode = 1;

                }
                else {
                    $AVGSTATS{$host} = $_;
                }
            }
            elsif ( $mode == 1 ) {
                if ( $_ eq 'MEMSTATS' ) {
                    $mode = 2;

                }
                elsif (0 == index $_, $cpustring) {
                    my ( $name, $load ) = parse_cpu_line $_;
                    $CPUSTATS{"$host;$name"} = join ';',
                      map  { $_ . '=' . $load->{$_} }
                      grep { defined $load->{$_} } keys %$load;
                }
                elsif ($_ =~ $loadavg_re) {
                    $AVGSTATS{$host} = "$1;$2;$3";

                }
            }
            elsif ( $mode == 2 ) {
                if ( $_ eq 'NETSTATS' ) {
                    $mode = 3;

                }
                else {
                    for my $meminfo (@meminfo)
                    {
                        if ($_ =~ $meminfo->[1]) {
                            $MEMSTATS{"$host;$meminfo->[0]"} = $1;
                            $MEMSTATS_HAS{$host} = 1 unless defined $MEMSTATS_HAS{$host};
                        }
                    }
                }
            }
            elsif ( $mode == 3 ) {
                if ( $_ eq 'LOADAVG' ) {
                    $mode = 0;

                }
                else {
                    #$NETSTATS{$host} = $_;
                    #$NETSTATS_HAS{$host} = 1 unless defined $NETSTATS_HAS{$host};
                }
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

sub get_rect ($$) {
    my ( $rects, $name ) = @_;

    return $rects->{$name} if exists $rects->{$name};
    return $rects->{$name} = SDL::Rect->new();
}

sub normalize_loads (%) {
    my %loads = @_;

    return %loads unless exists $loads{TOTAL};

    my $total = $loads{TOTAL} == 0 ? 1 : $loads{TOTAL};
    return map { $_ => $loads{$_} / ( $total / 100 ) } keys %loads;
}

sub get_cpuaverage ($@) {
    my ( $factor, @loads ) = @_;
    my ( %cpumax, %cpuaverage );

    for my $l (@loads) {
        for ( keys %$l ) {
            $cpuaverage{$_} += $l->{$_};

            $cpumax{$_} = $l->{$_}
              if not exists $cpumax{$_}
                  or $cpumax{$_} < $l->{$_};
        }
    }

    my $div = @loads / $factor;

    for ( keys %cpuaverage ) {
        $cpuaverage{$_} /= $div;
        $cpumax{$_}     /= $factor;
    }

    return ( \%cpumax, \%cpuaverage );
}

sub draw_background ($$) {
    my ( $app, $rects ) = @_;
    my $rect = get_rect $rects, 'background';

    $rect->width( $C{width} );
    $rect->height( $C{height} );
    $app->fill( $rect, Loadbars::Constants->BLACK );
    $app->update($rect);

    return undef;
}

sub create_threads (@) {
    return map { $_->detach(); $_ }
      map { threads->create( 'stats_thread', split ':' ) } @_;
}

sub auto_off_text ($) {
    my ($barwidth) = @_;

    if ( $barwidth < $C{barwidth} - 1 && $I{showtextoff} == 0 ) {
        return unless $C{showtext};
        display_warn
'Disabling text display, text does not fit into window. Use \'t\' to re-enable.';
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
        if (defined $C{title}) {
            $C{title};
        } else {
            'Loadbars ' . get_version . ' (press h for help on stdout)';
        }
    };

    my $app = SDL::App->new(
        -title => $title,
        -icon_title => Loadbars::Constants->VERSION,
        -width      => $C{width},
        -height     => $C{height},
        -depth      => Loadbars::Constants->COLOR_DEPTH,
        -resizeable => 1,
    );

    my $font = do {
        my $fontbase = 'fonts/font.png';

        if ( -f "./$fontbase" ) {
            "./$fontbase";
        }
        elsif ( -f "/usr/share/loadbars/$fontbase" ) {
            "/usr/share/loadbars/$fontbase";
        }
    };

    SDL::Font->new($font)->use();

    my $rects = {};
    my %prev_stats;
    my %last_loads;

    my $redraw_background = 0;
    my $font_height       = 14;

    my $infotxt : shared       = '';
    my $quit : shared          = 0;
    my $resize_window : shared = 0;
    my %newsize : shared;
    my $event = SDL::Event->new();

    my ( $t1, $t2 ) = ( Time::HiRes::time(), undef );

    # Closure for event handling
    my $event_handler = sub {

        # While there are events to poll, poll them all!
        while ( $event->poll() == 1 ) {
            next if $event->type() != 2;
            my $key_name = $event->key_name();

            if ( $key_name eq '1' ) {
                $C{showcores} = !$C{showcores};
                set_showcores_regexp;
                $_->kill('USR1') for @threads;
                %AVGSTATS          = ();
                %CPUSTATS          = ();
                $redraw_background = 1;
                display_info 'Toggled CPUs';

            }
            elsif ( $key_name eq 'e' ) {
                $C{extended} = !$C{extended};
                $redraw_background = 1;
                display_info 'Toggled extended display';

            }
            elsif ( $key_name eq 'h' ) {
                say '=> Hotkeys to use in the SDL interface';
                say $dispatch->('hotkeys');
                display_info 'Hotkeys help printed on terminal stdout';

            }
            elsif ( $key_name eq 'm' ) {
                $C{showmem} = !$C{showmem};
                display_info 'Toggled show mem';

            }
            elsif ( $key_name eq 't' ) {
                $C{showtext} = !$C{showtext};
                $redraw_background = 1;
                display_info 'Toggled text display';

            }
            elsif ( $key_name eq 'u' ) {
                $C{showtexthost} = !$C{showtexthost};
                $redraw_background = 1;
                display_info 'Toggled number/hostname display';

            }
            elsif ( $key_name eq 'q' ) {
                terminate_pids @threads;
                $quit = 1;
                return;

            }
            elsif ( $key_name eq 'w' ) {
                Loadbars::Config::write;

            }
            elsif ( $key_name eq 'a' ) {
                ++$C{average};
                display_info "Set sample average to $C{average}";
            }
            elsif ( $key_name eq 'y' or $key_name eq 'z' ) {
                my $avg = $C{average};
                --$avg;
                $C{average} = $avg > 1 ? $avg : 2;
                display_info "Set sample average to $C{average}";

            }
            elsif ( $key_name eq 's' ) {
                $C{factor} += 0.1;
                display_info "Set scale factor to $C{factor}";
            }
            elsif ( $key_name eq 'x' or $key_name eq 'z' ) {
                $C{factor} -= 0.1;
                display_info "Set scale factor to $C{factor}";

            }
            elsif ( $key_name eq 'left' ) {
                $newsize{width}  = $C{width} - 100;
                $newsize{height} = $C{height};
                $resize_window   = 1;
            }
            elsif ( $key_name eq 'right' ) {
                $newsize{width}  = $C{width} + 100;
                $newsize{height} = $C{height};
                $resize_window   = 1;

            }
            elsif ( $key_name eq 'up' ) {
                $newsize{width}  = $C{width};
                $newsize{height} = $C{height} - 100;
                $resize_window   = 1;
            }
            elsif ( $key_name eq 'down' ) {
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

            my %stat = map {
                my ( $k, $v ) = split '=';
                $k => $v

            } split ';', $CPUSTATS{$key};

            unless ( exists $prev_stats{$key} ) {
                $prev_stats{$key} = \%stat;
                next;
            }

            my $prev_stat = $prev_stats{$key};
            my %loads =
              null $stat{TOTAL} == null $prev_stat->{TOTAL}
              ? %stat
              : map { $_ => $stat{$_} - $prev_stat->{$_} } keys %stat;

            $prev_stats{$key} = \%stat;

            %loads = normalize_loads %loads;
            push @{ $last_loads{$key} }, \%loads;
            shift @{ $last_loads{$key} }
              while @{ $last_loads{$key} } >= $C{average};

            my ( $cpumax, $cpuaverage ) = get_cpuaverage $C{factor},
              @{ $last_loads{$key} };

            my %heights = map {
                    $_ => defined $cpuaverage->{$_}
                  ? $cpuaverage->{$_} * ( $C{height} / 100 )
                  : 1
            } keys %$cpuaverage;

            my $is_host_summary = $name eq 'cpu' ? 1 : 0;

            my $rect_separator = undef;

            my $rect_idle    = get_rect $rects, "$key;idle";
            my $rect_steal   = get_rect $rects, "$key;steal";
            my $rect_guest   = get_rect $rects, "$key;guest";
            my $rect_irq     = get_rect $rects, "$key;irq";
            my $rect_softirq = get_rect $rects, "$key;softirq";
            my $rect_nice    = get_rect $rects, "$key;nice";
            my $rect_iowait  = get_rect $rects, "$key;iowait";
            my $rect_user    = get_rect $rects, "$key;user";
            my $rect_system  = get_rect $rects, "$key;system";

            my $rect_peak;

            $y = $C{height} - $heights{system};
            $rect_system->width($width);
            $rect_system->height( $heights{system} );
            $rect_system->x($x);
            $rect_system->y($y);

            $y -= $heights{user};
            $rect_user->width($width);
            $rect_user->height( $heights{user} );
            $rect_user->x($x);
            $rect_user->y($y);

            $y -= $heights{nice};
            $rect_nice->width($width);
            $rect_nice->height( $heights{nice} );
            $rect_nice->x($x);
            $rect_nice->y($y);

            $y -= $heights{idle};
            $rect_idle->width($width);
            $rect_idle->height( $heights{idle} );
            $rect_idle->x($x);
            $rect_idle->y($y);

            $y -= $heights{iowait};
            $rect_iowait->width($width);
            $rect_iowait->height( $heights{iowait} );
            $rect_iowait->x($x);
            $rect_iowait->y($y);

            $y -= $heights{irq};
            $rect_irq->width($width);
            $rect_irq->height( $heights{irq} );
            $rect_irq->x($x);
            $rect_irq->y($y);

            $y -= $heights{softirq};
            $rect_softirq->width($width);
            $rect_softirq->height( $heights{softirq} );
            $rect_softirq->x($x);
            $rect_softirq->y($y);

            $y -= $heights{guest};
            $rect_guest->width($width);
            $rect_guest->height( $heights{guest} );
            $rect_guest->x($x);
            $rect_guest->y($y);

            $y -= $heights{steal};
            $rect_steal->width($width);
            $rect_steal->height( $heights{steal} );
            $rect_steal->x($x);
            $rect_steal->y($y);

            my $all     = 100 - $cpuaverage->{idle};
            my $max_all = 0;

            $app->fill( $rect_idle,    Loadbars::Constants->BLACK );
            $app->fill( $rect_steal,   Loadbars::Constants->RED );
            $app->fill( $rect_guest,   Loadbars::Constants->RED );
            $app->fill( $rect_irq,     Loadbars::Constants->WHITE );
            $app->fill( $rect_softirq, Loadbars::Constants->WHITE );
            $app->fill( $rect_nice,    Loadbars::Constants->GREEN );
            $app->fill( $rect_iowait,  Loadbars::Constants->PURPLE );

            my $add_x         = 0;
            my $rect_memused  = get_rect $rects, "$host;memused";
            my $rect_memfree  = get_rect $rects, "$host;memfree";
            my $rect_buffers  = get_rect $rects, "$host;buffers";
            my $rect_cached   = get_rect $rects, "$host;cached";
            my $rect_swapused = get_rect $rects, "$host;swapused";
            my $rect_swapfree = get_rect $rects, "$host;swapfree";

            my %meminfo;
            if ($is_host_summary) {
                if ( $C{showmem} ) {
                    $add_x = $width + 1;

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

                    my $half_width = $width / 2;
                    $y = $C{height} - $heights{MemUsed};
                    $rect_memused->width($half_width);
                    $rect_memused->height( $heights{MemUsed} );
                    $rect_memused->x( $x + $add_x );
                    $rect_memused->y($y);

                    $y -= $heights{MemFree};
                    $rect_memfree->width($half_width);
                    $rect_memfree->height( $heights{MemFree} );
                    $rect_memfree->x( $x + $add_x );
                    $rect_memfree->y($y);

                    $y = $C{height} - $heights{SwapUsed};
                    $rect_swapused->width($half_width);
                    $rect_swapused->height( $heights{SwapUsed} );
                    $rect_swapused->x( $x + $add_x + $half_width );
                    $rect_swapused->y($y);

                    $y -= $heights{SwapFree};
                    $rect_swapfree->width($half_width);
                    $rect_swapfree->height( $heights{SwapFree} );
                    $rect_swapfree->x( $x + $add_x + $half_width );
                    $rect_swapfree->y($y);

                    $app->fill( $rect_memused, Loadbars::Constants->DARK_GREY );
                    $app->fill( $rect_memfree, Loadbars::Constants->BLACK );

                    $app->fill( $rect_swapused, Loadbars::Constants->GREY );
                    $app->fill( $rect_swapfree, Loadbars::Constants->BLACK );
                }

                if ( $C{showcores} ) {
                    $current_corenum = 0;
                    $rect_separator = get_rect $rects, "$key;separator";
                    $rect_separator->width(1);
                    $rect_separator->height( $C{height} );
                    $rect_separator->x( $x - 1 );
                    $rect_separator->y(0);
                    $app->fill( $rect_separator, Loadbars::Constants->GREY );
                }
            }

            if ( $C{extended} ) {
                my %maxheights = map {
                        $_ => defined $cpumax->{$_}
                      ? $cpumax->{$_} * ( $C{height} / 100 )
                      : 1
                } keys %$cpumax;

                $rect_peak = get_rect $rects, "$key;max";
                $rect_peak->width($width);
                $rect_peak->height(1);
                $rect_peak->x($x);
                $rect_peak->y(
                    $C{height} - $maxheights{system} - $maxheights{user} );

                $max_all =
                  sum @{$cpumax}
                  {qw(user system iowait irq softirq steal guest)};

                $app->fill(
                    $rect_peak,
                    $max_all > Loadbars::Constants->USER_ORANGE
                    ? Loadbars::Constants->ORANGE
                    : (
                        $max_all > Loadbars::Constants->USER_YELLOW0
                        ? Loadbars::Constants->YELLOW0
                        : ( Loadbars::Constants->YELLOW )
                    )
                );
            }

            $app->fill(
                $rect_user,
                $all > Loadbars::Constants->USER_ORANGE
                ? Loadbars::Constants->ORANGE
                : (
                    $all > Loadbars::Constants->USER_YELLOW0
                    ? Loadbars::Constants->YELLOW0
                    : ( Loadbars::Constants->YELLOW )
                )
            );
            $app->fill( $rect_system,
                $cpuaverage->{system} > Loadbars::Constants->SYSTEM_BLUE0
                ? Loadbars::Constants->BLUE0
                : Loadbars::Constants->BLUE );

            my ( $y, $space ) = ( 5, $font_height );

            my @loadavg = split ';', $AVGSTATS{$host};

            if ( $C{showtext} ) {
                if ( $C{showmem} && $is_host_summary ) {
                    my $y_ = $y;
                    $app->print( $x + $add_x, $y_, 'Ram:' );
                    $app->print(
                        $x + $add_x,
                        $y_ += $space,
                        sprintf '%02d',
                        ( 100 - $meminfo{ram_per} )
                    );
                    $app->print( $x + $add_x, $y_ += $space, 'Swp:' );
                    $app->print(
                        $x + $add_x,
                        $y_ += $space,
                        sprintf '%02d',
                        ( 100 - $meminfo{swap_per} )
                    );
                }
                if ( $C{showtexthost} && $is_host_summary ) {

                    # If hostname is printed don't use FQDN
                    # because of its length.
                    $host =~ /([^\.]*)/;
                    $app->print( $x, $y, sprintf '%s:', $1 );

                }
                else {
                    $app->print( $x, $y, sprintf '%i:',
                          $C{showcores}
                        ? $current_corenum
                        : $current_barnum + 1 );
                }

                if ( $C{extended} ) {
                    $app->print(
                        $x,
                        $y += $space,
                        sprintf '%02d%s',
                        norm $cpuaverage->{steal}, 'st'
                    );
                    $app->print(
                        $x,
                        $y += $space,
                        sprintf '%02d%s',
                        norm $cpuaverage->{guest}, 'gt'
                    );
                    $app->print(
                        $x,
                        $y += $space,
                        sprintf '%02d%s',
                        norm $cpuaverage->{softirq}, 'sr'
                    );
                    $app->print(
                        $x,
                        $y += $space,
                        sprintf '%02d%s',
                        norm $cpuaverage->{irq}, 'ir'
                    );
                }

                $app->print(
                    $x,
                    $y += $space,
                    sprintf '%02d%s',
                    norm $cpuaverage->{iowait}, 'io'
                );

                $app->print(
                    $x,
                    $y += $space,
                    sprintf '%02d%s',
                    norm $cpuaverage->{idle}, 'id'
                ) if $C{extended};

                $app->print(
                    $x,
                    $y += $space,
                    sprintf '%02d%s',
                    norm $cpuaverage->{nice}, 'ni'
                );
                $app->print(
                    $x,
                    $y += $space,
                    sprintf '%02d%s',
                    norm $cpuaverage->{user}, 'us'
                );
                $app->print(
                    $x,
                    $y += $space,
                    sprintf '%02d%s',
                    norm $cpuaverage->{system}, 'sy'
                );
                $app->print(
                    $x,
                    $y += $space,
                    sprintf '%02d%s',
                    norm $all, 'to'
                );

                $app->print(
                    $x,
                    $y += $space,
                    sprintf '%02d%s',
                    norm $max_all, 'pk'
                ) if $C{extended};

                if ($is_host_summary) {
                    if ( defined $loadavg[0] ) {
                        $app->print( $x, $y += $space, 'Avg:' );
                        $app->print(
                            $x,
                            $y += $space,
                            sprintf "%.2f",
                            $loadavg[0]
                        );
                        $app->print(
                            $x,
                            $y += $space,
                            sprintf "%.2f",
                            $loadavg[1]
                        );
                        $app->print(
                            $x,
                            $y += $space,
                            sprintf "%.2f",
                            $loadavg[2]
                        );
                    }
                }
            }

            $app->update(
                $rect_idle,  $rect_iowait,  $rect_irq,
                $rect_nice,  $rect_softirq, $rect_steal,
                $rect_guest, $rect_system,  $rect_user,
            );

            $app->update(
                $rect_memfree,  $rect_memused,
                $rect_swapused, $rect_swapfree
            ) if $C{showmem};
            $app->update($rect_separator) if defined $rect_separator;

            $x += $width + 1 + $add_x;

        }

      TIMEKEEPER:
        $t2 = Time::HiRes::time();
        my $t_diff = $t2 - $t1;

        if ( Loadbars::Constants->INTERVAL > $t_diff ) {
            usleep 10000;

            # Goto is OK as long you don't produce spaghetti code
            goto TIMEKEEPER;

        }
        elsif ( Loadbars::Constants->INTERVAL_WARN < $t_diff ) {
            display_warn
"WARN: Loop is behind $t_diff seconds, your computer may be too slow";
        }

        $t1 = $t2;
        $event_handler->();

        my $new_num_stats = keys %CPUSTATS;
        $new_num_stats += keys %MEMSTATS_HAS if $C{showmem};

        if ( $new_num_stats != $num_stats ) {
            %prev_stats = ();
            %last_loads = ();

            $num_stats       = $new_num_stats;
            $newsize{width}  = $C{barwidth} * $num_stats;
            $newsize{height} = $C{height};
            $resize_window   = 1;
        }

        if ($resize_window) {
            set_dimensions $newsize{width}, $newsize{height};
            $app->resize( $C{width}, $C{height} );
            $resize_window     = 0;
            $redraw_background = 1;
        }

        if ($redraw_background) {
            draw_background $app, $rects;
            $redraw_background = 0;
        }

        auto_off_text $width;

    } until $quit;

    say "Good bye";

    exit Loadbars::Constants->SUCCESS;
}

1;
