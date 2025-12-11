#!/usr/local/bin/perl
use strict;
use warnings;
use POSIX 'strftime';
use File::Basename;
use File::Copy;

# ============ CONFIGURATION ============
my @ALLOW_PHONES = ("79991234567", "79991234568");
my $COMMAND_CHAR = "#";
my $SEND_BACK_REPORT = "YES";
my $MAX_SMS_LENGTH = 900;
my $MAX_LOG_LENGTH = 2000;
my $SENDSMS = "/usr/local/bin/sendsms";
my $COMMAND_MODE = "ALL";  # "ALL" or "LIST"
my $MAX_LOG_SIZE_KB = 512;
my $LOG_BACKUP_COUNT = 7;
my $USE_GZIP = "NO";

# ALWAYS declare @ALLOWED_COMMANDS, even if empty
my @ALLOWED_COMMANDS = ();  # Empty by default

# For LIST mode, uncomment and fill:
# @ALLOWED_COMMANDS = (
#     "date",
#     "uptime",
#     "df -h",
#     "systemctl status sshd",
#     "ping -c 3 8.8.8.8",
#     "tail -20 /var/log/syslog",
#     "service --status-all",
#     "/root/scripts/reboot_server.sh"
# );

# ============ PATH CONSTANTS ============
my $SMS_LOG = "/var/tmp/sms.log";
my $CTRL_LOG = "/var/log/smsctrl.log";
my $COMMAND_LOG = "/var/log/sms_commands.log";

# ============ LOGGING FUNCTIONS ============
sub log_message {
    my ($message) = @_;
    my $timestamp = strftime("%b %d %Y %H:%M:%S", localtime);
    my $hostname = `hostname -s`;
    chomp $hostname;
    open(my $fh, '>>', $CTRL_LOG) or return;
    print $fh "$timestamp $hostname $message\n";
    close $fh;
}

sub rotate_logs {
    my ($logfile) = @_;
    return unless -f $logfile;
    
    my $max_size_bytes = $MAX_LOG_SIZE_KB * 1024;
    my $file_size = -s $logfile;
    
    return if $file_size <= $max_size_bytes;
    
    log_message("Rotating log file: $logfile (size: " . int($file_size/1024) . "KB, limit: ${MAX_LOG_SIZE_KB}KB)");
    
    my $timestamp = strftime("%Y%m%d_%H%M%S", localtime);
    my $archive_file = "$logfile.$timestamp";
    
    if ($USE_GZIP eq "YES" && system("which gzip > /dev/null 2>&1") == 0) {
        if (system("gzip -c '$logfile' > '${archive_file}.gz' 2>/dev/null") == 0) {
            $archive_file .= ".gz";
            log_message("Created compressed log archive: $archive_file");
        } else {
            log_message("ERROR: Failed to compress log file, creating uncompressed backup");
            copy($logfile, $archive_file) or warn "Copy failed: $!";
        }
    } else {
        copy($logfile, $archive_file) or warn "Copy failed: $!";
        log_message("Created uncompressed log backup: $archive_file");
    }
    
    # Clear current log
    open(my $fh, '>', $logfile);
    close $fh;
    
    # Clean old backups
    cleanup_old_backups($logfile);
}

sub cleanup_old_backups {
    my ($logfile) = @_;
    my $dir = dirname($logfile);
    my $base = basename($logfile);
    
    my @backups = glob("$dir/$base.*");
    return unless @backups;
    
    # Sort by modification time (newest first)
    @backups = sort { -M $b <=> -M $a } @backups;
    
    if (@backups > $LOG_BACKUP_COUNT) {
        for (my $i = $LOG_BACKUP_COUNT; $i < @backups; $i++) {
            unlink $backups[$i] or warn "Failed to delete $backups[$i]: $!";
            log_message("Removed old log backup: $backups[$i]");
        }
    }
}

