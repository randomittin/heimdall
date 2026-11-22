# Stack Pack — `react-native`

Cold-start knowledge for the `coder`, `architect`, `reviewer`, and `planner`
role agents when working in a React Native or Expo project.

This is the base scaffold. Repo-specific quirks (custom Metro config, monorepo
package paths, internal design-system imports) belong in the project's
`.planning/skills/`, which layers on top of and overrides this pack.

---

## Section 1 — Stack ID & Detection Signals

- **Stack id:** `react-native`
- **Detected from:** `package.json` whose `dependencies` or
  `devDependencies` contain `react-native` **or** `expo`.
- **Disambiguation:** presence of `next` in `dependencies` detects as
  `nextjs`, not `react-native`. Presence of `react-native` (with or without
  `expo`) always wins over plain `react`. A bare `expo` entry without
  `react-native` is still `react-native` — Expo SDK bundles RN internally.

---

## Section 2 — Directory Layout Conventions

### Expo Router project (managed workflow, SDK 50+)

```
app/                        # file-based routes (Expo Router v3+)
  (tabs)/
    _layout.tsx             # tab navigator config
    index.tsx               # first tab screen
  _layout.tsx               # root layout — providers, splash, fonts
  +not-found.tsx            # 404 screen
assets/
  fonts/                    # OTF/TTF files loaded via expo-font
  images/                   # static images; use require('./assets/...')
components/
  ui/                       # primitives: Button, Text, Icon, etc.
  <FeatureName>/            # feature-scoped composites
constants/
  Colors.ts                 # design-token palette
  Layout.ts                 # spacing / breakpoints if needed
hooks/
  use<Name>.ts              # custom hooks — one per file, named export
store/                      # global state (Zustand slices or Redux RTK)
  <slice>.ts
services/                   # API clients + data-fetching
  api.ts
lib/                        # pure utilities (no RN imports)
  <util>.ts
__tests__/
  use-cases/                # THE GATE: one file per user journey, driven through the real screens
    <journey>.test.tsx      # it('search email by sender', ...)
  <module>.test.tsx         # optional: pins one specific bug; never a gate
test-support/
  fakes/                    # one fake per external system (API, push, payments, location); NOT under
                            # __tests__ (jest would run every file there as a test)
app.json / app.config.ts    # Expo config (SDK version, plugins, scheme)
babel.config.js             # must include expo preset first
tsconfig.json               # "extends": "expo/tsconfig.base"
eas.json                    # EAS Build / Submit profiles
```

### Bare React Native project (no Expo Router)

```
src/
  screens/                  # one file per screen
  components/
  hooks/
  navigation/               # React Navigation stacks/tabs
  store/
  services/
  lib/
android/                    # native Android project
ios/                        # native iOS project (CocoaPods)
__tests__/
index.js                    # RN entry — AppRegistry.registerComponent
babel.config.js
tsconfig.json
metro.config.js
```

**Placement rules for new files:**

- New screens go in `app/` (Expo Router) or `src/screens/` (bare), never
  in `components/`.
- Shared presentational primitives go in `components/ui/`.
- Feature-scoped components go in `components/<FeatureName>/`.
- Hooks that wrap a single external library go in `hooks/use<LibName>.ts`.
- No business logic inside screen files — extract to hooks or services.
- A new user-facing capability gets a journey file in `__tests__/use-cases/`
  (`<journey>.test.tsx`), not a per-component test; an external system (API,
  push, payments, location) gets one fake in `test-support/fakes/`.
- Platform-specific variants use `.ios.tsx` / `.android.tsx` suffixes;
  the shared import resolves them automatically at bundle time.

---

## Section 3 — Lint / Format / Test / Build Commands

### Install

Use `npx expo install` for packages that have known Expo SDK peer
requirements (e.g. `expo-camera`, `react-native-gesture-handler`). It pins
the correct version for the installed SDK.

```
npx expo install <package>          # Expo-managed dep — version-pinned
npm install <package>               # non-Expo dep (e.g. zustand, zod)
```

### Run

```
npx expo start                      # Metro + DevTools
npx expo start --ios                # open in iOS Simulator
npx expo start --android            # open in Android Emulator
npx expo start --tunnel             # LAN-less via ngrok
npx react-native run-ios            # bare RN — direct Xcode build
npx react-native run-android        # bare RN — direct Gradle build
```

### Lint

```
npx eslint . --max-warnings 0
```

Config must extend `expo` (via `eslint-config-expo`) or `@react-native`
(via `@react-native/eslint-config`). `--max-warnings 0` means any ESLint
warning is a build failure — this is the enforced bar.

Single file:

```
npx eslint src/components/Button.tsx --max-warnings 0
```

### Format

```
npx prettier --write .
```

### Type check

```
npx tsc --noEmit
```

