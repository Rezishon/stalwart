# MailiaM `install.sh` Interactive Prompt Flow Specification & Implementation Plan

**Date:** 2026-10-19  
**Status:** Approved & Ready for Implementation  
**Target File:** `install.sh` (repository root)  
**Test Environment:** Running Docker container `test-container` (`docker exec -it test-container`)

---

## 1. Global Styling & UX Principles

### ANSI Color and Font Palette
- **Banner / Brand Art:** Bright Red (`\033[1;31m`)
- **Question Headers / Titles / Section Headers:** Bold (`\033[1m`)
- **Menu Option Numbers:** Bright Blue (`\033[94m`)
- **Defaults & Helper Hints:** Dim + Italic (`\033[2;3m`)
- **Important Values / URLs:** Bold Blue (`\033[1;94m`)
- **Credentials / Passwords:** Bold Green (`\033[1;32m`)
- **Box Borders & Divider Lines:** Dim (`\033[2m`)
- **Commands / Code Examples:** Dim + Italic (`\033[2;3m`)
- **Reset Code:** `\033[0m`
- **Strict Rule:** No decorative emoji.
- **Graceful Fallback:** Automatically strip/disable all escape codes if `[ ! -t 1 ]`, `TERM=dumb`, or `$NO_COLOR` is present.

---

## 2. Step-by-Step Interactive Flow

### Step 0: Existing Installation Detection (`prompt_mode`)
- **Ordering:** Prints the Red ASCII Banner first so the user has visual context.
- **Custom Path Detection:** Checks `/usr/local/bin/mailiam`, `/usr/local/bin/stalwart`, and `command -v mailiam`/`stalwart`.
- **Remote Version Check (No API token / Zero Rate Limit):**
  - Runs `curl -sIL -o /dev/null -w '%{url_effective}\n' "https://github.com/${_repo}/releases/latest"` to extract latest release tag without API rate limits.
  - Queries `$_bin_file --version` for current version.
  - If up-to-date, notifies user: `You are currently running the latest version.`
  - If update available, highlights in Bold Blue: `Update available: v0.16.25-rl1.0.20 (Current: v0.16.25-rl1.0.19)`.
- **MailiaM Naming & Symlinks:**
  - Archive target: `mailiam-${_target}.tar.gz`
  - Primary command: `mailiam` (with `stalwart -> mailiam` symlink for legacy scripts).
  - Service: `mailiam.service`
  - Config directory: `/etc/mailiam` (with `/etc/stalwart -> mailiam` symlink).
  - User account: `mailiam`
- **Improved UX Layout:** Shows detected installation state and version comparison:
```text
\033[1mCurrent installation detected:\033[0m
  - Binary:   /usr/local/bin/mailiam \033[2;3m(version 0.16.25-rl1.0.19)\033[0m
  - Config:   /etc/mailiam
  - Database: /var/lib/mailiam
  - Status:   \033[1;94mUpdate available: v0.16.25-rl1.0.20\033[0m

\033[1mSelect action:\033[0m
  \033[94m1)\033[0m Update binary to v0.16.25-rl1.0.20 \033[2;3m(Default - keeps config & mail data safe)\033[0m
  \033[94m2)\033[0m Reconfigure server settings \033[2;3m(Update domain, ports, TLS, or admin)\033[0m
  \033[94m3)\033[0m Fresh reinstall \033[2;3m(Clean install - resets configuration)\033[0m
\033[1mChoice [1-3]\033[0m \033[2;3m(Default: 1)\033[0m: 
```

#### Dedicated Binary Update Flow (Mode 1 / `--update`):
1. **Download Source:** Step 1 menu (GitHub / URL / Local) with palette.
2. **Target Version:** Step 2 prompt:
   `\033[1mRelease version to install\033[0m \033[2;3m(Default: latest)\033[0m: `
3. **Service Restart:**
   `\033[1mRestart MailiaM service after update? [Y/n]\033[0m \033[2;3m(Default: Y)\033[0m: `
