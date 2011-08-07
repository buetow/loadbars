#!/usr/bin/perl

# loadbars (c) 2010-2011, Dipl.-Inform. (FH) Paul Buetow
#
# 	E-Mail: loadbars@mx.buetow.org 	WWW: http://loadbars.buetow.org
#
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in the
#       documentation and/or other materials provided with the distribution.
#     * Neither the name of buetow.org nor the names of its contributors may
#       be used to endorse or promote products derived from this software
#       without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED Paul Buetow ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT Paul Buetow BE LIABLE FOR ANY DIRECT,
# INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
#  SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
# STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
# IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

use strict;
use warnings;

use Getopt::Long;

use SDL::App;
use SDL::Rect;
use SDL::Color;
use SDL::Event;

use SDL::Surface;
use SDL::Font;

use Time::HiRes qw(usleep gettimeofday);

use threads;
use threads::shared;

use constant {
	DEPTH => 8,
	VERSION => 'loadbars v0.2.1-devel',
	COPYRIGHT => '2010-2011 (c) Paul Buetow <loadbars@mx.buetow.org>',
	BLACK => SDL::Color->new(-r => 0x00, -g => 0x00, -b => 0x00),
	BLUE => SDL::Color->new(-r => 0x00, -g => 0x00, -b => 0xff),
	GREEN => SDL::Color->new(-r => 0x00, -g => 0x90, -b => 0x00),
	ORANGE => SDL::Color->new(-r => 0xff, -g => 0x70, -b => 0x00),
	PURPLE => SDL::Color->new(-r => 0xa0, -g => 0x20, -b => 0xf0),
	RED => SDL::Color->new(-r => 0xff, -g => 0x00, -b => 0x00),
	WHITE => SDL::Color->new(-r => 0xff, -g => 0xff, -b => 0xff),
	YELLOW0 => SDL::Color->new(-r => 0xff, -g => 0xa0, -b => 0x00),
	YELLOW => SDL::Color->new(-r => 0xff, -g => 0xc0, -b => 0x00),
	SYSTEM_PURPLE => 30,
	USER_WHITE => 99,
	USER_RED => 90,
	USER_ORANGE => 70,
	USER_YELLOW0 => 50,
	NULL => 0,
	DEBUG => 0,
};

$| = 1;

my %AVGSTATS : shared;
my %CPUSTATS : shared;
my %CONF : shared;

# Setting defaults
%CONF = (
	title => VERSION . ' (press h for help)',
	average => 30,
	togglecpu => 1,
	cpuregexp => 'cpu',
	factor => 1,
	displaytxt => 1,
	displaytxthost => 0,
	inter => 0.1,
	samples => 1000,
	sshopts => '',
	width => 1200,
	height => 200,
);

# Quick n dirty helpers
sub say (@) { print "$_\n" for @_; return undef }
sub newline () { say ''; return undef }
sub debugsay (@) { say "DEBUG: $_" for @_; return undef }
sub sum (@) { my $sum = 0; $sum += $_ for @_; return $sum }
sub null ($) { my $arg = shift; return defined $arg ? $arg : 0 }
sub set_togglecpu_regexp () { $CONF{cpuregexp} = $CONF{togglecpu} ? 'cpu ' : 'cpu' }

sub parse_cpu_line ($) {
	my ($name, %load);

	($name, @load{qw(user nice system iowait irq softirq)}) = split ' ', shift;
	$load{TOTAL} = sum @load{qw(user nice system iowait)};

	return ($name, \%load);
}

sub thread_get_stats ($) {
	my $host = shift;

	my $sigusr1 = 0;
	my $loadavgexp = qr/(\d+\.\d{2}) (\d+\.\d{2}) (\d+\.\d{2})/;

	for (;;) {
		my $bash = <<"BASH";
			if [ -e /proc/stat ]; then 
				loadavg=/proc/loadavg
				stat=/proc/stat
			else 
			   	loadavg=/compat/linux/proc/loadavg
			   	stat=/compat/linux/proc/stat
			fi
			
			for i in \$(seq $CONF{samples}); do 
			   	cat \$loadavg \$stat
				sleep $CONF{inter}
			done
BASH
		my $cmd = $host eq 'localhost' ? $bash 
			: "ssh -o StrictHostKeyChecking=no $CONF{sshopts} $host '$bash'";

		my $pid = open my $pipe, "$cmd |" or do {
			say "Warning: $!";
			sleep 3;
			next;
		};

		# Toggle CPUs
		$SIG{USR1} = sub { $sigusr1 = 1 };
		my $cpuregexp = qr/$CONF{cpuregexp}/;

		while (<$pipe>) {		
	   		if (/^$loadavgexp/) {
				$AVGSTATS{$host} = "$1;$2;$3";

			} elsif (/$cpuregexp/) {
				my ($name, $load) = parse_cpu_line $_;
				$CPUSTATS{"$host;$name"} = join ';', 
				   	map { $_ . '=' . $load->{$_} } keys %$load;
			}

			if ($sigusr1) {
				$cpuregexp = qr/$CONF{cpuregexp}/;
				$sigusr1 = 0;
			}
		}

	} 

	return undef;
}

