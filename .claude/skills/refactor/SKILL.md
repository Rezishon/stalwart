---
name: refactor
description: Invokes refactorer agent on specified paths, crates, or modified git diffs in the Rust codebase.
---

# Refactor Workflow

1. Identify modified files or target paths provided in arguments.
2. Dispatch `refactorer` agent to evaluate zero-copy efficiency, async tokio handling, lock contention, and YAGNI simplification.
3. Report concrete refactoring proposals with minimal, atomic diffs.