4. **Pre-Flight Update Summary:**
```text
\033[2m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m
\033[1m                    MailiaM Binary Update Summary\033[0m
\033[2m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m
  Current Binary:    /usr/local/bin/stalwart \033[2;3m(version 0.16.25-rl1.0.19)\033[0m
  Target Version:    latest \033[2;3m(from Rezishon/stalwart)\033[0m
  Config & Env:      \033[1;32mPreserved\033[0m \033[2;3m(/etc/stalwart)\033[0m
  Mail Database:     \033[1;32mPreserved\033[0m \033[2;3m(/var/lib/stalwart)\033[0m
  Service Action:    Restart mailiam service
\033[2m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m

\033[1mProceed with update? [Y/n]\033[0m \033[2;3m(Default: Y)\033[0m: 
```
5. **Post-Update Success Screen:**
```text
\033[2m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m
\033[1m                    MailiaM Updated Successfully\033[0m
\033[2m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m

\033[1m  Installed Version:\033[0m  \033[1;94m0.16.25-rl1.0.20\033[0m
\033[1m  Binary Path:\033[0m        /usr/local/bin/stalwart
\033[1m  Service Status:\033[0m     Active (running)

\033[1m  Useful Commands:\033[0m
    Check status:    \033[2;3msystemctl status mailiam\033[0m
    View live logs:  \033[2;3mjournalctl -u mailiam -f\033[0m

\033[2m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m
```

#### If Mode 2 (Reconfigure environment):
1. Keeps existing binary.
2. Reads current settings from `stalwart.env` as defaults (`seed_mode2_from_env`).
3. Re-prompts Hostname, Public URL, and Admin credentials.
4. Rewrites `stalwart.env` and restarts service.

#### If Mode 3 or Fresh Install (No existing binary):
Proceeds through the full 13-step flow below.

---

### Step 1: Banner & Download Source
```text
\033[1;31m ███▄ ▄███▓ ▄▄▄       ██▓ ██▓     ██▓ ▄▄▄       ███▄ ▄███▓
▓██▒▀█▀ ██▒▒████▄    ▓██▒▓██▒    ▓██▒▒████▄    ▓██▒▀█▀ ██▒
▓██    ▓██░▒██  ▀█▄  ▒██▒▒██░    ▒██▒▒██  ▀█▄  ▓██    ▓██░
▒██    ▒██ ░██▄▄▄▄██ ░██░▒██░    ░██░░██▄▄▄▄██ ▒██    ▒██ 
▒██▒   ░██▒ ▓█   ▓██▒░██░░██████▒░██░ ▓█   ▓██▒▒██▒   ░██▒
░ ▒░   ░  ░ ▒▒   ▓▒█░░▓  ░ ▒░▓  ░░▓   ▒▒   ▓▒█░░ ▒░   ░  ░
░  ░      ░  ▒   ▒▒ ░ ▒ ░░ ░ ▒  ░ ▒ ░  ▒   ▒▒ ░░  ░      ░
░      ░     ░   ▒    ▒ ░  ░ ░    ▒ ░  ░   ▒   ░      ░   
       ░         ░  ░ ░      ░  ░ ░        ░  ░       ░   \033[0m

\033[1mWelcome to MailiaM.\033[0m
\033[2mFresh install. No existing binary found at /usr/local/bin/stalwart.\033[0m

\033[1mSelect download source:\033[0m
  \033[94m1)\033[0m GitHub repository \033[2;3m(Default: Rezishon/stalwart)\033[0m
  \033[94m2)\033[0m Custom HTTPS URL
  \033[94m3)\033[0m Local archive file
\033[1mChoice [1-3]\033[0m \033[2;3m(Default: 1)\033[0m: 
```
- Sub-prompt if `1`: `\033[1mGitHub repository [owner/repo]\033[0m \033[2;3m(Default: Rezishon/stalwart)\033[0m: `
- Sub-prompt if `2`: `\033[1mHTTPS URL (e.g. https://example.com/releases)\033[0m: `
- Sub-prompt if `3`: `\033[1mLocal archive path (e.g. /path/to/mailman.tar.gz)\033[0m: `

### Step 2: Release Version
```text
\033[1mRelease version\033[0m \033[2;3m(Default: latest)\033[0m: 
```

