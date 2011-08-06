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

use IO::Socket;

use constant {
	DEPTH => 8,
	PROMPT => 'loadbars> ',
	VERSION => 'loadbars v0.2.0.0-devel',
	COPYRIGHT => '2010-2011 (c) Paul Buetow <loadbars@mx.buetow.org>',
	NULL => 0,
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
	DEBUG => 1,
};

$| = 1;

my %AVGSTATS : shared;
my %CPUSTATS : shared;
my %CONF : shared;

%CONF = (
	title => VERSION,
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

sub say (@) { print "$_\n" for @_; return undef }
sub newline () { say ''; return undef }
sub debugsay (@) { say "DEBUG: $_" for @_; return undef }

sub sum (@) { 
   my $sum = 0;
   $sum += $_ for @_;
   return $sum;
}

sub set_togglecpu_regexp () {
	$CONF{cpuregexp} = $CONF{togglecpu} ? 'cpu ' : 'cpu';
}

sub parse_cpu_line ($) {
	my ($name, %load);

	($name, @load{qw(user nice system iowait irq softirq)}) = split ' ', shift;
	$load{TOTAL} = sum @load{qw(user nice system iowait)};

	return ($name, \%load);
}

sub thr_get_stat ($) {
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

		$SIG{STOP} = sub {
			say "Terminating get_stat($host) [SSH PID $pid]";
			kill 1, $pid;
			close $pipe;
			threads->exit();
		};

		# Toggle CPUs
		$SIG{USR1} = sub {
		   	$sigusr1 = 1;
		};

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

sub null ($) {
   	my $arg = shift;
	return defined $arg ? $arg : 0;
}

sub display_stats (@) {
	my @threads = @_;
	my $app = SDL::App->new(
		-title => $CONF{title},
		-icon_title => $CONF{title},
		-width => $CONF{width},
		-height => $CONF{height}.
		-depth => DEPTH,
		-resizeable => 0,
	);

	SDL::Font->new('font.png')->use();

	my $num_stats = keys %CPUSTATS;

	my $rects = {};
	my %prev_stats;
	my %last_loads;

	my $redraw_background = 0;

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
			
			} elsif ($key_name eq 't') {
				$CONF{displaytxt} = !$CONF{displaytxt};	
				$displayinfo = 'Toggled text display';
			
			} elsif ($key_name eq 'h') {
				$CONF{displaytxthost} = !$CONF{displaytxthost};	
				$displayinfo = 'Toggled hostname display';

			} elsif ($key_name eq 'q') {
				$quit = 1;
				last;

			# Plus and minus pairs
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
			#draw_background $app, $rects;
		}

		my $div = $num_stats - 1;
		my $width = $CONF{width} / ($div ? $div : 1);

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
			

			my ($y, $space) = (5, 15);
			if (length $displayinfo && $barnum == 0) {
					$app->print($x, $y, "=> $displayinfo");
			}
			
			if ($CONF{displaytxt}) {
				my $is_host_summary = exists $is_host_summary{$host};

				if ($CONF{displaytxthost} && not $is_host_summary) {
					$host =~ /([^\.]*)/;
					$app->print($x, $y+=$space, sprintf '%s:', $1);

				} else {
					$app->print($x, $y+=$space, sprintf  '%i:', $barnum);
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
			goto TIMEKEEPER;
		}

		$t1 = $t2;

		if ($redraw_background) {
			draw_background $app, $rects;
			$redraw_background = 0;
		}

	} until $quit;

	$event_thread->join();
	exit;

	return undef;
}

sub set_value (*;*) {
	my ($key, $type) = @_;

	print "Please enter new value for $key (old value: $CONF{$key}): ";
	chomp ($CONF{$key} = <STDIN>);

	$CONF{$key} = int $CONF{$key} if defined $type and $type eq 'int';

	return undef;
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
		average => { menupos => 4,  cmd => 'a', help => 'Set number of samples for calculating average loads', mode => 7, type => 'i' },
		configuration => { menupos => 4,  cmd => 'c', help => 'Show current configuration', mode => 5 },
		factor => { menupos => 4,  cmd => 'f', help => 'Set scale factor (1.0 means 100%)', mode => 7, type => 's' },
		height => { menupos => 3,  help => 'Set windows height', mode => 6, type => 'i' },
		help => { menupos => 1,  cmd => 'h', help => 'Print this help screen', mode => 3 },
		help2 => { menupos => 2,  cmd => 'H', help => 'Print more help text', mode => 1 },
		hosts => { menupos => 4,  help => 'Comma separated list of hosts', var => \$hosts, mode => 6, type => 's' },
		title => { menupos => 4,  help => 'Set the window title', var => \$CONF{title}, mode => 6, type => 's' },
		inter => { menupos => 4,  cmd => 'i', help => 'Set update interval in seconds (default 0.1)', mode => 7, type => 's' },
		quit => { menupos => 5,  cmd => 'q', help => 'Quit', mode => 1 },
		samples => { menupos => 4,  cmd => 's', help => 'Set number of samples until ssh reconnects', mode => 7, type => 'i' },
		sshopts => { menupos => 7,  cmd => 'o', help => 'Set SSH options', mode => 7, type => 's' },
		togglecpu => { menupos => 4,  cmd => '1', help => 'Toggle CPUs (0 or 1)', mode => 7, type => 'i' },
		toggletxt => { menupos => 4,  cmd => '2', help => 'Toggle all text display (0 or 1)', mode => 7, type => 'i' },
		toggletxthost => { menupos => 4,  cmd => '3', help => 'Toggle hostname/num text display (0 or 1)', mode => 7, type => 'i' },
		width => { menupos => 2,  help => 'Set windows width', mode => 6, type => 'i' },
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
					do { $cmd = $key; last } if $d{$key}{cmd} eq $cmd
				}
			}

			(exists $cb->{cb} ? $cb->{cb} : sub { 
			 	my $display = shift;
			 	set_value $cmd;
			})->(@args);

		} elsif ($arg eq 'help') {
			(join "\n", map { 
				"$_\t- $d_by_short{$_}{help}" 

			} grep { 
			   	$d_by_short{$_}{mode} & 1 and exists $d_by_short{$_}{help}

			} sort { $d_by_short{$a}{menupos} <=> $d_by_short{$b}{menupos} } sort keys %d_by_short);

		} elsif ($arg eq 'usage') {
			join "\n", map { 
					if ($_ eq 'help') {
			   		"--$_\t\t- $d{$_}{help}" 
					} else {
			   		"--$_ <ARG>\t- $d{$_}{help}" 
					}

			} grep { 
			   	$d{$_}{mode} & 2 and exists $d{$_}{help} 

			} sort { $d{$a}{menupos} <=> $d{$b}{menupos} } sort keys %d;

		} elsif ($arg eq 'options') {
			map { 
			   	"$_=".$d{$_}{type} => (defined $d{$_}{var} ? $d{$_}{var} : \$CONF{$_})

			} grep { 
			   	$d{$_}{mode} & 4 and exists $d{$_}{type} 

			} sort keys %d;
		} 
	};

	$d{help}{cb} = sub { say $closure->('help') };
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

sub create_threads (\@) {
   	my ($hosts) = @_;

	return map { $_->detach(); $_ } map { threads->create('thr_get_stat', $_) } @$hosts;
}

sub stop_threads (@) {
	for (@_) {
		$_->kill('STOP');
		$_->join();
	}

	return undef;
}

sub main () {
	my ($hosts, $dispatch) = dispatch_table;
	my $help;
	GetOptions ('help|?' => \$help, $dispatch->('options'));

	if (defined $help) {
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

	display_stats @threads;
	stop_threads @threads;

	#say "Good bye";
	#exit 0;
}

main;
