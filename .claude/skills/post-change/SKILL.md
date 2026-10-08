---
name: post-change
description: Runs verification pipeline (cargo check, tests) and targeted reviews (security, schema, refactor) after code modifications.
---

# Post-Change Verification & Review Pipeline

1. **Run Verifier**:
   - `cargo check --workspace` (or targeted crate: `cargo check -p <modified_crate>@0.16.25`).
2. **Inspect Changed Files**:
   - Run `git status -s` to identify touched crates.
3. **Targeted Agent Audits**:
   - If changes touch `crates/http`, `crates/smtp`, `crates/imap`, or auth flows -> invoke `security-reviewer`.
   - If changes touch `resources/schema/`, `crates/registry`, or WebUI -> invoke `schema-reviewer`.
   - If changes touch complex business logic, storage engines (`crates/store`), or performance loops -> invoke `refactorer`.
4. **Summary**:
   - Report compile status, lint warnings, and key reviewer recommendations.