### Step 3: Installation Paths
- Displays current layout, then offers progressive disclosure menu:
```text
\033[1mInstallation paths:\033[0m
  - Binary:  /usr/local/bin/stalwart
  - Config:  /etc/stalwart
  - Data:    /var/lib/stalwart
  - Logs:    /var/log/stalwart

\033[1mSelect installation path:\033[0m
  \033[94m1)\033[0m Standard system paths \033[2;3m(Default)\033[0m
  \033[94m2)\033[0m Single base path \033[2;3m(e.g. /opt/stalwart)\033[0m
  \033[94m3)\033[0m Advanced: customize each path
\033[1mChoice [1-3]\033[0m \033[2;3m(Default: 1)\033[0m: 
```
- Sub-prompt if `2`: `\033[1mBase directory path\033[0m \033[2;3m(e.g. /opt/stalwart)\033[0m: `
- Sub-prompts if `3`:
  - `\033[1mBinary directory\033[0m \033[2;3m(Default: /usr/local/bin)\033[0m: `
  - `\033[1mConfig directory\033[0m \033[2;3m(Default: /etc/stalwart)\033[0m: `
  - `\033[1mData directory\033[0m \033[2;3m(Default: /var/lib/stalwart)\033[0m: `
  - `\033[1mLog directory\033[0m \033[2;3m(Default: /var/log/stalwart)\033[0m: `

### Step 4: MailiaM User Account
```text
\033[1mMailiaM user account\033[0m \033[2;3m(Default: mailiam)\033[0m: 
\033[2;3mDedicated unprivileged user for daemon and file permissions. Created automatically if missing.\033[0m
```

### Step 5: Server Hostname (FQDN)
```text
\033[1mServer hostname (FQDN)\033[0m \033[2;3m(e.g. mail.yourdomain.com) (Default: mail.localhost)\033[0m: 
\033[2;3mPrimary domain for SMTP HELO, TLS certificates, and DeltaChat discovery.\033[0m
\033[2;3mNote: You can easily change this later in the WebUI admin dashboard.\033[0m
```
- Safe fallback: If detected system hostname has no dot `.` (e.g. Docker container ID `58cc45e5c613`), default safely to `mail.localhost` to avoid accidental external bans and indicate placeholder.

### Step 6: Network Listener Ports
- HTTP changed to 80 (was legacy 8080).
```text
\033[1mNetwork listener ports:\033[0m
  - SMTP:         25       \033[2;3m(Mail delivery)\033[0m
  - Submission:   587      \033[2;3m(Client send, STARTTLS)\033[0m
  - SMTPS:        465      \033[2;3m(Client send, TLS)\033[0m
  - IMAP:         143      \033[2;3m(Mail access)\033[0m
  - POP3:         110      \033[2;3m(Legacy access)\033[0m
  - ManageSieve:  4190     \033[2;3m(Mail filtering)\033[0m
  - HTTP:         80       \033[2;3m(Web / ACME challenges)\033[0m
  - HTTPS:        443      \033[2;3m(Relay SPA / WebUI / JMAP)\033[0m

\033[1mSelect port configuration:\033[0m
  \033[94m1)\033[0m Use standard ports \033[2;3m(Default)\033[0m
  \033[94m2)\033[0m Advanced: customize individual ports
\033[1mChoice [1-2]\033[0m \033[2;3m(Default: 1)\033[0m: 
```
- If `2`: Prompt each of the 8 ports individually.

### Step 7: TLS / SSL Certificate Configuration
- MailiaM has native Rust-embedded ACME client in binary (no external bash certbot).
```text
\033[1mTLS / SSL encryption:\033[0m
  \033[94m1)\033[0m Automatic Let's Encrypt (ACME) \033[2;3m(Default)\033[0m
  \033[94m2)\033[0m Custom certificate files \033[2;3m(Path to .crt and .key)\033[0m
  \033[94m3)\033[0m Disabled / Plaintext \033[2;3m(Only if behind reverse proxy)\033[0m
\033[1mChoice [1-3]\033[0m \033[2;3m(Default: 1)\033[0m: 
```
- Sub-prompt if `1`: `\033[1mACME contact email\033[0m \033[2;3m(Default: admin@<hostname>)\033[0m: `
- Sub-prompts if `2`:
  - `\033[1mTLS certificate path\033[0m \033[2;3m(e.g. /etc/ssl/certs/fullchain.pem)\033[0m: `
  - `\033[1mTLS private key path\033[0m \033[2;3m(e.g. /etc/ssl/private/privkey.pem)\033[0m: `

