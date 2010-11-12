#!/usr/bin/perl
# loadbars.pl 2010 (c) Paul Buetow

use strict;
use warnings;

use IPC::Open2;
use Data::Dumper;

use Getopt::Long;
use Term::ReadLine;

use SDL::App;
use SDL::Rect;
use SDL::Color;
use SDL::Event;

use Time::HiRes qw(usleep gettimeofday);

use threads;
use threads::shared;

use constant {
	DEPTH => 8,
	PROMPT => 'loadbars> ',
	VERSION => 'loadbars v0.0.3',
	COPYRIGHT => '2010 (c) Paul Buetow <loadbars@mx.buetow.org>',
	NULL => 0,
	MSG_SET_DIMENSION => 1,
	MSG_TOGGLE_FULLSCREEN => 2,
};


$| = 1;

my %STATS :shared;
my %CONF  :shared;
my $MSG   :shared;

%CONF = (
	average => 30,
	samples => 1000,
	interval => 0.1,
	sshopts => '',
	cpuregexp => 'cpu',
	toggle => 1,
	scale => 1,
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

	my $bash = "if [ -e /proc/stat ]; then proc=/proc/stat; else proc=/usr/compat/linux/proc/stat; fi; for i in \$(seq $CONF{samples}); do cat \$proc; sleep 0.1; done";
	my $cmd = $host eq 'localhost' ? $bash : "ssh $CONF{sshopts} $host '$bash'";
	my $sigusr1 = 0;

	loop {
		my $pid = open2 my $out, my $in, $cmd or die "Error: $!\n";

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
	my ($scale, @loads) = @_;	
	my %load_average;

	for my $l (@loads) {
		$load_average{$_} += $l->{$_} for keys %$l;
	}

	my $div = @loads / $scale;
	$load_average{$_} /= $div for keys %load_average;

	return %load_average;
}

sub wait_for_stats () {
	sleep 1 until %STATS;
}

sub draw_background ($$$) {
   	my ($app, $colors, $rect) = @_;

	$rect->width($CONF{width});
	$rect->height($CONF{height});
	$app->fill($rect, $colors->{black});
	$app->update($rect);
}

sub null ($) {
   	my $arg = shift;
	return defined $arg ? $arg : 0;
}

sub graph_stats ($$) {
  	my ($app, $colors) = @_;

	wait_for_stats;

	my $num_stats = keys %STATS;
	my $width = $CONF{width} / $num_stats - 1;

	my $rects = {};
	my %prev_stats;
	my %last_loads;
	my $rect_bg = SDL::Rect->new();

	# Toggle CPUs
	$SIG{USR1} = sub {
		wait_for_stats;
	};

	# Set new window dimensions 
	$SIG{USR2} = sub {
	   	if ($MSG == MSG_SET_DIMENSION) {
			$width = $CONF{width} / $num_stats - 1;
			$app->resize($CONF{width}, $CONF{height});

		} elsif ($MSG == MSG_TOGGLE_FULLSCREEN) {
		   	$app->fullscreen();
		}
	};

	loop {
		my ($x, $y) = (0, 0);

		my $scale = $CONF{scale};

		my $new_num_stats = keys %STATS;
		if ($new_num_stats != $num_stats) {
			%prev_stats = ();
			%last_loads = ();
	
			$num_stats = $new_num_stats;
			$width = $CONF{width} / $num_stats - 1;
			draw_background $app, $colors, $rect_bg;
		}

		for my $key (sort keys %STATS) {
			my ($host, $name) = split ';', $key;
			next unless defined $STATS{$key};

			my %stat = map { my ($k, $v) = split '='; $k => $v } split ';', $STATS{$key};

			unless (exists $prev_stats{$key}) {
				$prev_stats{$key} = \%stat;
				next;
			}

			my $prev_stat = $prev_stats{$key};
			my %loads = null $stat{TOTAL} == null $prev_stat->{TOTAL} 
				? %stat : map { $_ => $stat{$_} - $prev_stat->{$_} } keys %stat;
			$prev_stats{$key} = \%stat;

			%loads = normalize_loads %loads;
			push @{$last_loads{$key}}, \%loads;
			shift @{$last_loads{$key}} while @{$last_loads{$key}} >= $CONF{average};
			my %load_average = get_load_average $scale, @{$last_loads{$key}};

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

			$app->fill($rect_iowait, $colors->{black});
			$app->fill($rect_nice, $colors->{green});
			$app->fill($rect_system, $colors->{blue});
			$app->fill($rect_system, $load_average{system} > 30
			      	? $colors->{purple} 
				: $colors->{blue});
			$app->fill($rect_user, $system_n_user > 90 
			      	? $colors->{red} 
				: ( $system_n_user > 70 
					? $colors->{orange} 
					: ( $system_n_user > 50 
						? $colors->{yellow0} 
						: $colors->{yellow})));

			$app->update($_) for $rect_nice, $rect_iowait, $rect_system, $rect_user;
			$x += $width + 1;
		};

		usleep $CONF{interval} * 1000000;
	};

	return undef;
}

sub thr_display_stats () {
	# Wait until first results are available
	my $app = SDL::App->new(
		-width => $CONF{width},
		-height => $CONF{height},
		-depth => DEPTH,
		-title => VERSION,
		-resizeable => 0,
	);

  	my $colors = {
		red => SDL::Color->new(-r => 0xff, -g => 0x00, -b => 0x00),
		orange => SDL::Color->new(-r => 0xff, -g => 0x70, -b => 0x00),
		yellow0 => SDL::Color->new(-r => 0xff, -g => 0xa0, -b => 0x00),
		yellow => SDL::Color->new(-r => 0xff, -g => 0xc0, -b => 0x00),
		green => SDL::Color->new(-r => 0x00, -g => 0x90, -b => 0x00),
		blue => SDL::Color->new(-r => 0x00, -g => 0x00, -b => 0xff),
		purple => SDL::Color->new(-r => 0xa0, -g => 0x20, -b => 0xf0),
		black => SDL::Color->new(-r => 0x00, -g => 0x00, -b => 0x00),
	};

	$SIG{STOP} = sub {
		say "Shutting down display_stats";
		threads->exit();
	};

	$app->add_event_handler( sub { debugsay shift->type; return 1 } );

	graph_stats $app, $colors;;
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

sub set_toggle_regexp () {
	$CONF{cpuregexp} = $CONF{toggle} ? 'cpu ' : 'cpu';

	return undef;
}

sub toggle_cpus ($@) {
	my ($display, @threads) = @_;

	$CONF{toggle} = ! $CONF{toggle};
	set_toggle_regexp;

	$_->kill('USR1') for @threads;
	%STATS = ();
	$display->kill('USR1');

	return undef;
}

sub toggle_fullscreen ($) {
   	my $display = shift;

	send_message $display, MSG_TOGGLE_FULLSCREEN;

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
}

sub print_help () {
	print <<"END";
1 	- Toggle CPUs
a 	- Set number of samples for calculating average loads ($CONF{average})
c 	- Set scale factor ($CONF{scale})
d 	- Set window dimensions ($CONF{width} $CONF{height}})
i 	- Set update interval in seconds ($CONF{interval})
s 	- Set number of samples until ssh reconnects ($CONF{samples})
h 	- Print this help screen
!<cmd> 	- Run a shell command
v 	- Print version
q 	- Quit
END
}

sub main () {
 	my ($config, $hosts) = ('', '');
	GetOptions (
		'config=s' => \$config,
		'hosts=s' => \$hosts,
		'scale=s' => \$hosts,
		'averate=i' => \$CONF{average},
		'interval=i' => \$CONF{interval},
		'samples=i' => \$CONF{samples},
		'toggle=i' => \$CONF{toggle},
		'ssh=s' => \$CONF{sshopts},
		'width=i' => \$CONF{width},
		'height=i' => \$CONF{height},
	);

  	my @hosts = split ',', $hosts;
	@hosts = 'localhost' unless @hosts;
	set_toggle_regexp;

  	my ($display, @threads) = create_threads @hosts;

	say VERSION . ' ' . COPYRIGHT;
	say "Type 'h' for help menu";

	my $term = new Term::ReadLine VERSION;

	while ( defined( $_ = $term->readline(PROMPT) ) ) {
        	$term->addhistory($_);
        	chomp;

        	my ($cmd, @args) = split /\s+/;
        	next unless defined $cmd;
        	$_ = shift @args if $cmd eq '';

		/^1/ && do { toggle_cpus $display, @threads };
		/^a/ && do { set_value average };
		/^c/ && do { set_value scale };
		/^d/ && do { set_dimensions $display };
		#/^f/ && do { toggle_fullscreen $display };
		/^s/ && do { set_value samples };
		/^i/ && do { set_value interval };
		/^h/ && do { print_help };
		/^!(.*)/ && do { system $1 };
		/^v/ && do { say VERSION . ' ' . COPYRIGHT };
		/^q/ && last;
	}

	stop_threads @threads,$display;

	say "Good bye";
	exit 0;
}

main;