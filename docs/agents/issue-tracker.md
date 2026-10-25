# Issue tracker: GitHub

Issues and specs for this repo live as GitHub issues. Use the `gh` CLI for all operations.

Repository: `WangFugui6672/agent-roundtable`

## Conventions

- **Create an issue:** `gh issue create --title "..." --body "..."`
- **Read an issue:** `gh issue view <number> --json number,title,body,labels,comments`
- **List issues:** `gh issue list --state open --json number,title,body,labels,comments`
- **Comment on an issue:** `gh issue comment <number> --body "..."`
- **Apply / remove labels:** `gh issue edit <number> --add-label "..."` / `--remove-label "..."`
- **Close:** `gh issue close <number> --comment "..."`

Infer the repository from `git remote -v`; `gh` does this automatically when run inside the clone.

## Pull requests as a triage surface

**PRs as a request surface: no.**

This is a solo portfolio project. Pull requests are used for development history, CI, and review, not as incoming feature requests.

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Use `gh issue view <number>` and read the full body and comments.

## Blocking edges

Use GitHub issue dependencies when available. Otherwise include `Blocked by: #<n>` at the top of the issue body.

