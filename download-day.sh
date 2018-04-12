#!/bin/bash

export LC_ALL=C

backup_owner="backup"
storage_configuration_file="/backups/mysql/object_storage_config.sh"
day_to_download="${1}"

# Use this to echo to standard error
error () {
    printf "%s: %s\n" "$(basename "${BASH_SOURCE}")" "${1}" >&2
    exit 1
}

trap 'error "An unexpected error occurred."' ERR

sanity_check () {
    # Check user running the script
    if [ "$(id -un)" != "$backup_owner" ]; then
        error "Script can only be run as the \"$backup_owner\" user"
    fi

    # Check whether the object storage configuration file is available
    if [ ! -r "${storage_configuration_file}" ]; then
        error "Cannot read object storage configuration from ${storage_configuration_file}"
    fi

    # Check whether the object storage configuration is set in the file
    source "${storage_configuration_file}"
    if [ -z "${MYACCESSKEY}" ] || [ -z "${MYSECRETKEY}" ] || [ -z "${MYBUCKETNAME}" ]; then
        error "Object storage configuration are not set properly in ${storage_configuration_file}"
    fi
}

main () {
    sanity_check
    /usr/local/bin/object_storage.py get_day "${day_to_download}"
}

main
