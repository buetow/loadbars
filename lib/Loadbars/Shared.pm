package Loadbars::Shared;

use Exporter;

use base 'Exporter';

our @EXPORT = qw(
  %PIDS
  %AVGSTATS
  %CPUSTATS
  %MEMSTATS
  %MEMSTATS_HAS
  %NETSTATS
  %NETSTATS_HAS
  %C
  %I
);

our %PIDS : shared;
our %AVGSTATS : shared;
our %CPUSTATS : shared;
our %MEMSTATS : shared;
our %MEMSTATS_HAS : shared;
our %NETSTATS : shared;
our %NETSTATS_HAS : shared;

# Global configuration hash
our %C : shared;

# Global configuration hash for internal settings (not configurable)
our %I : shared;

# Setting defaults
%C = (
    title        => undef,
    average      => 15,
    barwidth     => 35,
    extended     => 0,
    factor       => 1,
    hasagent     => 0,
    height       => 230,
    maxwidth     => 1280,
    samples      => 5000,
    showcores    => 0,
    showmem      => 0,
    showtext     => 1,
    showtexthost => 0,
    sshopts      => '',
);

%I = (
    cpustring   => 'cpu',
    showtextoff => 0,
);

