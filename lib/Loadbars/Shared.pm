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
    cpuaverage   => 15,
    netaverage   => 5,
    barwidth     => 35,
    extended     => 0,
    factor       => 1,
    hasagent     => 0,
    height       => 230,
    maxwidth     => 1250,
    showcores    => 0,
    showmem      => 0,
    shownet      => 0,
    showtext     => 1,
    showtexthost => 0,
    sshopts      => '',
    netint       => 'eth0',
);

%I = (
    cpustring   => 'cpu',
    showtextoff => 0,
);

