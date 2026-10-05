#!/usr/bin/env node
'use strict';

/*
 * runhmd — npx front door to hmd.
 *
 *   runhmd <path>          runs  hmd attack <path>     (attack is the default command)
 *   runhmd <subcommand> …  runs  hmd <subcommand> …    (any subcommand hmd itself dispatches)
 *   runhmd --version|--help  answered here — nothing is installed, fetched or run
 *
 * hmd is located the way a shell (or the installer, which links it into ~/.local/bin) would
 * have left it. If it is missing — or reports a release older than the one this package is
 * pinned to — the pinned install.sh is fetched, its sha256 asserted against the checksum baked in
 * at publish time, and only then handed to bash. That is the SAME installer, pin and check as
 * `npx runheimdall` (packages/runheimdall/bin/runheimdall.js): the pinning code below is
 * mirrored from it line for line, and test/runhmd-parity.test.sh fails when the two diverge.
 *
 * Trust model: we never run a single byte we did not first verify. The script is buffered
 * fully, hashed, compared, and only then handed to bash. A mismatch (tampered CDN, wrong tag,
 * truncated download) aborts before exec — and aborts the whole command: an hmd that happens to
 * be installed already is NOT run as a fallback, because the point of the pin is that this
 * package runs the hmd it was published with, or nothing.
 *
 * Offline-testable: set RUNHMD_INSTALL_SCRIPT to a local file path to use its bytes instead of
 * fetching over the network. The sha256 assertion runs identically against the local bytes —
 * point it at a file + a matching RUNHMD_SHA256 to prove the run path, or a mismatching one to
 * prove the abort.
 *
 * Zero footprint: `attack` and `demo --offline` are the trial path - a stranger runs them once to see
 * what runhmd does - so they leave nothing behind. They run with HOME (and every override that would
 * walk past it: HEIMDALL_HOME, CLAUDE_CONFIG_DIR, HEIMDALL_LAUNCH_AGENTS_DIR, HEIMDALL_TEAM_DIR)
 * redirected into one temp dir that is removed when the command ends; the pinned installer, if it has
 * to run, installs there and runs from an empty work dir, with the LaunchAgent schedule off and Python
 * bytecode writing off. A temp dir inside, or an --out aimed at, ~/.zshrc and its siblings,
 * ~/Library/LaunchAgents or ~/.claude is refused with exit 2 before anything runs. Every other
 * subcommand keeps the installer's normal footprint (see README). test/zero-footprint.test.sh proves it.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');

const pkg = require(path.join(__dirname, '..', 'package.json'));
const meta = pkg.heimdall || {};

// `URL` keeps runheimdall.js's name for the install URL so the two files stay line-for-line
// comparable. It shadows the global URL class, which fetchHttps therefore reaches through
// require('url') — the one sanctioned divergence (see test/runhmd-parity.test.sh).
const TAG = process.env.RUNHMD_TAG || meta.tag;
const URL = process.env.RUNHMD_INSTALL_URL || meta.installScriptUrl;
const EXPECTED_SHA = (process.env.RUNHMD_SHA256 || meta.sha256 || '').toLowerCase();
const LOCAL_OVERRIDE = process.env.RUNHMD_INSTALL_SCRIPT;
// The real home, read before zero-footprint mode redirects HOME; ZF is that mode's state (null = off).
const REAL_HOME = os.homedir();
let ZF = null;

function die(msg) {
  process.stderr.write('runhmd: ' + msg + '\n');
  process.exit(1);
}

// Narration of runhmd's own extra steps. Every such line carries ': note: ' so the parity test
// can tell it apart from the verification and refusal output, which must match runheimdall's.
function note(msg) {
  process.stderr.write('runhmd: note: ' + msg + '\n');
}

// Exit 2 (usage/config) is the refusal code across the runhmd tools. die() stays exactly as
// runheimdall.js has it - the parity test compares it - so zero-footprint refusals use their own.
function refuse(msg) {
  process.stderr.write('runhmd: ' + msg + '\n');
  process.exit(2);
}

function sha256(buf) {
  return crypto.createHash('sha256').update(buf).digest('hex');
}

// Read the install script bytes, either from a local override (offline tests)
// or by fetching the pinned-tag URL over HTTPS. Returns a Buffer.
function loadScript() {
  if (LOCAL_OVERRIDE) {
    if (!fs.existsSync(LOCAL_OVERRIDE)) {
      die('RUNHMD_INSTALL_SCRIPT points at a missing file: ' + LOCAL_OVERRIDE);
    }
    return Promise.resolve(fs.readFileSync(LOCAL_OVERRIDE));
  }
  if (!URL) {
    die('no install script URL configured (package.json heimdall.installScriptUrl is empty)');
  }
  return fetchHttps(URL);
}

function fetchHttps(url, redirects) {
  redirects = redirects || 0;
  if (redirects > 5) {
    return Promise.reject(new Error('too many redirects fetching ' + url));
  }
  const https = require('https');
  return new Promise(function (resolve, reject) {
    const req = https.get(url, { headers: { 'User-Agent': 'runhmd/' + pkg.version } }, function (res) {
      const status = res.statusCode || 0;
      // Follow the 302 (runheimdall.dev/install) and any GitHub raw redirects.
      if (status >= 300 && status < 400 && res.headers.location) {
        res.resume();
        const next = new (require('url').URL)(res.headers.location, url).toString();
        resolve(fetchHttps(next, redirects + 1));
        return;
      }
      if (status !== 200) {
        res.resume();
        reject(new Error('HTTP ' + status + ' fetching ' + url));
        return;
      }
      const chunks = [];
      res.on('data', function (c) { chunks.push(c); });
      res.on('end', function () { resolve(Buffer.concat(chunks)); });
      res.on('error', reject);
    });
    req.on('error', reject);
    req.setTimeout(30000, function () {
      req.destroy(new Error('timed out fetching ' + url));
    });
  });
}

// The two guards that run before anything else: a wrapper whose pin is missing, still the
// publish-time placeholder, or not a sha256 was not built by release/sync-release.sh and is
// not trusted to run anything at all — not the installer, and not an hmd that is already there.
function assertPinWellFormed() {
  if (!EXPECTED_SHA || EXPECTED_SHA === 'replace_at_publish') {
    die('no published checksum baked in — this wrapper was not built by release/sync-release.sh. Refusing to run an unverified script.');
  }
  if (!/^[0-9a-f]{64}$/.test(EXPECTED_SHA)) {
    die('configured sha256 is not a 64-char hex digest: ' + EXPECTED_SHA);
  }
}

// Fetch (or read) the install script and assert its sha256 against the pin. Resolves with the
// verified bytes; dies on a mismatch before anything has been executed.
function verifiedScript() {
  return loadScript().then(function (buf) {
    const actual = sha256(buf);
    if (actual !== EXPECTED_SHA) {
      die(
        'checksum mismatch — refusing to run.\n' +
        '  tag:      ' + (TAG || '(unknown)') + '\n' +
        '  source:   ' + (LOCAL_OVERRIDE || URL) + '\n' +
        '  expected: ' + EXPECTED_SHA + '\n' +
        '  actual:   ' + actual
      );
    }
    process.stderr.write('runhmd: verified install.sh (' + (TAG || 'pinned') + ', sha256 ' + actual.slice(0, 12) + '…) — running.\n');
    return buf;
  });
}

// Hand the verified script to bash and return its exit status. The buffer goes to a temp file
// (bash needs a path for $0 to be meaningful), and the file is removed whatever happens. The
// installer gets NO arguments: runhmd's arguments are for hmd.
function runScript(buf) {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'runhmd-'));
  const scriptPath = path.join(tmpDir, 'install.sh');
  fs.writeFileSync(scriptPath, buf, { mode: 0o700 });
  let result;
  try {
    result = spawnSync('bash', [scriptPath], { stdio: 'inherit', env: process.env, cwd: ZF ? ZF.work : undefined });
  } finally {
    try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch (e) { /* best effort cleanup */ }
  }
  if (result.error) {
    die('failed to run installer: ' + result.error.message);
  }
  if (typeof result.status !== 'number') {
    die('installer terminated by signal ' + result.signal);
  }
  return result.status;
}

