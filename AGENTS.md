# AGENTS.md

This file provides guidance to the AI agent when working with code in this repository.

## Project Structure

ZeroOmega is a browser extension (Manifest V3) for proxy management, forked from SwitchyOmega. It consists of four npm modules:

- `omega-pac` — PAC script generation (standalone, can be published to npm)
- `omega-target` — browser-independent options/profile management logic
- `omega-web` — Angular 1.x web-based configuration UI
- `omega-target-chromium-extension` — Chromium/Firefox extension target (background, popup, manifest)

## Language

The primary source language is **CoffeeScript** (`.coffee` files). Grunt compiles/bundles it. JavaScript files in `build/` and `dist/` are generated — do not edit them directly.

## Build System

- **Node.js 20.x+** is required.
- Prefix shell commands with `. run/setupEnv.sh` to ensure the correct Node version is used (it adjusts `PATH` if the active Node version is not v20.x).
- Build orchestration happens from `omega-build/` using Grunt and `grunt-hub`.
- Initial setup (run once):
  ```bash
  cd omega-build
  npm run deps   # installs deps in all modules + bower
  npm run dev    # npm links local modules together
  ```
- Build commands:
  ```bash
  cd omega-build
  npm run build    # default grunt build for all modules
  npm run release  # builds chromium-release.zip + firefox-release.zip in dist/
  ```
- `grunt watch` from `omega-build/` runs watchers across all modules.

## Code Style

CoffeeScript files are linted with `coffeelint`. Key rules that differ from typical CoffeeScript style:

- `arrow_spacing`: required (e.g. `->` must have spaces around it)
- `colon_assignment_spacing`: `left: 0, right: 1` (no space before colon, one space after)
- `space_operators`: required
- `no_stand_alone_at`: `@` must not stand alone
- `no_empty_functions`: error
- `no_empty_param_list`: error
- `indentation`: ignored (disabled due to coffeelint bug)

Always run `grunt` (which includes `coffeelint`) before committing.

## Testing

- Test framework: Mocha with `coffee-script/register`
- Test files: `test/**/*.coffee` in each module
- Commands:
  ```bash
  cd omega-pac && TZ=Europe/London npm test
  cd omega-target && npm test
  ```
- **Quirk:** `omega-pac` tests require `TZ=Europe/London` (set in its `package.json` script).

## Extension Architecture

- **Manifest V3** with service worker background (`x-background.js`).
- `omega-target-chromium-extension/src/coffee/background.coffee` is the main service-worker entry point.
- `omega-target-chromium-extension/src/coffee/omega_target_web.coffee` provides the `omegaTarget` Angular module that bridges `omega-web` UI to the background.
- Two manifests exist:
  - `overlay/manifest.json` — Chromium
  - `overlay/manifest-firefox.json` — Firefox (uses `scripts` array instead of `service_worker`, adds `webRequestBlocking`, has `browser_specific_settings.gecko`)
- The release task swaps the correct manifest into the build.

## Module Dependencies & Linking

Local modules depend on each other via relative paths and `npm link`:

- `omega-target` depends on `omega-pac`
- `omega-web` depends on `omega-pac`
- `omega-target-chromium-extension` depends on `omega-pac`, `omega-target`, `omega-web`

If you see "module not found" errors after pulling changes, re-run `npm run dev` from `omega-build/`.

## Translations

Do **not** submit translation changes via PR. Translations are managed on [Weblate](https://hosted.weblate.org/projects/switchyomega/). Translation files live in `omega-locales/` and are compiled into `build/_locales/` during the build.

## Pull Request Etiquette

- Translations and typo fixes go to Weblate, not PRs.
- Prefer rebasing over merging to resolve conflicts.
- Ensure `npm run build` and tests pass before submitting.
- New features may be rejected or require discussion.

## Gotchas

- `omega-target-chromium-extension/index.js` is a generated Browserify bundle (~1MB). Edit `index.coffee` or files in `src/` instead.
- `omega-web` uses **Bower** for frontend dependencies (Angular, Bootstrap, etc.). Run `bower install` inside `omega-web/` if bower deps are missing.
- The Firefox build uses a different popup entry (`popup/index.html`) vs Chromium (`popup-iframe.html`).
- Background page context menus are initialized in `background_preload.coffee`.
- `BUILD=release` env var triggers minification in the Browserify config.
