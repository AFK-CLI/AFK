Release the macOS agent to GitHub Releases and Sparkle.

## Steps

1. Ask the user for the version number (e.g. `1.0.3`). If provided as argument `$ARGUMENTS`, use that.
2. Run `git status` to ensure the working tree is clean. If not, stop and ask the user to commit or stash.
3. Run `git log --oneline -5` to confirm we're on the right branch.
4. Commit and push any pending changes if needed.
5. Create and push the tag: `git tag agent-v<VERSION> && git push origin agent-v<VERSION>`
6. Tell the user the workflow is triggered and link to the Actions tab.
