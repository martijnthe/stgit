# Test framework for git, adapted for StGit.  See t/README for usage.
#
# Copyright (c) 2005 Junio C Hamano
# Copyright (c) 2006 Yann Dirson - tuning for stgit
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see http://www.gnu.org/licenses/ .

# Test the binaries we have just built.  The tests are kept in
# t/ subdirectory and are run in 'trash directory' subdirectory.
if test -z "$TEST_DIRECTORY"
then
	# ensure that TEST_DIRECTORY is an absolute path so that it
	# is valid even if the current working directory is changed
	TEST_DIRECTORY=$(pwd)
else
	# The TEST_DIRECTORY will always be the path to the "t"
	# directory in the git.git checkout. This is overridden by
	# e.g. t/lib-subtest.sh, but only because its $(pwd) is
	# different. Those tests still set "$TEST_DIRECTORY" to the
	# same path.
	#
	# See use of "$GIT_BUILD_DIR" and "$TEST_DIRECTORY" below for
	# hard assumptions about "$GIT_BUILD_DIR/t" existing and being
	# the "$TEST_DIRECTORY", and e.g. "$TEST_DIRECTORY/helper"
	# needing to exist.
	TEST_DIRECTORY=$(cd "$TEST_DIRECTORY" && pwd) || exit 1
fi
if test -z "$TEST_OUTPUT_DIRECTORY"
then
	# Similarly, override this to store the test-results subdir
	# elsewhere
	TEST_OUTPUT_DIRECTORY=$TEST_DIRECTORY
fi
STG_ROOT="${TEST_DIRECTORY%/t}"
if test "$TEST_DIRECTORY" = "$STG_ROOT"
then
	echo "PANIC: Running in a $TEST_DIRECTORY that doesn't end in '/t'?" >&2
	exit 1
fi
export STG_ROOT

PERL_PATH=${PERL:-perl}
SHELL_PATH=${SHELL_PATH:-/bin/sh}
TEST_SHELL_PATH=${TEST_SHELL_PATH:-$SHELL_PATH}
export PERL_PATH SHELL_PATH

# In t0000, we need to override test directories of nested testcases. In case
# the developer has TEST_OUTPUT_DIRECTORY part of his build options, then we'd
# reset this value to instead contain what the developer has specified. We thus
# have this knob to allow overriding the directory.
if test -n "${TEST_OUTPUT_DIRECTORY_OVERRIDE}"
then
	TEST_OUTPUT_DIRECTORY="${TEST_OUTPUT_DIRECTORY_OVERRIDE}"
fi

# Explicitly set the default branch name for testing, to avoid the
# transitory "git init" warning under --verbose.
: ${GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME:=master}
export GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME

store_arg_to=
opt_required_arg=
# $1: option string
# $2: name of the var where the arg will be stored
mark_option_requires_arg () {
	if test -n "$opt_required_arg"
	then
		echo "error: options that require args cannot be bundled" \
			"together: '$opt_required_arg' and '$1'" >&2
		exit 1
	fi
	opt_required_arg=$1
	store_arg_to=$2
}

# These functions can be overridden e.g. to output JUnit XML
start_test_output () { :; }
start_test_case_output () { :; }
finalize_test_case_output () { :; }
finalize_test_output () { :; }

parse_option () {
	local opt="$1"

	case "$opt" in
	-d|--d|--de|--deb|--debu|--debug)
		debug=t ;;
	-i|--i|--im|--imm|--imme|--immed|--immedi|--immedia|--immediat|--immediate)
		immediate=t ;;
	-l|--l|--lo|--lon|--long|--long-|--long-t|--long-te|--long-tes|--long-test|--long-tests)
		GIT_TEST_LONG=t; export GIT_TEST_LONG ;;
	-r)
		mark_option_requires_arg "$opt" run_list
		;;
	--run=*)
		run_list=${opt#--*=} ;;
	-h|--h|--he|--hel|--help)
		help=t ;;
	-v|--v|--ve|--ver|--verb|--verbo|--verbos|--verbose)
		verbose=t ;;
	--verbose-only=*)
		verbose_only=${opt#--*=}
		;;
	-q|--q|--qu|--qui|--quie|--quiet)
		# Ignore --quiet under a TAP::Harness. Saying how many tests
		# passed without the ok/not ok details is always an error.
		test -z "$HARNESS_ACTIVE" && quiet=t ;;
	--no-color)
		color= ;;
	--tee)
		tee=t ;;
	--root=*)
		root=${opt#--*=} ;;
	-x)
		trace=t ;;
	-V|--verbose-log)
		verbose_log=t
		tee=t
		;;
	--write-junit-xml)
		. "$TEST_DIRECTORY/test-lib-junit.sh"
		;;
	--github-workflow-markup)
		. "$TEST_DIRECTORY/test-lib-github-workflow-markup.sh"
		;;
	--stress)
		stress=t ;;
	--stress=*)
		echo "error: --stress does not accept an argument: '$opt'" >&2
		echo "did you mean --stress-jobs=${opt#*=} or --stress-limit=${opt#*=}?" >&2
		exit 1
		;;
	--stress-jobs=*)
		stress=t;
		stress_jobs=${opt#--*=}
		case "$stress_jobs" in
		*[!0-9]*|0*|"")
			echo "error: --stress-jobs=<N> requires the number of jobs to run" >&2
			exit 1
			;;
		*)	# Good.
			;;
		esac
		;;
	--stress-limit=*)
		stress=t;
		stress_limit=${opt#--*=}
		case "$stress_limit" in
		*[!0-9]*|0*|"")
			echo "error: --stress-limit=<N> requires the number of repetitions" >&2
			exit 1
			;;
		*)	# Good.
			;;
		esac
		;;
	*)
		echo "error: unknown test option '$opt'" >&2; exit 1 ;;
	esac
}