// ── routing ──────────────────────────────────────────────────────────────────

// The subcommands hmd itself dispatches: subcommands.txt, one word per line, #-comments.
function loadSubcommands() {
  let text;
  try {
    text = fs.readFileSync(path.join(__dirname, '..', 'subcommands.txt'), 'utf8');
  } catch (e) {
    die('cannot read subcommands.txt (' + e.message + ') — without it runhmd cannot tell a subcommand from a path');
  }
  const words = text.split('\n')
    .map(function (line) { return line.trim(); })
    .filter(function (line) { return line !== '' && line.charAt(0) !== '#'; });
  if (words.length === 0) {
    die('subcommands.txt lists no subcommands — without it runhmd cannot tell a subcommand from a path');
  }
  return new Set(words);
}

function defaultCommand() {
  if (!meta.defaultCommand) {
    die('package.json heimdall.defaultCommand is not set — there is nothing to run for a bare path');
  }
  return meta.defaultCommand;
}

// A first argument that is an hmd subcommand passes through untouched; anything else — a path,
// a PR URL, a flag, nothing at all — is a target for the default command.
function route(args, subcommands, dflt) {
  if (args.length > 0 && subcommands.has(args[0])) {
    return args;
  }
  return [dflt].concat(args);
}

// ── zero-footprint mode ──────────────────────────────────────────────────────

