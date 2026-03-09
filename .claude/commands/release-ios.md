Release the iOS app to TestFlight (Open Beta).

## Steps

1. Run `git status` to ensure the working tree is clean. If not, stop and ask the user to commit or stash.
2. Run `git log --oneline -5` to confirm we're on the right branch.
3. The marketing version is fixed at `1.4.0` (open beta). The build number is auto-incremented by GitHub Actions (`run_number`). No version bump needed.
4. Push any unpushed commits: `git push origin main`
5. Create and push the tag: `git tag ios-v1.4.0-build.<NEXT> && git push origin ios-v1.4.0-build.<NEXT>` where `<NEXT>` is determined by checking existing tags: `git tag -l 'ios-v1.4.0-build.*' | sort -t. -k4 -n | tail -1`
   - If no previous build tags exist, start with `ios-v1.4.0-build.1`
   - If the latest is `ios-v1.4.0-build.N`, use `ios-v1.4.0-build.N+1`
6. Tell the user the workflow is triggered. Remind them:
   - Marketing version stays `1.4.0` (the tag suffix after `-` is stripped by the workflow)
   - Build number uses GitHub Actions `run_number` (independent of tag suffix)
   - Check progress at the GitHub Actions page