# Parse options while taking care to leave $@ intact, so we will still
# have all the original command line options when executing the test
# script again for '--tee' and '--verbose-log' later.
for opt
do
	if test -n "$store_arg_to"
	then
		eval $store_arg_to=\$opt
		store_arg_to=
		opt_required_arg=
		continue
	fi

	case "$opt" in
	--*|-?)
		parse_option "$opt" ;;
	-?*)
		# bundled short options must be fed separately to parse_option
		opt=${opt#-}
		while test -n "$opt"
		do
			extra=${opt#?}
			this=${opt%$extra}
			opt=$extra
			parse_option "-$this"
		done
		;;
	*)
		echo "error: unknown test option '$opt'" >&2; exit 1 ;;
	esac
done
if test -n "$store_arg_to"
then
	echo "error: $opt_required_arg requires an argument" >&2
	exit 1
fi

if test -n "$stress"
then
	verbose=t
	trace=t
	immediate=t
fi

TEST_STRESS_JOB_SFX="${GIT_TEST_STRESS_JOB_NR:+.stress-$GIT_TEST_STRESS_JOB_NR}"
TEST_NAME="$(basename "$0" .sh)"
TEST_NUMBER="${TEST_NAME%%-*}"
TEST_NUMBER="${TEST_NUMBER#t}"
TEST_RESULTS_DIR="$TEST_OUTPUT_DIRECTORY/test-results"
TEST_RESULTS_BASE="$TEST_RESULTS_DIR/$TEST_NAME$TEST_STRESS_JOB_SFX"
TRASH_DIRECTORY="trash directory.$TEST_NAME$TEST_STRESS_JOB_SFX"
test -n "$root" && TRASH_DIRECTORY="$root/$TRASH_DIRECTORY"
case "$TRASH_DIRECTORY" in
/*) ;; # absolute path is good
 *) TRASH_DIRECTORY="$TEST_OUTPUT_DIRECTORY/$TRASH_DIRECTORY" ;;
esac

# If --stress was passed, run this test repeatedly in several parallel loops.
if test "$GIT_TEST_STRESS_STARTED" = "done"
then
	: # Don't stress test again.
elif test -n "$stress"
then
	if test -n "$stress_jobs"
	then
		job_count=$stress_jobs
	elif test -n "$GIT_TEST_STRESS_LOAD"
	then
		job_count="$GIT_TEST_STRESS_LOAD"
	elif job_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null) &&
	     test -n "$job_count"
	then
		job_count=$((2 * $job_count))
	else
		job_count=8
	fi

	mkdir -p "$TEST_RESULTS_DIR"
	stressfail="$TEST_RESULTS_BASE.stress-failed"
	rm -f "$stressfail"

	stress_exit=0
	trap '
		kill $job_pids 2>/dev/null
		wait
		stress_exit=1
	' TERM INT HUP

	job_pids=
	job_nr=0
	while test $job_nr -lt "$job_count"
	do
		(
			GIT_TEST_STRESS_STARTED=done
			GIT_TEST_STRESS_JOB_NR=$job_nr
			export GIT_TEST_STRESS_STARTED GIT_TEST_STRESS_JOB_NR

			trap '
				kill $test_pid 2>/dev/null
				wait
				exit 1
			' TERM INT

			cnt=1
			while ! test -e "$stressfail" &&
			      { test -z "$stress_limit" ||
				test $cnt -le $stress_limit ; }
			do
				$TEST_SHELL_PATH "$0" "$@" >"$TEST_RESULTS_BASE.stress-$job_nr.out" 2>&1 &
				test_pid=$!

				if wait $test_pid
				then
					printf "OK   %2d.%d\n" $GIT_TEST_STRESS_JOB_NR $cnt
				else
					echo $GIT_TEST_STRESS_JOB_NR >>"$stressfail"
					printf "FAIL %2d.%d\n" $GIT_TEST_STRESS_JOB_NR $cnt
				fi
				cnt=$(($cnt + 1))
			done
		) &
		job_pids="$job_pids $!"
		job_nr=$(($job_nr + 1))
	done

	wait

	if test -f "$stressfail"
	then
		stress_exit=1
		echo "Log(s) of failed test run(s):"
		for failed_job_nr in $(sort -n "$stressfail")
		do
			echo "Contents of '$TEST_RESULTS_BASE.stress-$failed_job_nr.out':"
			cat "$TEST_RESULTS_BASE.stress-$failed_job_nr.out"
		done
		rm -rf "$TRASH_DIRECTORY.stress-failed"
		# Move the last one.
		mv "$TRASH_DIRECTORY.stress-$failed_job_nr" "$TRASH_DIRECTORY.stress-failed"
	fi

	exit $stress_exit
fi

# if --tee was passed, write the output not only to the terminal, but
# additionally to the file test-results/$BASENAME.out, too.
if test "$GIT_TEST_TEE_STARTED" = "done"
then
	: # do not redirect again
elif test -n "$tee"
then
	mkdir -p "$TEST_RESULTS_DIR"

	# Make this filename available to the sub-process in case it is using
	# --verbose-log.
	GIT_TEST_TEE_OUTPUT_FILE=$TEST_RESULTS_BASE.out
	export GIT_TEST_TEE_OUTPUT_FILE

	# Truncate before calling "tee -a" to get rid of the results
	# from any previous runs.
	>"$GIT_TEST_TEE_OUTPUT_FILE"

	(GIT_TEST_TEE_STARTED=done ${TEST_SHELL_PATH} "$0" "$@" 2>&1;
	 echo $? >"$TEST_RESULTS_BASE.exit") | tee -a "$GIT_TEST_TEE_OUTPUT_FILE"
	test "$(cat "$TEST_RESULTS_BASE.exit")" = 0
	exit
fi

if test -n "$trace" && test -n "$test_untraceable"
then
	# '-x' tracing requested, but this test script can't be reliably
	# traced, unless it is run with a Bash version supporting
	# BASH_XTRACEFD (introduced in Bash v4.1).
	#
	# Perform this version check _after_ the test script was
	# potentially re-executed with $TEST_SHELL_PATH for '--tee' or
	# '--verbose-log', so the right shell is checked and the
	# warning is issued only once.
	if test -n "$BASH_VERSION" && eval '
	     test ${BASH_VERSINFO[0]} -gt 4 || {
	       test ${BASH_VERSINFO[0]} -eq 4 &&
	       test ${BASH_VERSINFO[1]} -ge 1
	     }
	   '
	then
		: Executed by a Bash version supporting BASH_XTRACEFD.  Good.
	else
		echo >&2 "warning: ignoring -x; '$0' is untraceable without BASH_XTRACEFD"
		trace=
	fi
fi
if test -n "$trace" && test -z "$verbose_log"
then
	verbose=t
fi

# Since bash 5.0, checkwinsize is enabled by default which does
# update the COLUMNS variable every time a non-builtin command
# completes, even for non-interactive shells.
# Disable that since we are aiming for repeatability.
test -n "$BASH_VERSION" && shopt -u checkwinsize 2>/dev/null

# For repeatability, reset the environment to known value.
# TERM is sanitized below, after saving color control sequences.
LANG=${STG_TEST_LANG:-C}
LC_ALL=$LANG
PAGER=cat
TZ=UTC
COLUMNS=80
export LANG LC_ALL PAGER TZ COLUMNS
EDITOR=:

# A call to "unset" with no arguments causes at least Solaris 10
# /usr/xpg4/bin/sh and /bin/ksh to bail out.  So keep the unsets
# deriving from the command substitution clustered with the other
# ones.
unset VISUAL EMAIL LANGUAGE $("$PERL_PATH" -e '
	my @env = keys %ENV;
	my $ok = join("|", qw(
		TRACE
		DEBUG
		TEST
		.*_TEST
		PROVE
		VALGRIND
		UNZIP
		PERF_
		CURL_VERBOSE
		TRACE_CURL
	));
	my @vars = grep(/^GIT_/ && !/^GIT_($ok)/o, @env);
	print join("\n", @vars);
')
unset XDG_CACHE_HOME
unset XDG_CONFIG_HOME
unset GITPERLLIB
TEST_AUTHOR_LOCALNAME=author
TEST_AUTHOR_DOMAIN=example.com
GIT_AUTHOR_EMAIL=${TEST_AUTHOR_LOCALNAME}@${TEST_AUTHOR_DOMAIN}
GIT_AUTHOR_NAME='A Ú Thor'
GIT_AUTHOR_DATE='1112354055 +0200'
TEST_COMMITTER_LOCALNAME=committer
TEST_COMMITTER_DOMAIN=example.com
GIT_COMMITTER_EMAIL=${TEST_COMMITTER_LOCALNAME}@${TEST_COMMITTER_DOMAIN}
GIT_COMMITTER_NAME='C Ó Mitter'
GIT_COMMITTER_DATE='1112354055 +0200'
GIT_MERGE_VERBOSITY=5
GIT_MERGE_AUTOEDIT=no
export GIT_MERGE_VERBOSITY GIT_MERGE_AUTOEDIT
export GIT_AUTHOR_EMAIL GIT_AUTHOR_NAME
export GIT_COMMITTER_EMAIL GIT_COMMITTER_NAME
export GIT_COMMITTER_DATE GIT_AUTHOR_DATE
export EDITOR

GIT_DEFAULT_HASH="${GIT_TEST_DEFAULT_HASH:-sha1}"
export GIT_DEFAULT_HASH
GIT_TEST_MERGE_ALGORITHM="${GIT_TEST_MERGE_ALGORITHM:-ort}"
export GIT_TEST_MERGE_ALGORITHM

# Tests using GIT_TRACE typically don't want <timestamp> <file>:<line> output
GIT_TRACE_BARE=1
export GIT_TRACE_BARE

# Use specific version of the index file format
if test -n "${GIT_TEST_INDEX_VERSION:+isset}"
then
	GIT_INDEX_VERSION="$GIT_TEST_INDEX_VERSION"
	export GIT_INDEX_VERSION
fi

if test -n "$GIT_TEST_PERL_FATAL_WARNINGS"
then
	GIT_PERL_FATAL_WARNINGS=1
	export GIT_PERL_FATAL_WARNINGS
fi

# Protect ourselves from common misconfiguration to export
# CDPATH into the environment
unset CDPATH

unset GREP_OPTIONS
unset UNZIP

case $(echo $GIT_TRACE |tr "[A-Z]" "[a-z]") in
1|2|true)
	GIT_TRACE=4
	;;
esac

# Line feed
LF='
'

# Single quote
SQ=\'

# UTF-8 ZERO WIDTH NON-JOINER, which HFS+ ignores
# when case-folding filenames
u200c=$(printf '\342\200\214')

export _x05 _x35 LF u200c EMPTY_TREE EMPTY_BLOB ZERO_OID OID_REGEX

# Each test should start with something like this, after copyright notices:
#
# test_description='Description of this test...
# This test checks if command xyzzy does the right thing...
# '
# . ./test-lib.sh
test "x$TERM" != "xdumb" && (
		test -t 1 &&
		tput bold >/dev/null 2>&1 &&
		tput setaf 1 >/dev/null 2>&1 &&
		tput sgr0 >/dev/null 2>&1
	) &&
	color=t

if test -n "$color"
then
	# Save the color control sequences now rather than run tput
	# each time say_color() is called.  This is done for two
	# reasons:
	#   * TERM will be changed to dumb
	#   * HOME will be changed to a temporary directory and tput
	#     might need to read ~/.terminfo from the original HOME
	#     directory to get the control sequences
	# Note:  This approach assumes the control sequences don't end
	# in a newline for any terminal of interest (command
	# substitutions strip trailing newlines).  Given that most
	# (all?) terminals in common use are related to ECMA-48, this
	# shouldn't be a problem.
	say_color_error=$(tput bold; tput setaf 1) # bold red
	say_color_skip=$(tput setaf 4) # blue
	say_color_warn=$(tput setaf 3) # brown/yellow
	say_color_pass=$(tput setaf 2) # green
	say_color_info=$(tput setaf 6) # cyan
	say_color_reset=$(tput sgr0)
	say_color_="" # no formatting for normal text
	say_color () {
		test -z "$1" && test -n "$quiet" && return
		eval "say_color_color=\$say_color_$1"
		shift
		printf "%s\\n" "$say_color_color$*$say_color_reset"
	}
else
	say_color() {
		test -z "$1" && test -n "$quiet" && return
		shift
		printf "%s\n" "$*"
	}
fi

USER_TERM="$TERM"
TERM=dumb
export TERM USER_TERM

# What is written by tests to stdout and stderr is sent to different places
# depending on the test mode (e.g. /dev/null in non-verbose mode, piped to tee
# with --tee option, etc.). We save the original stdin to FD #6 and stdout and
# stderr to #5 and #7, so that the test framework can use them (e.g. for
# printing errors within the test framework) independently of the test mode.
exec 5>&1
exec 6<&0
exec 7>&2

_error_exit () {
	finalize_test_output
	GIT_EXIT_OK=t
	exit 1
}

error () {
	say_color error "error: $*"
	_error_exit
}

BUG () {
	error >&7 "bug in the test script: $*"
}

BAIL_OUT () {
	test $# -ne 1 && BUG "1 param"

	# Do not change "Bail out! " string. It's part of TAP syntax:
	# https://testanything.org/tap-specification.html
	local bail_out="Bail out! "
	local message="$1"

	say_color >&5 error $bail_out "$message"
	_error_exit
}

say () {
	say_color info "$*"
}

if test -n "$HARNESS_ACTIVE"
then
	if test "$verbose" = t || test -n "$verbose_only"
	then
		BAIL_OUT 'verbose mode forbidden under TAP harness; try --verbose-log'
	fi
fi

test "${test_description}" != "" ||
error "Test script did not set test_description."

if test "$help" = "t"
then
	printf '%s\n' "$test_description"
	exit 0
fi

if test "$verbose_log" = "t"
then
	exec 3>>"$GIT_TEST_TEE_OUTPUT_FILE" 4>&3
elif test "$verbose" = "t"
then
	exec 4>&2 3>&1
else
	exec 4>/dev/null 3>/dev/null
fi

# Send any "-x" output directly to stderr to avoid polluting tests
# which capture stderr. We can do this unconditionally since it
# has no effect if tracing isn't turned on.
#
# Note that this sets up the trace fd as soon as we assign the variable, so it
# must come after the creation of descriptor 4 above. Likewise, we must never
# unset this, as it has the side effect of closing descriptor 4, which we
# use to show verbose tests to the user.
#
# Note also that we don't need or want to export it. The tracing is local to
# this shell, and we would not want to influence any shells we exec.
BASH_XTRACEFD=4

test_failure=0
test_count=0
test_fixed=0
test_broken=0
test_success=0

test_missing_prereq=

test_external_has_tap=0

die () {
	code=$?
	# This is responsible for running the atexit commands even when a
	# test script run with '--immediate' fails, or when the user hits
	# ctrl-C, i.e. when 'test_done' is not invoked at all.
	test_atexit_handler || code=$?
	if test -n "$GIT_EXIT_OK"
	then
		exit $code
	else
		echo >&5 "FATAL: Unexpected exit with code $code"
		exit 1
	fi
}

GIT_EXIT_OK=
trap 'die' EXIT
# Disable '-x' tracing, because with some shells, notably dash, it
# prevents running the cleanup commands when a test script run with
# '--verbose-log -x' is interrupted.
trap '{ code=$?; set +x; } 2>/dev/null; exit $code' INT TERM HUP

# The user-facing functions are loaded from a separate file so that
# test_perf subshells can have them too
. "$TEST_DIRECTORY/test-lib-functions.sh"

# You are not expected to call test_ok_ and test_failure_ directly, use
# the test_expect_* functions instead.

test_ok_ () {
	test_success=$(($test_success + 1))
	say_color "" "ok $test_count - $@"
	finalize_test_case_output ok "$@"
}

test_failure_ () {
	failure_label=$1
	test_failure=$(($test_failure + 1))
	local pfx=""
	say_color error "not ok $test_count - ${pfx:+$pfx }$1"
	shift
	printf '%s\n' "$*" | sed -e 's/^/#	/'
	if test -n "$immediate"
	then
		say_color error "1..$test_count"
		_error_exit
	fi
	finalize_test_case_output failure "$failure_label" "$@"
}

test_known_broken_ok_ () {
	test_fixed=$(($test_fixed+1))
	say_color error "ok $test_count - $1 # TODO known breakage vanished"
	finalize_test_case_output fixed "$1"
}

test_known_broken_failure_ () {
	test_broken=$(($test_broken+1))
	say_color warn "not ok $test_count - $1 # TODO known breakage"
	finalize_test_case_output broken "$1"
}

test_debug () {
	test "$debug" = "" || eval "$1"
}

match_pattern_list () {
	arg="$1"
	shift
	test -z "$*" && return 1
	# We need to use "$*" to get field-splitting, but we want to
	# disable globbing, since we are matching against an arbitrary
	# $arg, not what's in the filesystem. Using "set -f" accomplishes
	# that, but we must do it in a subshell to avoid impacting the
	# rest of the script. The exit value of the subshell becomes
	# the function's return value.
	(
		set -f
		for pattern_ in $*
		do
			case "$arg" in
			$pattern_)
				exit 0
				;;
			esac
		done
		exit 1
	)
}

match_test_selector_list () {
	operation="$1"
	shift
	title="$1"
	shift
	arg="$1"
	shift
	test -z "$1" && return 0

	# Commas are accepted as separators.
	OLDIFS=$IFS
	IFS=','
	set -- $1
	IFS=$OLDIFS

	# If the first selector is negative we include by default.
	include=
	case "$1" in
		!*) include=t ;;
	esac

	for selector
	do
		orig_selector=$selector

		positive=t
		case "$selector" in
			!*)
				positive=
				selector=${selector##?}
				;;
		esac

		test -z "$selector" && continue

		case "$selector" in
			*-*)
				if expr "z${selector%%-*}" : "z[0-9]*[^0-9]" >/dev/null
				then
					echo "error: $operation: invalid non-numeric in range" \
						"start: '$orig_selector'" >&2
					exit 1
				fi
				if expr "z${selector#*-}" : "z[0-9]*[^0-9]" >/dev/null
				then
					echo "error: $operation: invalid non-numeric in range" \
						"end: '$orig_selector'" >&2
					exit 1
				fi
				;;
			*)
				if expr "z$selector" : "z[0-9]*[^0-9]" >/dev/null
				then
					case "$title" in *${selector}*)
						include=$positive
						;;
					esac
					continue
				fi
		esac

		# Short cut for "obvious" cases
		test -z "$include" && test -z "$positive" && continue
		test -n "$include" && test -n "$positive" && continue

		case "$selector" in
			-*)
				if test $arg -le ${selector#-}
				then
					include=$positive
				fi
				;;
			*-)
				if test $arg -ge ${selector%-}
				then
					include=$positive
				fi
				;;
			*-*)
				if test ${selector%%-*} -le $arg \
					&& test $arg -le ${selector#*-}
				then
					include=$positive
				fi
				;;
			*)
				if test $arg -eq $selector
				then
					include=$positive
				fi
				;;
		esac
	done

	test -n "$include"
}

maybe_teardown_verbose () {
	test -z "$verbose_only" && return
	exec 4>/dev/null 3>/dev/null
	verbose=
}

last_verbose=t
maybe_setup_verbose () {
	test -z "$verbose_only" && return
	if match_pattern_list $test_count "$verbose_only"
	then
		exec 4>&2 3>&1
		# Emit a delimiting blank line when going from
		# non-verbose to verbose.  Within verbose mode the
		# delimiter is printed by test_expect_*.  The choice
		# of the initial $last_verbose is such that before
		# test 1, we do not print it.
		test -z "$last_verbose" && echo >&3 ""
		verbose=t
	else
		exec 4>/dev/null 3>/dev/null
		verbose=
	fi
	last_verbose=$verbose
}

trace_level_=0
want_trace () {
	test "$trace" = t && {
		test "$verbose" = t || test "$verbose_log" = t
	}
}

# This is a separate function because some tests use
# "return" to end a test_expect_success block early
# (and we want to make sure we run any cleanup like
# "set +x").
test_eval_inner_ () {
	# Do not add anything extra (including LF) after '$*'
	eval "
		want_trace && trace_level_=$(($trace_level_+1)) && set -x
		$*"
}

test_eval_ () {
	# If "-x" tracing is in effect, then we want to avoid polluting stderr
	# with non-test commands. But once in "set -x" mode, we cannot prevent
	# the shell from printing the "set +x" to turn it off (nor the saving
	# of $? before that). But we can make sure that the output goes to
	# /dev/null.
	#
	# There are a few subtleties here:
	#
	#   - we have to redirect descriptor 4 in addition to 2, to cover
	#     BASH_XTRACEFD
	#
	#   - the actual eval has to come before the redirection block (since
	#     it needs to see descriptor 4 to set up its stderr)
	#
	#   - likewise, any error message we print must be outside the block to
	#     access descriptor 4
	#
	#   - checking $? has to come immediately after the eval, but it must
	#     be _inside_ the block to avoid polluting the "set -x" output
	#

	test_eval_inner_ "$@" </dev/null >&3 2>&4
	{
		test_eval_ret_=$?
		if want_trace
		then
			test 1 = $trace_level_ && set +x
			trace_level_=$(($trace_level_-1))
		fi
	} 2>/dev/null 4>&2

	if test "$test_eval_ret_" != 0 && want_trace
	then
		say_color error >&4 "error: last command exited with \$?=$test_eval_ret_"
	fi
	return $test_eval_ret_
}

test_run_ () {
	test_cleanup=:
	expecting_failure=$2

	test_eval_ "$1"
	eval_ret=$?

	if test -z "$immediate" || test $eval_ret = 0 ||
	   test -n "$expecting_failure" && test "$test_cleanup" != ":"
	then
		test_eval_ "$test_cleanup"
	fi
	if test "$verbose" = "t" && test -n "$HARNESS_ACTIVE"
	then
		echo ""
	fi
	return "$eval_ret"
}

test_start_ () {
	test_count=$(($test_count+1))
	maybe_setup_verbose
	start_test_case_output "$@"
}

test_finish_ () {
	echo >&3 ""
	maybe_teardown_verbose
	if test -n "$GIT_TEST_TEE_OFFSET"
	then
		GIT_TEST_TEE_OFFSET=$(fake_tool path-utils file-size \
			"$GIT_TEST_TEE_OUTPUT_FILE")
	fi
}

test_skip () {
	to_skip=
	skipped_reason=
	if match_pattern_list $this_test.$test_count $STG_SKIP_TESTS
	then
		to_skip=t
		skipped_reason="STG_SKIP_TESTS"
	fi
	if test -z "$to_skip" && test -n "$run_list" &&
	   ! match_test_selector_list '--run' "$1" $test_count "$run_list"
	then
		to_skip=t
		skipped_reason="--run"
	fi
	if test -z "$to_skip" && test -n "$test_prereq" &&
	   ! test_have_prereq "$test_prereq"
	then
		to_skip=t

		of_prereq=
		if test "$missing_prereq" != "$test_prereq"
		then
			of_prereq=" of $test_prereq"
		fi
		skipped_reason="missing $missing_prereq${of_prereq}"

		# Keep a list of all the missing prereq for result aggregation
		if test -z "$missing_prereq"
		then
			test_missing_prereq=$missing_prereq
		else
			test_missing_prereq="$test_missing_prereq,$missing_prereq"
		fi
	fi

	case "$to_skip" in
	t)

		say_color skip "ok $test_count # skip $1 ($skipped_reason)"
		: true
		finalize_test_case_output skip "$@"
		;;
	*)
		false
		;;
	esac
}

# stub; perf-lib overrides it
test_at_end_hook_ () {
	:
}

test_atexit_cleanup=:
test_atexit_handler () {
	# In a succeeding test script 'test_atexit_handler' is invoked
	# twice: first from 'test_done', then from 'die' in the trap on
	# EXIT.
	# This condition and resetting 'test_atexit_cleanup' below makes
	# sure that the registered cleanup commands are run only once.
	test : != "$test_atexit_cleanup" || return 0

	test_eval_ "$test_atexit_cleanup"
	test_atexit_cleanup=:
}

test_done () {

	# Run the atexit commands _before_ the trash directory is
	# removed, so the commands can access pidfiles and socket files.
	test_atexit_handler

	finalize_test_output

	if test -z "$HARNESS_ACTIVE"
	then
		mkdir -p "$TEST_RESULTS_DIR"

		cat >"$TEST_RESULTS_BASE.counts" <<-EOF
		total $test_count
		success $test_success
		fixed $test_fixed
		broken $test_broken
		failed $test_failure
		missing_prereq $test_missing_prereq

		EOF
	fi

	if test "$test_fixed" != 0
	then
		say_color error "# $test_fixed known breakage(s) vanished; please update test(s)"
	fi
	if test "$test_broken" != 0
	then
		say_color warn "# still have $test_broken known breakage(s)"
	fi
	if test "$test_broken" != 0 || test "$test_fixed" != 0
	then
		test_remaining=$(( $test_count - $test_broken - $test_fixed ))
		msg="remaining $test_remaining test(s)"
	else
		test_remaining=$test_count
		msg="$test_count test(s)"
	fi
	case "$test_failure" in
	0)
		if test $test_remaining -gt 0
		then
			say_color pass "# passed all $msg"
		fi

		# Maybe print SKIP message
		test -z "$skip_all" || skip_all="# SKIP $skip_all"
		case "$test_count" in
		0)
			say "1..$test_count${skip_all:+ $skip_all}"
			;;
		*)
			test -z "$skip_all" ||
			say_color warn "$skip_all"
			say "1..$test_count"
			;;
		esac

		if test -z "$debug" && test -n "$remove_trash"
		then
			test -d "$TRASH_DIRECTORY" ||
			error "Tests passed but trash directory already removed before test cleanup; aborting"

			cd "$TRASH_DIRECTORY/.." &&
			rm -fr "$TRASH_DIRECTORY" || {
				# try again in a bit
				sleep 5;
				rm -fr "$TRASH_DIRECTORY"
			} ||
			error "Tests passed but test cleanup failed; aborting"
		fi
		test_at_end_hook_

		GIT_EXIT_OK=t
		exit 0 ;;

	*)
		say_color error "# failed $test_failure among $msg"
		say "1..$test_count"

		GIT_EXIT_OK=t
		exit 1 ;;

	esac
}

if test -n "$STG_TEST_INSTALLED"
then
	PATH=$STG_TEST_INSTALLED:$PATH
else
	PATH="$TEST_DIRECTORY/test-bin:$PATH"
fi
GIT_EXEC_PATH=$(git --exec-path) || error "Cannot run git"
unset GIT_TEMPLATE_DIR
GIT_CONFIG_NOSYSTEM=1
GIT_ATTR_NOSYSTEM=1
GIT_CEILING_DIRECTORIES="$TRASH_DIRECTORY/.."
export PATH GIT_EXEC_PATH GIT_CONFIG_NOSYSTEM GIT_ATTR_NOSYSTEM GIT_CEILING_DIRECTORIES

if test -z "$GIT_TEST_CMP"
then
	DIFF="${DIFF:-diff}"
	if test -n "$GIT_TEST_CMP_USE_COPIED_CONTEXT"
	then
		GIT_TEST_CMP="$DIFF -c"
	else
		GIT_TEST_CMP="$DIFF -u"
	fi
fi

# Are we running this test at all?
remove_trash=
this_test=${0##*/}
this_test=${this_test%%-*}
if match_pattern_list "$this_test" "$STG_SKIP_TESTS"
then
	say_color info >&3 "skipping test $this_test altogether"
	skip_all="skip all tests in $this_test"
	test_done
