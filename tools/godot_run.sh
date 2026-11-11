#!/bin/zsh
# Runs Godot for a test / tool and never hangs: kills it after TIMEOUT seconds (default 120)
# and, unless KEEP_ON_ERROR is set, as soon as a script fails to parse or compile (the usual
# cause of a stuck run: the scene waits forever for a node that never loaded). Prints
# Godot's output; exits 0, or 124 on timeout, 125 on a script error.
#   tools/godot_run.sh [godot args...]        e.g.  tools/godot_run.sh --headless --path . tests/x.tscn
#   TIMEOUT=300 tools/godot_run.sh --path . --resolution 1280x720 tests/zones/shot.tscn
G="${GODOT:-/Users/sakwa/Library/Application Support/Godot/app_userdata/Godots/versions/Godot_v4_7_2-stable_mono_macos_universal/Godot_mono.app/Contents/MacOS/Godot}"
exec perl -e '
	use strict;
	my $timeout = $ENV{TIMEOUT} || 120;
	my $pid = open(my $out, "-|") // die "fork: $!";
	if ($pid == 0) { open(STDERR, ">&STDOUT"); exec(@ARGV) or die "exec: $!"; }
	my $code = 0;
	local $SIG{ALRM} = sub { print "\n[godot_run] timed out after ${timeout}s: killed\n"; kill("KILL", $pid); exit 124; };
	alarm $timeout;
	while (my $line = <$out>) {
		print $line;
		if (!$ENV{KEEP_ON_ERROR} && $line =~ /(Parse Error|Compile Error|Failed to load script)/) {
			print "[godot_run] script error: killed (KEEP_ON_ERROR=1 to run on)\n";
			kill("KILL", $pid);
			exit 125;
		}
	}
	waitpid($pid, 0);
	exit($? >> 8);
' "$G" "$@"
