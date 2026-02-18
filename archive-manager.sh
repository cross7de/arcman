#!/usr/bin/env bash

# Archive Manager
# Management of encrypted archives (Cryptomator, CryptomatorCLI, gocryptfs, ecryptfs, KeePassXC)
# Supports multi-user environments and various storage locations

# Function to retrieve a value from the .conf file
get_config_value() {
    local key="$1"
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$CONFIG_FILE" \
        | head -n1 \
        | cut -d'=' -f2- \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Function to convert a relative path to an absolute path
get_absolute_path() {
    local path="$1"
    # Remove leading and trailing whitespace
    path=$(echo "$path" | xargs)

    # If the path is empty, return an empty string immediately
    if [ -z "$path" ]; then
        echo ""
        return 1  # Error: No path specified
    fi

    # Ersetze Umgebungsvariablen (z.B. $USER) im Pfad
    path=$(eval echo "$path")

    # Falls der Pfad bereits absolut ist, gib ihn zurück
    if [[ "$path" = /* ]]; then
        echo "$path"
        return 0
    fi

    local abs_path
    abs_path=$(realpath "$path" 2>/dev/null)
    retVal=$?
    # If realpath fails, return the **original path** from working dir
    if [ $retVal -ne 0 ] || [ -z "$abs_path" ]; then
        echo "$path"  # **Return original value from configuration**
        return 2  # Error: realpath failed
    fi

    # Escape possible special characters in the path
    echo "$abs_path"
    return 0
}

# Non-interactive logging function (outputs to terminal and logfile)
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Interactive warning messages (output to terminal only, optionally colored)
warn() {
    local message="$1"
    if $COLOR_ENABLED; then
        echo -e "${ORANGE}WARNING:${NC} $message"
    else
        echo "WARNING: $message"
    fi
}

# Error handling with exit (optionally colored)
error_exit() {
    local message="$1"
    if $COLOR_ENABLED; then
        echo -e "${RED}ERROR:${NC} $message" | tee -a "$LOG_FILE"
    else
        echo "ERROR: $message" | tee -a "$LOG_FILE"
    fi
    exit 1
}

# Display usage information
usage() {
    echo "Usage: $0 [options] <command> [arguments]"
    echo ""
    echo "Options:"
    echo "  -c, --config <file>  Specify a custom configuration file (default locations will be used otherwise)"
    echo "  -h, --help           Show this help message and exit"
    echo "  -v, --version        Display the script version and exit"
    echo ""
    echo "Commands:"
    echo "  mount <ARCHIVE_ID>   Mount the specified archive"
    echo "  unmount <ARCHIVE_ID> Unmount the specified archive"
    echo "  list [long|ok]       Show all configured archives"
    echo "                         long – detailed view"
    echo "                         ok   – only archives found on disk"
    echo "  update               Check for updates and update the script if a new version is available"
    echo ""
    echo "Configuration File Lookup Order:"
    echo "  1. Custom file specified with '-c' or '--config'"
    echo "  2. ./archive-manager.conf"
    echo "  3. \$HOME/.local/share/archive-manager/archive-manager.conf"
    echo "  4. /etc/archive-manager/archive-manager.conf"
    echo ""
    echo "Examples:"
    echo "  $0 mount my_archive           # Mount 'my_archive'"
    echo "  $0 unmount my_archive         # Unmount 'my_archive'"
    echo "  $0 list                       # Show configured archives"
    echo "  $0 list long                  # Show detailed archive list"
    echo "  $0 list ok                    # Show only available archives"
    echo "  $0 -c my_config.conf mount my_archive  # Use custom config and mount"
    echo ""
    exit 0
}

# Checks if a tool exists and is executable. Logs an error if not found.
check_tool_path() {
    local var_name="$1"
    local tool_path="$2"

    # If the path is not set, provide a clear error message
    if [ -z "$tool_path" ]; then
        warn "The variable $var_name is not set in the configuration file."
        warn "  Please check $CONFIG_FILE and add the correct path for $var_name."
        return 1
    fi

    # Determine the absolute path of the tool
    local abs_tool_path
    abs_tool_path=$(get_absolute_path "$tool_path")
    local status_code=$?

    # If get_absolute_path returned an error, handle it appropriately
    if [ $status_code -eq 1 ]; then
        warn "The path for $var_name is not set or empty."
        return 2
    elif [ $status_code -eq 2 ]; then
        warn "The path for $var_name is invalid or not resolvable: $tool_path"
        return 3
    fi

    # Check if the tool exists
    if [ ! -e "$abs_tool_path" ]; then
        warn "The tool $var_name does not exist: $abs_tool_path"
        warn "  Please check $CONFIG_FILE and adjust the path for $var_name."
        return 4
    fi

    # Check if the tool is executable
    if [ ! -x "$abs_tool_path" ]; then
        warn "No access or not executable: $abs_tool_path"
        warn "  Please set the correct permissions or check the file."
        return 5
    fi

    return 0
}

# Cross-platform check if a mount point is active
is_mounted() {
    local mount_point="$1"
    if command -v findmnt &>/dev/null; then
        findmnt | grep -q "$mount_point"
    elif command -v mount &>/dev/null; then
        mount | grep -q "$mount_point"
    elif command -v df &>/dev/null; then
        df | grep -q "$mount_point"
    elif command -v diskutil &>/dev/null; then
        diskutil info "$mount_point" &>/dev/null
    else
        warn "No suitable tool found for mount verification!"
        return 1
    fi
}

# Starts an application (modular, without re-reading the config)
start_application() {
    local tool="$1"
    local archive_id="$2"
    local archive_path="$3"
    local log_file="$4"
    shift 4
    local additional_params=("$@")

    [ -z "$archive_path" ] && error_exit "Archive ID $archive_id not found."

    log "Starting $tool for archive $archive_id"
    nohup "$tool" "$archive_path" "${additional_params[@]}" > "$log_file" 2>&1 &
    local pid=$!
    sleep 2
    if ! ps -p $pid > /dev/null; then
        error_exit "$tool could not be started. See $log_file for details."
    fi
    log "$tool successfully started for $archive_id."
}

# Checks if the script is running with root privileges. Otherwise, exits with an error.
require_root() {
    if [ "$EUID" -ne 0 ]; then
        error_exit "Error: Root privileges are required for this operations. Please run the script as root."
    fi
}

# Action to perform after mounting
post_mount_action() {
    local mount_point="$1"
    local answer
    echo "Contents of the mount point ($mount_point):"
    ls -lah "$mount_point"
    echo
    read -p "Do you want to switch to the directory? (y/n): " answer
    if [[ "$answer" =~ ^[yY]$ ]]; then
        cd "$mount_point" || {
            echo "Error: Could not switch to directory $mount_point."
            return 1
        }
        # Start an interactive shell using the current shell environment
        echo "Starting an interactive shell in $mount_point ..."
        echo "  Type 'exit' to return to the original shell."
        if [ -n "$SHELL" ]; then
            exec "$SHELL" -i
        else
            exec bash -i
        fi
    fi
}

# Mounts an eCryptfs archive.
# Parameters:
#   $1: Archive ID (for logging purposes only)
#   $2: Absolute path to the archive (e.g., /home/.ecryptfs/user1)
#   $3: Absolute path to the mount point (e.g., /home/user1)
mount_ecryptfs() {
    local archive_id="$1"
    local archive_path="$2"
    local mount_point="$3"

    require_root

    local wrapped_pass="$archive_path/.ecryptfs/wrapped-passphrase"
    if [ ! -f "$wrapped_pass" ]; then
        error_exit "File $wrapped_pass not found. Cannot unwrap eCryptfs passphrase."
    fi

    echo -n "Enter the user password to decrypt the eCryptfs passphrase for archive $archive_id: "
    local user_passwd
    read -sr user_passwd
    echo

    local passphrase
    passphrase=$(ecryptfs-unwrap-passphrase "$wrapped_pass" <<< "$user_passwd" 2>/dev/null | sed -ne 2p)
    if [ -z "$passphrase" ]; then
        error_exit "Error unwrapping the eCryptfs passphrase."
    fi

    local output sig fnek_sig
    output=$(printf "%s" "$passphrase" | ecryptfs-add-passphrase --fnek - 2>/dev/null)
    sig=$(echo "$output" | sed -ne 1p | sed 's/.*\[\(.*\)\].*/\1/')
    fnek_sig=$(echo "$output" | sed -ne 2p | sed 's/.*\[\(.*\)\].*/\1/')

    local key_bytes="${ECRYPTFS_KEY_BYTES:-16}"

    local options="key=passphrase,ecryptfs_passthrough=n,ecryptfs_enable_filename_crypto=y,ecryptfs_sig=$sig,ecryptfs_fnek_sig=$fnek_sig,ecryptfs_unlink_sigs,ecryptfs_key_bytes=$key_bytes,ecryptfs_cipher=aes"
    log "eCryptfs mount options: $options"

    if [ ! -d "$archive_path/.Private" ]; then
        error_exit "Directory $archive_path/.Private not found."
    fi

    echo -n "Next, the mount command will be executed. Enter the user password again when prompted to mount archive $archive_id."
    echo
    "$ECRYPTFS_CMD" -t ecryptfs -o "$options" "$archive_path/.Private/" "$mount_point" || error_exit "Error mounting $archive_id (ecryptfs)"
}

# Mounts a LUKS archive (blockdevice expected).
# Config keys (optional unless stated):
#   ARCHIVE_<ID>_TYPE=luks
#   ARCHIVE_<ID>_PATH             -> LUKS source (blockdevice) [required]
#   ARCHIVE_<ID>_MOUNTPOINT       -> mount point [required]
#   ARCHIVE_<ID>_LUKS_NAME        -> mapper name (default: arcman_<ID>)
#   ARCHIVE_<ID>_LUKS_INNER       -> device to mount after open (default: /dev/mapper/<name>)
#   ARCHIVE_<ID>_LUKS_MOUNT_OPTS  -> mount -o ...
#   ARCHIVE_<ID>_LUKS_FS          -> mount -t ...
#   ARCHIVE_<ID>_LUKS_KEYFILE     -> cryptsetup --key-file <file> (instead of passphrase prompt)
mount_luks() {
    local archive_id="$1"
    local source_path="$2"
    local mount_point="$3"

    require_root

    command -v cryptsetup >/dev/null 2>&1 || error_exit "cryptsetup not found. Please install: cryptsetup"

    local mapper_name
    mapper_name=$(get_config_value "ARCHIVE_${archive_id}_LUKS_NAME")
    [ -z "$mapper_name" ] && mapper_name="arcman_${archive_id}"

    local inner_dev
    inner_dev=$(get_config_value "ARCHIVE_${archive_id}_LUKS_INNER")
    [ -z "$inner_dev" ] && inner_dev="/dev/mapper/$mapper_name"

    local mount_opts
    mount_opts=$(get_config_value "ARCHIVE_${archive_id}_LUKS_MOUNT_OPTS")
    local fs_type
    fs_type=$(get_config_value "ARCHIVE_${archive_id}_LUKS_FS")

    local keyfile
    keyfile=$(get_config_value "ARCHIVE_${archive_id}_LUKS_KEYFILE")
    if [ -n "$keyfile" ]; then
        keyfile=$(get_absolute_path "$keyfile")
    fi

    if [ -e "/dev/mapper/$mapper_name" ]; then
        warn "Mapper already open: /dev/mapper/$mapper_name"
    else
        log "Opening LUKS mapper: $mapper_name"
        if [ -n "$keyfile" ] && [ -f "$keyfile" ]; then
            cryptsetup open "$source_path" "$mapper_name" --key-file "$keyfile" || error_exit "Error opening $archive_id (luks)"
        else
            echo -n "Enter LUKS passphrase for archive $archive_id: "
            local luks_pw
            read -sr luks_pw
            echo
            printf "%s" "$luks_pw" | cryptsetup open "$source_path" "$mapper_name" --key-file - || error_exit "Error opening $archive_id (luks)"
            unset luks_pw
        fi
    fi

    [ -d "$mount_point" ] || mkdir -p "$mount_point"

    if [ -n "$fs_type" ] && [ -n "$mount_opts" ]; then
        mount -t "$fs_type" -o "$mount_opts" "$inner_dev" "$mount_point" || error_exit "Error mounting $archive_id (luks)"
    elif [ -n "$fs_type" ]; then
        mount -t "$fs_type" "$inner_dev" "$mount_point" || error_exit "Error mounting $archive_id (luks)"
    elif [ -n "$mount_opts" ]; then
        mount -o "$mount_opts" "$inner_dev" "$mount_point" || error_exit "Error mounting $archive_id (luks)"
    else
        mount "$inner_dev" "$mount_point" || error_exit "Error mounting $archive_id (luks)"
    fi
}

unmount_luks() {
    local archive_id="$1"
    local mount_point="$2"

    require_root

    command -v cryptsetup >/dev/null 2>&1 || error_exit "cryptsetup not found. Please install: cryptsetup"

    local mapper_name
    mapper_name=$(get_config_value "ARCHIVE_${archive_id}_LUKS_NAME")
    [ -z "$mapper_name" ] && mapper_name="arcman_${archive_id}"

    if is_mounted "$mount_point"; then
        umount "$mount_point" || error_exit "Error unmounting $archive_id (luks)"
    fi

    if [ -e "/dev/mapper/$mapper_name" ]; then
        cryptsetup close "$mapper_name" || error_exit "Error closing LUKS mapper $mapper_name"
    fi
}

# Mount function
mount_archive() {
    local archive_id="$1"
    local archive_type
    archive_type=$(get_config_value "ARCHIVE_${archive_id}_TYPE")
    local archive_path
    archive_path=$(get_absolute_path "$(get_config_value "ARCHIVE_${archive_id}_PATH")")
    local archive_description
    archive_description=$(get_config_value "ARCHIVE_${archive_id}_DESCRIPTION")
    local mount_point
    mount_point=$(get_absolute_path "$(get_config_value "ARCHIVE_${archive_id}_MOUNTPOINT")")

    [ -z "$archive_path" ] && error_exit "Configuration error: ARCHIVE_${archive_id}_PATH is not set or empty."

    # Note: Lockfile is only a warning, it does not prevent the mount operation.
    if [ -f "$archive_path/$LOCKFILE_SUFFIX" ]; then
        warn "Lockfile present ($archive_path/$LOCKFILE_SUFFIX). The archive may have been improperly handled before."
    fi

    log "Mounting $archive_id ($archive_type)"
    case "$archive_type" in
        Cryptomator)
            [ -z "$CRYPTOMATOR_CMD" ] && error_exit "Cryptomator path not set!"
            start_application "$CRYPTOMATOR_CMD" "$archive_id" "$archive_path" "./cryptomator.log" "vault"
            log "Application successfully started for archive:"
            log "  $archive_id | $archive_type | $archive_description | $archive_path"
            ;;
        CryptomatorCLI)
            [ -z "$CRYPTOMATOR_CLI_CMD" ] && error_exit "CryptomatorCLI path not set!"
            [ -z "$mount_point" ] && error_exit "Configuration error: ARCHIVE_${archive_id}_MOUNTPOINT is not set or empty."
            [ -d "$mount_point" ] || mkdir -p "$mount_point"

            echo -n "Enter password: "
            read -sr password
            echo

            echo "$password" | "$CRYPTOMATOR_CLI_CMD" unlock \
                --password:stdin \
                --mountPoint="$mount_point" \
                --mounter=org.cryptomator.frontend.fuse.mount.LinuxFuseMountProvider \
                "$archive_path" > ./cryptomator-cli.log 2>&1 &
            pid=$!

            unset password

            sleep 3

            if ps -p $pid > /dev/null; then
                log "CryptomatorCLI is running, cryptomator-cli pid: $pid"
                if [ -d "$mount_point" ] && [ "$(ls -A "$mount_point")" ]; then
                    log "Archive successfully mounted:"
                    log "  $archive_id | $archive_type | $archive_description | $archive_path -> $mount_point"
                    log "  to lock the archive, send 'kill $pid'"
                    post_mount_action "$mount_point"
                else
                    warn "  Unexpected situation: CryptomatorCLI is running, but the mount point is empty. Check what's going on and, if needed, send: 'kill $pid' or 'kill -9 $pid'"
                    warn "  $archive_id | $archive_type | $archive_description | $archive_path -> $mount_point"
                fi
            else
                error_exit "Error mounting $archive_id (CryptomatorCLI): Process $pid seems to have been terminated unexpectedly."
            fi
            ;;
        gocryptfs)
            [ -z "$GOCRYPTFS_CMD" ] && error_exit "gocryptfs path not set!"
            [ -z "$mount_point" ] && error_exit "Configuration error: ARCHIVE_${archive_id}_MOUNTPOINT is not set or empty."
            [ -d "$mount_point" ] || mkdir -p "$mount_point"
            "$GOCRYPTFS_CMD" "$archive_path" "$mount_point" || error_exit "Error mounting $archive_id (gocryptfs)"
            post_mount_action "$mount_point"
            log "Archive successfully mounted:"
            log "  $archive_id | $archive_type | $archive_description | $archive_path -> $mount_point"
            ;;
        ecryptfs)
            [ -z "$mount_point" ] && error_exit "Configuration error: ARCHIVE_${archive_id}_MOUNTPOINT is not set or empty."
            [ -d "$mount_point" ] || mkdir -p "$mount_point"
            mount_ecryptfs "$archive_id" "$archive_path" "$mount_point"
            post_mount_action "$mount_point"
            log "Archive successfully mounted:"
            log "  $archive_id | $archive_type | $archive_description | $archive_path -> $mount_point"
            ;;
        luks)
            [ -z "$mount_point" ] && error_exit "Configuration error: ARCHIVE_${archive_id}_MOUNTPOINT is not set or empty."
            [ -d "$mount_point" ] || mkdir -p "$mount_point"
            mount_luks "$archive_id" "$archive_path" "$mount_point"
            post_mount_action "$mount_point"
            log "Archive successfully mounted:"
            log "  $archive_id | $archive_type | $archive_description | $archive_path -> $mount_point"
            ;;
        KeePassXC)
            [ -z "$KEEPASSXC_CMD" ] && error_exit "KeePassXC path not set!"
            start_application "$KEEPASSXC_CMD" "$archive_id" "$archive_path" "./keepassxc.log"
            log "Application successfully started for archive:"
            log "  $archive_id | $archive_type | $archive_description | $archive_path"
            ;;
        *)
            error_exit "Unknown archive type: $archive_type"
            ;;
    esac

    # Lockfile is created for gocryptfs, ecryptfs, and CryptomatorCLI.
    if [[ "$archive_type" == "gocryptfs" || "$archive_type" == "ecryptfs" || "$archive_type" == "CryptomatorCLI" ]]; then
        if [ -n "$LOCKFILE_SUFFIX" ]; then
            printf "%s - %s\n" "$(hostname)" "$(date)" > "$archive_path/$LOCKFILE_SUFFIX" \
                || warn "Could not write lockfile: $archive_path/$LOCKFILE_SUFFIX"
        fi
    fi
}