fi


# Last-minute variable setup
USER_HOME="$HOME"
HOME="$TRASH_DIRECTORY"
GNUPGHOME="$HOME/gnupg-home-not-used"
export HOME GNUPGHOME USER_HOME

# "rm -rf" existing trash directory, even if a previous run left it
# with bad permissions.
remove_trash_directory () {
	dir="$1"
	if ! rm -rf "$dir" 2>/dev/null
	then
		chmod -R u+rwx "$dir"
		rm -rf "$dir"
	fi
	! test -d "$dir"
}

# Test repository
remove_trash_directory "$TRASH_DIRECTORY" || {
	BAIL_OUT 'cannot prepare test area'
}

remove_trash=t
if test -z "$TEST_NO_CREATE_REPO"
then
	git init \
	    "$TRASH_DIRECTORY" >&3 2>&4 ||
	error "cannot run git init"
	# StGit tests don't like starting with an unborn branch, so birth it.
	git -C "$TRASH_DIRECTORY" commit --allow-empty --message="empty start" >&3 2>&4 ||
	error "cannot run git commit"
else
	mkdir -p "$TRASH_DIRECTORY"
fi

# Use -P to resolve symlinks in our working directory so that the cwd
# in subprocesses like git equals our $PWD (for pathname comparisons).
cd -P "$TRASH_DIRECTORY" || BAIL_OUT "cannot cd -P to \"$TRASH_DIRECTORY\""

