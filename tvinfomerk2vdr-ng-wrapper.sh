#!/bin/bash
#
# Wrapper script for tvinfomerk2vdr-ng.pl to handle multiple TVinfo user accounts
#
# (P) & (C) 2013-2014 by Peter Bieringer <pb@bieringer.de>
#
# License: GPLv2
#
# 20130116/pb: initial release
# 20130128/pb: add -c/-C option passthrough
# 20130203/pb: add -L/-S option passthrough, use -L/-S by default if called by cron
# 20130228/pb: add -X option passthrough
# 20130509/pb: improve online help
# 20140704/pb: extend debug output

config="/etc/opt/tvinfomerk2vdr-ng/users.conf"

progname="`basename "$0"`"

script="$HOME/tvinfomerk2vdr/tvinfomerk2vdr-ng.pl"
script_test="$HOME/tvinfomerk2vdr/tvinfomerk2vdr-ng-test.pl"

if [ -e "./tvinfomerk2vdr-ng.pl" ]; then
	script="./tvinfomerk2vdr-ng.pl"
fi
if [ -e "./tvinfomerk2vdr-ng-test.pl" ]; then
	script_test="./tvinfomerk2vdr-ng-test.pl"
fi

eiles_executables="script"
files_test="config $files_executables"

run_by_cron=0
if [ ! -t 0 ]; then
	run_by_cron=1
fi

logging() {
	local level="$1"
	shift
	local message="$*"

	if [ "$run_by_cron" = "1" ]; then
		logger -t "$progname" "$message"
	else
		printf "%-6s: %s\n" "$level" "$message"
	fi
}

help() {
	cat <<END
Usage:
	(Normal operations need no option)
		read config: $config
		call script: $script

Debug options:
	-t	use test script $script_test
	-p	file prefix for data files (-R/-W)
	-u USER	select user from config list
	-l	list configured users

Debug options for called script:
	-R	read XML data from file
	-W	write XML data to file
	-N	do not execute any changes on VDR timers
	-D	enable debugging
	-T	enable tracing

Functional options for called script:
	-C ARGS	(see online help)
	-c 	(see online help)
	-L 	(see online help)
	-S 	(see online help)
	-X 	(see online help)

	online help: $script -h

Example for contents of $config:

# Configuration files for shell script wrapper
#TVinfo-User:TVinfo-Pass:Folder:Email
Account1:Password1:Folder1:test1@example.com
Account2:Password2:Folder2:test2@example.com

END
}

# option handling
while getopts "p:u:lXcRTDWNthSLC:?" opt; do
	case $opt in
	    R)
		logging "INFO" "debug option selected: read-from-file"
		opt_read_from_file=1
		;;
	    W)
		logging "INFO" "debug option selected: write-to-file"
		opt_write_to_file=1
		;;
	    N)
		logging "INFO" "debug option selected: no VDR timer change"
		script_flags="$script_flags -N"
		;;
	    D)
		logging "INFO" "debug option selected: script debug"
		script_flags="$script_flags -D"
		opt_debug=1
		;;
	    T)
		logging "INFO" "debug option selected: script tracing"
		script_flags="$script_flags -T"
		;;
	    p)
		opt_file_prefix="$OPTARG"
		logging "INFO" "file prefix: $opt_file_prefix"
		;;
	    t)
		logging "INFO" "debug option selected: use test script"
		script="$script_test"
		;;
	    u)
		user="$OPTARG"
		logging "INFO" "selected user: $user"
		;;
	    l)
		logging "INFO" "list users"
		opt_user_list="1"
		;;
	    C)
		logging "INFO" "add calling script option: -$opt $OPTARG"
		script_flags="-$opt $OPTARG $script_flags"
		;;
	    c|L|S|X)
		logging "INFO" "add calling script option: -$opt"
		script_flags="-$opt $script_flags"
		;;
	    'h'|'?')
		help
		exit 1
		;;
	    *)
		logging "ERROR" "invalid option: $OPTARG" 
		;;
	esac
done


for val in $files_test; do
	if [ -z "${!val}" ]; then
		logging "ERROR" "value empty: $val"
		exit 1
	fi
	if [ ! -e "${!val}" ]; then
		logging "ERROR" "missing given file: ${!val} ($val)"
		exit 1
	fi
	if [ ! -r "${!val}" ]; then
		logging "ERROR" "can't read given file: ${!val} ($val)"
		exit 1
	fi
done

for val in $files_executables; do
	if [ ! -x "${!val}" ]; then
		logging "ERROR" "can't execute given file: ${!val} ($val)"
		exit 1
	fi
done

cat "$config" | grep -v '^#' | while IFS=":" read username password folder email other; do
	if [ -n "$user" -a  "$user" != "$username" ]; then
		logging "INFO" "skip user: $username"
		continue
	fi

	if [ "$opt_user_list" = "1" ]; then
		logging "INFO" "List entry: $username:$password"
		continue
	fi

	file="$opt_file_prefix$username"

	if [ "$opt_read_from_file" = "1" ]; then
		script_flags="$script_flags -R $file"
	fi
	if [ "$opt_write_to_file" = "1" ]; then
		script_flags="$script_flags -W $file"
	fi

	if [ -z "$script_flags" ]; then
		logging "INFO" "run tvinfomerk2vdr-ng with username: $username (folder:$folder)"
	else
		logging "INFO" "run tvinfomerk2vdr-ng with username: $username (folder:$folder) and options: $script_flags"
	fi

	if [ $run_by_cron -eq 0 -o -z "$email" ]; then
		[ "$opt_debug" = "1" ] && set -x
		$script $script_flags -U "$username" -P "$password" -F "$folder" 
		[ "$opt_debug" = "1" ] && set +x
	else
		output="`$script $script_flags -S -L -U "$username" -P "$password" -F "$folder" 2>&1`"
		if [ -n "$output" ]; then
			echo "$output" | mail -s "tvinfomerk2vdr-ng `date '+%Y%m%d-%H%M'` $username" $email
		fi
	fi
done
