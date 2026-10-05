# runhmd

Front door to [hmd](https://runheimdall.dev): one command, no setup.

```bash
npx runhmd <path>        # runs: hmd attack <path>
npx runhmd attack .      # the same, spelled out
npx runhmd prove         # any other hmd subcommand passes straight through
```

`attack` is the default command. A first argument that is an hmd subcommand (the list is
`subcommands.txt`, kept in step with hmd's own dispatch by the repo's tests) passes through
untouched; anything else - a path, a PR URL, a flag such as `--json` - is a target for `attack`.
A directory that is named like a subcommand has to be spelled as a path: `npx runhmd ./team`.

`npx runhmd --version` and `npx runhmd --help` are answered by the wrapper itself: nothing is
fetched, installed or run.

## First run

hmd has to be on the machine. `runhmd` looks for it on `PATH`, then in `~/.local/bin`, then in
`~/.heimdall/bin`. If it finds none - or finds one older than the hmd release this package is
pinned to (`runhmd --version` prints it) - it runs the pinned installer first:

1. fetch `install.sh` for the pinned release tag,
2. compute its sha256 and compare it with the checksum baked into this package at publish time,
3. only if they are equal, hand it to `bash`.

A mismatch aborts before a single byte runs, and `runhmd` does not fall back to an hmd it
already found: this package runs the hmd it was published with, or nothing. An hmd newer than
the pin is never downgraded.

It is the installer `npx runheimdall` runs - same pin, same checks (the two wrappers' pinning
code is kept identical by `test/runhmd-parity.test.sh` in the repository) - so it writes the same
files: `~/.heimdall/`, `~/.local/bin/hmd`, a PATH line in your shell profile, Claude Code's
`settings.json`, and on macOS a nightly LaunchAgent (`HEIMDALL_NO_DREAM_SCHEDULE=1` skips it).
[What the installer writes](https://github.com/randomittin/heimdall#install) lists each one, and
`hmd uninstall` reverses them - for every subcommand except the two in the next section.

## Zero footprint

`npx runhmd attack ...` and `npx runhmd demo --offline` are the trial path, so they leave nothing
behind. They run with `HOME` redirected into one temp dir, together with the overrides that would walk
past it (`HEIMDALL_HOME`, `CLAUDE_CONFIG_DIR`, `HEIMDALL_LAUNCH_AGENTS_DIR`, `HEIMDALL_TEAM_DIR`), and the
temp dir is removed when the command ends. If hmd has to be installed first, the same pinned, sha256-checked
installer runs there - from an empty work dir, with the nightly LaunchAgent off - and goes with it. Your shell
profile, `~/Library/LaunchAgents`, `~/.claude`, `~/.heimdall` and the repository you run it in are not touched.

A temp dir inside, or an `--out` aimed at, `~/.zshrc` (and its siblings), `~/Library/LaunchAgents` or
`~/.claude` is refused with exit 2 before anything runs. `demo --offline` makes no network call (and neither
does `attack`'s built-in engine). Because `HOME` moves, a toolchain shim that finds its versions through `$HOME`
(asdf, volta) needs its own `*_DIR`/`*_HOME` variable exported; the node running `runhmd` is kept first on `PATH`.
`test/zero-footprint.test.sh` in the repository is the proof. Every other subcommand (`team`, `update`, ...)
keeps the installer's normal footprint.

Prerequisites are hmd's own: Claude Code, git and `jq`. Node 16 or newer, and bash.

## Two names

`runheimdall` installs hmd and stops. `runhmd` is the same verified install plus the default
command. Both are published from the same release and pin the same `install.sh`.

## License

MIT
