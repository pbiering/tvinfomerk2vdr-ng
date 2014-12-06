#!/bin/bash
#
# Wrapper script for tvinfomerk2vdr-ng.pl to handle multiple TVinfo user accounts
#
# (P) & (C) 2013-2014 by Peter Bieringer <pb@bieringer.de>
#
# License: GPLv2
#
# Authors:
#  Peter Bieringer (pb)
#
# 20130116/pb: initial release
# 20130128/pb: add -c/-C option passthrough
# 20130203/pb: add -L/-S option passthrough, use -L/-S by default if called by cron
# 20130228/pb: add -X option passthrough
# 20130509/pb: improve online help
# 20140704/pb: extend debug output
# 20140804/pb: add protection to avoid running this script as root
# 20140804/pb: add support for -P (password hash)
# 20141206/pb: add support for OpenELEC and new properties file

if [ -f "/etc/openelec-release" ]; then
	config_base="/storage/.config/tvinfomerk2vdr-ng"
	program_base="/storage/tvinfomerk2vdr-ng"
	system="openelec"
	perl="/storage/ActivePerl-5.18/bin/perl"
else
	config_base="/etc/opt/tvinfomerk2vdr-ng"
	program_base="/opt/tvinfomerk2vdr-ng"
	system="other"
	perl=""
	# others, e.g. ReelBox
	if [ $UID -eq 0 ]; then
		echo "ERROR : this script is not allowed to run as root"
		exit 1
	fi
fi

config="$config_base/tvinfomerk2vdr-ng-users.conf"
properties="$config_base/tvinfomerk2vdr-ng.properties"

progname="`basename "$0"`"

script="$program_base/tvinfomerk2vdr-ng.pl"
script_test="$program_base/tvinfomerk2vdr-ng-test.pl"

if [ -e "./tvinfomerk2vdr-ng.pl" ]; then
	script="./tvinfomerk2vdr-ng.pl"
fi
if [ -e "./tvinfomerk2vdr-ng-test.pl" ]; then
	script_test="./tvinfomerk2vdr-ng-test.pl"
fi

files_executables="$script"
files_test="$config $files_executables"

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

	-u USER	select user from config list
	-l	list configured users
	-P	generate password hash

Debug options:
	-t	use test script $script_test
	-p	file prefix for data files (-R/-W)
	-s	simulate run-by-cron

Debug options for called script:
	-R	read SERVICE/DVR data from file
	-W	write SERVICE/DVR data to file
	-N	do not execute any changes on DVR timers
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
while getopts "sp:u:lXcRPTDWNthSLC:?" opt; do
	case $opt in
	    s)
		run_by_cron=1
		;;
	    P)
		opt_password_hash=1
		;;
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
	if [ ! -e "${val}" ]; then
		logging "ERROR" "missing given file: ${val}"
		exit 1
	fi
	if [ ! -r "${val}" ]; then
		logging "ERROR" "can't read given file: ${val}"
		exit 1
	fi
done

for val in $files_executables; do
	if [ ! -x "${val}" ]; then
		logging "ERROR" "can't execute given file: ${val}"
		exit 1
	fi
done

if [ "$opt_password_hash" = "1" ]; then
	echo "Read password from stdin and generate hash for TVinfo account"
	read -s -t 30 -p "TVinfo password: " tvinfo_password
	ret=$?
	if [ $ret -gt 128 ]; then
		echo "No input given - stop"
		exit 1
	fi
	if [ $ret -ne 0 ]; then
		echo "Problem occurs - stop"
		exit 1
	fi
	if [ -z "$tvinfo_password" ]; then
		echo "Password length ZERO - stop"
		exit 1
	fi

	echo -n "{MD5}"
	echo -n "$tvinfo_password" | md5sum | awk '{ print $1 }'
	echo "Use this hashed password now in $config or config-ng.pl"

	exit 0
fi

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

	script_options=""
	if [ -n "$folder" ]; then
		script_options="$script_options -F $folder"
	fi
	if [ -n "$folder" ]; then
		script_options="$script_options -P $password"
	fi
	if [ -n "$properties" ]; then
		script_options="$script_options --rp $properties"
	fi

	if [ $run_by_cron -eq 0 -o -z "$email" ]; then
		[ "$opt_debug" = "1" ] && logging "DEBUG" "Execute: $script $script_flags -U \"$username\" $script_options"
		if [ $run_by_cron -eq 1 ]; then
			script_options="$script_options -L"
		fi
		$perl $script $script_flags -U "$username" $script_options 
	else
		output="`$perl $script $script_flags -S -L -U "$username" $script_options" 2>&1`"
		if [ -n "$output" ]; then
			echo "$output" | mail -s "tvinfomerk2vdr-ng `date '+%Y%m%d-%H%M'` $username" $email
		fi
	fi

	if [ -z "$user" ]; then
		if [ $run_by_cron -eq 1 ]; then
			sleep 30
		else
			sleep 5
		fi
	fi
done
