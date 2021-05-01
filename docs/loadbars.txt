NAME
    loadbars - A small and humble tool to observe server loads

SYNOPSIS
    loadbars [LIST OF HOSTNAMES] [OPTIONS]

  Tested platforms
    This version of loadbars has only been tested on Debian GNU/Linux
    Wheezy.

  I like flying elephants
    For any startup params help check out --help on command line or 'h'
    during program execution.

  A few examples however
    loadbars --extended 1 --showcores 1 --height 300 --hosts localhost

    loadbars --hosts localhost,server1.example.com,server2.example.com

    loadbars --cluster foocluster (foocluster is in /etc/clusters
    [ClusterSSH])

  More examples, using shell expansion
    loadbars servername{01,02,03}.example.com

    loadbars servername{01..50}.example.com --showcores 1

DESCRIPTION
    Loadbars is a small script that can be used to observe CPU loads of
    several remote servers at once in real time. It connects with SSH (using
    SSH public/private key auth) to several servers at once and vizualizes
    all server CPUs and memory statistics right next each other (either
    summarized or each core separately). Loadbars is not a tool for
    collecting CPU loads and drawing graphs for later analysis. However,
    since such tools require a significant amount of time before producing
    results, Loadbars lets you observe the current state immediately.
    Loadbars does not remember or record any load information. It just shows
    the current CPU usages like top or vmstat does.

INFO
  CPU stuff
    st = Steal in % [see man proc] (extended), Color: Red

    gt = Guest in % [see man proc] (extended), Color: Red

    sr = Soft IRQ usage in % (extended), Color: White

    ir = IRQ usage in % (extended), Color: White

    io = IOwait cpu sage in %, Color: Purple

    id = Idle cpu usage in % (extended), Color: Black

    ni = Nice cpu usage in %, Color: Green

    us = User cpu usage in %, Color: Yellow, dark yellow if to>50%, orange
    if to>50%

    sy = System cpu sage in %, Color: Blue, lighter blue if >30%

    to = Total CPU usage, which is (100% - id)

    pk = Max us+sy peak of last avg. samples (extended)

    1px horizontal line: Maximum sy+us+io of last 'avg' samples (extended)

  Memory stuff
    Ram: System ram usage in %, Color: Dark grey

    Swp: System swap usage in %, Color: Grey

  Network stuff
    Rxb: Incoming (received) traffic in %, Color: Light green, normal green
    if >100% while using low netlink reference. Bar comes from top and is
    half width.

    Txb: Outgoing (transmitted) traffic in %, Color: Light green, normal
    green if >100% while using low netlink reference. Bar comes from bottom
    and is half width.

    When network bar is red: The interface does not exist on the specific
    remote host.

   Config file support
    Loadbars tries to read ~/.loadbarsrc and it's possible to configure any
    option you find in --help but without leading '--'. For comments just
    use the '#' sign. Sample config:

        showcores=1 # Always show cores on startup

    will always show all CPU cores. If you press the 'w' hotkey during
    program execution your config file will be overwritten using the current
    settings.

LICENSE
    See package description or project website.

AUTHOR
    Paul Buetow - <http://buetow.org>