### Step 8: DeltaChat Autoconfig Endpoints
- Dynamically derived from hostname, ports, and TLS choices:
  - If TLS enabled: IMAP port 993 (SSL), SMTP port 465 (SSL), cert checks Strict (`ic=3`).
  - If TLS disabled: IMAP port 143 (Plain), SMTP port 587 (Plain), cert checks Disabled (`ic=0`).
```text
\033[1mDeltaChat autoconfig endpoints:\033[0m
  - IMAP:        mail.example.com:993 \033[2;3m(SSL/TLS)\033[0m
  - SMTP:        mail.example.com:465 \033[2;3m(SSL/TLS)\033[0m
  - Cert checks: Strict \033[2;3m(Automatic)\033[0m

\033[1mConfigure DeltaChat endpoints:\033[0m
  \033[94m1)\033[0m Use server defaults \033[2;3m(Default)\033[0m
  \033[94m2)\033[0m Advanced: customize DeltaChat endpoints
\033[1mChoice [1-2]\033[0m \033[2;3m(Default: 1)\033[0m: 
```
- If `2`: Prompt custom IMAP/SMTP hosts, ports, security modes, and cert level.

### Step 9: Public Web URL (Option B)
```text
\033[1mPublic web URL\033[0m \033[2;3m(Default: https://<hostname>)\033[0m: 
\033[2;3mWeb address for admin panel (/admin), user web portal, and DeltaChat invite links.\033[0m
\033[2;3mPress Enter to match mail hostname, or enter custom URL (e.g. https://yourdomain.com).\033[0m
```
- Pre-filled with auto-calculated scheme (`https://` or `http://`) and `$_hostname`.
- Port included if non-standard (e.g. 8443 or 8080); omitted if 443/80.

### Step 10: Admin WebUI Credentials
```text
\033[1mAdmin WebUI credentials:\033[0m
\033[2;3mInitial administrator account for the web management console (/admin).\033[0m

\033[1mSelect admin setup:\033[0m
  \033[94m1)\033[0m Auto-generate secure password \033[2;3m(Default: user 'admin')\033[0m
  \033[94m2)\033[0m Set custom username and password
\033[1mChoice [1-2]\033[0m \033[2;3m(Default: 1)\033[0m: 
```
- Sub-prompts if `2`:
  - `\033[1mAdmin username\033[0m \033[2;3m(Default: admin)\033[0m: `
  - `\033[1mAdmin password\033[0m: ` (Handles colons, spaces, and quotes safely).
- **Mode 2 (Reconfigure) Variation:**
  When reconfiguring an existing setup, Option 1 becomes `Keep existing admin password (Default)` so credentials are not accidentally overwritten unless requested.

### Step 11: Service Auto-Start
```text
\033[1mEnable and start MailiaM service now? [Y/n]\033[0m \033[2;3m(Default: Y)\033[0m: 
\033[2;3mRegisters system service (systemd/initd/rcd) and starts MailiaM automatically on boot.\033[0m
```

### Step 12: Pre-Flight Summary & Final Confirmation
- Displays complete summary with protocol breakdown and port-aware URLs.
```text
\033[2m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m
\033[1m                    MailiaM Installation Summary\033[0m
\033[2m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m
  Download Source:   Rezishon/stalwart (latest)
  Install Base:      /usr/local (Binary: /usr/local/bin/stalwart)
  Service User:      mailiam (unprivileged)
  Server Hostname:   mail.example.com
  Web URL:           https://mail.example.com

\033[1m  Active Listeners:\033[0m
    - SMTP (MTA):    Port 25
    - Submission:    Port 587 (STARTTLS)
    - SMTPS:         Port 465 (Implicit TLS)
    - IMAPS:         Port 993 (Implicit TLS)
    - ManageSieve:   Port 4190
    - Web (HTTP):    Port 80 (ACME challenges / redirect)
    - Web (HTTPS):   Port 443 (Relay SPA / WebUI / JMAP)

\033[1m  TLS / SSL:\033[0m         Automatic Let's Encrypt (ACME)

\033[1m  DeltaChat Config:\033[0m
    - Web & Relay:   https://mail.example.com/
    - IMAP Server:   mail.example.com:993 (IMAPS / SSL)
    - SMTP Server:   mail.example.com:465 (SMTPS / SSL)
    - Cert Checks:   Strict verification (ic=3)

\033[1m  Admin Account:\033[0m     admin (secure random password generated on boot)
\033[1m  Service Start:\033[0m     Yes (systemd auto-start enabled)
\033[2m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m

\033[1mProceed with installation? [Y/n]\033[0m \033[2;3m(Default: Y)\033[0m: 
```
- If user answers `n`, exits cleanly with zero filesystem changes.

