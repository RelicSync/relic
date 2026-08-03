# Contributing to Relic

Pull requests are welcome. This is a small project with one maintainer, so the
things that make a PR easy to merge are: it is small, it does one thing, and it
looks like the code around it.

## Before you start

- Get it building. [`BUILD.md`](./BUILD.md) covers every component from a clean
  checkout. Nothing needs a secret.
- For anything larger than a bug fix, open an issue first and describe the
  approach. It is cheaper to disagree about a plan than about a finished branch.
- Found a security issue? Do not open a PR or an issue.
  [`SECURITY.md`](./SECURITY.md) has the disclosure process.

## Where to start

Issues labelled
[`good first issue`](https://github.com/RelicSync/relic/labels/good%20first%20issue)
are scoped small and have enough context in the issue body to start without
asking. Documentation fixes are always welcome and are never too small.

## Developer Certificate of Origin

Contributions are accepted under the
[Developer Certificate of Origin](https://developercertificate.org/) (DCO).
There is no CLA and there will not be one.

Sign off every commit:

```sh
git commit -s -m "worker: reject envelopes with a negative byte_size"
```

That appends one line to your commit message:

```
Signed-off-by: Your Name <your.email@example.com>
```

By signing off you are certifying the DCO: that you wrote the change yourself,
or that you have the right to submit it under this project's license, and that
you are fine with the contribution and your sign-off record being public and
kept indefinitely. It is a statement about provenance, not an assignment of
copyright. You keep the copyright to your work.

Forgot to sign off? `git commit --amend -s` for the last commit, or
`git rebase --signoff main` for a branch, then force-push your branch.

## Licensing

- The app, the AI sidecar, the server, the CLI, and the core are
  **AGPL-3.0**. Contributions to them are accepted under AGPL-3.0.
- The `crypto/` package is **Apache-2.0**, deliberately, so it stays easy to
  read, reuse, and reimplement. Contributions to `crypto/` are accepted under
  Apache-2.0.

If a change touches both, say so in the PR description so the licensing is
obvious to anyone reading the history later.

## Pull request expectations

- **Small and focused.** One concern per PR. A refactor bundled with a behavior
  change is two PRs.
- **Match the surrounding style.** Do not reformat files you are not otherwise
  changing, and do not add a linter or a formatter config as part of a feature
  PR.
- **Tests for behavior changes.** Every component has a test path already:
  `flutter test` in `app/`, `cargo test` for the Rust crates, `npm test` in
  `worker/`, `npm run smoke` in `selfhost/`, `dart test` in `crypto/`. A bug fix
  should come with the test that would have caught it.
- **Crypto and wire format changes are special.** The wire format has multiple
  independent implementations that must stay byte-identical, and the contract
  lives in [`docs/crypto.md`](./docs/crypto.md) and
  [`docs/wire-format.md`](./docs/wire-format.md). Changing parameters, AAD
  strings, nonce sizes, ciphertext layout, or envelope fields means changing
  every implementation, the docs, and the pinned vectors together, in one PR.
  Expect a slow and careful review.
- **Describe the user-visible effect.** If there is none, say that.
- **No em dashes in user-facing copy.** It is a house style rule and it applies
  to UI strings, docs, and release notes.

## Releases

Official releases are built and signed by the maintainer, from tags, using
signing credentials that live only in CI secrets and a cloud signing service.
Nothing about signing is in this repository, and merged PRs do not produce
signed builds by themselves. Self-built binaries are perfectly usable and are
supported on a best-effort basis.

## Code of conduct

Participation is governed by [`CODE_OF_CONDUCT.md`](./CODE_OF_CONDUCT.md).
