---
name: agents-flow
description: Runs sequential multi-agent review pipeline tailored for Stalwart (security-reviewer, schema-reviewer, refactorer, verifier).
---

# Sequential Agents Review Pipeline

Execute the following agents in sequence for changes:

1. **`security-reviewer`**: Audit network protocol boundaries, RBAC permissions, SASL/OAuth auth flows, and cryptographic operations.
2. **`schema-reviewer`**: Audit schema JSON consistency, `permissionPrefix` validity, and JMAP get/set bindings.
3. **`refactorer`**: Audit memory zero-copy, async task cancellation, lock contention, and YAGNI clean design.
4. **`verifier`**: Run `cargo check` and targeted crate unit tests.

Summarize findings from all agents in a single actionable report.