# Unmount function
unmount_archive() {
    local archive_id="$1"
    local mount_point
    mount_point=$(get_absolute_path "$(get_config_value "ARCHIVE_${archive_id}_MOUNTPOINT")")
    local archive_path
    archive_path=$(get_absolute_path "$(get_config_value "ARCHIVE_${archive_id}_PATH")")
    local archive_type
    archive_type=$(get_config_value "ARCHIVE_${archive_id}_TYPE")

    if ! is_mounted "$mount_point"; then
        log "Archive $archive_id is not mounted."
        exit 0
    fi

    log "Unmounting $archive_id"
    case "$archive_type" in
        Cryptomator)
            warn "Cryptomator archives are closed via the Cryptomator app."
            ;;
        CryptomatorCLI)
            "$CRYPTOMATOR_CLI_CMD" lock "$mount_point" || error_exit "Error unmounting $archive_id (CryptomatorCLI)"
            ;;
        gocryptfs)
            fusermount -u "$mount_point" || umount "$mount_point" || diskutil unmount "$mount_point" || error_exit "Error unmounting $archive_id (gocryptfs)"
            ;;
        ecryptfs)
            require_root
            fusermount -u "$mount_point" || umount "$mount_point" || diskutil unmount "$mount_point" || error_exit "Error unmounting $archive_id (ecryptfs)"
            ;;
        luks)
            unmount_luks "$archive_id" "$mount_point"
            ;;
        KeePassXC)
            warn "KeePassXC archives are closed via the KeePassXC app."
            exit 0
            ;;
        *)
            error_exit "Unknown archive type: $archive_type"
            ;;
    esac

    # Remove lockfile if present.
    if [ -n "$LOCKFILE_SUFFIX" ]; then
        rm -f -- "$archive_path/$LOCKFILE_SUFFIX"
    fi
    log "Archive $archive_id successfully unmounted."
}