// What a trial run must never touch in the real home: the shell profiles the installer appends its
// PATH line to, LaunchAgents (a HOME redirect does not isolate launchd), and Claude Code's settings.
const PROTECTED_FILES = ['.zshrc', '.zprofile', '.zshenv', '.bashrc', '.bash_profile', '.profile'];
const PROTECTED_TREES = [path.join('Library', 'LaunchAgents'), '.claude'];
// Overrides the installer and hmd honour INSTEAD of $HOME: left in the environment they walk straight
// past the redirect (a Claude Code user very likely has CLAUDE_CONFIG_DIR set).
const HOME_OVERRIDES = ['HEIMDALL_HOME', 'HEIMDALL_TEAM_DIR', 'HEIMDALL_LAUNCH_AGENTS_DIR', 'CLAUDE_CONFIG_DIR'];

function wantsZeroFootprint(hmdArgs) {
  return hmdArgs[0] === 'attack' || (hmdArgs[0] === 'demo' && hmdArgs.indexOf('--offline') !== -1);
}

// realpath of the deepest ancestor that exists, plus the part that does not exist yet.
function resolveLoose(p) {
  let head = path.resolve(p);
  const rest = [];
  while (true) {
    try {
      return path.join.apply(path, [fs.realpathSync(head)].concat(rest));
    } catch (e) {
      const parent = path.dirname(head);
      if (parent === head) {
        return path.resolve(p);
      }
      rest.unshift(path.basename(head));
      head = parent;
    }
  }
}

// Which protected location (as the user would write it) p is, or lies inside; null if none.
function protectedReason(p) {
  const target = resolveLoose(p);
  for (let i = 0; i < PROTECTED_FILES.length; i++) {
    if (target === resolveLoose(path.join(REAL_HOME, PROTECTED_FILES[i]))) {
      return '~/' + PROTECTED_FILES[i];
    }
  }
  for (let i = 0; i < PROTECTED_TREES.length; i++) {
    const tree = resolveLoose(path.join(REAL_HOME, PROTECTED_TREES[i]));
    if (target === tree || target.indexOf(tree + path.sep) === 0) {
      return '~/' + PROTECTED_TREES[i];
    }
  }
  return null;
}

// The directories handed to --out: `--out DIR` and `--out=DIR`.
function outTargets(args) {
  const found = [];
  args.forEach(function (a, i) {
    if (a === '--out' && i + 1 < args.length) {
      found.push(args[i + 1]);
    } else if (a.indexOf('--out=') === 0) {
      found.push(a.slice('--out='.length));
    }
  });
  return found;
}

