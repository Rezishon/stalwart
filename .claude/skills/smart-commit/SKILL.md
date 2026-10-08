---
name: smart-commit
description: Analyzes git diffs, groups changes logically by atomic concern, and outputs a chained commit command matching Stalwart repo style with descriptive why-bodies.
---

# Smart Commit

Analyzes git diffs at the hunk/line level, groups related changes into atomic commits, ignores local configs/secrets when not requested, and formats commit messages tailored to Stalwart's conventions.

## Workflow

1. **Inspect granular changes:**
   - Run `git status -s` and `git diff` (including unstaged files).
   - Inspect individual diff hunks and line changes across all modified crates.

2. **Handle local dev configs & test data:**
   - Unless user explicitly requests to include environment/endpoint updates:
     - Ignore local dev overrides (`docker-compose.yml`, `Dockerfile.dev`, `resources/webui.zip`, local `.sqlite` / `.db` files, temporary `.pem` certs, local `.env` files, `graphify-out/`).
     - Ignore unstaged scratch files or local test runs in `/target` or `/cargo-target`.

3. **Group changes by atomic concern & crate:**
   - Group related line changes together across files into atomic commits.
   - Separate concerns cleanly by crate / subsystem:
     - `Fix <Component>: <Summary>` / `<Type> <Component>: <Summary>`
     - Common scopes: `MTA`, `SMTP`, `IMAP`, `JMAP`, `WebUI`, `Spam filter`, `RocksDB`, `Store`, `Directory`, `OAuth`, `SCIM`, `DAV`, `WebDAV`, `Autodiscover`, `ACME`, `Telemetry`, `Docs`.

4. **Format commit messages (Header + Descriptive Body):**
   - **Header:** `<type>(<scope>): <short summary>` (e.g. `feat(skills): add development agents and skills`, `fix(imap): handle untagged NO response`, `chore(docker): add dev compose config`).
   - **Body:** Provide a clear breakdown explaining what and why (e.g. `"these skills added: rust-developer, post-change, agents-flow, smart-commit"` or context on the fix).
   - Format using `-m "<header>" -m "<body>"`.
   - No `Co-Authored-By` trailers or filler text.

5. **Output command:**
   - Output ONLY a single copy-pasteable bash command:
     `git add <files1> && git commit -m "<header1>" -m "<body1>"`