# List all archives
list_archives() {
    local long_format=false
    local ok_filter=false

    # Parameter auswerten: "long" oder "ok"
    if [[ "$1" == "long" ]]; then
        long_format=true
    elif [[ "$1" == "ok" ]]; then
        ok_filter=true
    fi

    declare -A archive_type
    declare -A archive_description
    declare -A archive_path
    declare -A archive_block
    declare -A archive_status

    declare -A group_desc
    declare -a group_order
    declare -A groups

    # Subfunction: Formats and prints all archives within a group
    print_group() {
        local group_id="$1"
        local archive_ids_str="$2"
        local long_format="$3"

        local header
        if [ "$group_id" == "Uncategorized" ]; then
            header="Uncategorized"
        else
            header="${group_desc[$group_id]}"
            [ -z "$header" ] && header="Uncategorized ($group_id)"
        fi

        echo
        echo -e "${BLUE}### $header ###${NC}"

        local id
        for id in $archive_ids_str; do
            local color_id color_status
            if $COLOR_ENABLED; then
                if [ -z "${archive_path[$id]}" ]; then
                    color_id="$RED"
                    color_status="$RED"
                elif [ "${archive_status[$id]}" != "OK" ]; then
                    color_id="$ORANGE"
                    color_status="$ORANGE"
                else
                    color_id="$GREEN"
                    color_status="$GREEN"
                fi
            else
                color_id=""
                color_status=""
            fi

            if $long_format; then
                printf "${color_id}%-4s ${NC}| %-20s | %s\n" \
                    "$id" "${archive_type[$id]}" "${archive_description[$id]}"
                printf "  | %s | ${color_status}%s${NC}\n" \
                    "${archive_path[$id]}" "${archive_status[$id]}"
            else
                local trimmed_description
                trimmed_description=$(printf "%-20s" "${archive_description[$id]}" | cut -c1-20)
                printf "${color_id}%-4s${NC} | %-14s | %s | %s | ${color_status}%s${NC}\n" \
                    "$id" "${archive_type[$id]}" "$trimmed_description" \
                    "${archive_path[$id]}" "${archive_status[$id]}"
            fi
        done
    }

    # Step 1: Load archive IDs und deren Daten
    local id
    readarray -t archive_ids < <(
        grep -E "^ARCHIVE_[^_]+_TYPE=" "$CONFIG_FILE" \
        | sed -E 's/^ARCHIVE_([^_]+)_TYPE=.*/\1/' \
        | sort -u
    )

    for id in "${archive_ids[@]}"; do
        archive_type["$id"]="$(get_config_value "ARCHIVE_${id}_TYPE")"
        archive_description["$id"]="$(get_config_value "ARCHIVE_${id}_DESCRIPTION")"
        archive_path["$id"]="$(get_absolute_path "$(get_config_value "ARCHIVE_${id}_PATH")")"
        archive_block["$id"]="$(get_config_value "ARCHIVE_${id}_BLOCK")"

        if [ -z "${archive_path[$id]}" ]; then
            archive_status["$id"]="ARCHIVE_${id}_PATH not set"
        else
            local ls_output
            ls_output=$(ls "${archive_path[$id]}" 2>&1)
            if [ $? -eq 0 ]; then
                archive_status["$id"]="OK"
            else
                archive_status["$id"]="$(echo "${ls_output##*:}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            fi
        fi

        # Bei 'ok_filter' nur Status OK behalten
        if $ok_filter && [ "${archive_status[$id]}" != "OK" ]; then
            unset archive_type["$id"] archive_description["$id"] archive_path["$id"] archive_block["$id"] archive_status["$id"]
            continue
        fi
    done

    # Step 2: Blocks (Gruppen) einlesen
    while IFS='=' read -r key value; do
        local grp_id="${key#ARCHIVE_BLOCK_}"
        group_desc["$grp_id"]="$value"
        group_order+=("$grp_id")
    done < <(grep -E "^ARCHIVE_BLOCK_" "$CONFIG_FILE")

    # Step 3: Assign archives to groups
    for id in "${archive_ids[@]}"; do
        # Übersprungene IDs (bei ok_filter) haben kein archive_block und kein archive_type
        [ -z "${archive_block[$id]}" ] && continue

        local blk="${archive_block[$id]}"
        if [ -z "$blk" ] || [ -z "${group_desc[$blk]}" ]; then
            blk="Uncategorized"
        fi
        if [ -n "${groups[$blk]}" ]; then
            groups[$blk]+=" $id"
        else
            groups[$blk]="$id"
        fi
    done

    # Unkategorisierte am Ende, falls vorhanden
    if [ -n "${groups[Uncategorized]}" ]; then
        local found=false
        for grp in "${group_order[@]}"; do
            [ "$grp" == "Uncategorized" ] && found=true
        done
        $found || group_order+=("Uncategorized")
    fi

    # Step 4: Ausgabe pro Block, leere Blöcke automatisch übersprungen
    for grp in "${group_order[@]}"; do
        [ -n "${groups[$grp]}" ] && print_group "$grp" "${groups[$grp]}" "$long_format"
    done
}

get_script_path() {
    local source="$0"
    local resolved

    # Falls über alias oder PATH ausgeführt
    if [[ "$source" != /* ]]; then
        source="$(command -v "$source")"
    fi

    # Folge Symlinks bis zur echten Datei
    while [ -h "$source" ]; do
        resolved="$(readlink "$source")"
        if [[ "$resolved" == /* ]]; then
            source="$resolved"
        else
            source="$(dirname "$source")/$resolved"
        fi
    done

    realpath "$source"
}

update_script() {
    local github_repo="cross7de/arcman"
    local repo_url="https://github.com/$github_repo"

    # Remote-Dateiname im Repo (lokaler Name ist egal)
    local upstream_script="archive-manager.sh"

    local latest_version latest_tag local_version
    local_version="$VERSION"

    log "Checking for updates..."
    log "Fetching latest version from: https://api.github.com/repos/$github_repo/tags"

    # Get the latest version tag from GitHub with safe error handling
    latest_tag=$(curl --fail --silent --show-error \
        "https://api.github.com/repos/$github_repo/tags" \
        | grep -o '"name": *"v[0-9]*\.[0-9]*\.[0-9]*"' \
        | head -n1 | cut -d'"' -f4)
    retVal=$?

    if [ $retVal -ne 0 ] || [ -z "$latest_tag" ]; then
        log "Failed to fetch latest version from GitHub or no version found."
        return 1
    fi

    latest_version="${latest_tag#v}"  # Remove leading "v" if present

    log "Current version: $local_version"
    log "Latest version: $latest_version"

    # Compare versions
    if [ "$(printf '%s\n' "$latest_version" "$local_version" | sort -V | tail -n1)" == "$local_version" ]; then
        log "You are already using the latest version."
        return 0
    fi

    log "Updating script to version $latest_version..."

    # Besser: direkt von raw.githubusercontent.com und vom Tag laden
    local script_url="https://raw.githubusercontent.com/$github_repo/$latest_tag/$upstream_script"
    log "Downloading new script from: $script_url"

    local current_script
    current_script=$(get_script_path)

    # Backup current script
    local backup_file
    backup_file="${current_script}.bkp"
    cp "$current_script" "$backup_file" || error_exit "Failed to create backup."

    # Download new version with error handling
    if ! curl -L -A "Mozilla/5.0" --fail --silent --show-error \
         -o "${current_script}.tmp" "$script_url"; then
        error_exit "Failed to download latest version from: $script_url"
    fi

    # Verify script integrity (optional)
    if ! grep -q 'VERSION=' "${current_script}.tmp"; then
        error_exit "Downloaded script is invalid. Update aborted."
    fi

    # Replace old script with new version
    mv "${current_script}.tmp" "$current_script" || error_exit "Failed to apply update."
    chmod +x "$current_script"

    log "Update successful! New version: $latest_version"
}

# Find and set the configuration file path (without sourcing it)
set_config_path() {
    # Highest priority: configuration file provided via parameter
    if [ -n "$CONFIG_FILE" ]; then
        if [ -f "$CONFIG_FILE" ]; then
            echo "Configuration file set to: $CONFIG_FILE"
            return
        else
            error_exit "The specified configuration file was not found: $CONFIG_FILE"
        fi
    fi

    local candidates=(
        "./archive-manager.conf"
        "$HOME/.local/share/archive-manager/archive-manager.conf"
        "/etc/archive-manager/archive-manager.conf"
    )

    for candidate in "${candidates[@]}"; do
        if [ -f "$candidate" ]; then
            CONFIG_FILE="$candidate"
            echo "Configuration file set to: $CONFIG_FILE"
            return
        fi
    done

    error_exit "No configuration file found. Searched in: ${candidates[*]}"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config)
                if [[ -n "$2" ]]; then
                    CONFIG_FILE="$2"
                    shift 2
                else
                    error_exit "Option -c|--config requires an argument."
                fi
                ;;
            -h|--help)
                usage
                ;;
            -v|--version)
                echo "Version: $VERSION"
                exit 0
                ;;
            *)
                ARCHIVE_ARGS+=("$1")
                shift
                ;;
        esac
    done
}

# Initialization function
init() {

    VERSION="1.4.2"

    # Check if colors are supported (TERM must not be "dumb" and must be outputting to a terminal)
    if [ -t 1 ] && [[ "$TERM" != "dumb" ]]; then
        COLOR_ENABLED=true
    else
        COLOR_ENABLED=false
    fi

    # ANSI color codes (only used if COLOR_ENABLED=true)
    RED='\033[0;31m'     # Red for errors
    ORANGE='\033[1;33m'  # Bright orange for warnings
    GREEN='\033[0;32m'   # Green for success messages
    BLUE='\033[1;34m'    # Blue for other informational messages, such as archive blocks
    NC='\033[0m'         # Reset (no color)

    LOG_FILE="./archive-manager.log"
    : > "$LOG_FILE"

    CONFIG_FILE="" # will be initialized in parse_args
    parse_args "$@"
    set_config_path

    # Load configuration values
    LOCKFILE_SUFFIX=$(get_config_value "LOCKFILE_SUFFIX")
    LOCKFILE_SUFFIX=$(printf "%s" "$LOCKFILE_SUFFIX" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -z "$LOCKFILE_SUFFIX" ]; then
        LOCKFILE_SUFFIX=".arcman.lock"
        warn "LOCKFILE_SUFFIX not set in config; using default: $LOCKFILE_SUFFIX"
    fi
    if [[ "$LOCKFILE_SUFFIX" == */* ]]; then
        error_exit "LOCKFILE_SUFFIX must be a filename (no '/'): $LOCKFILE_SUFFIX"
    fi

    # Define tools with absolute paths
    KEEPASSXC_CMD=$(get_config_value "KEEPASSXC")
    CRYPTOMATOR_CMD=$(get_config_value "CRYPTOMATOR")
    CRYPTOMATOR_CLI_CMD=$(get_config_value "CRYPTOMATOR_CLI")
    GOCRYPTFS_CMD=$(get_config_value "GOCRYPTFS")
    ECRYPTFS_CMD=$(get_config_value "ECRYPTFS")

    # Verify tool paths
    check_tool_path "KEEPASSXC" "$KEEPASSXC_CMD"
    check_tool_path "CRYPTOMATOR" "$CRYPTOMATOR_CMD"
    check_tool_path "CRYPTOMATOR_CLI" "$CRYPTOMATOR_CLI_CMD"
    check_tool_path "GOCRYPTFS" "$GOCRYPTFS_CMD"
    check_tool_path "ECRYPTFS" "$ECRYPTFS_CMD"
}

# Main control function
main() {
    #if [ ${#ARCHIVE_ARGS[@]} -eq 0 ]; then
    if [ $# -eq 0 ]; then
        usage
    fi

    case "${ARCHIVE_ARGS[0]}" in
        mount)
            [ -z "${ARCHIVE_ARGS[1]}" ] && usage
            mount_archive "${ARCHIVE_ARGS[1]}"
            ;;
        unmount)
            [ -z "${ARCHIVE_ARGS[1]}" ] && usage
            unmount_archive "${ARCHIVE_ARGS[1]}"
            ;;
        list)
            list_archives "${ARCHIVE_ARGS[1]}"
            ;;
        update)
            update_script
            ;;
        *)
            usage
            ;;
    esac
}

init "$@"
main "$@"

