#!/bin/bash
set -euo pipefail


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
    local paths=$(get_section_value "$vmid" paths | sed 's/, /;/g')
    if [ -z "$paths" ]; then
        log ERROR "No configuration for vm: '$vmid'. Exiting..."
        exit 5
    fi

    local loglevel=$(get_section_value "$vmid" loglevel | sed 's/, */;/g')
    if [ -z "$loglevel" ]; then loglevel="$DEFAULT_VFS_LOGLEVEL"; fi

    local virtiofs_args=$(get_section_value "$vmid" virtiofs_args | sed 's/, */;/g')
    local vm_args=$(get_section_value "$vmid" vm_args)

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

setup_args_in_proxmox_config() {
    local paths="$1"
    local vm_args="$2"

     # Get args from proxmox config
    args_from_config=$(get_key_from_proxmox_config "args")
    # TODO: if backup and restore works, maybe we can also remove alltogether 
    if [ ! -z "$args_from_config" ]; then 
        # Writing args to temp 
        echo "$args_from_config" > /run/$vmid.virtfs
    fi

    memory=$(get_key_from_proxmox_config "memory")
    # Generating object section of args:
    args="-object memory-backend-memfd,id=mem,size=${memory}M,share=on -numa node,memdev=mem"

    IFS=';'
    read -r -a paths <<< "$paths_all"
    for path in "${paths[@]}"; do
        log DEBUG "Processing path '$path'"
        escapedpath=$(echo "$path" | sed 's/\//_/g; s/ /-/g')
        escapedpath="${escapedpath:1}" 
        log DEBUG "Escaped path '$escapedpath'"
        # generating chardev
        chardev="-chardev socket,id=char_${vmid}_${escapedpath},path=/run/virtiofsd/$vmid-$escapedpath.sock"
        log DEBUG "Chardev: '$chardev'"
        # generating device
        device="-device vhost-user-fs-pci,chardev=char_${vmid}_${escapedpath},tag=$vmid-$escapedpath"
        log DEBUG "Device: '$chardev'"
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
        sed "s/^args:.*/args: $escaped_args\n/g" -i "$PROXMOX_CONFIG"
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

        if [ ! -z $loglevel ]; then 
            log DEBUG "Setting provided loglevel for all - in loop"
            ll="$loglevel"
        else
            ll="${loglevels[$i]:-$DEFAULT_VFS_LOGLEVEL}"
            log DEBUG "Setting specific loglevel for vfs $i to $ll"
        fi

        vfs_args="${virtiofs_args[$i]:-}"

        log INFO "Paths: '$p', Loglevel: '$ll', vfsargs: '$vfs_args'"
    done
        
}

pre_start() {
    # Call get_config with variable names to store the results
    ret=$(get_config paths_all loglevel_all virtiofs_args_all vm_args)
    if [ ! $? -eq 0 ]; then log ERROR "Error when getting config for '$vmid'. Exiting..."; return 1; fi;
    eval "$ret"

    echo "paths: $paths_all"
    echo "loglevel: $loglevel_all"
    echo "virtiofs_args: $virtiofs_args_all"
    echo "vm_args: $vm_args"

    log INFO "Setuping argument in Proxmox config"
    setup_args_in_proxmox_config $paths_all $vm_args

    log INFO "Creating virtiofs socket(s)."
    setup_virtiofs_sockets $paths_all $loglevel_all $virtiofs_args_all
    
}



# Example hook script for PVE guests (hookscript config option)
# You can set this via pct/qm with
# pct set <vmid> -hookscript <volume-id>
# qm set <vmid> -hookscript <volume-id>
# where <volume-id> has to be an executable file in the snippets folder
# of any storage with directories e.g.:
# qm set 100 -hookscript local:snippets/hookscript.sh

echo "GUEST HOOK: $*"

# First argument is the vmid
vmid="$1"

# Second argument is the phase
phase="$2"


# Example usage
CONF_FILE="./virtiofs-hook.conf"
PROXMOX_CONFIG_DIR="."
LOGLEVEL="DEBUG"
PROXMOX_CONFIG="$PROXMOX_CONFIG_DIR/$vmid.conf"
PROXMOX_CONFIG_BAK="$PROXMOX_CONFIG_DIR/$vmid.conf.bak"
DEFAULT_VFS_LOGLEVEL="info"


ret=$(get_config paths_all loglevel_all virtiofs_args_all vm_args)
if [ ! $? -eq 0 ]; then log ERROR "Error when getting config for '$vmid'. Exiting..."; return 1; fi;
eval "$ret"

setup_virtiofs_sockets "$paths_all" "$loglevel_all" "$virtiofs_args_all"

exit 0

case "$phase" in
    pre-start)
        # First phase 'pre-start' will be executed before the guest
        # is started. Exiting with a code != 0 will abort the start
        echo "$vmid is starting, doing preparations."
        
        # Uncomment the following lines to abort the start
        # echo "preparations failed, aborting."
        # exit 1
        ;;

    post-start)
        # Second phase 'post-start' will be executed after the guest
        # successfully started.
        echo "$vmid started successfully."
        ;;

    pre-stop)
        # Third phase 'pre-stop' will be executed before stopping the guest
        # via the API. Will not be executed if the guest is stopped from
        # within e.g., with a 'poweroff'
        echo "$vmid will be stopped."
        ;;

    post-stop)
        # Last phase 'post-stop' will be executed after the guest stopped.
        # This should even be executed in case the guest crashes or stopped
        # unexpectedly.
        echo "$vmid stopped. Doing cleanup."
        ;;

    *)
        echo "got unknown phase '$phase'" >&2
        exit 1
        ;;
esac

exit 0