start_test_output "$0"

# Convenience
# A regexp to match 5 and 35 hexdigits
_x05='[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]'
_x35="$_x05$_x05$_x05$_x05$_x05$_x05$_x05"

test_oid_init

ZERO_OID=$(test_oid zero)
OID_REGEX=$(echo $ZERO_OID | sed -e 's/0/[0-9a-f]/g')
OIDPATH_REGEX=$(test_oid_to_path $ZERO_OID | sed -e 's/0/[0-9a-f]/g')
EMPTY_TREE=$(test_oid empty_tree)
EMPTY_BLOB=$(test_oid empty_blob)

# Provide an implementation of the 'yes' utility; the upper bound
# limit is there to help Windows that cannot stop this loop from
# wasting cycles when the downstream stops reading, so do not be
# tempted to turn it into an infinite loop. cf. 6129c930 ("test-lib:
# limit the output of the yes utility", 2016-02-02)
yes () {
	if test $# = 0
	then
		y=y
	else
		y="$*"
	fi

	i=0
	while test $i -lt 99
	do
		echo "$y"
		i=$(($i+1))
	done
}

# The GIT_TEST_FAIL_PREREQS code hooks into test_set_prereq(), and
# thus needs to be set up really early, and set an internal variable
# for convenience so the hot test_set_prereq() codepath doesn't need
# to call "git env--helper" (via test_bool_env). Only do that work
# if needed by seeing if GIT_TEST_FAIL_PREREQS is set at all.
GIT_TEST_FAIL_PREREQS_INTERNAL=
if test -n "$GIT_TEST_FAIL_PREREQS"
then
	if test_bool_env GIT_TEST_FAIL_PREREQS false
	then
		GIT_TEST_FAIL_PREREQS_INTERNAL=true
		test_set_prereq FAIL_PREREQS
	fi
