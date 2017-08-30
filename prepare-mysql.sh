#!/bin/bash

export LC_ALL=C

shopt -s nullglob
incremental_dirs=( ./incremental-*/ )
full_dirs=( ./full-*/ )
shopt -u nullglob

backup_owner="backup"
log_file="prepare-progress.log"
full_backup_dir="${full_dirs[0]}"

# Use this to echo to standard error
error() {
    printf "%s: %s\n" "$(basename "${BASH_SOURCE}")" "${1}" >&2
    exit 1
}

trap 'error "An unexpected error occurred.  Try checking the \"${log_file}\" file for more information."' ERR

sanity_check () {
    # Check user running the script
    if [ "${USER}" != "${backup_owner}" ]; then
        error "Script can only be run as the \"${backup_owner}\" user."
    fi

    # Check whether a single full backup directory are available
    if (( ${#full_dirs[@]} != 1 )); then
        error "Exactly one full backup directory is required."
    fi
}

do_backup () {
    # Apply the logs to each of the backups
    printf "Initial prep of full backup %s\n" "${full_backup_dir}"
    xtrabackup --prepare --apply-log-only --target-dir="${full_backup_dir}"
    
    for increment in "${incremental_dirs[@]}"; do
        printf "Applying incremental backup %s to %s\n" "${increment}" "${full_backup_dir}"
        xtrabackup --prepare --apply-log-only --incremental-dir="${increment}" --target-dir="${full_backup_dir}"
    done
    
    printf "Applying final logs to full backup %s\n" "${full_backup_dir}"
    xtrabackup --prepare --target-dir="${full_backup_dir}"
}

sanity_check && do_backup > "${log_file}" 2>&1

# Check the number of reported completions.  Each time a backup is processed,
# an informational "completed OK" and a real version is printed.  At the end of
# the process, a final full apply is performed, generating another 2 messages.
ok_count="$(grep -c 'completed OK' "${log_file}")"

if (( ${ok_count} == ${#full_dirs[@]} + ${#incremental_dirs[@]} + 1 )); then
    cat << EOF
Backup looks to be fully prepared.  Please check the "prepare-progress.log" file
to verify before continuing.

If everything looks correct, you can apply the restored files.

First, stop MySQL and move or remove the contents of the MySQL data directory:
    
        sudo systemctl stop mysql
        sudo mv /var/lib/mysql/ /tmp/
    
Then, recreate the data directory and  copy the backup files:
    
        sudo mkdir /var/lib/mysql
        sudo xtrabackup --copy-back --target-dir=${PWD}/$(basename "${full_backup_dir}")
    
Afterward the files are copied, adjust the permissions and restart the service:
    
        sudo chown -R mysql:mysql /var/lib/mysql
        sudo find /var/lib/mysql -type d -exec chmod 750 {} \\;
        sudo systemctl start mysql
EOF
else
    error "It looks like something went wrong.  Check the \"${log_file}\" file for more information."
fi
