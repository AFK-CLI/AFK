# Contributing

## Reporting Bugs

Use [GitHub Issues](https://github.com/AFK-CLI/AFK/issues). Include:

- Which component is affected (backend, agent, iOS app)
- Steps to reproduce
- Expected vs. actual behavior
- OS version, Xcode version (if relevant)
- Backend logs or agent console output (redact any sensitive data)

For security vulnerabilities, do not open a public issue — see [SECURITY.md](SECURITY.md).

## Submitting Patches

1. Fork the repository and clone your fork.
2. Create a branch from `main`:
   ```bash
   git checkout -b feat/my-change main
   ```
3. Follow the [development setup guide](docs/development.md) to build and test locally.
4. Make your changes. Keep the scope narrow — one logical change per PR.
5. Ensure tests pass:
   ```bash
   cd backend && go build ./cmd/server && go test ./...
   ```
6. Commit with a [Conventional Commits](https://www.conventionalcommits.org/) message:
   ```
   feat: add session export endpoint
   fix: correct WebSocket reconnect backoff on agent restart
   docs: clarify APNs key setup in self-hosting guide
   ```
7. Push to your fork and open a pull request against `main`.

## Code Style

**Go (backend)**:
- `gofmt` formatted. `go vet ./...` clean.
- Standard library patterns. Handlers are plain `http.HandlerFunc` — no web framework.
- Error messages start lowercase, no trailing punctuation.

**Swift (agent and iOS)**:
- Follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).
- Use `actor` for thread-safe mutable state. Use `@Observable` for SwiftUI models.
- No third-party dependencies for crypto — use Apple CryptoKit.

**General**:
- Keep functions focused. If a function does two things, split it.
- Add doc comments for public APIs. Don't add comments that restate what the code already says.
- No dead code. Remove unused imports, variables, and functions.

## PR Process

- Reference related issues (e.g., `Closes #42`).
- Describe what changed and why in the PR body.
- CI must pass before merge. The pipeline runs Go build + test and iOS Simulator build.
- Maintainers may request changes. Be responsive.
- PRs are squash-merged into `main`.

## What We Accept

- Bug fixes with reproduction steps.
- Performance improvements with measurements.
- New event types or message formats that follow the existing patterns (see [docs/development.md](docs/development.md#adding-a-new-websocket-message-type)).
- Documentation corrections and clarifications.
- Test coverage improvements.

Before starting on a large feature, open an issue to discuss the design first.

## What We Don't Accept

- Changes that break backward compatibility for the WebSocket protocol or wire format without a migration path.
- Third-party dependencies where the standard library or Apple frameworks suffice.
- Code formatting changes unrelated to a functional fix.

## Contributor Rewards

Contributors who have a pull request merged into AFK receive **lifetime AFK Pro** — no subscription required, ever.

After your PR is merged, we'll grant contributor status to the email associated with your AFK account. If your GitHub email differs from your AFK account email, mention it in the PR.

Contributor tier includes all Pro features: unlimited devices, 90-day event history, and priority support.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
