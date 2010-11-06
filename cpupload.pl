#!/usr/bin/perl
# cpuload.pl 2010 (c) Paul Buetow

use strict;
use warnings;

use IPC::Open2;
use Data::Dumper;

use SDL::App;
use SDL::Rect;
use SDL::Color;

use threads;
use threads::shared;

use constant {
	WIDTH => 1000,
	HEIGHT => 1000,
	DEPTH => 16,
};

$| = 1;

my %GLOBAL_STATS :shared;
my %GLOBAL_CONF  :shared;

%GLOBAL_CONF = (
	events => 100,
	'sleep' => 0.2,
);

sub say (@) { print "$_\n" for @_; return undef }
sub debugsay (@) { say "DEBUG: $_" for @_; return undef }

sub reduce (&@) {
	my ($func, @params) = @_;

	my $sub;
	$sub = sub { 
		my ($elem, @rest) = @_;
		$func->($elem, @rest == 1 ? $rest[0] : $sub->(@rest));
	};

	return $sub->($func, @params);
}

#sub sum (@) { reduce { $_[0] + $_[1] } @_ }
sub sum (@) { 
   my $sum = 0;
   $sum += $_ for @_;
   return $sum;
}

sub loop (&) { $_[0]->() while 1 }

sub parse_cpu_line ($) {
   	my %load;
	@load{qw(name user nice system iowait irq softirq)} = split ' ', shift;
	$load{TOTAL} = sum @load{qw(user nice system iowait)};

	return ($load{name}, \%load);
}

sub get_remote_stat ($) {
   	my $host = shift;

	loop {
		my $sleep = $GLOBAL_CONF{sleep};
		my $events = $GLOBAL_CONF{events};

		my $pid = open2 my $out, my $in, qq{ 
		   	ssh $host 'for i in \$(seq $events); do cat /proc/stat; sleep $sleep; done'
		} or die "Error: $!\n";

		$SIG{STOP} = sub {
			say "Shutting down get_remote_stat($host) & $pid";
			kill 1, $pid;
			threads->exit();
		};

		while (<$out>) {
		   	/^cpu/ && do {
				my ($name, $load) = parse_cpu_line $_;
				$GLOBAL_STATS{"$host;$name"} =
					join ';', map { $_ . '=' . $load->{$_} } keys %$load;
			}
		}
	}
}

sub draw_frame {
   	my ($app, %args) = @_;

#	$app->fill($args{ bg }, $args{ bg_color });
	$app->fill($args{rect}, $args{rect_color});
	$app->update($args{bg});
}

sub graph_stats ($$) {
   	my ($app,$colors) = @_;

   	my $width = WIDTH / (keys %GLOBAL_STATS) - 1;
   	my ($x, $y) = (0, 0);

	for my $key (sort keys %GLOBAL_STATS) {
		my ($host, $name) = split ';', $key;
		my %stat = map { my ($k, $v) = split '='; $k => $v } split ';', $GLOBAL_STATS{$key};
		my %load = (
			perc_idle => ($stat{nice}/($stat{TOTAL}/100)),
			perc_iowait => ($stat{iowait}/($stat{TOTAL}/100)),
			perc_system => ($stat{system}/($stat{TOTAL}/100)),
			perc_user => ($stat{user}/($stat{TOTAL}/100))
		);

		#$load{perc_total} = sum @load{qw{perc_idle perc_iowait perc_system perc_user}};


		my $height_user = $load{perc_user}/(HEIGHT/10000);
		my $rect_user = SDL::Rect->new(-height => $height_user, -width => $width, -x => $x, -y => HEIGHT - $height_user);
		$app->fill($rect_user, $colors->{red});
		$app->update($rect_user);

		my $height_system = $load{perc_system}/(HEIGHT/10000);
		my $rect_system = SDL::Rect->new(-height => $height_system, -width => $width, -x => $x, -y => HEIGHT - $height_user - $height_system);
		$app->fill($rect_system, $colors->{yellow});
		$app->update($rect_system);

		my $height_iowait = $load{perc_iowait}/(HEIGHT/10000);
		my $rect_iowait = SDL::Rect->new(-height => $height_iowait, -width => $width, -x => $x, -y => HEIGHT - $height_user - $height_system - $height_iowait);
		$app->fill($rect_iowait, $colors->{blue});
		$app->update($rect_iowait);

		my $height_idle = $load{perc_idle}/(HEIGHT/10000);
		my $rect_idle = SDL::Rect->new(-height => $height_idle, -width => $width, -x => $x, -y => HEIGHT - $height_user - $height_system - $height_iowait - $height_idle);
		$app->fill($rect_idle, $colors->{blue});
		$app->update($rect_idle);

		
		$x += $width + 1;

		say $GLOBAL_STATS{$key};
		system('vmstat');
		print Dumper %stat;
		print Dumper %load;
	}

   	loop { sleep 1 };

	return undef;
}

sub display_stats () {
	my $app = SDL::App->new(
		-width => WIDTH,
		-height => HEIGHT,
		-depth => DEPTH,
	);

   	my $colors = {
		red => SDL::Color->new(-r => 0xff, -g => 0x00, -b => 0x00),
		yellow => SDL::Color->new(-r => 0xff, -g => 0xa5, -b => 0x00),
		green => SDL::Color->new(-r => 0x00, -g => 0xff, -b => 0x00),
		blue => SDL::Color->new(-r => 0x00, -g => 0x00, -b => 0xff),
		black => SDL::Color->new(-r => 0x00, -g => 0x00, -b => 0x00),
	};
   	
	$SIG{STOP} = sub {
		say "Shutting down display_stats";
		threads->exit();
	};

	# Wait until first results are available
	sleep 1 until %GLOBAL_STATS;
	graph_stats $app, $colors;;
}

sub main () {
   	my @threads;
	push @threads, threads->create('get_remote_stat', 'localhost');
	push @threads, threads->create('display_stats');

	while (<STDIN>) {
		/^q/ && last;
		/^s/ && do { $GLOBAL_CONF{sleep} = <STDIN> };
		/^e/ && do { $GLOBAL_CONF{events} = <STDIN> };
	}

	for (@threads) {
		$_->kill('STOP');
		$_->join();
	}

	say "Good bye";
	exit 0;
}

main;


