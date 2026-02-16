# arcman
A Bash script for managing encrypted archives using various tools like Cryptomator, gocryptfs, eCryptfs, KeePassXC, LUKS, ...  

## Features
- Mount & Unmount encrypted archives.
- Support for multiple tools.
- Logging & Error Handling with color-coded output.
- Flexible Configuration via archive-manager.conf.
- Optional "long" listing format for better readability.

## Configuration File Lookup Order
The script automatically searches for a configuration file in the following order:
1. A custom file specified using `-c <config-file>` or `--config <config-file>`.
2. The local directory: `./archive-manager.conf`
3. The user-specific config directory: `$HOME/.local/share/archive-manager/archive-manager.conf`
4. The system-wide config directory: `/etc/archive-manager/archive-manager.conf`

## Usage
```bash
./archive-manager.sh [options] <command> [arguments]
```

### Options: 
| Option             | Description                                                          |
|--------------------|----------------------------------------------------------------------|
| -c \<config-file\> | Use a custom configuration file instead of the default lookup order. |
| -h                 | Show help message and exit                                           |
| -v                 | Display the script version and exit                                  |

### Commands:
| Command                | Description                                |
|------------------------|--------------------------------------------|
| `list`                 | Show configured archives (compact view)    |
| `list long`            | Show archives in a detailed multi-line format |
| `mount <ARCHIVE_ID>`   | Mount an archive                           |
| `unmount <ARCHIVE_ID>` | Unmount an archive                         |
| `update`               | Check for updates and update script if a new version is available |

### Example Output for `list`
The `list` command displays all configured archives. If archives are grouped into **blocks**, these are shown with a header.

#### **Compact view (`list`)**
```
🔵 ### Work Archives ###
🟢 A    | Cryptomator | Important Projects   | /work/archives/projects | 🟢 OK
🟢 B    | KeePassXC   | Customer Database    | /work/archives/passwords.kdbx | 🟢 OK

🔵 ### Private Archives ###
🟢  Y    | Cryptomator | Secret Files         | /home/user/secrets | 🟢 OK 

🔵 ### Uncategorized ###
🟠 X    | gocryptfs   | Photos               | /home/user/photos | 🟠 File not found
```

## Requirements
- bash
- realpath
- Required encryption tools (e.g. Cryptomator, gocryptfs, KeePassXC, ...)
- archive-manager.conf (configuration file)

