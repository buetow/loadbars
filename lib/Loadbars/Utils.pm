package Loadbars::Utils;

use strict;
use warnings;

use Exporter;

use base 'Exporter';

our @EXPORT = qw (
  debugsay
  display_info
  display_info_no_nl
  display_warn
  newline
  notnull
  null
  say
  sum
  trim
  get_version
);

sub say (@) { print "$_\n" for @_; return undef }
sub newline () { say ''; return undef }
sub debugsay (@) { say "Loadbars::DEBUG: $_" for @_; return undef }
sub sum (@) { my $sum = 0; $sum += $_ for @_; return $sum }
sub null ($)    { defined $_[0] ? $_[0] : 0 }
sub notnull ($) { $_[0] != 0    ? $_[0] : 1 }
sub error ($) { die shift, "\n" }

sub trim (\$) {
    my $str = shift;
    $$str =~ s/^[\s\t]+//;
    $$str =~ s/[\s\t]+$//;
    return undef;
}
sub display_info_no_nl ($) { print "==> " . (shift) . ' ' }
sub display_info ($)       { say "==> " . shift }
sub display_warn ($)       { say "!!! " . shift }

sub get_version () {
    my $versionfile = do {
        if ( -f '.version' ) {
            '.version';
        }
        else {
            '/usr/share/loadbars/version';
        }
    };

    open my $fh, $versionfile or error("$!: $versionfile");
    my $version = <$fh>;
    close $fh;

    chomp $version;
    return $version;
}

1;