else
	test_lazy_prereq FAIL_PREREQS '
		test_bool_env GIT_TEST_FAIL_PREREQS false
	'
fi

# Fix some commands on Windows, and other OS-specific things
uname_s=$(uname -s)
case $uname_s in
*MINGW*)
	# Windows has its own (incompatible) sort and find
	sort () {
		/usr/bin/sort "$@"
	}
	find () {
		/usr/bin/find "$@"
	}
	# git sees Windows-style pwd
	pwd () {
		builtin pwd -W
	}
	# no POSIX permissions
	# backslashes in pathspec are converted to '/'
	# exec does not inherit the PID
	test_set_prereq MINGW
	test_set_prereq NATIVE_CRLF
	test_set_prereq SED_STRIPS_CR
	test_set_prereq GREP_STRIPS_CR
	test_set_prereq WINDOWS
	GIT_TEST_CMP=mingw_test_cmp
	;;
*CYGWIN*)
	test_set_prereq POSIXPERM
	test_set_prereq EXECKEEPSPID
	test_set_prereq CYGWIN
	test_set_prereq SED_STRIPS_CR
	test_set_prereq GREP_STRIPS_CR
	test_set_prereq WINDOWS
	;;
*)
	test_set_prereq POSIXPERM
	test_set_prereq BSLASHPSPEC
	test_set_prereq EXECKEEPSPID
	;;
esac

test -z "$NO_PERL" && test_set_prereq PERL

test_lazy_prereq QUILT '
	# test whether quilt is installed
	quilt --version 2>/dev/null >/dev/null
'

test_lazy_prereq GITSENDEMAIL '
	# test whether git send-email is available
	git send-email --help 2>/dev/null >/dev/null
'
