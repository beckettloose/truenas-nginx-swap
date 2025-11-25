#!/bin/sh
# Swap nginx.conf on a running TrueNAS SCALE system for a limited, temporary one
# In order to obtain a certificate using ACME HTTP validation
# https://github.com/beckettloose/truenas-nginx-swap
# "Forked" from https://github.com/danb35/freenas-nginx-swap

# Check for root privileges
if ! [ "$(id -u)" = 0 ]; then
   echo "This script must be run with root privileges"
   exit 1
fi

#####
#
# General configuration
#
#####

# Initialize defaults
ACME_SH_PATH="/root/.acme.sh/acme.sh"
ACME_SH_ARGS=""
TRUENAS_FQDN=$(hostname -f)
CONFIG_NAME="nginx-swap-config"

# Check for debug flag
while getopts ":d" o; do
	case "${o}" in
		d)
			ACME_SH_ARGS="--debug"
			;;
		*)
			echo "Usage: $0 [-d]"
			exit 1
	esac
done

# Check for nginx-swap-config and set configuration
SCRIPT=$(readlink -f "$0")
SCRIPTPATH=$(dirname "${SCRIPT}")
if ! [ -e "${SCRIPTPATH}"/"${CONFIG_NAME}" ]; then
  echo "${SCRIPTPATH}/${CONFIG_NAME} must exist."
  exit 1
fi
. "${SCRIPTPATH}"/"${CONFIG_NAME}"

#####
#
# Input/Config Sanity checks
#
#####

# Check that necessary variables were set by nextcloud-config
if [ -z "${CA_URL}" ]; then
  echo 'Configuration error: CA_URL must be set'
  exit 1
fi

if [ -z "${CA_CERT_PATH}" ]; then
  echo 'Configuration error: CA_CERT_PATH must be set'
  exit 1
fi

# Check the existing nginx.conf, make sure it's the FreeNAS file
if ! grep 'TrueNAS' /etc/nginx/nginx.conf
then
	echo "nginx.conf appears to have been modified, aborting."
	exit 1
fi

# Back up nginx.conf
cp -f /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak

# Create new nginx.conf
cat <<__EOF__ >/etc/nginx/nginx.conf

#
# Temporary nginx configuration file
# This file should only be used while obtaining a cert from
# an ACME certificate authority
#

user www-data www-data;
worker_processes  1;

events {
    worker_connections  1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

  server {
    listen 80;
    server_name localhost;
    root /tmp;
    error_page 500 502 504 /50X.html;

    location ^~ / {
      deny all;
    }

    location ^~ /.well-known/acme-challenge/ {
      allow all;
    }

  }
}
__EOF__

# Use new configuration
systemctl restart nginx.service

# Issue the cert
if [ -n "${CERT_INSTALL_SCRIPT}" ]; then
  "${ACME_SH_PATH}" --issue --force -w /tmp \
    -d "${TRUENAS_FQDN}" \
    --server "${CA_URL}" \
    --ca-bundle "${CA_CERT_PATH}" \
    --reloadcmd "cp -f /etc/nginx/nginx.conf.bak /etc/nginx/nginx.conf; systemctl restart nginx.service; ${CERT_INSTALL_SCRIPT}"
else
  "${ACME_SH_PATH}" --issue --force -w /tmp \
    -d "${TRUENAS_FQDN}" \
    --server "${CA_URL}" \
    --ca-bundle "${CA_CERT_PATH}"
fi

# Wait 5 seconds to hopefully avoid weird issues with systemctl
sleep 5

# Restore nginx.conf and reload
cp -f /etc/nginx/nginx.conf.bak /etc/nginx/nginx.conf
systemctl restart nginx.service
