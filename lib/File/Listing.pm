#
# $Id: Listing.pm,v 1.1 1996/03/05 10:58:48 aas Exp $

package File::Listing;

sub Version { $VERSION; }
$VERSION = sprintf("%d.%02d", q$Revision: 1.1 $ =~ /(\d+)\.(\d+)/);

=head1 NAME

parse_dir - parse directory listing

=head1 SYNOPSIS

 use File::Listing;
 for (parse_dir(`ls -l`)) {
     ($name, $type, $size, $mtime, $mode) = @$_;
     next if $type ne 'f'; # plain file
     #...
 }

 # directory listing can also be read from a file
 open(DIR, "ls -lR|);
 $dir = parse_dir(\*DIR, '+0000', 'unix');

=head1 DESCRIPTION

The parse_dir() routine can be used to parse directory
listings. Currently it only understand Unix C<'ls -l'> and C<'ls -lR'>
format.  It should eventually be able to most things you might get
back from a ftp server file listing (LIST command), i.e. VMS listings,
NT listings, DOS listings,...

The first parameter to parse_dir() is the directory listing to parse.
It can be a scalar, a reference to an array of directory lines or a
glob representing a filehandle to read the directory listing from.

The second parameter is the timezone to use when parsing time stamps
in the listing. If this value is undefined, then the local timezone is
assumed.

The third parameter is the type of listing to assume.  The values will
be strings like 'unix', 'vms', 'dos'.  Currently only 'unix' is
implemented and this is also the default value.  Ideally, the listing
type should be determined automatically.

The fourth parameter specify how unparseable lines should be treated.
Values can be 'ignore', 'warn' or a code reference.  Warn means that
the perl warn() function will be called.  If a code reference is
passed, then this routine will be called and the return value from it
will be incoporated in the listing.  The default is 'ignore'.

Only the first parameter is mandatory.  The parse_dir() prototype is
($;$$$).

The return value from parse_dir() is a list of directory entries.  In
scalar context the return value is a reference to the list.  The
directory entries are represented by an array consisting of [
$filename, $filetype, $filesize, $filetime, $filemode ].  The
$filetype value is one of the letters 'f', 'd', 'l' or '?'.  The
$filetime value is converted to seconds since Jan 1, 1970.  The
$filemode is a bitmask like the mode returned by stat().

=head1 CREDITS

Based on lsparse.pl (from Lee McLoughlin's ftp mirror package) and
Net::FTP's parse_dir (Graham Barr).

=cut

require Exporter;
@ISA = qw(Exporter);

@EXPORT = qw(parse_dir);

use strict;

use Carp ();
use HTTP::Date qw(str2time);


sub parse_dir ($;$$)
{
   my($dir, $tz, $fstype, $error) = shift;

   # First let's try to determine what kind of dir parameter we have
   # received.  We allow both listings, reference to arrays and
   # file handles to read from.

   if (ref($dir) eq 'ARRAY') {
       # Already splitted up
   } elsif (ref($dir) eq 'GLOB') {
       # A file handle
   } elsif (ref($dir)) {
      Carp::croak("Illegal argument to parse_dir()");
   } elsif ($dir =~ /^\*\w+(::\w+)+$/) {
      # This scalar looks like a file handle, so we assume it is
   } else {
      # A normal scalar listing
      $dir = [ split(/\n/, $dir) ];
   }

   # Let's convert the tz to an offset in seconds
   if (defined $tz) {
       if ($tz =~ /^([-+])?(\d{1,2})(\d{2})?$/) {
	   $tz = 3600 * $2;
	   $tz +=  60 * $3 if $3;
	   $tz *= -1 if $1 ne '-';
       } else {
	   Carp::croak("Illegal timezone argument (format is +0100)");
       }
   }

   # Default listing type is Unix 'ls -l'
   $fstype ||= 'unix';

   no strict 'refs';

   my $init   = "parse_${fstype}_init";
   my $parser = "parse_${fstype}_line";
   &$init if defined &$init;

   my @files;
   if (ref($dir) eq 'ARRAY') {
       for (@$dir) {
	   push(@files, &$parser($_, $tz, $error));
       }
   } else {
       while (<$dir>) {
	   chomp;
	   push(@files, &$parser($_, $tz, $error));
       }
   }
   wantarray ? @files : \@files;

}


sub file_mode ($)
{
    # This routine was originally borrowed from Graham Barr's
    # Net::FTP package.

    local $_ = shift;
    my $mode = 0;
    my($type,$ch);

    s/^(.)// and $type = $1;

    while (/(.)/g) {
	$mode <<= 1;
	$mode |= 1 if $1 ne "-" &&
                      $1 ne 'S' &&
                      $1 ne 't' &&
                      $1 ne 'T';
    }

    $type eq "d" and $mode |= 0040000 or	# Directory
      $type eq "l" and $mode |= 0120000 or	# Symbolic Link
	$mode |= 0100000;			# Regular File

    $mode |= 0004000 if /^...s....../i;
    $mode |= 0002000 if /^......s.../i;
    $mode |= 0001000 if /^.........t/i;

    $mode;
}

# A place to remember current directory from last line parsed.
use vars qw($curdir);

sub parse_unix_init
{
    $curdir = '';
}

sub parse_unix_line
{
    local($_) = shift;
    my($tz, $error) = @_;

    s/\015//g;
    #study;
    my ($kind, $size, $date, $name);
    if (($kind, $size, $date, $name) =
	/^([\-FlrwxsStTdD]{10})                   # Type and permission bits
         .*                                       # Graps
	 \D(\d+)                                  # File size
         \s+                                      # Some space
         (\w{3}\s+\d+\s+(?:\d{1,2}:\d{2}|\d{4}))  # Date
         \s+                                      # Some more space
         (.*)$                                    # File name
        /x )

    {  
	next if $name eq '.' || $name eq '..';
	$name = "$curdir/$name" if length $curdir;
	my $type = '?';
	if ($kind =~ /^l/ && $name =~ /(.*) -> (.*)/ ) {
	    $name = $1;
	    $type = "l $2";
	} elsif ($kind =~ /^[\-F]/) { # (hopefully) a regular file
	    $type = 'f';
	} elsif ($kind =~ /^[dD]/) {
	    $type = 'd';
	    #$size = undef;  # Don't believe the reported size
	}
	return [$name, $type, $size, str2time($date, $tz), file_mode($kind)];

    } elsif (/^(.+):$/) {
	my $dir = $1;
        next if $dir eq '.';
	$dir = "$curdir/$dir" if $dir !~ m|/| && length($curdir);
	$curdir = $dir;
	return ();
    } elsif (/^[Tt]otal\s+(\d+)$/ || /^\s*$/) {
	return ();
    } else {
	return () unless defined $error;
	&$error($_) if ref($error) eq 'CODE';
        warn "Can't parse: $_\n" if $error eq 'warn';
	return ();
    }

}

sub parse_vms_line
{
    Carp::croak("Not implemented yet");
}

sub parse_netware_line
{
    Carp::croak("Not implemented yet");
}

sub parse_dosftp_line
{
    Carp::croak("Not implemented yet");
}

1;