// Refuse (exit 2) anything that would write a protected path, then move the whole run into a temp dir
// that is removed when this process exits - on every path out, die() and refuse() included.
function enterZeroFootprint(hmdArgs) {
  const tmpInside = protectedReason(os.tmpdir());
  if (tmpInside) {
    refuse('zero-footprint: the temporary directory (' + os.tmpdir() + ') is inside ' + tmpInside + ' - refusing to create anything there. Point TMPDIR somewhere else.');
  }
  outTargets(hmdArgs).forEach(function (out) {
    const why = protectedReason(out);
    if (why) {
      refuse('zero-footprint: --out ' + out + ' would write into ' + why + ' - refusing. Pick another directory.');
    }
  });

  let root;
  try {
    root = fs.mkdtempSync(path.join(os.tmpdir(), 'runhmd-zf-'));
  } catch (e) {
    die('cannot create a temporary directory under ' + os.tmpdir() + ': ' + e.message);
  }
  ['home', 'work', 'tmp'].forEach(function (d) { fs.mkdirSync(path.join(root, d)); });
  process.on('exit', function () {
    try { fs.rmSync(root, { recursive: true, force: true }); } catch (e) { /* the OS reaps its temp dir */ }
  });

  HOME_OVERRIDES.forEach(function (name) { delete process.env[name]; });
  process.env.HOME = path.join(root, 'home');
  process.env.TMPDIR = path.join(root, 'tmp');
  process.env.HEIMDALL_NO_DREAM_SCHEDULE = '1';
  process.env.PYTHONDONTWRITEBYTECODE = '1';
  // The node that is running this wrapper stays first: a shim that finds its versions through $HOME cannot.
  process.env.PATH = path.dirname(process.execPath) + path.delimiter + (process.env.PATH || '');
  return { root: root, home: path.join(root, 'home'), work: path.join(root, 'work') };
}

// ── hmd discovery ────────────────────────────────────────────────────────────

function isExecutableFile(p) {
  try {
    fs.accessSync(p, fs.constants.X_OK);
    return fs.statSync(p).isFile();
  } catch (e) {
    return false;
  }
}

// PATH first, then where the installer links it (~/.local/bin/hmd) and where it lives
// (~/.heimdall/bin/heimdall) — a fresh install is usable in this very process even though the
// PATH line it appended to the shell profile only reaches NEW shells.
function findHmd(homes, searchPath) {
  const dirs = searchPath === false ? [] : (process.env.PATH || '').split(path.delimiter).filter(Boolean);
  const candidates = dirs.map(function (dir) { return path.join(dir, 'hmd'); });
  (homes || [os.homedir()]).forEach(function (home) {
    candidates.push(path.join(home, '.local', 'bin', 'hmd'), path.join(home, '.heimdall', 'bin', 'heimdall'));
  });
  for (let i = 0; i < candidates.length; i++) {
    if (isExecutableFile(candidates[i])) {
      return candidates[i];
    }
  }
  return null;
}

// "Heimdall vX.Y.Z" (first line of `hmd --version`) -> [X, Y, Z]; null when unreadable.
function parseVersion(text) {
  const m = /v?(\d+)\.(\d+)\.(\d+)/.exec(String(text).split('\n')[0]);
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null;
}

function compareVersions(a, b) {
  for (let i = 0; i < 3; i++) {
    if (a[i] !== b[i]) {
      return a[i] < b[i] ? -1 : 1;
    }
  }
  return 0;
}

function formatVersion(v) {
  return 'v' + v.join('.');
}

function installedVersion(hmd) {
  const r = spawnSync(hmd, ['--version'], { encoding: 'utf8', timeout: 20000 });
  if (r.error || r.status !== 0) {
    return null;
  }
  return parseVersion(r.stdout);
}

