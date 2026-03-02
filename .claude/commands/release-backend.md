Deploy the backend to production.

## Steps

1. Ask the user for the version number (e.g. `1.0.3`). If provided as argument `$ARGUMENTS`, use that.
2. Run `git status` to ensure the working tree is clean. If not, stop and ask the user to commit or stash.
3. Run `git log --oneline -5` to confirm we're on the right branch.
4. Commit and push any pending changes if needed.
5. Create and push the tag: `git tag backend-v<VERSION> && git push origin backend-v<VERSION>`
6. Tell the user the workflow is triggered. Remind them:
   - The deploy SSHs into the server, pulls the tag, rebuilds the Docker container
   - Health check runs automatically (6 attempts, 10s apart)
   - Version will be embedded as `AFK_VERSION` in the binary
