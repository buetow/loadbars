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

use IPC::Open2;

use Getopt::Long;
use Term::ReadLine;

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
	PROMPT => 'loadbars> ',
	VERSION => 'loadbars v0.1.1-devel',
	COPYRIGHT => '2010-2011 (c) Paul Buetow <loadbars@mx.buetow.org>',
	NULL => 0,
	MSG_SET_DIMENSION => 1,
	MSG_TOGGLE_TXT => 2,
	FONT => SDL::Font->new('font.png'),
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
};

$| = 1;

my %STATS :shared;
my %CONF  :shared;
my $MSG   :shared;

%CONF = (
	average => 30,
	samples => 1000,
	inter => 0.1,
	sshopts => '',
	cpuregexp => 'cpu',
	toggletxt => 1,
	togglecpu => 1,
	factor => 1,
	width => 1200,
	height => 200,
);

sub say (@) { print "$_\n" for @_; return undef }
sub debugsay (@) { say "DEBUG: $_" for @_; return undef }

sub sum (@) { 
   my $sum = 0;
   $sum += $_ for @_;
   return $sum;
}

sub loop (&) { $_[0]->() while 1 }

sub parse_cpu_line ($) {
	my ($name, %load);

	($name, @load{qw(user nice system iowait irq softirq)}) = split ' ', shift;
	$load{TOTAL} = sum @load{qw(user nice system iowait)};

	return ($name, \%load);
}

