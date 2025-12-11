#!/usr/local/bin/bash
set -euo pipefail

# ============ CONFIGURATION ============

# 1. ALLOWED PHONE NUMBERS
readonly ALLOW_PHONES=("79991234567" "79991234568")

# 2. COMMAND CHARACTER
readonly COMMAND_CHAR="#"

# 3. SEND BACK EXECUTION REPORT?
readonly SEND_BACK_REPORT="YES"

# 4. MAXIMUM SMS RESPONSE LENGTH (characters)
readonly MAX_SMS_LENGTH=900

# 5. MAXIMUM LOG LENGTH (characters) - prevents disk filling
readonly MAX_LOG_LENGTH=2000

# 6. PATH TO sendsms (standard in smstools)
readonly SENDSMS="/usr/local/bin/sendsms"

# 7. COMMAND PERMISSION MODE (choose ONE option!)
# 
# Option A: ALLOW ANY COMMANDS (emergency management mode)
COMMAND_MODE="ALL"
#
# Option B: ALLOW ONLY SPECIFIED COMMANDS
# COMMENT OUT the line above and UNCOMMENT these two:
# COMMAND_MODE="LIST"
# ALLOWED_COMMANDS=(
#     "date"
#     "uptime"
#     "who"
#     "w"
#     "df -h"
#     "free -h"
#     "systemctl status sshd"
#     "systemctl restart sshd"
#     "ping -c 3 8.8.8.8"
#     "tail -20 /var/log/syslog"
#     "service --status-all"
#     "/root/scripts/reboot_server.sh"
#     # Add your own commands below:
#     # "your_command"
# )

# 8. LOG ROTATION SETTINGS
readonly MAX_LOG_SIZE_KB=512
readonly LOG_BACKUP_COUNT=7
readonly USE_GZIP="NO"

# ============ END OF CONFIGURATION ============

# Path constants
readonly SMS_LOG="/var/tmp/sms.log"
readonly CTRL_LOG="/var/log/smsctrl.log"
readonly COMMAND_LOG="/var/log/sms_commands.log"

# Validate configuration
validate_configuration() {
    if [[ "$COMMAND_MODE" == "LIST" && -z "${ALLOWED_COMMANDS+x}" ]]; then
        echo "ERROR: COMMAND_MODE is LIST but ALLOWED_COMMANDS is not defined" >&2
        exit 1
    fi
    
    if [[ "$USE_GZIP" != "YES" && "$USE_GZIP" != "NO" ]]; then
        echo "ERROR: USE_GZIP must be either 'YES' or 'NO'" >&2
        exit 1
    fi
}

# Log rotation function with numbering
rotate_logs() {
    local logfile="$1"
    local max_size_bytes=$((MAX_LOG_SIZE_KB * 1024))
    
    if [[ ! -f "$logfile" ]] || [[ ! -s "$logfile" ]]; then
        return 0
    fi
    
    local file_size
    if file_size=$(stat -c%s "$logfile" 2>/dev/null); then
        :
    elif file_size=$(wc -c < "$logfile" 2>/dev/null); then
        :
    else
        log "WARNING: Could not determine size of $logfile"
        return 1
    fi
    
    if [[ $file_size -le $max_size_bytes ]]; then
        return 0
    fi
    
    log "Rotating log file: $logfile (size: $((file_size/1024))KB, limit: ${MAX_LOG_SIZE_KB}KB)"
    
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local archive_file="${logfile}.${timestamp}"
    
    if [[ "$USE_GZIP" == "YES" ]] && command -v gzip > /dev/null 2>&1; then
        if gzip -c "$logfile" > "${archive_file}.gz" 2>/dev/null; then
            archive_file="${archive_file}.gz"
            log "Created compressed log archive: $archive_file"
        else
            log "ERROR: Failed to compress log file, creating uncompressed backup"
            cp "$logfile" "$archive_file" 2>/dev/null || true
        fi
    else
        if [[ "$USE_GZIP" == "YES" ]] && ! command -v gzip > /dev/null 2>&1; then
            log "WARNING: gzip requested but not available, creating uncompressed backup"
        fi
        
        cp "$logfile" "$archive_file" 2>/dev/null || true
        log "Created uncompressed log backup: $archive_file"
    fi
    
    > "$logfile"
    
    cleanup_old_backups "$logfile"
    
    return 0
}

