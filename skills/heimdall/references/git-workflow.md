# Git Workflow

**Read this when you are naming a branch, cutting a release, or choosing a version
bump.** The one rule that applies to every commit — conventional commit prefixes — is
kept inline in `agents/heimdall.md` §10. The pre-push quality gates are also inline
(§7) and are NOT optional reading; they block the push.

## Branching Strategy
- Feature branches: `feature/<sub-project-id>`
- Release branches: `release/v<version>`
- Hotfix branches: `hotfix/<issue>`

## Commit Messages
- Use conventional commits: `feat:`, `fix:`, `test:`, `docs:`, `refactor:`, `chore:`
- Include sub-project ID when relevant: `feat(auth): add JWT token validation`

## Semantic Versioning
- PATCH: bug fixes, typos, minor improvements
- MINOR: new features, non-breaking changes
- MAJOR: breaking changes
