#!/bin/bash

export LC_ALL=C

days_to_keep=30
backup_owner="backup"
parent_dir="/backups/mysql"
defaults_file="/etc/mysql/backup.cnf"
working_dir="${parent_dir}/working"
log_file="${working_dir}/backup-progress.log"
encryption_key_file="${parent_dir}/encryption_key"
storage_configuration_file="${parent_dir}/object_storage_config.sh"
now="$(date)"
now_string="$(date -d"${now}" +%m-%d-%Y_%H-%M-%S)"
processors="$(nproc --all)"

# Use this to echo to standard error
error () {
    printf "%s: %s\n" "$(basename "${BASH_SOURCE}")" "${1}" >&2
    exit 1
}

trap 'error "An unexpected error occurred."' ERR

sanity_check () {
    # Check user running the script
    if [ "$USER" != "$backup_owner" ]; then
        error "Script can only be run as the \"$backup_owner\" user"
    fi

    # Check whether the encryption key file is available
    if [ ! -r "${encryption_key_file}" ]; then
        error "Cannot read encryption key at ${encryption_key_file}"
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

set_backup_type () {
    backup_type="full"


    # Grab date of the last backup if available
    if [ -r "${working_dir}/xtrabackup_info" ]; then
        last_backup_date="$(date -d"$(grep start_time "${working_dir}/xtrabackup_info" | cut -d' ' -f3)" +%s)"
    else
            last_backup_date=0
    fi

    # Grab today's date, in the same format
    todays_date="$(date -d"$(echo "${now}" | cut -d' ' -f 1-3)" +%s)"

    # Compare the two dates
    (( $last_backup_date == $todays_date ))
    same_day="${?}"

    # The first backup each new day will be a full backup
    # If today's date is the same as the last backup, take an incremental backup instead
    if [ "$same_day" -eq "0" ]; then
        backup_type="incremental"
    fi
}

set_options () {
    # List the xtrabackup arguments
    xtrabackup_args=(
        "--defaults-file=${defaults_file}"
        "--backup"
        "--extra-lsndir=${working_dir}"
        "--compress"
        "--stream=xbstream"
        "--encrypt=AES256"
        "--encrypt-key-file=${encryption_key_file}"
        "--parallel=${processors}"
        "--compress-threads=${processors}"
        "--encrypt-threads=${processors}"
        "--slave-info"
    )

    set_backup_type

    # Add option to read LSN (log sequence number) if taking an incremental backup
    if [ "$backup_type" == "incremental" ]; then
        lsn=$(awk '/to_lsn/ {print $3;}' "${working_dir}/xtrabackup_checkpoints")
        xtrabackup_args+=( "--incremental-lsn=${lsn}" )
    fi
}

rotate_old () {
    # Remove previous backup artifacts
    find "${working_dir}" -name "*.xbstream" -type f -delete

    # Remove any backups from object storage older than 30 days
    /usr/local/bin/object_storage.py prune --days-to-keep "${days_to_keep}"
}

take_backup () {
    find "${working_dir}" -type f -name "*.incomplete" -delete
    xtrabackup "${xtrabackup_args[@]}" --target-dir="${working_dir}" > "${working_dir}/${backup_type}-${now_string}.xbstream.incomplete" 2> "${log_file}"

    mv "${working_dir}/${backup_type}-${now_string}.xbstream.incomplete" "${working_dir}/${backup_type}-${now_string}.xbstream"
}

upload_backup () {
    /usr/local/bin/object_storage.py upload "${working_dir}/${backup_type}-${now_string}.xbstream"
}

main () {
    mkdir -p "${working_dir}"
    sanity_check && set_options && rotate_old && take_backup && upload_backup

    # Check success and print message
    if tail -1 "${log_file}" | grep -q "completed OK"; then
        printf "Backup successful!\n"
        printf "Backup created at %s/%s-%s.xbstream\n" "${working_dir}" "${backup_type}" "${now_string}"
    else
        error "Backup failure! If available, check ${log_file} for more information"
    fi
}

main