# Clean up old backup files
cleanup_old_backups() {
    local logfile="$1"
    
    local backups=()
    
    if [[ -d "$(dirname "$logfile")" ]]; then
        local base_name=$(basename "$logfile")
        local dir_name=$(dirname "$logfile")
        
        while IFS= read -r -d '' file; do
            if [[ "$file" != "$logfile" ]]; then
                backups+=("$file")
            fi
        done < <(find "$dir_name" -maxdepth 1 -name "${base_name}.*" -type f -print0 2>/dev/null)
    fi
    
    local sorted_backups=()
    if [[ ${#backups[@]} -gt 0 ]]; then
        local find_output
        if find_output=$(find "$(dirname "$logfile")" -maxdepth 1 -name "$(basename "$logfile").*" -type f ! -name "$(basename "$logfile")" -printf "%T@ %p\0" 2>/dev/null | sort -zrn); then
            while IFS= read -r -d '' line; do
                local file="${line#* }"
                sorted_backups+=("$file")
            done < <(echo -n "$find_output")
        fi
        
        if [[ ${#sorted_backups[@]} -eq 0 ]]; then
            mapfile -t sorted_backups < <(printf '%s\n' "${backups[@]}" | sort -r)
        fi
    fi
    
    if [[ ${#sorted_backups[@]} -gt $LOG_BACKUP_COUNT ]]; then
        local to_delete=$(( ${#sorted_backups[@]} - LOG_BACKUP_COUNT ))
        for ((i=LOG_BACKUP_COUNT; i<${#sorted_backups[@]}; i++)); do
            rm -f "${sorted_backups[$i]}" 2>/dev/null || true
            log "Removed old log backup: ${sorted_backups[$i]}"
        done
    fi
}

# Check for required dependencies
check_dependencies() {
    local deps=("grep" "cut" "xargs" "head" "sed" "mkdir" "touch" "rm" "stat")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" > /dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo "ERROR: Missing required dependencies: ${missing_deps[*]}" >&2
        log "CRITICAL: Missing dependencies: ${missing_deps[*]}"
        exit 1
    fi
    
    if [[ ! -f "$SENDSMS" ]]; then
        echo "ERROR: sendsms not found at $SENDSMS" >&2
        log "CRITICAL: sendsms not found at $SENDSMS"
        exit 1
    fi
    
    if [[ ! -x "$SENDSMS" ]]; then
        echo "ERROR: sendsms is not executable at $SENDSMS" >&2
        log "CRITICAL: sendsms is not executable"
        exit 1
    fi
    
    if ! command -v timeout > /dev/null 2>&1; then
        log "WARNING: 'timeout' command not found - commands will run without timeout"
    fi
    
    if ! command -v iconv > /dev/null 2>&1; then
        log "WARNING: 'iconv' command not found - UCS2 messages may not decode properly"
    fi
    
    if [[ "$USE_GZIP" == "YES" ]] && ! command -v gzip > /dev/null 2>&1; then
        log "WARNING: USE_GZIP=YES but gzip command not found - backups will be uncompressed"
    fi
}

# Logging function
log() {
    local message="$*"
    local log_entry="$(date '+%b %d %Y %H:%M:%S') $(hostname -s) $message"
    echo "$log_entry" >> "$CTRL_LOG" 2>/dev/null || true
}

# Command logging function
log_command() {
    local phone="$1"
    local command="$2"
    local output="$3"
    local timestamp=$(date '+%b %d %Y %H:%M:%S')
    
    local log_output="$output"
    if [[ ${#log_output} -gt $MAX_LOG_LENGTH ]]; then
        log_output="${log_output:0:$MAX_LOG_LENGTH}... [log truncated to $MAX_LOG_LENGTH chars]"
    fi
    
    {
        echo "=== $timestamp ==="
        echo "Sender: $phone"
        echo "Command: $command"
        echo "Output (${#output} characters, logged ${#log_output}):"
        echo "$log_output"
        echo ""
    } >> "$COMMAND_LOG" 2>/dev/null || true
}

# Safe command execution with timeout
safe_execute() {
    local command="$1"
    local out
    local exit_code=0
    
    if command -v timeout > /dev/null 2>&1; then
        local timeout_seconds=60
        if [[ "$command" == *"ping"* ]] || [[ "$command" == *"curl"* ]] || [[ "$command" == *"wget"* ]] || [[ "$command" == *"nc"* ]]; then
            timeout_seconds=30
        fi
        
        out=$(timeout $timeout_seconds bash -c "$command" 2>&1)
        exit_code=$?
        
        if [[ $exit_code -eq 124 ]]; then
            out="ERROR: Execution timeout ($timeout_seconds seconds)"
        fi
    else
        log "WARNING: timeout command not found, executing without timeout"
        out=$(bash -c "$command" 2>&1)
        exit_code=$?
    fi
    
    echo "$out"
    return $exit_code
}

# Command validation and execution function
execute_command() {
    local command="$1"
    local phone="$2"
    local out
    
    log "Received command: '$command' from $phone"
    
    case "$COMMAND_MODE" in
        "ALL")
            local dangerous_patterns=("rm -rf" "dd " "mkfs" "fdisk" ":(){:|:&};:")
            for pattern in "${dangerous_patterns[@]}"; do
                if [[ "$command" == *"$pattern"* ]]; then
                    out="ERROR: Dangerous command pattern '$pattern' is blocked"
                    log "BLOCKED: Dangerous command from $phone: '$command'"
                    echo "$out"
                    return 1
                fi
            done
            
            log "WARNING: Executing arbitrary command in ALL mode"
            out=$(safe_execute "$command")
            local exit_code=$?
            
            if [[ $exit_code -eq 124 ]]; then
                log "TIMEOUT: Command '$command' from $phone"
            elif [[ $exit_code -ne 0 ]]; then
                log "EXECUTION ERROR: Command '$command' exited with code $exit_code"
            fi
            ;;
            
        "LIST")
            local allowed=0
            
            for allowed_cmd in "${ALLOWED_COMMANDS[@]}"; do
                if [[ "$command" == "$allowed_cmd" ]]; then
                    allowed=1
                    break
                fi
            done
            
            if [[ $allowed -eq 1 ]]; then
                out=$(safe_execute "$command")
                local exit_code=$?
                
                if [[ $exit_code -eq 124 ]]; then
                    log "TIMEOUT: Command '$command' from $phone"
                elif [[ $exit_code -ne 0 ]]; then
                    log "EXECUTION ERROR: Command '$command' exited with code $exit_code"
                fi
            else
                out="ERROR: Command '$command' is not allowed"
                log "SECURITY: Blocked unauthorized command '$command' from $phone"
            fi
            ;;
            
        *)
            out="ERROR: Invalid COMMAND_MODE in script settings"
            log "CRITICAL ERROR: Invalid COMMAND_MODE"
            ;;
    esac
    
    log_command "$phone" "$command" "$out"
    
    echo "$out"
}

# Extract sender information from SMS file
extract_sender() {
    local file="$1"
    local sender=""
    
    # First try to extract using strings (for binary files)
    sender=$(strings "$file" 2>/dev/null | grep -m1 "^From: " | head -1)
    
    # If strings didn't work, try direct grep with -a flag
    if [[ -z "$sender" ]]; then
        sender=$(grep -a -m1 "^From: " "$file" 2>/dev/null | head -1)
    fi
    
    # If still no result and file might be UCS2 encoded
    if [[ -z "$sender" ]] && grep -q "Alphabet: UCS2" "$file" 2>/dev/null; then
        if command -v iconv > /dev/null 2>&1; then
            sender=$(iconv -f UCS-2 -t UTF-8 "$file" 2>/dev/null | grep -m1 "^From: " | head -1)
        fi
    fi
    
    # Clean up the sender string
    if [[ -n "$sender" ]]; then
        # Remove "From: " prefix and trim whitespace
        sender="${sender#From: }"
        sender=$(echo "$sender" | xargs)
    fi
    
    echo "$sender"
}

# Incoming SMS processing function
process_received() {
    local file="$1"
    local phone allowed=0
    
    # Extract sender's phone number using improved method
    local phone=""
    phone=$(extract_sender "$file")
    
    if [[ -z "$phone" ]]; then
        log "ERROR: Failed to extract sender information from $file"
        return 1
    fi
    
    # Check if extracted sender is empty or just whitespace
    if [[ -z "$phone" ]]; then
        log "WARNING: Empty sender information extracted from $file"
        return 1
    fi
    
    # Check if the extracted information looks like a phone number
    # If it's not a phone number (like "MegaFon"), log it differently
    if [[ ! "$phone" =~ ^[0-9+][0-9]{10,14}$ ]]; then
        # Log service messages clearly
        log "INFO: Service SMS received from: '$phone'"
        return 0
    fi
    
    # Check if the number is allowed
    for allowed_phone in "${ALLOW_PHONES[@]}"; do
        if [[ "$phone" == "$allowed_phone" ]]; then
            allowed=1
            break
        fi
    done
    
    if [[ $allowed -eq 0 ]]; then
        log "BLOCKED: SMS from unauthorized number $phone"
        return 0
    fi
    
    log "Processing SMS from authorized number: $phone"
    
    # Extract the command
    local command=""
    local command_line=""
    
    # Use same extraction method for command as for sender
    local message_text=""
    if grep -q "Alphabet: UCS2" "$file" 2>/dev/null && command -v iconv > /dev/null 2>&1; then
        message_text=$(iconv -f UCS-2 -t UTF-8 "$file" 2>/dev/null)
    else
        message_text=$(cat "$file" 2>/dev/null)
    fi
    
    # Find command character in message text
    if command_line=$(echo "$message_text" | grep -m1 "$COMMAND_CHAR"); then
        command=$(echo "$command_line" | cut -d"$COMMAND_CHAR" -f2-)
    fi
    
    command=$(echo "$command" | xargs)
    
    if [[ -z "$command" ]]; then
        log "WARNING: SMS from $phone doesn't contain command after $COMMAND_CHAR"
        return 0
    fi
    
    # Execute the command
    local full_output
    full_output=$(execute_command "$command" "$phone")
    
    # Send response if needed
    if [[ "$SEND_BACK_REPORT" == "YES" ]]; then
        local sms_output="$full_output"
        if [[ ${#sms_output} -gt $MAX_SMS_LENGTH ]]; then
            sms_output="${sms_output:0:$MAX_SMS_LENGTH}... [output truncated]"
        fi
        
        log "Preparing SMS response to $phone: ${#sms_output} chars (was ${#full_output} chars)"
        
        if "$SENDSMS" "$phone" "$sms_output" > /dev/null 2>&1; then
            log "Response sent: $phone, length: ${#sms_output} characters"
        else
            log "ERROR: Failed to send response to $phone"
        fi
    fi
    
    rm -f "$file"
    log "Deleted file: $file"
    
    return 0
}

# SMS logging function
log_sms() {
    local file="$1"
    local timestamp=$(date '+%b %d %Y %H:%M:%S')
    
    mkdir -p "$(dirname "$SMS_LOG")" 2>/dev/null || true
    
    echo "====== SMS received: $timestamp ======" >> "$SMS_LOG" 2>/dev/null || true
    
    # Extract and log sender info clearly
    local sender_info=$(extract_sender "$file")
    if [[ -n "$sender_info" ]]; then
        echo "From: $sender_info" >> "$SMS_LOG" 2>/dev/null || true
    fi
    
    # Log Received timestamp if available
    {
        head -5 "$file" 2>/dev/null | grep -e "^Received: " 2>/dev/null || true
        echo ""
    } >> "$SMS_LOG" 2>/dev/null || true
    
    # Log message body with UCS2 handling
    if grep -q "Alphabet: UCS2" "$file" 2>/dev/null; then
        if command -v iconv > /dev/null 2>&1; then
            sed -e '1,/^$/ d' "$file" 2>/dev/null | iconv -f UCS-2 -t UTF-8 2>/dev/null >> "$SMS_LOG" 2>/dev/null || true
        else
            echo "[UCS2 message, but iconv not available]" >> "$SMS_LOG"
            sed -e '1,/^$/ d' "$file" 2>/dev/null >> "$SMS_LOG" 2>/dev/null || true
        fi
    else
        sed -e '1,/^$/ d' "$file" 2>/dev/null >> "$SMS_LOG" 2>/dev/null || true
    fi
    
    echo "" >> "$SMS_LOG" 2>/dev/null || true
}

# Initialize log directories and rotate logs
init_logs() {
    mkdir -p "$(dirname "$SMS_LOG")" 2>/dev/null || true
    mkdir -p "$(dirname "$CTRL_LOG")" 2>/dev/null || true
    mkdir -p "$(dirname "$COMMAND_LOG")" 2>/dev/null || true
    
    touch "$SMS_LOG" "$CTRL_LOG" "$COMMAND_LOG" 2>/dev/null || true
    
    rotate_logs "$CTRL_LOG"
    rotate_logs "$COMMAND_LOG"
    rotate_logs "$SMS_LOG"
}

# ============ MAIN PROCESS ============

validate_configuration

check_dependencies

init_logs

if [[ $# -lt 2 ]]; then
    log "ERROR: Insufficient parameters. Usage: $0 <status> <file>"
    echo "ERROR: Insufficient parameters. Usage: $0 <status> <file>" >&2
    exit 1
fi

status="$1"
file="$2"

if [[ ! -f "$file" ]]; then
    log "ERROR: File not found: $file"
    echo "ERROR: File not found: $file" >&2
    exit 1
fi

case "$status" in
    RECEIVED)
        log_sms "$file"
        if ! process_received "$file"; then
            log "ERROR: Failed to process received SMS"
            exit 1
        fi
        ;;
        
    *)
        log "Skipped unknown status: $status"
        exit 0
        ;;
esac

log "Processing completed for status: $status"
exit 0