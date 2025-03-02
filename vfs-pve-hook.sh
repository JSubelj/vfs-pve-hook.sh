#!/bin/bash
set -euo pipefail

LOGLEVEL="DEBUG"
DEFAULT_VFS_LOGLEVEL="info"

VIRTIOFS_EXE="/usr/libexec/virtiofsd"
SOCKET_DIR="/run/virtiofsd"


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
    # This function is called: eval $(get_config paths loglevel virtiofs_args vm_args)
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
    local vm_args=$(get_section_value "$VMID" vm_args)

    # Use eval to assign values to the output variables in the caller's scope
    echo "$1=\"$paths\";$2=\"$loglevel\";$3=\"$virtiofs_args\";$4=\"$vm_args\""
}

backup_proxmox_conf() {
    if [ -f "$PROXMOX_CONFIG_BAK" ]; then 
        log ERROR "$PROXMOX_CONFIG_BAK already exist! Please check if $PROXMOX_CONFIG is as it should be and remove $PROXMOX_CONFIG_BAK!"
        exit 1
    fi

    cp $PROXMOX_CONFIG $PROXMOX_CONFIG_BAK
}

restore_proxmox_conf() {
    if [ ! -f "$PROXMOX_CONFIG_BAK" ]; then 
        log ERROR "$PROXMOX_CONFIG_BAK does not exist, can't restore!"
        exit 1
    fi

    mv $PROXMOX_CONFIG_BAK $PROXMOX_CONFIG
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

setup_args_in_proxmox_config() {
    local paths="$1"
    local vm_args="$2"

     # Get args from proxmox config
    args_from_config=$(get_key_from_proxmox_config "args")
    # TODO: if backup and restore works, maybe we can also remove alltogether 
    if [ ! -z "$args_from_config" ]; then 
        # Writing args to temp 
        echo "$args_from_config" > /run/$VMID.virtfs
    fi

    memory=$(get_key_from_proxmox_config "memory")
    # Generating object section of args:
    args="-object memory-backend-memfd,id=mem,size=${memory}M,share=on -numa node,memdev=mem"
    IFS=';'
    read -r -a paths <<< "$paths_all"
    for path in "${paths[@]}"; do
        log DEBUG "Processing path '$path'"
        escapedpath=$(get_escaped_path "$path")
        log DEBUG "Escaped path '$escapedpath'"
        # generating chardev
        chardev="-chardev socket,id=char_${VMID}_${escapedpath},path=$(get_socket_path $escapedpath)"
        log DEBUG "Chardev: '$chardev'"
        # generating device
        local tag="$VMID-$escapedpath"
        device="-device vhost-user-fs-pci,chardev=char_${VMID}_${escapedpath},tag=$tag"
        log DEBUG "Device: '$device'"
        args="$args $chardev $device"
    done

    if [[ -n "$args_from_config" && "$args_from_config" != "$args" ]]; then
        log DEBUG "Adding args from config"
        args="$args_from_config $args"
    fi

    if [ ! -z "$vm_args" ]; then
        args="$args $vm_args"
    fi

    prettyargs=$(echo "$args" | sed 's/ -/\n-/g; s/^-/\n-/g; s/\n/\n\t/g;' )
    log INFO "Final vm args are: $prettyargs"

    log INFO "Backing up $PROXMOX_CONFIG to $PROXMOX_CONFIG_BAK"
    backup_proxmox_conf

    log INFO "Writting args into proxmox config"
    escaped_args=${args//\//\\/}
    if [ -z "$args_from_config" ]; then 
        # Writing args to config
        sed "1s/^/args: $escaped_args\n/" -i "$PROXMOX_CONFIG"
    else
        sed "s/^args:.*/args: $escaped_args/g" -i "$PROXMOX_CONFIG"
    fi
    log INFO "Writting to config successful."


}


setup_virtiofs_sockets() {
    local paths_all="$1"
    local loglevel_all="$2"
    local virtiofs_args_all="$3"
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
        p="${paths[$i]}"
        escapedpath=$(get_escaped_path "$p")

        if [ ! -z $loglevel ]; then 
            log DEBUG "Setting provided loglevel for all - in loop"
            ll="$loglevel"
        else
            ll="${loglevels[$i]:-$DEFAULT_VFS_LOGLEVEL}"
            log DEBUG "Setting specific loglevel for vfs $i to $ll"
        fi

        vfs_args="${virtiofs_args[$i]:-}"
        service_name="virtiofs-$VMID-${escapedpath}"
        socket_path="$(get_socket_path $escapedpath)"

        mkdir -p "$SOCKET_DIR"
        log INFO "Creating socket '$socket_path' with unit name '$service_name' for '$p' with loglevel: '$ll' and additional vfsargs: '$vfs_args'"
        
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
        set +e
        eval "$service_command"
            
        log INFO "Checking if service was created"
        systemctl --no-pager status "$service_name"
        if [ $? -ne 0 ]; then
            log ERROR "Can't start service. Cleaning up."
            systemctl disable $service_name
            systemctl reset-failed $service_name
            log INFO "Exiting..."
            exit 3
        fi
        set -e
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
    # Call get_config with variable names to store the results
    ret=$(get_config paths_all loglevel_all virtiofs_args_all vm_args)
    if [ ! $? -eq 0 ]; then log ERROR "Error when getting config for '$VMID'. Exiting..."; return 1; fi;
    eval "$ret"

    log INFO "Setuping argument in Proxmox config"
    setup_args_in_proxmox_config "$paths_all" "$vm_args"

    log INFO "Creating virtiofs socket(s)."
    setup_virtiofs_sockets "$paths_all" "$loglevel_all" "$virtiofs_args_all"
}

post_start() {
    print_helper_script_for_mnt
    
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
PROXMOX_CONFIG_BAK="$PROXMOX_CONFIG_DIR/$VMID.conf.bak"

RUNTIME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$RUNTIME_DIR/vfs-pve-hook.conf"




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
        log INFO "Configuration for $VMID restored to state before touching it."
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
        
        log INFO "Restoring proxmox config."
        restore_proxmox_conf
        # Removes services if they still exist.
        ;;

    *)
        echo "got unknown phase '$phase'" >&2
        exit 1
        ;;
esac

exit 0
