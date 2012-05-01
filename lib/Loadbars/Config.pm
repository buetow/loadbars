package Loadbars::Config;

use strict;
use warnings;

use Loadbars::Utils;
use Loadbars::Shared;

use Exporter;

use base 'Exporter';

our @EXPORT = qw ( %C %I );

sub read () {
    return unless -f Loadbars::Constants->CONFFILE;

    display_info(
        "Reading configuration from " . Loadbars::Constants->CONFFILE );
    open my $conffile, Loadbars::Constants->CONFFILE
      or die "$!: " . Loadbars::Constants->CONFFILE . "\n";

    while (<$conffile>) {
        chomp;
        s/[\t\s]*?#.*//;

        next unless length;

        my ( $key, $val ) = split '=';

        unless ( defined $val ) {
            display_warn("Could not parse config line: $_");
            next;
        }

        trim($key);
        trim($val);

        if ( not exists $C{$key} ) {
            display_warn("There is no such config key: $key, ignoring");

        }
        else {
            display_info(
"Setting $key=$val, it might be overwritten by command line params."
            );
            $C{$key} = $val;
        }
    }

    close $conffile;
}

sub write () {
    display_warn( "Overwriting config file " . Loadbars::Constants->CONFFILE )
      if -f Loadbars::Constants->CONFFILE;

    open my $conffile, '>', Loadbars::Constants->CONFFILE or do {
        display_warn( "$!: " . Loadbars::Constants->CONFFILE );

        return undef;
    };

    for ( keys %C ) {
        print $conffile "$_=$C{$_}\n";
    }

    close $conffile;
}

# Recursuve function
sub get_cluster_hosts ($;$);

sub get_cluster_hosts ($;$) {
    my ( $cluster, $recursion ) = @_;

    unless ( defined $recursion ) {
        $recursion = 1;

    }
    elsif ( $recursion > Loadbars::Constants->CSSH_MAX_RECURSION ) {
        error(  "CSSH_MAX_RECURSION reached. Infinite circle loop in "
              . Loadbars::Constants->CSSH_CONFFILE
              . "?" );
    }

    open my $fh, Loadbars::Constants->CSSH_CONFFILE
      or error( "$!: " . Loadbars::Constants->CSSH_CONFFILE );
    my $hosts;

    while (<$fh>) {
        if (/^$cluster\s*(.*)/) {
            $hosts = $1;
            last;
        }
    }

    close $fh;

    unless ( defined $hosts ) {
        error(  "No such cluster in "
              . Loadbars::Constants->CSSH_CONFFILE
              . ": $cluster" )
          unless defined $recursion;

        return ($cluster);
    }

    my @hosts;
    push @hosts, get_cluster_hosts $_, ( $recursion + 1 )
      for ( split /\s+/, $hosts );

    return @hosts;
}

1;
