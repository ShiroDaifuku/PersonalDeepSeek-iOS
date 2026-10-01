# Native Agent worktree rules

- Work only in this worktree on feature/native-agent-loop.
- Do not access or modify the original or Deep Research workspace.
- Do not build, upload, release, or trigger an IPA without an explicit user request.
- Before pushing, verify the branch cannot trigger the IPA workflow.
- Keep native V1 tools read-only: web_search and local_knowledge_search.
