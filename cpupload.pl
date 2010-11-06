#!/usr/bin/perl
# cpuload.pl 2010 (c) Paul Buetow

use strict;
use warnings;

use IPC::Open2;
use Data::Dumper;

use threads;
use threads::shared;

$| = 1;

my %GLOBAL_STATS :shared;
my %GLOBAL_CONF  :shared;

%GLOBAL_CONF = (
	events => 20,
	header => 10,
	size => 10,
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

sub display_stats () {
	$SIG{STOP} = sub {
		say "Shutting down display_stats";
		threads->exit();
	};

   	my $size = $GLOBAL_CONF{size};
   	my $line_counter = $GLOBAL_CONF{header} - 1;

	# Wait until first results are available
	sleep 1 until %GLOBAL_STATS;

	my $header_closure = sub {
		return if ++$line_counter % $GLOBAL_CONF{header};
		$line_counter = 0;

		my (@header) = ('', '');

		for my $key (sort keys %GLOBAL_STATS) {
			my ($host, $name) = split ';', $key;
			$header[0] .= sprintf "%${size}s ", $host;
			$header[1] .= sprintf "%${size}s ", $name;
		}

		say @header;
	};

   	loop { 
		$header_closure->();

		my $line = '';
		$line .= sprintf "%${size}d", $GLOBAL_STATS{$_} for sort keys %GLOBAL_STATS;
		say $line;

	   	sleep $GLOBAL_CONF{sleep};
	}
}

sub main () {
   	my @threads;
	push @threads, threads->create('get_remote_stat', 'localhost');
	push @threads, threads->create('display_stats');

	while (<STDIN>) {
		/^q/ && last;
		/^s/ && do { $GLOBAL_CONF{sleep} = <STDIN> };
		/^e/ && do { $GLOBAL_CONF{events} = <STDIN> };
		/^h/ && do { $GLOBAL_CONF{header} = <STDIN> };
	}

	for (@threads) {
		$_->kill('STOP');
		$_->join();
	}

	say "Good bye";
	exit 0;
}

main;


