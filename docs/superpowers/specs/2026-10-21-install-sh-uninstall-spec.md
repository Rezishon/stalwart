# MailiaM `install.sh` Uninstall Feature Specification

**Date:** 2026-10-21  
**Status:** Approved & Ready for Implementation  
**Target Files:** `install.sh` (repository root), `scripts/test-install.sh`  
**Branding Rule:** Pure MailiaM branding only. Zero legacy server name references in any added code, messages, or identifiers.

---

## 1. Overview & Objectives

Add clean, robust, and safe uninstallation capability to `install.sh`:
1. Integrated seamlessly into the existing interactive terminal UI (`prompt_mode` menu option 4).
2. Available via CLI flags for automation (`--uninstall` and `--purge`).
3. Safe-by-default behavior: keeps mail database and configuration files unless explicitly chosen/flagged to purge.
4. Professional step progress visualization with aligned status indicators (`[OK]` / `[FAILED]`) matching the installer ANSI styling.
5. Dual logging: step progress on stdout/console, detailed timestamped execution log in `/tmp/mailiam-uninstall.log`.

---

## 2. CLI Interface & Flags

```text
  -d, --uninstall               Uninstall MailiaM (stops service, removes binary & service unit)
  --purge                       When uninstallation is performed, also delete configuration, database, and logs
```

### CLI Invocations:
- `install.sh --uninstall`: Interactive uninstall. Prompts whether to keep or purge data.
- `install.sh --uninstall --purge`: Interactive uninstall with purge defaulted to enabled.
- `install.sh -y --uninstall`: Automated non-interactive uninstall; keeps database and config safe.
- `install.sh -y --uninstall --purge`: Automated non-interactive complete wipe.

---

## 3. Interactive Menu Integration

### Updated Step 0 Menu (`prompt_mode`):
```text
Current installation detected:
  - Binary:   /usr/local/bin/mailiam (version 0.16.25-rl1.0.19)
  - Config:   /etc/mailiam
  - Database: /var/lib/mailiam
  - Status:   You are currently running the latest version.

Select action:
  1) Update binary (Default - keeps config & mail data safe)
  2) Reconfigure server settings (Update domain, ports, TLS, or admin)
  3) Fresh reinstall (Clean install - resets configuration)
  4) Uninstall MailiaM (Remove binary, service, and optional data)
Choice [1-4] (Default: 1): 4
```

### Step 4A: Data Retention Prompt (Interactive):
```text
Data removal options:
  1) Keep config and mail data (Default - preserves data & config)
  2) Purge all data, config, and logs (Completely remove all MailiaM files)
Choice [1-2] (Default: 1): 
```

### Step 4B: Pre-Flight Summary (`print_uninstall_summary`):
```text
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                    MailiaM Uninstall Summary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Binary Path:       /usr/local/bin/mailiam (Removed)
  Service Unit:      mailiam.service (Stopped & Removed)
  Service User:      mailiam (Removed)
  Config & Env:      /etc/mailiam (Preserved)
  Mail Database:     /var/lib/mailiam (Preserved)
  Log Directory:     /var/log/mailiam (Preserved)
  Uninstall Log:     /tmp/mailiam-uninstall.log
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Proceed with uninstallation? [y/N] (Default: N): 
```
*Note: If purge is selected, Config, Database, and Logs are labeled in bold red as `(Purged)`.*

---

## 4. Execution Pipeline & Step Progress Bar

Uninstall runs with clear step-by-step console feedback:
```text
  [1/5] Stopping MailiaM service...                  [OK]
  [2/5] Removing service configuration (systemd)...  [OK]
  [3/5] Removing binary and executables...           [OK]
  [4/5] Removing service account (mailiam)...        [OK]
  [5/5] Preserving configuration and data files...   [OK]
```
*(If purge is selected, step 5 displays `Purging configuration and database directories... [OK]`)*

### Operations Breakdown:
1. **Stop Service:**
   - Calls `stop_service`
   - Kills any lingering process if needed
   - Cleans up PID file (`/var/run/mailiam.pid` or `/run/mailiam.pid`)
2. **Remove Service Configuration:**
   - **systemd:** `systemctl disable mailiam.service 2>/dev/null`, `rm -f /etc/systemd/system/mailiam.service`, `systemctl daemon-reload`
   - **sysv:** `update-rc.d -f mailiam remove 2>/dev/null` or `chkconfig mailiam off 2>/dev/null`, `rm -f /etc/init.d/mailiam`
   - **openrc:** `rc-update del mailiam default 2>/dev/null`, `rm -f /etc/init.d/mailiam`
   - **freebsd:** `sysrc -x mailiam_enable 2>/dev/null`, `rm -f /usr/local/etc/rc.d/mailiam`
3. **Remove Executables:**
   - `rm -f "$_bin_file" "${_bin_file}.bak"`
4. **Remove Service User:**
   - Linux: `userdel "$_account" 2>/dev/null || deluser "$_account" 2>/dev/null || true`
   - FreeBSD: `pw userdel "$_account" 2>/dev/null || true`
5. **Data & Config Handling:**
   - If `_purge=1`:
     - Recursively delete `$_conf_dir`, `$_data_dir`, `$_log_dir`
   - If `_purge=0`:
     - Keep directories intact, log paths preserved.

### Step 4C: Post-Uninstall Success Screen (`print_uninstall_success`):
```text
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                  MailiaM Uninstalled Successfully
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Binary & Services: Removed
  Service Account:   mailiam (removed)
  Mail Data & Conf:  Preserved in /var/lib/mailiam and /etc/mailiam
  Uninstall Log:     /tmp/mailiam-uninstall.log
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 5. Technical Implementation Details

### Functions to add/update in `install.sh`:
- `validate_mode`: update regex to `1|2|3|4`.
- `prompt_mode`: add option 4, adjust menu bounds to 1-4.
- `prompt_uninstall_purge`: prompts for keep vs purge data.
- `print_uninstall_summary`: renders box summary.
- `print_uninstall_success`: renders completion box.
- `log_uninstall`: appends timestamped message to `/tmp/mailiam-uninstall.log`.
- `run_uninstall_step`: takes step index, total steps, description, and shell command/function. Prints step with padding, executes command, logs output, prints `[OK]` or `[FAILED]`.
- `uninstall_mailiam`: coordinates the 5 steps and log finalization.
- `print_usage`: document `--uninstall` and `--purge`.

---

## 6. Testing Plan (`scripts/test-install.sh`)

1. **Validators:**
   - Verify `validate_mode "4"` passes.
   - Verify `validate_mode "5"` fails.
2. **CLI Flags Parsing:**
   - Verify `--uninstall` sets `_install_mode=4` and `_uninstall=1`.
   - Verify `--purge` sets `_purge=1`.
3. **Dry-Run / Unit Testing:**
   - Verify `run_uninstall_step` format and output.
   - Verify `print_uninstall_summary` output for both keep and purge modes.
