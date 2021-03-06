#!/bin/bash

#
# ssh.sh - SSH plugin for check_vpn
# Copyright (C) 2013 Dan Fruehauf <malkoadan@gmail.com>
# Copyright (C) 2012 Lacoon Security <lacoon.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#

###########
### SSH ###
###########
# You'll have to enable on the SSH server:
#PermitTunnel=yes

[ x"$SSH_DEVICE_PREFIX" = x ] && declare -r SSH_DEVICE_PREFIX=tun
declare -r SSH_VPN_NET=192.168.8.
declare -i -r SSH_PORT=22

# returns a free vpn device
_ssh_allocate_vpn_device() {
	local i
	for i in `seq 0 255`; do
		if ! echo $* | grep -q "\b${SSH_DEVICE_PREFIX}$i\b"; then
			! ifconfig ${SSH_DEVICE_PREFIX}$i >& /dev/null && \
				# TODO might cause race conditions if a few devices
				# are allocated at the same time, but i'd rather have this
				# than a mayhem of allocated and unused tun* devices
				#openvpn --mktun --dev ${SSH_DEVICE_PREFIX}$i >& /dev/null && \
				#ifconfig ${SSH_DEVICE_PREFIX}$i up >& /dev/null && \
				echo "${SSH_DEVICE_PREFIX}$i" && \
				return 0
		fi
	done
	return 1
}

# returns the vpn devices for the given lns
# $1 - lns
_ssh_vpn_device() {
	local lns=$1; shift
	local pids=`_ssh_get_pids $lns`
	local pid
	for pid in $pids; do
		if ps -p $pid --no-header -o cmd | grep -q "\b$lns\b"; then
			local -i device_nr=`ps -p $pid --no-header -o cmd | grep -o "\-w [[:digit:]]\+:" | cut -d' ' -f2 | cut -d: -f1`
			devices="$devices ${SSH_DEVICE_PREFIX}$device_nr"
		fi
	done
	echo "$devices"
}

# initiate a ssh connection
# $1 - lns - where to connect to
# $2 - username
# $3 - password
# $4 - device
_ssh_start_vpn() {
	local lns=$1; shift
	local username=$1; shift
	local password=$1; shift
	local device=$1; shift
	local -i device_nr=`echo $device | sed -e "s/^$SSH_DEVICE_PREFIX//"`
	local -i retval=0

	if ! which ssh >& /dev/nulll; then
		ERROR_STRING="Error: ssh not installed"
		return 1
	fi

	local -i port=`_ssh_guess_port "$@"`
	check_open_port $lns $port
	if [ $? -ne 0 ]; then
		ERROR_STRING="Port '$port' closed on '$lns'"
		return 1
	fi

	# TODO HARDCODED!!!
	local remote_ip="$SSH_VPN_NET"1
	local local_ip="$SSH_VPN_NET"2

	if ! ssh -o ServerAliveInterval=10 -o TCPKeepAlive=yes "$@" $username@$lns "true"; then
		ERROR_STRING="Could not SSH to '$username@$lns'"
		return 1
	fi

	# TODO this is susecptible to race conditions if a few people try to
	# allocate a device at the same time
	local remote_device=$(ssh "$@" $username@$lns "for i in \`seq 0 255\`; do ! ifconfig $SSH_DEVICE_PREFIX\$i >& /dev/null && echo $SSH_DEVICE_PREFIX\$i && break; done")
	if [ x"$remote_device" = x ]; then
		ERROR_STRING="Error: Could not allocate '$SSH_DEVICE_PREFIX' device on '$lns'"
		return 1
	fi
	local -i remote_device_nr=`echo $remote_device | sed -e "s/^$SSH_DEVICE_PREFIX//"`

	# pass correct tunnel parameters
	local tunnel_parameters="-o Tunnel=point-to-point"
	if [ "$SSH_DEVICE_PREFIX" = "tap" ]
		tunnel_parameters="-o Tunnel=ethernet"
	fi

	# activate tunnel
	ssh -o ServerAliveInterval=10 -o TCPKeepAlive=yes -f "$@" -w $device_nr:$remote_device_nr $tunnel_parameters $username@$lns "/sbin/ifconfig $remote_device $remote_ip netmask 255.255.255.252" && \
	ifconfig $device $local_ip netmask 255.255.255.252 && \
	
	if [ $? -ne 0 ]; then
		ERROR_STRING="Error: SSH connection failed to '$lns'"
		return 1
	fi
}

# stops the vpn
# $1 - lns
# $2 - vpn device (optional)
_ssh_stop_vpn() {
	local lns=$1; shift
	local device=$1; shift
	if [ x"$lns" = x ]; then
		echo "lns unspecified, can't kill ssh" 1>&2
		return 1
	fi
	local pids=`_ssh_get_pids $lns $device`
	if [ x"$pids" != x ]; then
		kill $pids
	fi
}

# returns a list of ssh pids
# $1 - lns
# $2 - vpn device (optional)
_ssh_get_pids() {
	local lns=$1; shift
	local device=$1; shift
	local ssh_pids=`pgrep ssh | xargs`
	local ssh_relevant_pids
	for pid in $ssh_pids; do
		if ps -p $pid --no-header -o cmd | grep -q "\b$lns\b"; then
			if [ x"$device" != x ]; then
				if ps -p $pid --no-header -o cmd | grep -q " -w $device_nr\b"; then
					ssh_relevant_pids="$ssh_relevant_pids $pid"
				fi
			else
				ssh_relevant_pids="$ssh_relevant_pids $pid"
			fi
		fi
	done
	echo $ssh_relevant_pids
}

# return true if VPN is up, false otherwise...
# $1 - lns
# $2 - vpn device (optional)
_ssh_is_vpn_up() {
	local lns=$1; shift
	local device=$1; shift
	ifconfig $device >& /dev/null && \
		ip addr show dev $device | grep -q "\binet\b"
}


# try to guess port from extra parameters
# "$@" - extra parameters
_ssh_guess_port() {
	local -i port=0

	# probe for '-p PORT'
	port=`echo "$@" | grep -o "[[:space:]]*\-p [[:digit:]]\+[[:space:]]*" | cut -d' ' -f2`
	[ $port -ne 0 ] && echo $port && return

	# probe for '-o Port=PORT'
	port=`echo "$@" | grep -o "[[:space:]]*\-o Port=[[:digit:]]\+[[:space:]]*" | cut -d'=' -f2`
	[ $port -ne 0 ] && echo $port && return

	# use default port
	port=$SSH_PORT
	echo $port
}
