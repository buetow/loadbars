package Loadbars::Shared;

use Exporter;

use base 'Exporter';

our @EXPORT = qw(
  %PIDS
  %CPUSTATS
  %NETSTATS_LASTUPDATE
  %AVGSTATS
  %AVGSTATS_HAS
  %MEMSTATS
  %MEMSTATS_HAS
  %NETSTATS
  %NETSTATS_HAS
  %NETSTATS_INT
  %C
  %I
);

our %PIDS : shared;

our %CPUSTATS : shared;
our %AVGSTATS : shared;
our %AVGSTATS_HAS : shared;

our %MEMSTATS : shared;
our %MEMSTATS_HAS : shared;

our %NETSTATS : shared;
our %NETSTATS_HAS : shared;
our %NETSTATS_INT : shared;

# Global configuration hash
our %C : shared;

# Global configuration hash for internal settings (not configurable)
our %I : shared;

# Setting defaults
%C = (
    title        => undef,
    barwidth     => 35,
    cpuaverage   => 15,
    extended     => 0,
    factor       => 1,
    hasagent     => 0,
    height       => 230,
    maxwidth     => 1250,
    netaverage   => 15,
    netint       => 'eth0',
    netusepeak   => 0,
    showcores    => 0,
    showmem      => 0,
    shownet      => 0,
    showtext     => 1,
    showtexthost => 0,
    sshopts      => '',
);

%I = (
    cpustring   => 'cpu',
    showtextoff => 0,
);

