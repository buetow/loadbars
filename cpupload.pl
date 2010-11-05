#!/usr/bin/perl
# cpuload.pl 2010 (c) Paul Buetow

use strict;
use warnings;

sub say (@) {
   	print "$_\n" for @_;
	return scalar @_;
}

sub reduce (&@) {
   	
}

sub parse_stat_line ($) {
   	my %load;
	my ($name, $user, $nice, $system, $idle, @rest) = split / +/, shift;
	my $total = $user + $nice + $system + $idle;
	print $nice, "\n";

	return undef;
}

sub parse_stat (@) {
	my ($total,@rest) = @_;

	parse_stat_line $total;

	return undef;
}

sub get_local_stat () {
   	open my $fh, '/proc/stat' or die "$!: /proc/stat\n";
	my @stat = <$fh>;
	close $fh;

	return @stat;
}

sub main () {
	parse_stat get_local_stat;

	exit 0;
}

main;


