package Loadbars::Shared;

my %PIDS : shared;
my %AVGSTATS : shared;
my %CPUSTATS : shared;
my %MEMSTATS : shared;
my %MEMSTATS_HAS : shared;
#my %NETSTATS : shared;
#my %NETSTATS_HAS : shared;

# Global configuration hash
my %C : shared;
# Global configuration hash for internal settings (not configurable)
my %I : shared;

# Setting defaults
%C = (
    average => 15,
    barwidth => 35,
    extended => 0,
    factor => 1,
    height => 230,
    maxwidth => 1280, 
    samples => 1000,
    showcores => 0,
    showmem => 0,
    showtext => 1,
    showtexthost => 0,
    sshopts => '',
);

%I = (
    cpuregexp => 'cpu',
    showtextoff => 0,
);