# ============ SMS LOGGING FUNCTION ============
sub log_sms {
    my ($file) = @_;
    my $timestamp = strftime("%b %d %Y %H:%M:%S", localtime);
    
    # Ensure directory exists
    system("mkdir -p " . dirname($SMS_LOG) . " 2>/dev/null");
    
    open(my $sms_fh, '>>', $SMS_LOG) or warn "Cannot open SMS log: $!";
    print $sms_fh "====== SMS received: $timestamp ======\n";
    
    # Extract and log sender info clearly
    my $sender_info = extract_sender($file);
    if ($sender_info) {
        print $sms_fh "From: $sender_info\n";
    }
    
    # Try to read and log the message properly
    my $is_ucs2 = 0;
    
    # Check if it's UCS2 encoded
    open(my $in_fh, '<', $file) or do {
        print $sms_fh "[Cannot open file for reading]\n\n";
        close $sms_fh;
        return;
    };
    
    my $in_body = 0;
    my $body_content = "";
    
    while (my $line = <$in_fh>) {
        chomp $line;
        
        # Check for encoding marker
        if ($line =~ /Alphabet:\s*UCS2/) {
            $is_ucs2 = 1;
            next;
        }
        
        # Skip empty line that separates headers from body
        if ($line eq "" && !$in_body) {
            $in_body = 1;
            next;
        }
        
        if (!$in_body) {
            # Log important headers (not all of them)
            if ($line =~ /^(Received:|Sent:|Subject:)/) {
                print $sms_fh "$line\n";
            }
        } else {
            # This is the message body
            $body_content .= $line . "\n";
        }
    }
    close $in_fh;
    
    # Process message body based on encoding
    if ($body_content) {
        print $sms_fh "\nMessage body:\n";
        
        if ($is_ucs2) {
            if (system("which iconv > /dev/null 2>&1") == 0) {
                # Write body to temp file for iconv processing
                my $temp_file = "/tmp/sms_temp_$$";
                open(my $temp_fh, '>', $temp_file);
                print $temp_fh $body_content;
                close $temp_fh;
                
                # Convert UCS2 to UTF-8
                my $converted = `iconv -f UCS-2 -t UTF-8 '$temp_file' 2>/dev/null`;
                unlink $temp_file;
                
                if ($converted) {
                    print $sms_fh $converted;
                } else {
                    print $sms_fh "[UCS2 message - conversion failed]\n";
                    print $sms_fh "[Raw hex dump]:\n";
                    # Show hex representation instead of binary garbage
                    for (my $i = 0; $i < length($body_content); $i += 16) {
                        my $chunk = substr($body_content, $i, 16);
                        my $hex = unpack('H*', $chunk);
                        $hex =~ s/(.{2})/$1 /g;
                        print $sms_fh sprintf("%04x: %-48s\n", $i, $hex);
                    }
                }
            } else {
                print $sms_fh "[UCS2 message, but iconv not available]\n";
                print $sms_fh "[Install iconv package for proper decoding]\n";
            }
        } else {
            # Regular text - just print it
            print $sms_fh $body_content;
        }
    } else {
        print $sms_fh "[No message body found]\n";
    }
    
    print $sms_fh "\n";
    close $sms_fh;
}

# Helper function to escape shell commands safely
sub shell_escape {
    my ($command) = @_;
    $command =~ s/'/'\\''/g;
    return "'$command'";
}

# ============ SAFE COMMAND EXECUTION ============
sub safe_execute {
    my ($command) = @_;
    
    # Check for dangerous patterns
    my @dangerous_patterns = ("rm -rf", "dd ", "mkfs", "fdisk");
    foreach my $pattern (@dangerous_patterns) {
        if ($command =~ /\Q$pattern\E/) {
            return "ERROR: Dangerous command pattern '$pattern' is blocked";
        }
    }
    
    # Use Perl's built-in alarm for timeout
    my $timeout_seconds = 60;
    if ($command =~ /ping|curl|wget|nc/) {
        $timeout_seconds = 30;
    }
    
    my $output = "";
    
    eval {
        local $SIG{ALRM} = sub { die "TIMEOUT\n" };
        alarm($timeout_seconds);
        
        # Execute command using /bin/sh explicitly
        my $escaped_cmd = shell_escape($command);
        $output = `/bin/sh -c $escaped_cmd 2>&1`;
        
        alarm(0);
    };
    
    alarm(0);  # Clear any pending alarm
    
    if ($@) {
        if ($@ eq "TIMEOUT\n") {
            return "ERROR: Execution timeout ($timeout_seconds seconds)";
        } else {
            return "ERROR: Failed to execute command: $@";
        }
    }
    
    # Get exit code
    my $exit_code = $? >> 8;
    
    # Add exit code to output for non-zero exits
    if ($exit_code != 0) {
        $output = "Exit code: $exit_code\n" . $output;
    }
    
    return $output;
}

# ============ EXTRACT SENDER ============
sub extract_sender {
    my ($file) = @_;
    open(my $fh, '<', $file) or return "";
    
    while (my $line = <$fh>) {
        if ($line =~ /^From:\s*(.+)/) {
            close $fh;
            my $sender = $1;
            $sender =~ s/^\s+|\s+$//g;  # trim whitespace
            return $sender;
        }
    }
    
    close $fh;
    
    # Try strings for binary files
    if (-B $file) {
        my $sender = `strings '$file' 2>/dev/null | grep -m1 '^From: '`;
        if ($sender =~ /^From:\s*(.+)/) {
            my $result = $1;
            $result =~ s/^\s+|\s+$//g;
            return $result;
        }
    }
    
    return "";
}