sub get_rect ($$) {
	my ($rects, $name) = @_;

	return $rects->{$name} if exists $rects->{$name};
	return $rects->{$name} = SDL::Rect->new();
}

sub normalize_loads (%) {
  	my %loads = @_;

	return %loads unless exists $loads{TOTAL};

	my $total = $loads{TOTAL} == 0 ? 1 : $loads{TOTAL};
	return map { $_ => $loads{$_} / ($total / 100) } keys %loads;
}

sub get_cpuaverage ($@) {
	my ($factor, @loads) = @_;	
	my %cpuaverage;

	for my $l (@loads) {
		$cpuaverage{$_} += $l->{$_} for keys %$l;
	}

	my $div = @loads / $factor;
	$cpuaverage{$_} /= $div for keys %cpuaverage;

	return %cpuaverage;
}

sub draw_background ($$) {
   	my ($app, $rects) = @_;
	my $rect = get_rect $rects, 'background';

	$rect->width($CONF{width});
	$rect->height($CONF{height});
	$app->fill($rect, BLACK);
	$app->update($rect);

	return undef;
}

sub create_threads (@) {
	return map { $_->detach(); $_ } map { threads->create('thread_get_stats', $_) } @_;
}

sub main_loop ($@) {
	my ($dispatch, @threads) = @_;

	# Planned for the future
	my $statusbar_height = 0;

	my $app = SDL::App->new(
		-title => $CONF{title},
		-icon_title => $CONF{title},
		-width => $CONF{width},
		-height => $CONF{height}+$statusbar_height,
		-depth => DEPTH,
		-resizeable => 0,
	);

	SDL::Font->new('font.png')->use();

	my $num_stats = keys %CPUSTATS;

	my $rects = {};
	my %prev_stats;
	my %last_loads;

	my $redraw_background = 0;
	my $font_height = 14;

	my $displayinfo_time = 5;
	my $displayinfo_start = 0;
	my $displayinfo : shared = '';
	my $infotxt : shared = '';
	my $quit : shared = 0;

	$SIG{STOP} = sub { $quit = 1 };

	my ($t1, $t2) = (Time::HiRes::time(), undef);
	my $event = SDL::Event->new();

	my $event_thread = async {
		for (;;) {
			$event->pump();
			$event->poll();
			$event->wait();

			my $type = $event->type();
			my $key_name = $event->key_name(); 

			debugsay "Event type=$type key_name=$key_name" if DEBUG;
			next if $type != 2;

			if ($key_name eq '1') {
				$CONF{togglecpu} = !$CONF{togglecpu};
				set_togglecpu_regexp;
				$_->kill('USR1') for @threads;
				%AVGSTATS = ();
				%CPUSTATS = ();
				$displayinfo = 'Toggled CPUs';
			
			} elsif ($key_name eq 'h') {
				say '=> Hotkeys to use in the SDL interface';
				say $dispatch->('hotkeys');
				$displayinfo = 'Hotkeys help printed on terminal stdout';

			} elsif ($key_name eq 't') {
				$CONF{displaytxt} = !$CONF{displaytxt};	
				$displayinfo = 'Toggled text display';
			
			} elsif ($key_name eq 'u') {
				$CONF{displaytxthost} = !$CONF{displaytxthost};	
				$displayinfo = 'Toggled number/hostname display';

			} elsif ($key_name eq 'q') {
				$quit = 1;
				last;

			# Increase and decrease pairs
			} elsif ($key_name eq 'a') {
				++$CONF{average};
				$displayinfo = "Set sample average to $CONF{average}";
			} elsif ($key_name eq 'y' or $key_name eq 'z') {
				my $avg = $CONF{average};
				--$avg;
				$CONF{average} = $avg > 1 ? $avg : 2;
				$displayinfo = "Set sample average to $CONF{average}";
			
			} elsif ($key_name eq 's') {
				$CONF{factor} += 0.1;
				$displayinfo = "Set scale factor to $CONF{factor}";
			} elsif ($key_name eq 'x' or $key_name eq 'z') {
				$CONF{factor} -= 0.1;
				$displayinfo = "Set scale factor to $CONF{factor}";

			} elsif ($key_name eq 'd') {
				$CONF{inter} += 0.1;
				$displayinfo = "Set graph update interval to $CONF{inter}";
			} elsif ($key_name eq 'c' or $key_name eq 'z') {
				my $int = $CONF{inter};
				$int -= 0.1;
				$CONF{inter} = $int > 0 ? $int : 0.1;
				$displayinfo = "Set graph update interval to $CONF{inter}";

=cut
			} elsif ($key_name eq 'down') {
				my $height = $CONF{height} + 10;
				$app->resize($CONF{width},$height);
				$CONF{height} = $height;
				$displayinfo = "Set graph height to $CONF{height}";
			} elsif ($key_name eq 'up') {
				my $height = $CONF{height};
				$height -= 10;
				$CONF{height} = $height > 1 ? $height : 1;
				$app->resize($CONF{width},$CONF{height});
				$displayinfo = "Set graph height to $CONF{height}";

			} elsif ($key_name eq 'right') {
				$CONF{width} += 10;
				$app->resize($CONF{width},$CONF{height});
				$displayinfo = "Set graph width to $CONF{width}";
			} elsif ($key_name eq 'left') {
				my $width = $CONF{width};
				$width -= 10;
				$CONF{width} = $width > 1 ? $width : 1;
				$app->resize($CONF{width},$CONF{height});
				$displayinfo = "Set graph width to $CONF{width}";
=cut
			}
		}
	};

	do {
		my ($x, $y) = (0, 0);
		my %is_host_summary;

		my $new_num_stats = keys %CPUSTATS;

		if ($new_num_stats != $num_stats) {
			%prev_stats = ();
			%last_loads = ();
	
			$num_stats = $new_num_stats;
			$redraw_background = 1;
		}

		# Avoid division by null
		my $width = $CONF{width} / ($num_stats ? $num_stats : 1);

		my $barnum = -1;
		for my $key (sort keys %CPUSTATS) {
			++$barnum;
			my ($host, $name) = split ';', $key;

			next unless defined $CPUSTATS{$key};

			my %stat = map { 
			   	my ($k, $v) = split '='; $k => $v 

			} split ';', $CPUSTATS{$key};

			unless (exists $prev_stats{$key}) {
				$prev_stats{$key} = \%stat;
				next;
			}

			my $prev_stat = $prev_stats{$key};
			my %loads = null $stat{TOTAL} == null $prev_stat->{TOTAL} 
				? %stat : map { 
					$_ => $stat{$_} - $prev_stat->{$_} 
				} keys %stat;

			$prev_stats{$key} = \%stat;

			%loads = normalize_loads %loads;
			push @{$last_loads{$key}}, \%loads;
			shift @{$last_loads{$key}} while @{$last_loads{$key}} >= $CONF{average};

			my %cpuaverage = get_cpuaverage $CONF{factor}, @{$last_loads{$key}};

			my %heights = map { 
				$_ => defined $cpuaverage{$_} ? $cpuaverage{$_} * ($CONF{height}/100) : 1 

			} keys %cpuaverage;
			
			my $rect_user = get_rect $rects, "$key;user";
			my $rect_system = get_rect $rects, "$key;system";
			my $rect_iowait = get_rect $rects, "$key;iowait";
			my $rect_nice = get_rect $rects, "$key;nice";
			
			$y = $CONF{height} - $heights{system};
			$rect_system->width($width);
			$rect_system->height($heights{system});
			$rect_system->x($x);
			$rect_system->y($y);
			
			$y -= $heights{user};
			$rect_user->width($width);
			$rect_user->height($heights{user});
			$rect_user->x($x);
			$rect_user->y($y);
			
			$y -= $heights{nice};
			$rect_nice->width($width);
			$rect_nice->height($heights{nice});
			$rect_nice->x($x);
			$rect_nice->y($y);
			
			$y -= $heights{iowait};
			$rect_iowait->width($width);
			$rect_iowait->height($heights{iowait});
			$rect_iowait->x($x);
			$rect_iowait->y($y);
			
			my $system_n_user = sum @cpuaverage{qw(user system)};
			
			$app->fill($rect_iowait, BLACK);
			$app->fill($rect_nice, GREEN);
			$app->fill($rect_system, BLUE);
			$app->fill($rect_system, $cpuaverage{system} > SYSTEM_PURPLE
			      	? PURPLE 
				: BLUE);
			$app->fill($rect_user, $system_n_user > USER_WHITE ? WHITE 
			      	: ($system_n_user > USER_RED ? RED 
				: ($system_n_user > USER_ORANGE ? ORANGE 
				: ($system_n_user > USER_YELLOW0 ? YELLOW0 
				: (YELLOW)))));
			

			my ($y, $space) = (5, $font_height);
			if ($CONF{displaytxt}) {
				my $is_host_summary = exists $is_host_summary{$host};

				if ($CONF{displaytxthost} && not $is_host_summary) {
					# If hostname is printed don't use FQDN
					# because of its length.
					$host =~ /([^\.]*)/;
					$app->print($x, $y, sprintf '%s:', $1);

				} else {
					$app->print($x, $y, sprintf  '%i:', $barnum);
				}

				$app->print($x, $y+=$space, sprintf '%d%s', $cpuaverage{nice}, 'ni');
				$app->print($x, $y+=$space, sprintf '%d%s', $cpuaverage{user}, 'us');
				$app->print($x, $y+=$space, sprintf '%d%s', $cpuaverage{system}, 'sy');
				$app->print($x, $y+=$space, sprintf '%d%s', $system_n_user, 'su');

				unless ($is_host_summary) {
					my @loadavg = split ';', $AVGSTATS{$host};
	
					if (defined $loadavg[0]) {	
						$app->print($x, $y+=$space, 'avg:');
						$app->print($x, $y+=$space, sprintf "%.2f", $loadavg[0]);
						$app->print($x, $y+=$space, sprintf "%.2f", $loadavg[1]);
						$app->print($x, $y+=$space, sprintf "%.2f", $loadavg[2]);
					}
		
					$is_host_summary{$host} = 1;
				}
			}

			# Display an informational text message if any
			$app->print(0, $y+=$space, $displayinfo) if length $displayinfo;

		
			$app->update($_) for $rect_nice, $rect_iowait, $rect_system, $rect_user;
			$x += $width + 1;
		}

TIMEKEEPER:
		$t2 = Time::HiRes::time();

		if (length $displayinfo) {
			if ($displayinfo_start == 0) {
				$displayinfo_start = $t2;

			} else {
				if ($displayinfo_time < $t2 - $displayinfo_start) {
					$displayinfo = '';
					$displayinfo_start = 0;
				}		
			}	
		}

		if ($CONF{inter} > $t2 - $t1) {
			usleep 10000;
			# Goto is OK if you don't produce spaghetti code with it
			goto TIMEKEEPER;
		}

		$t1 = $t2;

		if ($redraw_background) {
			draw_background $app, $rects;
			$redraw_background = 0;
		}

	} until $quit;

	say "Good bye";
	$event_thread->join();
	exit 0;
}


