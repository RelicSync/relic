<!-- Thanks for contributing. The short version of CONTRIBUTING.md: -->

## What & why

<!-- What does this change, and what problem does it solve? Link the issue if there is one. -->

## How it was tested

<!-- Check what you ran. CI runs all of these, but running the relevant one locally first saves you a round trip. -->

- [ ] `app/`: `flutter analyze && flutter test`
- [ ] Rust: `cargo test --workspace`
- [ ] `crypto/`: `dart test`
- [ ] `worker/`: `npm test`
- [ ] `selfhost/`: `npm run smoke`
- [ ] Not applicable (docs only)

## Checklist

- [ ] Commits are signed off (`git commit -s`) — we use [DCO](../blob/main/CONTRIBUTING.md), not a CLA
- [ ] No clipboard contents, personal data, or live credentials in code, tests, or fixtures