// Return a path to an hmd at least as new as the pinned release — running the pinned installer
// first when there is none. An hmd older than the pin is never run: a release that predates a
// subcommand treats it as a free-text task prompt and starts an agent session instead.
async function ensureHmd(pinned) {
  let hmd = findHmd(ZF ? [REAL_HOME] : undefined);   // zero-footprint: HOME is already the temp dir, so look in the real one
  let have = hmd ? installedVersion(hmd) : null;
  if (hmd && have && compareVersions(have, pinned) >= 0) {
    return hmd;
  }

  if (!hmd) {
    note('hmd is not installed — running the pinned installer (' + TAG + ') first.');
  } else if (!have) {
    note('could not read the version of ' + hmd + ' — running the pinned installer (' + TAG + ') first.');
  } else {
    note('installed hmd ' + formatVersion(have) + ' is older than the ' + TAG + " this runhmd is pinned to — running the pinned installer first.");
  }
  if (ZF) {
    note('zero-footprint: installing into a throwaway directory (' + ZF.root + ', removed when this command ends) - nothing is written to your home directory, shell profile, LaunchAgents or Claude Code settings.');
  } else {
    note('same installer and footprint as `npx runheimdall`: ~/.heimdall, ~/.local/bin, a PATH line in your shell profile, Claude Code settings, and on macOS a nightly LaunchAgent (HEIMDALL_NO_DREAM_SCHEDULE=1 skips it). `hmd uninstall` reverses it.');
  }

  const status = runScript(await verifiedScript());
  if (status !== 0) {
    die('installer exited with status ' + status + ' — not running hmd.');
  }

  // zero-footprint: the installer ran with HOME = the temp dir, so what it installed is there and only there
  hmd = ZF ? findHmd([ZF.home], false) : findHmd();
  if (!hmd) {
    die('the installer finished but no hmd was found (looked ' + (ZF ? 'in ' + ZF.home + '/.local/bin and ' + ZF.home + '/.heimdall/bin' : 'on PATH, in ~/.local/bin and in ~/.heimdall/bin') + ').');
  }
  have = installedVersion(hmd);
  if (!have || compareVersions(have, pinned) < 0) {
    die('the installer finished but ' + hmd + ' reports ' + (have ? formatVersion(have) : 'no readable version') + ', older than the pinned ' + TAG + ' — refusing to run hmd on a build that predates this release.');
  }
  return hmd;
}

// ── local flags ──────────────────────────────────────────────────────────────

function printVersion() {
  process.stdout.write(
    'runhmd ' + pkg.version + '\n' +
    'pinned hmd release:        ' + (meta.tag || '(none)') + '\n' +
    'pinned install.sh sha256:  ' + (meta.sha256 ? meta.sha256.slice(0, 12) + '…' : '(none baked in)') + '\n'
  );
}

function printHelp() {
  process.stdout.write([
    'runhmd - front door to hmd',
    '',
    'usage:',
    '  runhmd [<path>|<pr-url>] [options]   run `hmd attack` (the default command) on a target',
    '  runhmd <subcommand> [args...]        pass through to `hmd <subcommand> [args...]`',
    '  runhmd --version                     this package, and the hmd release it is pinned to',
    '  runhmd --help                        this text',
    '',
    'A first argument that is not an hmd subcommand is a target for `hmd attack`. To attack a',
    'directory that is named like a subcommand, spell it as a path: runhmd ./team',
    '',
    'If hmd is missing - or older than the release this package is pinned to - the pinned',
    'install.sh is fetched, checked against the sha256 baked into this package, and only then run:',
    'the installer `npx runheimdall` runs, with the same footprint. `hmd uninstall` reverses it.',
    ''
  ].join('\n'));
}

// ── main ─────────────────────────────────────────────────────────────────────

async function main() {
  const args = process.argv.slice(2);

  if (['--version', '-v', '-V'].indexOf(args[0]) !== -1) {
    printVersion();
    return;
  }
  if (['--help', '-h'].indexOf(args[0]) !== -1) {
    printHelp();
    return;
  }

  assertPinWellFormed();
  const hmdArgs = route(args, loadSubcommands(), defaultCommand());
  const pinned = parseVersion(TAG);
  if (!pinned) {
    die('the pinned release "' + TAG + '" is not a vX.Y.Z version');
  }

  if (wantsZeroFootprint(hmdArgs)) {
    ZF = enterZeroFootprint(hmdArgs);
  }
  const hmd = await ensureHmd(pinned);
  const result = spawnSync(hmd, hmdArgs, { stdio: 'inherit', env: process.env });
  if (result.error) {
    die('failed to run hmd: ' + result.error.message);
  }
  if (typeof result.status !== 'number') {
    die('hmd terminated by signal ' + result.signal);
  }
  process.exitCode = result.status;
}

main().catch(function (err) {
  die(err && err.message ? err.message : String(err));
});
