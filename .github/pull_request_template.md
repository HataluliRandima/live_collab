## What does this change?

<!-- One or two sentences. Link related issues with "Fixes #123". -->

## Why?

## How was it verified?

- [ ] `mix test` (and `mix test --only distributed` if Presence/cluster behaviour changed)
- [ ] `npm test` (if hooks under `assets/js` changed)
- [ ] `mix format --check-formatted` and `mix credo --strict`
- [ ] New behaviour is covered by tests; bug fixes include a regression test

## Checklist

- [ ] Public API changes are documented (`@doc`, README, guides)
- [ ] `CHANGELOG.md` has an entry under "Unreleased"
- [ ] Breaking changes are called out above