sub thr_get_stat ($) {
	my $host = shift;

	my $sigusr1 = 0;

	loop {
		my $bash = <<"BASH";
			if [ -e /proc/stat ]; then 
				proc=/proc/stat
			else 
			   	proc=/compat/linux/proc/stat
			fi
			
			for i in \$(seq $CONF{samples}); do 
			   	cat \$proc
				sleep $CONF{inter}
			done
BASH
		my $cmd = $host eq 'localhost' ? $bash 
			: "ssh -o StrictHostKeyChecking=no $CONF{sshopts} $host '$bash'";

		my $pid = open2 my $out, my $in, $cmd or do {
			say "Warning: $!";
			return;
		};

		$SIG{STOP} = sub {
			say "Shutting down get_stat($host) & PID $pid";
			kill 1, $pid;
			threads->exit();
		};

		# Toggle CPUs
		$SIG{USR1} = sub {
		   	$sigusr1 = 1;
		};

		my $cpuregexp = qr/$CONF{cpuregexp}/;

		while (<$out>) {
	   		/$cpuregexp/ && do {
				my ($name, $load) = parse_cpu_line $_;
				$STATS{"$host;$name"} = join ';', 
				   	map { $_ . '=' . $load->{$_} } keys %$load;
			};

			if ($sigusr1) {
				$cpuregexp = qr/$CONF{cpuregexp}/;
				$sigusr1 = 0;
			}
		}
	}
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

sub get_load_average ($@) {
	my ($factor, @loads) = @_;	
	my %load_average;

	for my $l (@loads) {
		$load_average{$_} += $l->{$_} for keys %$l;
	}

	my $div = @loads / $factor;
	$load_average{$_} /= $div for keys %load_average;

	return %load_average;
}

sub wait_for_stats () {
	sleep 1 until %STATS;
}

sub draw_background ($$) {
   	my ($app, $rect) = @_;

	$rect->width($CONF{width});
	$rect->height($CONF{height});
	$app->fill($rect, BLACK);
	$app->update($rect);
}

sub null ($) {
   	my $arg = shift;
	return defined $arg ? $arg : 0;
}

sub graph_stats ($) {
  	my ($app) = @_;

	wait_for_stats;

	my $num_stats = keys %STATS;
	my $width = $CONF{width} / $num_stats - 1;

	my $rects = {};
	my %prev_stats;
	my %last_loads;
	my $rect_bg = SDL::Rect->new();
	my $display_txt = $CONF{toggletxt};

	# Toggle CPUs
	$SIG{USR1} = sub { wait_for_stats };

	# Set new window dimensions 
	$SIG{USR2} = sub {
	   	if ($MSG == MSG_SET_DIMENSION) {
			$width = $CONF{width} / $num_stats - 1;
			$app->resize($CONF{width}, $CONF{height});

		} elsif ($MSG == MSG_TOGGLE_TXT) {
		   	$display_txt = $CONF{toggletxt};
		}

		$MSG = NULL;
	};

	my ($t1, $t2) = (Time::HiRes::time(), undef);

	loop {
		my ($x, $y) = (0, 0);

		my $factor = $CONF{factor};

		my $new_num_stats = keys %STATS;
		if ($new_num_stats != $num_stats) {
			%prev_stats = ();
			%last_loads = ();
	
			$num_stats = $new_num_stats;
			$width = $CONF{width} / $num_stats - 1;
			draw_background $app, $rect_bg;
		}

		for my $key (sort keys %STATS) {
			my ($host, $name) = split ';', $key;
			next unless defined $STATS{$key};

			my %stat = map { 
			   	my ($k, $v) = split '='; $k => $v 
			} split ';', $STATS{$key};

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
			my %load_average = get_load_average $factor, @{$last_loads{$key}};

			my %heights = map { 
				$_ => defined $load_average{$_} ? $load_average{$_} * ($CONF{height}/100) : 1 
			} keys %load_average;

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
	
			my $system_n_user = sum @load_average{qw(user system)};

			$app->fill($rect_iowait, BLACK);
			$app->fill($rect_nice, GREEN);
			$app->fill($rect_system, BLUE);
			$app->fill($rect_system, $load_average{system} > SYSTEM_PURPLE
			      	? PURPLE 
				: BLUE);
			$app->fill($rect_user, $system_n_user > USER_WHITE ? WHITE 
			      	: ($system_n_user > USER_RED ? RED 
				: ($system_n_user > USER_ORANGE ? ORANGE 
				: ($system_n_user > USER_YELLOW0 ? YELLOW0 
				: (YELLOW)))));

			if ($display_txt) {
				$app->print($x, 5, sprintf  "%d%s", $load_average{nice}, 'ni');
				$app->print($x, 25, sprintf "%d%s", $load_average{user}, 'us');
				$app->print($x, 45, sprintf "%d%s", $load_average{system}, 'sy');
				$app->print($x, 65, sprintf "%d%s", $system_n_user, 'su');
			}

			$app->update($_) for $rect_nice, $rect_iowait, $rect_system, $rect_user;
			$x += $width + 1;
		};

TIMEKEEPER:
		$t2 = Time::HiRes::time();

		if ($CONF{inter} > $t2 - $t1) {
			usleep 10000;
			goto TIMEKEEPER;
		}

		$t1 = $t2;
	};

	return undef;
}

sub thr_display_stats () {
	my $app = SDL::App->new(
		-width => $CONF{width},
		-height => $CONF{height}.
		-depth => DEPTH,
		-title => VERSION,
		-resizeable => 0,
	);

	$SIG{STOP} = sub {
		say "Shutting down display_stats";
		threads->exit();
	};


	graph_stats $app
}

sub send_message ($$) {
   	my ($thread, $message) = @_;

	$MSG = $message;
	$thread->kill('USR2');
}

sub create_threads (\@) {
   	my ($hosts) = @_;

	my @threads;
	push @threads, threads->create('thr_get_stat', $_) for @$hosts;

	return (threads->create('thr_display_stats'), @threads);
}

sub stop_threads (@) {
	for (@_) {
		$_->kill('STOP');
		$_->join();
	}

	return undef;
}

sub set_togglecpu_regexp () {
	$CONF{cpuregexp} = $CONF{togglecpu} ? 'cpu ' : 'cpu';

	return undef;
}

sub togglecpu ($@) {
	my ($display, @threads) = @_;

	$CONF{togglecpu} = ! $CONF{togglecpu};
	set_togglecpu_regexp;

	$_->kill('USR1') for @threads;
	%STATS = ();
	$display->kill('USR1');

	return undef;
}

sub toggletxt ($@) {
	my ($display, @threads) = @_;

	$CONF{toggletxt} = ! $CONF{toggletxt};

	$MSG = MSG_TOGGLE_TXT;
	$display->kill('USR2');

	return undef;
}

sub set_value (*;*) {
	my ($key, $type) = @_;

	print "Please enter new value for $key (old value: $CONF{$key}): ";
	chomp ($CONF{$key} = <STDIN>);

	$CONF{$key} = int $CONF{$key} if defined $type and $type eq 'int';

	return undef;
}

sub set_dimensions ($) {
   	my $display = shift;

	set_value width;
	set_value height;

	send_message $display, MSG_SET_DIMENSION;

	return 0;
}


sub dispatch_table () {
 	my $hosts = '';

	# mode 1: Option is shown in the online help menu
	# mode 2: Option is shown in the 'usage' screen from the command line
	# mode 4: Option is used to generate the GetOptions parameters for Getopt::Long
	# Combinations: Like chmod(1)

	my %d = ( 
		average => { menupos => 4,  cmd => 'a', help => 'Set number of samples for calculating average loads', mode => 7, type => 'i' },
		configuration => { menupos => 4,  cmd => 'c', help => 'Show current configuration', mode => 5 },
		factor => { menupos => 4,  cmd => 'f', help => 'Set scale factor (1.0 means 100%)', mode => 7, type => 's' },
		height => { menupos => 2,  help => 'Set windows height', mode => 6, type => 'i' },
		help => { menupos => 1,  cmd => 'h', help => 'Print this help screen', mode => 3 },
		hosts => { menupos => 4,  help => 'Comma separated list of hosts', var => \$hosts, mode => 6, type => 's' },
		inter => { menupos => 4,  cmd => 'i', help => 'Set update interval in seconds (default 0.1)', mode => 7, type => 's' },
		quit => { menupos => 5,  cmd => 'q', help => 'Quit', mode => 1, cb => sub { -1 } },
		samples => { menupos => 4,  cmd => 's', help => 'Set number of samples until ssh reconnects', mode => 7, type => 'i' },
		sshopts => { menupos => 7,  cmd => 'o', help => 'Set SSH options', mode => 7, type => 's' },
		togglecpu => { menupos => 4,  cmd => '1', help => 'Toggle CPUs (0 or 1)', mode => 7, type => 'i', cb => \&togglecpu },
		toggletxt => { menupos => 4,  cmd => '2', help => 'Toggle display text (0 or 1)', mode => 7, type => 'i', cb => \&toggletxt },
		version => { menupos => 3,  cmd => 'v', help => 'Print version', mode => 1, cb => sub { say VERSION . ' ' . COPYRIGHT } },
		width => { menupos => 2,  help => 'Set windows width', mode => 6, type => 'i' },
	);

	my %d_by_short = map { 
	   	$d{$_}{cmd} => $d{$_} 

	} grep { 
	   	exists $d{$_}{cmd} 

	} keys %d;

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
END

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

			(exists $cb->{cb} ? $cb->{cb} : sub { set_value $cmd })->(@args);

		} elsif ($arg eq 'help') {
			(join "\n", map { 
				"$_\t- $d_by_short{$_}{help}" 

			} grep { 
			   	$d_by_short{$_}{mode} & 1 and exists $d_by_short{$_}{help}

			} sort { $d_by_short{$a}{menupos} <=> $d_by_short{$b}{menupos} } sort keys %d_by_short)
			. "\n\n$textdesc";

		} elsif ($arg eq 'usage') {
			join "\n", map { 
					if ($_ eq 'help') {
			   		"--$_\t\t- $d{$_}{help}" 
					} else {
			   		"--$_ <ARG>\t- $d{$_}{help}" 
					}

			} grep { 
			   	$d{$_}{mode} & 2 and exists $d{$_}{help} 

			} sort { $d{$a}{menupos} <=> $d{$b}{menupos} } sort keys %d

		} elsif ($arg eq 'options') {
			map { 
			   	"$_=".$d{$_}{type} => (defined $d{$_}{var} ? $d{$_}{var} : \$CONF{$_})

			} grep { 
			   	$d{$_}{mode} & 4 and exists $d{$_}{type} 

			} sort keys %d
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

  	my ($display, @threads) = create_threads @hosts;
	my $term = new Term::ReadLine VERSION;

	say VERSION . ' ' . COPYRIGHT;
	say 'Type \'h\' for help menu. Or start program with --help for startup options.';

	while ( defined( $_ = $term->readline(PROMPT) ) ) {
        	$term->addhistory($_);
        	chomp;

        	my ($cmd, @args) = split /\s+/;
        	next unless defined $cmd;
        	$_ = shift @args if $cmd eq '';

		last if $dispatch->('command', $_, $display, @threads);
	}

	stop_threads @threads,$display;

	say "Good bye";
	exit 0;
}

main;
