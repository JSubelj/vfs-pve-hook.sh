#!/bin/bash
set -euo pipefail

LOGLEVEL="INFO"
DEFAULT_VFS_LOGLEVEL="info"
DEFAULT_NUMA="true"

VIRTIOFS_EXE="/usr/libexec/virtiofsd"
SOCKET_DIR="/run/vfs-pve-hook"


log() {
    local level=$1
    local message=$2
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    # Define log levels in order of severity
    local log_levels=("DEBUG" "INFO" "WARN" "ERROR")

    # Determine the index of the current log level and the loglevel variable
    local level_index=-1
    local loglevel_index=-1

    # Default loglevel to INFO if not set
    local current_loglevel=${LOGLEVEL:-INFO}
    local i=0;
    for i in "${!log_levels[@]}"; do
        if [[ "${log_levels[$i]}" == "$level" ]]; then
            level_index=$i
        fi
        if [[ "${log_levels[$i]}" == "$current_loglevel" ]]; then
            loglevel_index=$i
        fi
    done

    # Only log messages that are at or above the current log level
    if [[ $level_index -ge $loglevel_index ]]; then
        case $level in
            INFO)
                printf "\e[32m[%s] [INFO] %s\e[0m\n" "$timestamp" "$message" > /dev/stdout
                ;;
            WARN)
                printf "\e[33m[%s] [WARN] %s\e[0m\n" "$timestamp" "$message" > /dev/stdout
                ;;
            ERROR)
                printf "\e[31m[%s] [ERROR] %s\e[0m\n" "$timestamp" "$message" > /dev/stderr
                ;;
            DEBUG)
                printf "\e[34m[%s] [DEBUG] %s\e[0m\n" "$timestamp" "$message"
                ;;
            *)
                printf "\e[34m[%s] [%s] %s\e[0m\n" "$timestamp" "$level" "$message"
                ;;
        esac
    fi
}


get_key_from_proxmox_config() {
    local key="$1"

    grep "^$key:" "$PROXMOX_CONFIG" | head -n 1 | cut -d ' ' -f 2- || true
}

# Function to extract a value from a specific section
get_section_value() {
  local section="$1"
  local key="$2"
  sed -n "/^\[$section\]/,/^\[/p" "$CONF_FILE" | grep "^$key:" | head -n 1 | cut -d ' ' -f 2-
}

get_config() {
    # This function is called: eval $(get_config paths loglevel virtiofs_args numa)
    # In those variables, data will be stored

    # Read paths and replace commas with spaces
    local paths=$(get_section_value "$VMID" paths | sed 's/, /;/g')
    if [ -z "$paths" ]; then
        log ERROR "No configuration for vm: '$VMID'. Exiting..."
        exit 5
    fi

    local loglevel=$(get_section_value "$VMID" loglevel | sed 's/, */;/g')
    if [ -z "$loglevel" ]; then loglevel="$DEFAULT_VFS_LOGLEVEL"; fi

    local virtiofs_args=$(get_section_value "$VMID" virtiofs_args | sed 's/, */;/g')
    local numa=$(get_section_value "$VMID" numa)
    if [ -z "$numa" ]; then numa="$DEFAULT_NUMA"; fi


    # Use eval to assign values to the output variables in the caller's scope
    echo "$1=\"$paths\";$2=\"$loglevel\";$3=\"$virtiofs_args\";$4=\"$numa\""
}

get_escaped_path(){
    local path="$1"

    local escapedpath=$(echo "$path" | sed 's/\//_/g; s/ /-/g')
    escapedpath="${escapedpath:1}" 

    echo "$escapedpath"
}

get_socket_path(){
    local escapedpath="$1"
    echo "$SOCKET_DIR/$VMID-$escapedpath.sock"
}