The `tsconfig.json` must extend `expo/tsconfig.base` (Expo) or include
`@tsconfig/react-native` (bare). Strict mode is expected; do not weaken
`strict: true`.

### Test — the gate is the use-case suite

The gate is `lint` + the use-case suite: one journey per file, driven through the
app's real screens the way the user drives them (`@testing-library/react-native`
on the real root: `renderRouter` from `expo-router/testing-library` for Expo
Router, `<App />` for bare), with the real navigation, providers and store. Fakes
only at the external boundaries: the API client or network, push, camera,
location, payments, the clock. See `skills/heimdall/references/use-case-tests.md`.

```
npm run test:use-cases                           # "test:use-cases": "jest __tests__/use-cases"
npx jest __tests__/use-cases/book-a-cab          # one journey: select its file by path
```

Jest exits 1 ("No tests found") when the path matches no file; never add
`--passWithNoTests`. Select a journey by its file path (one file per journey).
A journey that needs native behaviour (deep links, permissions, push) runs on a
simulator build with Maestro (`maestro test e2e/use-cases/<journey>.yaml`) or
Detox, chained into the same `test:use-cases` script.

During work, run only the tests of the files you touched, once. These pin a
specific bug and are not a gate:

```
npx jest --testPathPattern="Button" # single file / pattern
```

Test runner is `jest-expo` (Expo) or `@react-native/jest-preset` (bare).
Config lives in `jest.config.js` or the `jest` key in `package.json`. Do not gate
on the whole suite (`npx jest`) or on coverage (`--coverage`).

### Gate declaration

`.heimdall/repo-checks.json`, committed (each `cmd` runs with `bash -c` from the
repo root). Nothing else gates the repo: no full-suite or coverage check.

```json
{"schema":1,"checks":[
  {"name":"lint","cmd":"npx eslint . --max-warnings 0 && npx tsc --noEmit"},
  {"name":"use-cases","cmd":"npm run test:use-cases"}
]}
```

### Build (EAS)

```
eas build --platform ios --profile preview
eas build --platform android --profile preview
eas build --platform all --profile production
eas submit --platform ios                        # upload to App Store Connect
eas submit --platform android                    # upload to Play Console
```

Profiles (`preview`, `production`, `development`) are defined in `eas.json`.
`development` profile builds a dev client; `preview` builds a signed
distributable without store submission.

---

## Section 4 — Acceptance-Criteria Templates

Drop these into a task plan verbatim. Each is a copy-paste-runnable command
with a checkable exit code or output. The gate is the first group: `lint` +
`use-cases`.

### Gate: `lint` + `use-cases`

- `npx eslint . --max-warnings 0 && npx tsc --noEmit` exits 0 — the `lint` check:
  zero warnings, no TypeScript errors.
- `npm run test:use-cases` exits 0 — the `use-cases` check: every journey passes
  through the real screens. Jest exits 1 when no test file matches.
- For each journey the plan names, `npx jest __tests__/use-cases/<journey>` exits
  0 — the file exists and passes.
- No journey is skipped or a todo:
  `grep -rnE "(it|test|describe)\.(skip|todo)|(^|[^a-zA-Z])x(it|describe)\(" __tests__/use-cases/`
  returns no lines.
- Journeys render the root and act like the user, never a component or hook on
  its own:
  `grep -rnE "from ['\"](\.\./)+(components|hooks)/" __tests__/use-cases/*.test.tsx`
  returns no lines.
- The app's own code is never mocked (only external clients and native modules are):
  `grep -rnE "jest\.mock\(['\"](\.\./)+(components|hooks|store|lib)/" __tests__/use-cases/`
  returns no lines.
- A new screen is reached by a journey:
  `grep -rln "<ScreenName>\|<route path>" __tests__/use-cases/` returns a file.

### Code shape and build

- No inline styles where a `StyleSheet` is already defined in the file:
  `git diff --name-only HEAD | xargs grep -n "style={{" 2>/dev/null` returns
  no output for the changed files.
- New component exported from `components/ui/` has a named export (not
  default): `grep -n "export default" components/ui/<ComponentName>.tsx`
  returns no matches.
- Platform-specific file pairs are both present when one is added:
  if `<Name>.ios.tsx` is added, `ls <Name>.android.tsx` exits 0.
- `eas build --platform all --profile preview --non-interactive` exits 0 —
  cloud build succeeds for both platforms (run on CI or before shipping).
- Safe-area applied on every new top-level screen:
  `grep -n "SafeAreaView\|useSafeAreaInsets\|edges=" app/<ScreenFile>.tsx`
  returns at least one match.

---

## Section 5 — Common Failure Patterns + Fixes

- **Symptom:** Metro `ENOENT` or stale module error after installing a new
  package or switching branches.
  **Cause:** Metro's transform cache is stale.
  **Fix:** `npx expo start --clear` (Expo) or
  `npx react-native start --reset-cache` (bare). If the error persists,
  delete `node_modules/.cache` and restart.

