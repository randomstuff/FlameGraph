#!/usr/bin/perl -w
#
# stackcollapse-jstack.pl	collapse jstack samples into single lines.
#
# Parses Java stacks generated by jstack(1) and outputs RUNNABLE stacks as
# single lines, with methods separated by semicolons, and then a space and an
# occurrence count. This also filters some other "RUNNABLE" states that we
# know are probably not running, such as epollWait. For use with flamegraph.pl.
#
# You want this to process the output of at least 100 jstack(1)s. ie, run it
# 100 times with a sleep interval, and append to a file. This is really a poor
# man's Java profiler, due to the overheads of jstack(1), and how it isn't
# capturing stacks asynchronously. For a better profiler, see:
# http://www.brendangregg.com/blog/2014-06-12/java-flame-graphs.html
#
# USAGE: ./stackcollapse-jstack.pl infile > outfile
#
# Example input:
#
# "MyProg" #273 daemon prio=9 os_prio=0 tid=0x00007f273c038800 nid=0xe3c runnable [0x00007f28a30f2000]
#    java.lang.Thread.State: RUNNABLE
#        at java.net.SocketInputStream.socketRead0(Native Method)
#        at java.net.SocketInputStream.read(SocketInputStream.java:121)
#        ...
#        at java.lang.Thread.run(Thread.java:744)
#
# Example output:
#
#  MyProg;java.lang.Thread.run;java.net.SocketInputStream.read;java.net.SocketInputStream.socketRead0 1
#
# Input may be created and processed using:
#
#  i=0; while (( i++ < 200 )); do jstack PID >> out.jstacks; sleep 10; done
#  cat out.jstacks | ./stackcollapse-jstack.pl > out.stacks-folded
#
# WARNING: jstack(1) incurs overheads. Test before use, or use a real profiler.
#
# Copyright 2014 Brendan Gregg.  All rights reserved.
#
#  This program is free software; you can redistribute it and/or
#  modify it under the terms of the GNU General Public License
#  as published by the Free Software Foundation; either version 2
#  of the License, or (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software Foundation,
#  Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
#
#  (http://www.gnu.org/copyleft/gpl.html)
#
# 14-Sep-2014	Brendan Gregg	Created this.

use strict;

use Getopt::Long;

# tunables
my $include_tname = 1;		# include thread names in stacks
my $include_tid = 0;		# include thread IDs in stacks
<<<<<<< HEAD
my $include_lines = 0;		# include thread IDs in stacks
=======
my $include_all_states = 0;	# include all thread states
>>>>>>> jstack-all-states
my $shorten_pkgs = 0;		# shorten package names
my $help = 0;

sub usage {
	die <<USAGE_END;
USAGE: $0 [options] infile > outfile\n
	--include-tname
	--no-include-tname # include/omit thread names in stacks (default: include)
	--include-tid
	--no-include-tid   # include/omit thread IDs in stacks (default: omit)
	--include-lines
	--no-include-lines # include/omit line numbers in stacks (default: omit)
	--no-include-all-states
	--include-all-states  # include all thread states (WAITING, etc.) (default: omit)
	--shorten-pkgs
	--no-shorten-pkgs  # (don't) shorten package names (default: don't shorten)

	eg,
	$0 --no-include-tname stacks.txt > collapsed.txt
USAGE_END
}

GetOptions(
	'include-tname!'  => \$include_tname,
	'include-tid!'    => \$include_tid,
	'include-lines!'  => \$include_lines,
	'include-all-states!' => \$include_all_states,
	'shorten-pkgs!'   => \$shorten_pkgs,
	'help'            => \$help,
) or usage();
$help && usage();


# internals
my %collapsed;

sub remember_stack {
	my ($stack, $count) = @_;
	$collapsed{$stack} += $count;
}

my @stack;
my $tname;
my $state = "?";
my $background = 0;

foreach (<>) {
	next if m/^#/;
	chomp;

	if (m/^$/) {
		# only include RUNNABLE states
		goto clear if $background == 1 or (not $include_all_states and $state ne "RUNNABLE");

		# save stack
		if (defined $tname) { unshift @stack, $tname; }
		remember_stack(join(";", @stack), 1) if @stack;
clear:
		undef @stack;
		undef $tname;
		$state = "?";
		next;
	}

	#
	# While parsing jstack output, the $state variable may be altered from
	# RUNNABLE to other states. This causes the stacks to be filtered later,
	# since only RUNNABLE stacks are included.
	#

	if (/^"([^"]*)/) {
		my $name = $1;

		if ($include_tname) {
			$tname = $name;
			unless ($include_tid) {
				$tname =~ s/-\d+$//;
			}
		}

		# set $background for various background threads
		$background = 0;
		$background = 1 if $name =~ /C. CompilerThread/;
		$background = 1 if $name =~ /Signal Dispatcher/;
		$background = 1 if $name =~ /Service Thread/;
		$background = 1 if $name =~ /Attach Listener/;

	} elsif (/java.lang.Thread.State: (\S+)/) {
		$state = $1 if $state eq "?";
	} elsif (/^\s*at ([^\(]*)/) {
		my $func = $1;
		if ($shorten_pkgs) {
			my ($pkgs, $clsFunc) = ( $func =~ m/(.*\.)([^.]+\.[^.]+)$/ );
			$pkgs =~ s/(\w)\w*/$1/g;
			$func = $pkgs . $clsFunc;
		}
		if ($include_lines and /:([0-9]+)\)$/) {
			unshift @stack, $func . ':' . $1;
		}
		unshift @stack, $func;

		# fix state for epollWait
		$state = "WAITING" if $func =~ /epollWait/;
		$state = "WAITING" if $func =~ /EPoll\.wait/;


		# fix state for various networking functions
		$state = "NETWORK" if $func =~ /socketAccept$/;
		$state = "NETWORK" if $func =~ /Socket.*accept0$/;
		$state = "NETWORK" if $func =~ /socketRead0$/;

	} elsif (/^\s*-/ or /^2\d\d\d-/ or /^Full thread dump/ or
		 /^JNI global references:/) {
		# skip these info lines
		next;
	} else {
		warn "Unrecognized line: $_";
	}
}

foreach my $k (sort { $a cmp $b } keys %collapsed) {
	print "$k $collapsed{$k}\n";
}