sub dispatch_table () {
 	my $hosts = '';

	my $textdesc = <<END;
Explanation colors:
	Blue: System cpu usage 
	Purple: System usage if system cpu is >30%
	Yellow: User cpu usage 
	Darker yellow: User usage if system & user cpu is >50%
	Orange: User usage if system & user cpu is >70%
	White: Usage usage if system & user cpu is >99%
	Green: Nice cpu usage
Explanation text display:
	ni = Nice cpu usage in %
	us = User cpu usage in %
	sy = System cpu sage in %
	su = System & user cpu usage in %
	avg = System load average (desc. order: 1, 5 and 15 min. avg.)
END

	# mode 1: Option is shown in the online help menu (stdout not sdl)
	# mode 2: Option is shown in the 'usage' screen from the command line
	# mode 4: Option is used to generate the GetOptions parameters for Getopt::Long
	# Combinations: Like chmod(1)

	my %d = ( 
		togglecpu => { menupos => 1,  help => 'Toggle CPUs (0 or 1)', mode => 7, type => 'i' },
		togglecpu_hot => { menupos => 2,  cmd => '1', help => 'Toggle CPUs', mode => 1 },

		average => { menupos => 3,  help => 'Set number of samples for calculating avg.', mode => 6, type => 'i' },
		average_hot_up => { menupos => 4,  cmd => 'a', help => 'Increases number of samples for calculating avg. by 1', mode => 1 },
		average_hot_dn => { menupos => 5,  cmd => 'y', help => 'Decreases number of samples for calculating avg. by 1', mode => 1 },

		configuration => { menupos => 6,  cmd => 'c', help => 'Show current configuration', mode => 4 },

		factor => { menupos => 7,  help => 'Set graph scale factor (1.0 means 100%)', mode => 6, type => 's' },
		factor_hot_up => { menupos => 8,  cmd => 's', help => 'Increases graph scale factor by 0.1', mode => 1 },
		factor_hot_dn => { menupos => 9,  cmd => 'x', help => 'Decreases graph scale factor by 0.1', mode => 1 },

		height => { menupos => 10,  help => 'Set windows height', mode => 6, type => 'i' },

		help_hot => { menupos => 11,  cmd => 'h', help => 'Prints this help screen', mode => 1 },

		hosts => { menupos => 12, help => 'Comma separated list of hosts', var => \$hosts, mode => 6, type => 's' },

		inter => { menupos => 13, help => 'Set update interval in seconds (default 0.1)', mode => 7, type => 's' },
		inter_hot_up => { menupos => 14,  cmd => 'd', help => 'Increases update interval in seconds by 0.1', mode => 1 },
		inter_hot_dn => { menupos => 15,  cmd => 'c', help => 'Decreases update interval in seconds by 0.1', mode => 1 },

		quit_hot => { menupos => 16,  cmd => 'q', help => 'Quits', mode => 1 },

		samples => { menupos => 17,  help => 'Set number of samples until ssh reconnects', mode => 6, type => 'i' },
		sshopts => { menupos => 18,  help => 'Set SSH options', mode => 6, type => 's' },
		title => { menupos => 19,  help => 'Set the window title', var => \$CONF{title}, mode => 6, type => 's' },

		toggletxthost => { menupos => 20,  help => 'Toggle hostname/num text display (0 or 1)', mode => 7, type => 'i' },
		toggletxthost_hot => { menupos => 21, cmd => 'u', help => 'Toggle hostname/num text display', mode => 1 },

		toggletxt => { menupos => 22,  help => 'Toggle text display (0 or 1)', mode => 7, type => 'i' },
		toggletxt_hot => { menupos => 23, cmd => 't', help => 'Toggle text display', mode => 1 },

		width => { menupos => 24,  help => 'Set windows width', mode => 6, type => 'i' },
	);

	my %d_by_short = map { 
	   	$d{$_}{cmd} => $d{$_} 

	} grep { 
	   	exists $d{$_}{cmd} 

	} keys %d;

	my $closure = sub ($;$) {
		my ($arg, @rest) = @_;

		if ($arg eq 'command') {
			my ($cmd, @args) = @rest;

			my $cb = $d{$cmd};
			$cb = $d_by_short{$cmd} unless defined $cb;

			unless (defined $cb) {
				system $cmd;	
				return 0;
			}

			if (length $cmd == 1) {
				for my $key (grep { exists $d{$_}{cmd} } keys %d) {
					do { $cmd = $key; last } if $d{$key}{cmd} eq $cmd;
				}
			}

		} elsif ($arg eq 'hotkeys') {
			(join "\n", map { 
				"$_\t- $d_by_short{$_}{help}" 

			} grep { 
			   	$d_by_short{$_}{mode} & 1 and exists $d_by_short{$_}{help};

			} sort { $d_by_short{$a}{menupos} <=> $d_by_short{$b}{menupos} } sort keys %d_by_short)
				. "\n$textdesc";

		} elsif ($arg eq 'usage') {
			(join "\n", map { 
					if ($_ eq 'help') {
			   		"--$_\t\t- $d{$_}{help}" 
					} else {
			   		"--$_ <ARG>\t- $d{$_}{help}" 
					}

			} grep { 
			   	$d{$_}{mode} & 2 and exists $d{$_}{help} 

			} sort { $d{$a}{menupos} <=> $d{$b}{menupos} } sort keys %d)
				. "\n$textdesc";

		} elsif ($arg eq 'options') {
			map { 
			   	"$_=".$d{$_}{type} => (defined $d{$_}{var} ? $d{$_}{var} : \$CONF{$_});

			} grep { 
			   	$d{$_}{mode} & 4 and exists $d{$_}{type}; 

			} sort keys %d;
		} 
	};

	$d{configuration}{cb} = sub { 
		say sort map { 
		   	"$_->[0] = $_->[1]" 

		} grep { 
		   	defined $_->[1] 

		} map { 
		   	[$_ => exists $d{$_}{var} ? ${$d{$_}{var}} : $CONF{$_}] 

		} keys %d
	};

	return (\$hosts, $closure);
}

sub main () {
	my ($hosts, $dispatch) = dispatch_table;
	my $usage;

	GetOptions ('help|?' => \$usage, $dispatch->('options'));

	if (defined $usage) {
		say $dispatch->('usage');
		exit 0;
	}

	set_togglecpu_regexp;

  	my @hosts = split ',', $$hosts;

	if (@hosts) {
		system 'ssh-add';

	} else {
		@hosts = 'localhost';
	}

  	my @threads = create_threads @hosts;
	main_loop $dispatch, @threads;
}

main;
