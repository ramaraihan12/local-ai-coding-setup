---
description: Answer a library/framework question from current documentation (Context7)
argument-hint: "<library> <question>"
---
Answer from the current documentation of `$1`: ${@:2}

1. If the project pins a version (composer.json, package.json, lock files), find it first with grep.
2. `mcp__context7__resolve_library_id` with libraryName "$1" and the question as query; choose the official match for that version.
3. One focused `mcp__context7__query_docs` call (a second only if the first misses). If Context7 has nothing useful, one `mcp__web__search`.
4. Answer in the user's language: short explanation plus a minimal code example that matches that version; name the library ID/version used. If the docs do not cover it, say so instead of guessing.
