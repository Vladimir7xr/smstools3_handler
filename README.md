# smstools3_handler

**SMS handler for work with SMS Server Tools 3 (smstools3)**

A set of scripts for executing commands on a server via SMS messages. Solution for basic monitoring and management when SSH or internet access is unavailable (e.g., during network failures).

---

## TABLE OF CONTENTS

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
- [Security](#security)
- [Logging](#logging)
- [Two Script Versions](#two-script-versions)
- [Troubleshooting](#troubleshooting)
- [License](#license)
- [Important Disclaimer](#important-disclaimer)

---

## FEATURES

### Core Functionality

- Execute commands on a server via SMS
- Phone number authorization — only trusted numbers
- Two security modes: `"ALL"` (any command) and `"LIST"` (allowed only)
- Automatic response with command execution results
- UCS2 encoding support for Cyrillic and other alphabets

### Security and Reliability

- Protection against dangerous commands (e.g., `rm -rf`, `dd`, `mkfs`)
- Execution timeouts (60 sec for regular commands, 30 sec for network commands)
- Detailed logging of all operations in three separate logs
- Automatic log rotation with configurable size and optional compression
- Dependency checking at startup

---

## REQUIREMENTS

### Required Software

- **smstools3** (package for working with SMS via modem/GSM module)
- **Bash 4.0+** (for Bash script) or **Perl 5.10+** (for Perl version)
- **GNU Coreutils** (e.g., `grep`, `cut`, `sed`, `xargs`)

### Optional (Recommended)

- **iconv** — for proper UCS2 message handling
- **gzip** — for log archive compression
- **timeout** — for command execution time limiting

---

## INSTALLATION

### Install smstools3

For **Debian/Ubuntu**:
```bash
sudo apt update
sudo apt install smstools
```

For **CentOS/RHEL**:
```bash
sudo yum install smstools
```

For **FreeBSD**:
```bash
sudo pkg install smstools
sudo rehash
```

### Configure smstools3

Add or modify the following line of your `/etc/smsd.conf`:

For **Bash** version:
```
eventhandler = /usr/local/bin/sms_event.sh
```

For **Perl** version:
```
eventhandler = /usr/local/bin/sms_event.pl
```

### Place the Scripts

Clone the repository or copy the files:
```bash
sudo cp sms_event.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/sms_event.sh
```

For the **Perl** version:
```bash
sudo cp sms_event.pl /usr/local/bin/
sudo chmod +x /usr/local/bin/sms_event.pl
```

Create necessary directories:
```bash
sudo mkdir -p /var/log/ /var/tmp
```

### Set Permissions

Ensure that the script runs under the `smstools` user:
```bash
sudo chown smstools:smstools /usr/local/bin/sms_event.sh
```

---

## CONFIGURATION

### Main Parameters (edit at the top of the script)

- **Allowed Phone Numbers**: Only these numbers can send commands:
    ```bash
    readonly ALLOW_PHONES=("79991234567" "79991234568")
    ```

- **Command Mode**:
    - Mode `"ALL"`: Any commands (for trusted administrators only)
    - Mode `"LIST"`: Only allowed commands (recommended)
    ```bash
    COMMAND_MODE="LIST"
    ALLOWED_COMMANDS=("date" "uptime" "df -h" "systemctl status sshd" "ping -c 3 8.8.8.8" "/root/scripts/backup.sh")
    ```

- **Other Important Settings**:
    ```bash
    COMMAND_CHAR="#"   # Character preceding the command in SMS
    SEND_BACK_REPORT="YES"   # Whether to send back a result report
    MAX_SMS_LENGTH=900   # Max length of reply SMS (characters)
	MAX_LOG_LENGTH=2000  # The maximum number of characters to log from the beginning of the command output.
	SENDSMS="/usr/local/bin/sendsms"  # PATH TO sendsms (standard in smstools)
	MAX_LOG_SIZE_KB=512  # The maximum log file size after which rotation begins (kilobytes)
	LOG_BACKUP_COUNT=7  # Total number of archive copies
	USE_GZIP="NO"  # Whether to use GZIP for archive copies compression (recommended to set to "NO" when using ZFS)
    ```

---

## USAGE

### SMS Command Format

The command format for SMS is as follows:
```
#command_to_execute
```

#### Example Commands:

- **Check server time**: `#date`
- **System load**: `#uptime`
- **Disk space**: `#df -h`
- **Restart service**: `#systemctl restart nginx`
- **Network check**: `#ping -c 3 google.com`
- **Online users**: `#who`

#### Example Dialogue

You (SMS): `#uptime`  
Server (SMS reply): `15:32:45 up 45 days, 3:21, 1 user, load average: 0.08, 0.03, 0.01`

---

## SECURITY

### Critical Security Measures

- **Phone number whitelist**: Only specified numbers can control the server.
- **Dangerous command blocking**: Automatic blocking of `rm -rf`, `dd`, `mkfs`.
- **Two access modes**:
    - **LIST** (recommended): Only predefined safe commands.
    - **ALL** (administrative): Any commands, but with dangerous command filter.
- **Logging**: All actions are logged in `/var/log/sms_commands.log`.

---

## LOGGING

The script maintains three types of logs:

| Log File                | Purpose                        | Rotation                     |
|-------------------------|--------------------------------|------------------------------|
| `/var/log/smsctrl.log`   | Main script events             | 512KB + 7 archives           |
| `/var/log/sms_commands.log` | Detailed command logs        | 512KB + 7 archives           |
| `/var/tmp/sms.log`       | Raw SMS messages               | 512KB + 7 archives           |

### Viewing logs:

- View executed commands:  
  ```bash
  tail -f /var/log/sms_commands.log
  ```
- View script system events:  
  ```bash
  tail -f /var/log/smsctrl.log
  ```

---

## TWO SCRIPT VERSIONS

The repository contains two scripts with identical functionality:

| Version | File              | Advantages                               |
|---------|-------------------|------------------------------------------|
| Bash    | `sms_event.sh`     | Better compatibility, fewer dependencies |
| Perl    | `sms_event.pl`     | Stricter error handling, built-in timeouts |

---

## TROUBLESHOOTING

### Common Issues

- **Script doesn't start**: Check permissions (`chmod +x`) and ownership (`chown smstools`).
- **SMS not being processed**: Check settings in `/etc/smsd.conf`.
- **No reply**: Ensure `SEND_BACK_REPORT="YES"` and the modem is working.
- **Incorrect encoding**: Install `iconv` for UCS2 support.

---

## LICENSE

MIT License - see the LICENSE file for details.

---

## IMPORTANT DISCLAIMER

**Use this script at your own risk!**  
The scripts are provided "as is," without any warranty of any kind. The author is not responsible for any damages, data loss, or unauthorized access that may occur as a result of using these scripts.

Always test in an isolated environment before using on production servers!