- **Symptom:** `TypeError: undefined is not a function` at runtime referencing
  `Animated` or `useSharedValue`; or build error `Reanimated Babel plugin was
  not found`.
  **Cause:** `react-native-reanimated/plugin` is missing from `babel.config.js`
  or it is not the **last** entry in the `plugins` array.
  **Fix:** In `babel.config.js`, ensure:
  ```js
  plugins: [
    // ... other plugins first ...
    'react-native-reanimated/plugin',  // MUST be last
  ]
  ```
  Then clear Metro cache: `npx expo start --clear`.

- **Symptom:** App crashes on Android with `JSIModule was already registered`
  or performance differs wildly between iOS and Android.
  **Cause:** Hermes is enabled on Android (default since RN 0.70 / Expo SDK 48)
  but disabled on iOS, or vice versa.
  **Fix:** In `app.json` / `app.config.ts`, set `jsEngine: "hermes"` for both
  platforms. For bare projects, set `hermesEnabled = true` in both
  `android/gradle.properties` and `ios/Podfile`. Hermes is strongly preferred
  over JSC for startup time and memory.

- **Symptom:** `expo install` or `npx expo start` prints
  `Your project may not work correctly until you install the correct versions
  of the packages` with a list of mismatched versions.
  **Cause:** One or more packages are pinned to versions incompatible with the
  installed Expo SDK.
  **Fix:** Run `npx expo install --fix`. Commit the updated `package.json` and
  `package-lock.json`. Do not manually pin Expo-managed packages.

- **Symptom:** `@react-native-async-storage/async-storage` calls resolve but
  always return `null`; or a red-screen native module error on device.
  **Cause:** Native module not linked. On Expo managed workflow the package
  requires an Expo config plugin; on bare RN it requires `pod install`.
  **Fix (Expo):** Add `@react-native-async-storage/async-storage` to
  `app.json` plugins array or confirm it is auto-linked (SDK 43+). Rebuild
  the dev client: `eas build --profile development`.
  **Fix (bare):** `cd ios && pod install && cd ..`, then rebuild.

- **Symptom:** `FlatList` renders slowly or drops frames when scrolling a
  large list.
  **Cause:** Missing `keyExtractor`, heavy `renderItem` components, or missing
  `getItemLayout` preventing scroll optimization.
  **Fix:** Provide a stable string `keyExtractor`. Wrap `renderItem` in
  `React.memo`. If all items have fixed height, add `getItemLayout`. Avoid
  anonymous arrow functions in JSX props of `FlatList`. Consider
  `FlashList` from `@shopify/flash-list` for lists > 200 items.

- **Symptom:** Content hidden behind the notch, home indicator, or camera
  cutout on iOS / Android.
  **Cause:** Screen does not use safe-area insets.
  **Fix (Expo):** Wrap root screen content in `<SafeAreaView>` from
  `react-native-safe-area-context` (not the deprecated one from
  `react-native`). Or use the `useSafeAreaInsets()` hook to apply padding
  manually. Ensure `<SafeAreaProvider>` wraps the root layout in
  `app/_layout.tsx`.

- **Symptom:** TypeScript reports `Cannot find module 'expo-router'` or
  path alias `@/` resolves to `any`.
  **Cause:** `tsconfig.json` is missing the `expo/tsconfig.base` extension
  or the `paths` alias is defined but `babel-plugin-module-resolver` is not
  installed / configured.
  **Fix:** Extend `expo/tsconfig.base` in `tsconfig.json`. For custom `@/`
  aliases, install `babel-plugin-module-resolver` and add it to
  `babel.config.js` before the reanimated plugin. Re-run `npx tsc --noEmit`
  to confirm.

- **Symptom:** `eas build` fails with `Gradle build daemon disappeared`.
  **Cause:** Android build ran out of heap on the EAS build worker.
  **Fix:** In `android/gradle.properties`, set
  `org.gradle.jvmargs=-Xmx4096m -XX:MaxMetaspaceSize=1024m`. Commit and
  re-trigger the build.

- **Symptom:** Hot reload stops working; editing a file does nothing until
  full reload.
  **Cause:** Fast Refresh incompatibility — the module exports a mix of
  components and non-component values, or a `useEffect` has a missing
  dependency that breaks the Fast Refresh contract.
  **Fix:** Separate component files from non-component utility files. Fix
  `useEffect` dependency arrays. Avoid exporting plain objects alongside
  components from the same file.

---

## Code Quality Bar

All generated code must be production-ready: real implementations only.
Do not emit incomplete or unfinished code, do not leave function bodies empty,
do not return hard-coded fake data in place of real logic. If something cannot
be fully implemented, state that explicitly — do not fake it.
