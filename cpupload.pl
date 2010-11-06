#!/usr/bin/perl
# cpuload.pl 2010 (c) Paul Buetow

use strict;
use warnings;

use IPC::Open2;
use Data::Dumper;

use Tk;
use Tk::Graph;

use threads;
use threads::shared;

$| = 1;

my %GLOBAL_STATS :shared;
my %GLOBAL_CONF  :shared;

%GLOBAL_CONF = (
	events => 20,
	'sleep' => 1,
);

sub say (@) {
   	print "$_\n" for @_;
	return undef;
}

sub reduce (&@) {
	my ($func, @params) = @_;

	my $sub;
	$sub = sub { 
		my ($elem, @rest) = @_;
		$func->($elem, @rest == 1 ? $rest[0] : $sub->(@rest));
	};

	return $sub->($func, @params);
}

sub sum (@) { reduce { $_[0] + $_[1] } @_ }

sub loop (&) { $_[0]->() while 1 }

sub parse_cpu_line ($) {
   	my %load;
	@load{qw(name user nice system iowait irq softirq)} = split ' ', shift;
	$load{TOTAL} = sum @load{qw(user)};

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
				my ($name, $val) = parse_cpu_line $_;
				$GLOBAL_STATS{"$host;$name"} = $val->{TOTAL};
			}
		}
	}
}

sub graph_stats ($) {
   	my $mw = shift;

	my $data = { };
	my $ca = $mw->Graph(-type => 'BARS')->pack(-expand => 1, -fill => 'both');

	$ca->configure(-variable => $data);
	$mw->repeat($GLOBAL_CONF{sleep}*100, sub {
			for my $key (sort keys %GLOBAL_STATS) {
				my ($host, $name) = split ';', $key;
				$host = substr $host, 0, 16 if length $host > 16;
				$data->{"$host $name"} = $GLOBAL_STATS{$key};
			}

			$ca->set($data);
	      }
	);

	return undef;
}

sub display_stats () {
   	my $mw = MainWindow->new;

	$SIG{STOP} = sub {
		say "Shutting down display_stats";
		threads->exit();
	};

	# Wait until first results are available
	sleep 1 until %GLOBAL_STATS;
	graph_stats $mw;

	MainLoop;
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


