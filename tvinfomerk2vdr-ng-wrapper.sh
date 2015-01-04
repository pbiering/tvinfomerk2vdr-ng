#!/bin/bash
#
# Wrapper script for tvinfomerk2vdr-ng.pl to handle multiple TVinfo user accounts
#
# (P) & (C) 2013-2015 by Peter Bieringer <pb@bieringer.de>
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
# 20141227/pb: improve debug options (add -d), allow also script to be executed by root
# 20141227/pb: add support for status file (tested on ReelBox), prohibit run in case of last run was less then minimum delta
# 20150103/pb: recode output to ISO8859-1 before sending to mail, also add result token to subject and change priority to high in case of a problem

if [ -f "/etc/openelec-release" ]; then
	config_base="/storage/.config/tvinfomerk2vdr-ng"
	program_base="/storage/tvinfomerk2vdr-ng"
	system="openelec"
	perl="/storage/ActivePerl-5.18/bin/perl"
else
	config_base="/etc/opt/tvinfomerk2vdr-ng"
	program_base="/opt/tvinfomerk2vdr-ng"
	var_base="/var/opt/tvinfomerk2vdr-ng"
	system="other"
	perl=""
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
dirs_test="$var_base"

status_delta_minimum=900	# 15 min

if [ -n "$var_base" ]; then
	file_status="$var_base/tvinfomerk2vdr-ng-wrapper.status"
fi

run_by_cron=0
if [ ! -t 0 ]; then
	run_by_cron=1
fi

logging() {
	local level="$1"
	shift
	local message="$*"

	if [ "$run_by_cron" = "1" -a "$opt_debug" != "1" ]; then
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
	-d	debug this wrapper script
	-n	no minimum delta seconds check

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
while getopts "sp:u:dnlXcRPTDWNthSLC:?" opt; do
	case $opt in
	    s)
		run_by_cron=1
		;;
	    n)
		no_delta_check=1
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
		logging "INFO" "debug option selected: no DVR timer change"
		script_flags="$script_flags -N"
		;;
	    d)
		logging "INFO" "debug option selected: wrapper script debug"
		opt_debug=1
		;;
	    D)
		logging "INFO" "debug option selected: script debug"
		script_flags="$script_flags -D"
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
		logging "INFO" "list users (use e.g. later with -u <user>)"
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

for val in $dirs_test; do
	if [ ! -d "${val}" ]; then
		logging "ERROR" "missing given directory: ${val}"
		exit 1
	fi
	if [ ! -w "${val}" ]; then
		logging "ERROR" "can't write to given directory: ${val}"
		exit 1
	fi
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

if [ "$opt_user_list" != "1" ]; then
	## check status file
	unixtime_current=$(date '+%s')
	if [ -n "$file_status" -a -f "$file_status" ]; then
		logging "DEBUG" "status file found: $file_status"
		unixtime_status=$(stat -c "%Z" "$file_status")

		if [ -n "$unixtime_status" ]; then
			status_delta=$[ $unixtime_current - $unixtime_status ]
			logging "DEBUG" "delta seconds to last status update: $status_delta"
			if [ $status_delta -lt $status_delta_minimum ]; then
				if [ "$no_delta_check" = "1" ]; then
					logging "INFO" "delta seconds to last status update is less than given minimum, but continue (option -n given): $status_delta / $status_delta_minimum"
				else
					logging "INFO" "delta seconds to last status update is less than given minimum, stop: $status_delta / $status_delta_minimum"
					exit 0
				fi
			fi
		fi
	fi

	if [ -n "$file_status" ]; then
		# update status file this also blocks rerun
		logging "DEBUG" "update status file: $file_status"
		touch $file_status
	fi
fi

if [ $run_by_cron -eq 1 -a "$opt_debug" != "1" ]; then
	# called by cron
	random_delay=$[ $RANDOM / 100 ] # 0-5 min
	logging "DEBUG" "sleep random delay: $random_delay seconds"
	sleep $random_delay
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
		if [ $run_by_cron -eq 1 ]; then
			script_options="$script_options -L"
		fi
		[ "$opt_debug" = "1" ] && logging "DEBUG" "Execute: $script $script_flags -U \"$username\" $script_options"
		$perl $script $script_flags -U "$username" $script_options 
	else
		script_flags="$script_flags -S"
		script_options="$script_options -L"
		[ "$opt_debug" = "1" ] && logging "DEBUG" "Execute: $script $script_flags -U \"$username\" $script_options"
		output="`$perl $script $script_flags -U "$username" $script_options 2>&1`"
		result=$?
		result_token="OK"
		option_header_prio_opt=""
		option_header_prio_val=""
		if [ $result -ne 0 ]; then
			result_token="PROBLEM"
			option_header_prio_opt="-a"
			option_header_prio_val="X-Priority: 2"
		fi
		if [ -n "$output" -a "$opt_debug" != "1" ]; then
			echo "$output" | iconv -c -t ISO8859-1 | mail $option_header_prio_opt "$option_header_prio_val" -s "tvinfomerk2vdr-ng `date '+%Y%m%d-%H%M'` $username $result_token" $email
		else
			if [ -n "$output" ]; then
				logging "DEBUG" "in non-debug mode output would be sent via mail to: $email"
				echo "==="
				echo "$output"
				echo "==="
			else
				logging "DEBUG" "no important output, no e-mail would be sent via mail to: $email"
			fi
		fi
	fi

	if [ -z "$user" ]; then
		sleeptime=5
		if [ $run_by_cron -eq 1 -a "$opt_debug" != "1" ]; then
			sleeptime=30
		fi
		[ "$opt_debug" = "1" ] && logging "DEBUG" "Sleep some seconds: $sleeptime"
		sleep $sleeptime
	fi
done