### Step 13: Post-Install Completion Screen
```text
\033[2m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m
\033[1m                  MailiaM Installed Successfully\033[0m
\033[2m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m

\033[1m  Admin Web Console:\033[0m
    URL:             \033[1;94mhttps://mail.example.com/admin\033[0m
    Username:        admin
    Password:        \033[1;32m[GENERATED_PASSWORD_OR_CUSTOM]\033[0m

\033[1m  User Portal & Web Apps:\033[0m
    DeltaChat Relay: \033[1;94mhttps://mail.example.com/\033[0m
    User Account:    \033[1;94mhttps://mail.example.com/account\033[0m

\033[1m  Useful Commands:\033[0m
    Check status:    \033[2;3msystemctl status mailiam\033[0m
    View live logs:  \033[2;3mjournalctl -u mailiam -f\033[0m
    Config file:     /etc/stalwart/stalwart.env

\033[2m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m
```

---

## 3. Implementation Details & Architecture in `install.sh`

### Functions to Add / Modify in `install.sh`:
1. **ANSI Color Helpers:**
   - Define color variables: `CLR_RED`, `CLR_BOLD`, `CLR_BLUE`, `CLR_DIM`, `CLR_ITALIC`, `CLR_GREEN`, `CLR_RESET`.
   - Add `init_colors()`: detect `[ -t 1 ]`, check `$NO_COLOR` and `TERM=dumb`. If colors unsupported, set all variables to empty strings.
2. **`print_banner()`:**
   - Update with Bright Red MailiaM ASCII art.
3. **`prompt_value()`, `prompt_read()`, `prompt_yes_no()`:**
   - Update prompt formatting to apply `CLR_BOLD` on question and `CLR_DIM` + `CLR_ITALIC` on `(Default: ...)`.
4. **Interactive Flow in `main()`:**
   - Step 1: Menu for source (1. GitHub, 2. URL, 3. Local).
   - Step 2: Release version prompt.
   - Step 3: Installation paths overview + menu (1. Standard, 2. Base path, 3. Advanced per-directory).
   - Step 4: User account prompt (default: `mailiam`).
   - Step 5: Hostname prompt (safe default `mail.localhost` if no dot).
   - Step 6: Ports overview + menu (1. Standard [HTTP 80], 2. Advanced customize).
   - Step 7: TLS menu (1. ACME Let's Encrypt, 2. Custom cert, 3. Disabled).
   - Step 8: DeltaChat autoconfig overview + menu (1. Server defaults, 2. Customize).
   - Step 9: Public web URL prompt pre-filled with dynamic host & port.
   - Step 10: Admin credentials menu (1. Random password for `admin`, 2. Custom user/pass).
   - Step 11: Service start `[Y/n]`.
   - Step 12: Pre-flight review box + final `[Y/n]` confirmation.
   - Step 13: Post-install completion box.

---

## 4. Verification Plan

1. **Syntax Check:** `sh -n install.sh` / `shellcheck -s dash install.sh`.
2. **Non-Interactive Regression Test:** `sh install.sh -y --no-start` inside `test-container` to ensure scripted installs remain 100% automated and unbroken.
3. **Interactive Step-by-Step Test:** Run via Python PTY harness or `docker exec -it test-container sh install.sh` verifying all 13 prompts, color escapes, defaults, and the final confirmation screen.