move_old_args_files() {
    # Initialize the suffix
    suffix=1

    base_file="$OLD_ARGS_FILE"

    log INFO "Moving backup args config"
    # Check if the base file exists and rename existing files incrementally
    while [[ -e "$base_file" ]]; do
        # Define the new file name with the next suffix
        new_file="${base_file}.$suffix"

        # If the new file name already exists, increment the suffix
        while [[ -e "$new_file" ]]; do
            ((suffix++))
            new_file="${base_file}.$suffix"
        done
        log DEBUG "Moving $base_file into $new_file"
        # Move the existing file to the new file name
        mv "$base_file" "$new_file"

        # Reset the suffix for the next iteration
        suffix=1
    done
}

setup_args_in_proxmox_config() {
    # Checks if args in config. If not adds them and STOPS execution! 
    # Copies old args into <vmid>.conf.old_args
    # If old args exist, 

     # Get args from proxmox config
    args_from_config=$(get_key_from_proxmox_config "args")

    local touching_args="false";
    local memory=$(get_key_from_proxmox_config "memory")

    local args="$args_from_config" 

    local memory_part_of_args="-object memory-backend-memfd,id=mem,size=${memory}M,share=on"
    if [[ "$args" != *"$memory_part_of_args"* ]]; then
        log DEBUG "Memory part of args missing, adding to generate args"
        args+=" $memory_part_of_args"
        touching_args="true"
    fi

    local numa_part_of_args="-numa node,memdev=mem"
    if [[ "$numa" == "true" && "$args" != *"$numa_part_of_args"* ]]; then
        log DEBUG "Including NUMA"
        args+=" $numa_part_of_args"
        touching_args="true"
    fi

    if [[ "$numa" != "true" && "$args" == *"$numa_part_of_args"* ]]; then
        log DEBUG "Removing NUMA"
        args=${args//$numa_part_of_args/}
        touching_args="true"
    fi


    IFS=';'
    read -r -a paths <<< "$paths_all"
    for path in "${paths[@]}"; do
        log DEBUG "Processing path '$path'"
        escapedpath=$(get_escaped_path "$path")
        log DEBUG "Escaped path '$escapedpath'"
        # generating chardev
        local chardev_part_of_args="-chardev socket,id=char_${VMID}_${escapedpath},path=$(get_socket_path $escapedpath)"
        log DEBUG "Chardev: '$chardev_part_of_args'"
        if [[ "$args" != *"$chardev_part_of_args"* ]]; then
            log DEBUG "Including chardev for $path"
            args+=" $chardev_part_of_args"
            touching_args="true"
        fi
        # generating device
        local tag="$VMID-$escapedpath"
        local device_part_of_args="-device vhost-user-fs-pci,queue-size=1024,chardev=char_${VMID}_${escapedpath},tag=$tag"
        log DEBUG "Device: '$device_part_of_args'"
        if [[ "$args" != *"$device_part_of_args"* ]]; then
            log DEBUG "Including device for $path"
            args+=" $device_part_of_args"
            touching_args="true"
        fi
    done

    prettyargs=$(echo "$args" | sed 's/ -/\n-/g; s/^-/\n-/g; s/\n/\n\t/g;' )
    log INFO "Final vm args are: $prettyargs"

    

    # I didn't want to change config with sed, because it's not really a supported mode. Via bash api would timeout for lock only perl way works.
    if [[ "$touching_args" == "true" ]]; then
        move_old_args_files
        log INFO "Writing args to $OLD_ARGS_FILE"
        echo "$args_from_config" > $OLD_ARGS_FILE

        log INFO "Writting args into proxmox config"

        perl -e "
        use PVE::QemuServer;
        my \$conf = PVE::QemuConfig->load_config($VMID);
        \$conf->{args} = \"$args\";
        PVE::QemuConfig->write_config($VMID, \$conf);
        "

        log WARN "Args were written. Because Proxmox does not reload config after pre-start (unless you install a patch that does this), this script will exit and you will need to qm start your VM again."
        exit -1
    fi
    log INFO "Writting to config not needed. Continuing with setup."
}


redirect_if_not_DEBUG() {
    # write your test however you want; this just tests if SILENT is non-empty
    if [[ "$LOGLEVEL" == "DEBUG" ]]; then
        "$@" 
    else
        "$@" > /dev/null
    fi
}

setup_virtiofs_sockets() {
    IFS=';'
    read -r -a paths <<< "$paths_all"
    read -r -a loglevels <<< "$loglevel_all"
    read -r -a virtiofs_args <<< "$virtiofs_args_all"

    local loglevel=''
    if [[ ${#loglevels[@]} == 0 ]]; then
        log DEBUG "Setting default loglevel because non provided"
        loglevel="$DEFAULT_VFS_LOGLEVEL"
    fi
    if [[ ${#loglevels[@]} == 1 ]]; then
        log DEBUG "Setting provided loglevel for all"
        loglevel="${loglevels[0]}"
    fi
    
    local i=0
    for ((i=0; i<${#paths[@]}; i++)); do
        local p="${paths[$i]}"
        local escapedpath=$(get_escaped_path "$p")

        if [ ! -z $loglevel ]; then 
            log DEBUG "Setting provided loglevel for all - in loop"
            ll="$loglevel"
        else
            ll="${loglevels[$i]:-$DEFAULT_VFS_LOGLEVEL}"
            log DEBUG "Setting specific loglevel for vfs $i to $ll"
        fi

        local vfs_args="${virtiofs_args[$i]:-}"
        local service_name="virtiofs-$VMID-${escapedpath}"
        local socket_path="$(get_socket_path $escapedpath)"

        mkdir -p "$SOCKET_DIR"
        log INFO "Creating socket '$socket_path' with unit name '$service_name' for '$p' with loglevel: '$ll' and additional vfs args: '$vfs_args'"
        
        local service_command="systemd-run \
                --unit=\"$service_name\" \
                \"$VIRTIOFS_EXE\" \
                --log-level \"$ll\" \
                --socket-path \"$socket_path\" \
                --shared-dir \"$p\" \
                --announce-submounts \
                --inode-file-handles=mandatory"
                
        if [ ! -z "$vfs_args" ]; then
            service_command="$service_command $vfs_args"
        fi

        if [[ "$LOGLEVEL" != "DEBUG" ]]; then
            service_command="$service_command > /dev/null"
        fi

        set +e
        eval "$service_command"
        if [ $? -ne 0 ]; then
            log ERROR "Can't start service. Cleaning up."
            systemctl stop "$service_name"
            systemctl disable "$service_name"
            systemctl reset-failed "$service_name"
            log INFO "Exiting..."
            exit 3
        fi

        log INFO "Checking if service was created"
        redirect_if_not_DEBUG systemctl --no-pager status "$service_name" 
        if [ $? -ne 0 ]; then
            log ERROR "Can't start service. Cleaning up."
            systemctl stop "$service_name"
            systemctl disable "$service_name"
            systemctl reset-failed "$service_name"
            log INFO "Exiting..."
            exit 3
        fi
        set -e
        ls "$socket_path"
    done
        
}

read_tags() {
    local tags=""
    local tags_all=$(cat "$PROXMOX_CONFIG" | grep "^args: " |  grep -o 'tag=[^ ,]*' | awk -F '=' '{print $2}')
    mapfile -t tags < <(echo $tags_all)
    echo $tags
}

print_helper_script_for_mnt() {
    tags_all="$(read_tags)"
    IFS=' '
    read -r -a tags <<< "$tags_all"
 

    log INFO "Printing helper guid for mounting:"
    echo
    echo "Tags:"
    for tag in "${tags[@]}"; do
        echo -e "\t- '$tag'"
    done
    echo
    echo -e "To mount virtiofs mounts run in VM:"
    echo -e "$ mount -t virtiofs <tag> <mountpoint>"
    echo
    echo -e "To mount from fstab edit /etc/fstab and add:"
    echo "------------------------------------------------"
    echo -e "<tag> <mountpoint> virtiofs defaults,nofail 0 0"
    echo "------------------------------------------------"
    echo
}

pre_start() {
    log INFO "Setuping argument in Proxmox config"
    setup_args_in_proxmox_config 

    log INFO "Creating virtiofs socket(s)."
    setup_virtiofs_sockets 
}

post_start() {
    print_helper_script_for_mnt
}

remove_virtiofs_services() {
    IFS=';'
    read -r -a paths <<< "$paths_all"
    for ((i=0; i<${#paths[@]}; i++)); do
        p="${paths[$i]}"
        escapedpath=$(get_escaped_path "$p")
        service_name="virtiofs-$VMID-${escapedpath}"
        log INFO "Stopping, disabling and reseting failed $service_name"
        systemctl stop $service_name
        systemctl disable $service_name
        systemctl reset-failed $service_name
    done
}

# Example hook script for PVE guests (hookscript config option)
# You can set this via pct/qm with
# pct set <vmid> -hookscript <volume-id>
# qm set <vmid> -hookscript <volume-id>
# where <volume-id> has to be an executable file in the snippets folder
# of any storage with directories e.g.:
# qm set 100 -hookscript local:snippets/hookscript.sh

log INFO "GUEST HOOK: $*"

# First argument is the vmid
VMID="$1"

# Second argument is the phase
phase="$2"


PROXMOX_CONFIG_DIR="/etc/pve/qemu-server"
PROXMOX_CONFIG="$PROXMOX_CONFIG_DIR/$VMID.conf"

OLD_ARGS_FILE="$PROXMOX_CONFIG_DIR/$VMID.conf.old_args"
RUNTIME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$RUNTIME_DIR/vfs-pve-hook.conf"

if [ -f "$RUNTIME_DIR/vfs-pve-hook.env" ]; then
    . "$RUNTIME_DIR/vfs-pve-hook.env"
fi

# Call get_config with variable names to store the results
ret=$(get_config paths_all loglevel_all virtiofs_args_all numa)
if [ ! $? -eq 0 ]; then log ERROR "Error when getting config for '$VMID'. Exiting..."; exit 6; fi;
eval "$ret"

log DEBUG "env vars:"
log DEBUG "LOGLEVEL=\"$LOGLEVEL\""
log DEBUG "DEFAULT_VFS_LOGLEVEL=\"$DEFAULT_VFS_LOGLEVEL\""
log DEBUG "DEFAULT_NUMA=\"$DEFAULT_NUMA\""
log DEBUG "VIRTIOFS_EXE=\"$VIRTIOFS_EXE\""
log DEBUG "SOCKET_DIR=\"$SOCKET_DIR\""
log DEBUG "CONF_FILE=\"$CONF_FILE\""
log DEBUG "PROXMOX_CONFIG_DIR=\"$PROXMOX_CONFIG_DIR\""
log DEBUG "PROXMOX_CONFIG=\"$PROXMOX_CONFIG\""
log DEBUG "OLD_ARGS_FILE=\"$OLD_ARGS_FILE\""


case "$phase" in
    pre-start)
        # First phase 'pre-start' will be executed before the guest
        # is started. Exiting with a code != 0 will abort the start

        # Prestart generates args: for proxmox config and opens needed sockets

        log INFO "$VMID is starting, doing preparations."
        pre_start
        log INFO "Prestart for $VMID successful."
        ;;

    post-start)
        # Second phase 'post-start' will be executed after the guest
        # successfully started.

        # Post start restores proxmox config back to previous conf.

        log INFO "$VMID started successfully."
        post_start
        
        ;;

    pre-stop)
        # Third phase 'pre-stop' will be executed before stopping the guest
        # via the API. Will not be executed if the guest is stopped from
        # within e.g., with a 'poweroff'
        
        # Not needed.

        ;;

    post-stop)
        # Last phase 'post-stop' will be executed after the guest stopped.
        # This should even be executed in case the guest crashes or stopped
        # unexpectedly.
        log INFO "Removing virtiofs services."
        remove_virtiofs_services
        # Removes services if they still exist.
        ;;

    *)
        echo "got unknown phase '$phase'" >&2
        exit 1
        ;;
esac

exit 0
