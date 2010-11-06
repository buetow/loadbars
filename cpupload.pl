#!/usr/bin/perl
# cpuload.pl 2010 (c) Paul Buetow

use strict;
use warnings;

use IPC::Open2;
use Data::Dumper;

use SDL::App;
use SDL::Rect;
use SDL::Color;

use Time::HiRes 'usleep';

use threads;
use threads::shared;

use constant {
	WIDTH => 100,
	HEIGHT => 500,
	DEPTH => 8,
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

sub sum (@) { 
   my $sum = 0;
   $sum += $_ for @_;
   return $sum;
}

sub loop (&) { $_[0]->() while 1 }

sub parse_cpu_line ($) {
   	my %load;
	@load{qw(name user nice system iowait irq softirq)} = split ' ', shift;
	my $name = $load{name};
	delete $load{name};

	$load{TOTAL} = sum @load{qw(user nice system iowait)};

	return ($name, \%load);
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
				$GLOBAL_STATS{"$host;$name"} = join ';', map { $_ . '=' . $load->{$_} } keys %$load;
			}
		}
	}
}

sub get_rect ($$) {
   	my ($rects, $name) = @_;

	return $rects->{$name} if exists $rects->{$name};
	return $rects->{$name} = SDL::Rect->new();
}

sub get_jiffies_diff ($$) {
   	my ($prev_stat, $stat) = @_;

	return $stat unless defined $prev_stat;
	return map { $_ => $stat->{$_} - $prev_stat->{$_} } keys %$stat;
}

sub normalize_loads (%) {
   	my (%loads) = @_;

	return %loads unless exists $loads{TOTAL};

	my $total = $loads{TOTAL} == 0 ? 1 : $loads{TOTAL};
	return map { $_ => $loads{$_} / ($total / 100) } keys %loads;
}

sub graph_stats ($$) {
   	my ($app, $colors) = @_;

   	my $width = WIDTH / (keys %GLOBAL_STATS) - 1;

	my $rects = {};
	my %prev_stat;

	loop {
   		my ($x, $y) = (0, 0);
		for my $key (sort keys %GLOBAL_STATS) {
			my ($host, $name) = split ';', $key;
			my %stat = map { my ($k, $v) = split '='; $k => $v } split ';', $GLOBAL_STATS{$key};

			my %loads = normalize_loads get_jiffies_diff $prev_stat{$key}, \%stat;

			$prev_stat{$key} = \%stat;

			my %heights = map { $_ => $loads{$_} * (HEIGHT/50) } keys %loads;
			next unless exists $heights{user};

			my $rect_user = get_rect $rects, "$key;user";
			my $rect_system = get_rect $rects, "$key;system";
			my $rect_iowait = get_rect $rects, "$key;iowait";
			my $rect_nice = get_rect $rects, "$key;nice";
	

			$y = HEIGHT - $heights{user};
			$rect_user->width($width);
			$rect_user->height($heights{user});
			$rect_user->x($x);
			$rect_user->y($y);
		
			$y -= $heights{system};
			$rect_system->width($width);
			$rect_system->height($heights{system});
			$rect_system->x($x);
			$rect_system->y($y);
		
			$y -= $heights{iowait};
			$rect_iowait->width($width);
			$rect_iowait->height($heights{iowait});
			$rect_iowait->x($x);
			$rect_iowait->y($y);
		
			$y -= $heights{nice};
			$rect_nice->width($width);
			$rect_nice->height($heights{nice});
			$rect_nice->x($x);
			$rect_nice->y($y);
	
			$app->fill($rect_nice, $colors->{green});
			$app->fill($rect_iowait, $colors->{black});
			$app->fill($rect_system, $colors->{yellow});
			$app->fill($rect_user, $colors->{red});
		
			$app->update($_) for $rect_nice, $rect_iowait, $rect_system, $rect_user;
			
			$x += $width + 1;
		
			usleep $GLOBAL_CONF{sleep} * 1000000;
		};

	};

	return undef;
}

sub display_stats () {
	# Wait until first results are available
	sleep 1 until %GLOBAL_STATS;

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

	graph_stats $app, $colors;;
}

sub main (@_) {
   	my $host = shift;
	$host = 'localhost' unless defined $host;

   	my @threads;
	push @threads, threads->create('get_remote_stat', $host);
	push @threads, threads->create('display_stats');

	while (<STDIN>) {
		/^q/ && last;
		/^s/ && do { chomp ($GLOBAL_CONF{sleep} = <STDIN>) };
		/^e/ && do { chomp ($GLOBAL_CONF{events} = <STDIN>) };
	}

	for (@threads) {
		$_->kill('STOP');
		$_->join();
	}

	say "Good bye";
	exit 0;
}

main @ARGV;