# ============ MAIN PROCESSING ============
sub process_received {
    my ($file) = @_;
    
    # Extract sender
    my $phone = extract_sender($file);
    if (!$phone) {
        log_message("ERROR: Failed to extract sender information from $file");
        return 0;
    }
    
    # Check if it's a phone number or service message
    if ($phone !~ /^[0-9+][0-9]{10,14}$/) {
        log_message("INFO: Service SMS received from: '$phone'");
        return 1;
    }
    
    # Check if number is allowed
    my $allowed = 0;
    foreach my $allowed_phone (@ALLOW_PHONES) {
        if ($phone eq $allowed_phone) {
            $allowed = 1;
            last;
        }
    }
    
    if (!$allowed) {
        log_message("BLOCKED: SMS from unauthorized number $phone");
        return 1;
    }
    
    log_message("Processing SMS from authorized number: $phone");
    
    # Extract command
    my $command = "";
    open(my $fh, '<', $file) or return 0;
    
    while (my $line = <$fh>) {
        if ($line =~ /\Q$COMMAND_CHAR\E(.+)/) {
            $command = $1;
            $command =~ s/^\s+|\s+$//g;
            last;
        }
    }
    close $fh;
    
    if (!$command) {
        log_message("WARNING: SMS from $phone doesn't contain command after $COMMAND_CHAR");
        return 1;
    }
    
    # Command validation based on mode
    my $output = "";
    if ($COMMAND_MODE eq "LIST") {
        my $found = 0;
        foreach my $allowed_cmd (@ALLOWED_COMMANDS) {
            if ($command eq $allowed_cmd) {
                $found = 1;
                last;
            }
        }
        
        if ($found) {
            $output = safe_execute($command);
        } else {
            $output = "ERROR: Command '$command' is not allowed";
            log_message("SECURITY: Blocked unauthorized command '$command' from $phone");
        }
    } else { # ALL mode
        $output = safe_execute($command);
        # No warning for ALL mode - trusted administrators know what they're doing
    }
    
    # Log command execution
    my $timestamp = strftime("%b %d %Y %H:%M:%S", localtime);
    my $log_output = $output;
    if (length($log_output) > $MAX_LOG_LENGTH) {
        $log_output = substr($log_output, 0, $MAX_LOG_LENGTH) . "... [log truncated to $MAX_LOG_LENGTH chars]";
    }
    
    open(my $cmd_fh, '>>', $COMMAND_LOG) or warn "Cannot open command log: $!";
    print $cmd_fh "=== $timestamp ===\n";
    print $cmd_fh "Sender: $phone\n";
    print $cmd_fh "Command: $command\n";
    print $cmd_fh "Output (" . length($output) . " characters, logged " . length($log_output) . "):\n";
    print $cmd_fh "$log_output\n\n";
    close $cmd_fh;
    
    # Send response if needed
    if ($SEND_BACK_REPORT eq "YES") {
        my $sms_output = $output;
        if (length($sms_output) > $MAX_SMS_LENGTH) {
            $sms_output = substr($sms_output, 0, $MAX_SMS_LENGTH) . "... [output truncated]";
        }
        
        log_message("Preparing SMS response to $phone: " . length($sms_output) . " chars");
        
        if (system("'$SENDSMS' '$phone' '$sms_output' > /dev/null 2>&1") == 0) {
            log_message("Response sent: $phone, length: " . length($sms_output) . " characters");
        } else {
            log_message("ERROR: Failed to send response to $phone");
        }
    }
    
    # Delete the file
    unlink $file or warn "Failed to delete $file: $!";
    log_message("Deleted file: $file");
    
    return 1;
}

# ============ MAIN ============
# Initialize logs
system("mkdir -p " . dirname($SMS_LOG) . " 2>/dev/null");
system("mkdir -p " . dirname($CTRL_LOG) . " 2>/dev/null");
system("mkdir -p " . dirname($COMMAND_LOG) . " 2>/dev/null");
system("touch '$SMS_LOG' '$CTRL_LOG' '$COMMAND_LOG' 2>/dev/null");

rotate_logs($CTRL_LOG);
rotate_logs($COMMAND_LOG);
rotate_logs($SMS_LOG);

# Check arguments
if (@ARGV < 2) {
    log_message("ERROR: Insufficient parameters. Usage: $0 <status> <file>");
    print STDERR "ERROR: Insufficient parameters. Usage: $0 <status> <file>\n";
    exit 1;
}

my $status = $ARGV[0];
my $file = $ARGV[1];

if (!-f $file) {
    log_message("ERROR: File not found: $file");
    print STDERR "ERROR: File not found: $file\n";
    exit 1;
}

if ($status eq "RECEIVED") {
    # Log SMS to SMS_LOG first
    log_sms($file);
    
    # Process the SMS
    if (!process_received($file)) {
        log_message("ERROR: Failed to process received SMS");
        exit 1;
    }
} else {
    # Silently ignore SENT and other statuses
    exit 0;
}

log_message("Processing completed for status: $status");
exit 0;