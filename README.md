# eRep — eRepublik Automation in Ruby

A daily automation bot for [eRepublik](https://www.erepublik.com) that **trains, fights, and shops** while you sleep. Built in Ruby with Ferrum (raw Chrome DevTools Protocol) — no Selenium, no Capybara, no shortcuts.

The interesting bits aren't the click-the-button parts. They're what sits between you and the click:

- **Two-phase Chrome dance** to survive Cloudflare Turnstile
- **Idempotent `launchd` scheduling** that gracefully eats overlapping triggers
- CAPTCHA solver — *work in progress* (see below)

---

## What it does

| Routine | Trigger | Actions |
|---|---|---|
| **Train** | `launchd` @ 12:00 daily | Login → API train all default grounds → claim VIP points → weekly energy bar shop → end-of-month pro contract |
| **Fight** | Manual / cron | Login → safety-gate infantry kit → pick allied battle → solve CAPTCHA → spend energy (40 / 160 split) |

Strength gain runs ~+90/day. The trainer has been compounding daily without intervention for weeks at a time.

---

## The Cloudflare problem

eRepublik sits behind Cloudflare Turnstile. Launching Chrome via CDP (the only way to drive it from Ferrum) sets a flag Cloudflare hates: `navigator.webdriver`, plus a fingerprintable command-line shape. The challenge then never auto-solves, and you stare at a spinner forever.

The fix is two Chromes:

```
┌─ Phase 1 ─────────────────────────────┐    ┌─ Phase 2 ────────────────────────┐
│ Plain Chrome, no CDP                  │    │ Same profile, --remote-debugging │
│ Navigates to https://erepublik.com    │ →  │ Ferrum attaches via CDP          │
│ Turnstile auto-solves silently        │    │ cf_clearance cookie carries over │
│ cf_clearance written to profile DB    │    │ Login form actually renders      │
└───────────────────────────────────────┘    └──────────────────────────────────┘
```

The shared `--user-data-dir` is the trick — the cookie persists across the two launches. Phase 2 inherits clearance from Phase 1 without ever touching Cloudflare's JS in CDP mode.

### What can go wrong (and how it's handled)

A few months of running this revealed every pathological case. Each one has a guard:

| Failure mode | Symptom | Defense |
|---|---|---|
| Stale `cf_clearance` cookie in profile | Phase 1 thinks it's done in 1s, Phase 2 still gets the challenge wall | `clear_cf_clearance` deletes the row from Chrome's cookies SQLite DB before re-seed |
| Chrome already owns the profile | New spawn forwards URL as a *new tab* in the existing instance — no fresh challenge | `ensure_profile_unlocked` kills Chromes bound to `--user-data-dir` + removes `SingletonLock` symlink |
| Helper processes survive `SIGTERM` on launcher PID | Profile stays locked, port `9232` doesn't free | Kill by `pgrep -f user-data-dir=…`, wait until `lsof -ti:9232` is empty |
| Concurrent `launchd` fires after sleep wake | Two trainers racing on the same profile | `flock` on `log/train.lock` (non-blocking, second instance exits clean) |
| Already trained earlier today | Silent re-runs waste API calls + risk detection | `log/last_run` date guard in `bin/train_once` |
| CDP session torn mid-run | `Ferrum::Client raise_browser_error: Session with given id not found` | Re-launch Chrome, re-attach, retry |

The full state machine lives in `lib/erep/browser.rb` — about 1800 lines of Chrome whispering.

---

## The CAPTCHA pipeline (work in progress)

eRepublik's CAPTCHA is the "click the icons in this order" kind: a 400×230 composite with semi-transparent overlay icons over a photo scene, plus a reference strip at the bottom telling you which order to click.

The current direction is **hybrid**: an LLM (Gemini 2.5 Flash, free tier) names the icons in the reference strip, then template matching locates them in the scene. The naming step is in shape; **the template-matching step isn't finished** — edge-based NCC search produces too many false positives on the translucent overlays, and the click-coordinate mapping hasn't been validated end-to-end against the live game.

For now the fight routine falls back to either manual solve (user clicks within a 30s window) or the paid 2captcha.com service. See `CAPTCHA.md` for the design notes.

---

## Project layout

```
lib/erep/
├── browser.rb          ← Chrome lifecycle, login, train, fight, VIP, shop
├── trainer.rb          ← Daily routine entry point
├── fighter.rb          ← Battle workflow + energy/XP rules
├── battle_selector.rb  ← Picks the right allied battle
├── fuel_budget.rb      ← Energy bar accounting
├── captcha_solver.rb   ← Orchestration
├── template_matcher.rb ← ImageMagick NCC wrapper
├── two_captcha_solver.rb ← Paid fallback (2captcha.com)
└── captcha/
    ├── icon_catalog.rb
    ├── image_preprocessor.rb
    ├── solve_pipeline.rb
    └── template_extractor.rb

bin/
├── cron_train, cron_fight    ← Shell wrappers for launchd (mise activation)
├── train_once, fight_once    ← Ruby entry points with idempotency + flock guards
├── label_captchas            ← Interactive CAPTCHA dataset builder
├── test_captcha              ← Run solver against fixtures
└── test_retry_path           ← Force Cloudflare re-seed for testing

Local-only (gitignored): launchd plist + shell wrappers with absolute paths to
your home directory. Recreate from the snippets in the scheduling section below.
```

---

## Running it

Stack:

- **Ruby 4.0.2** (managed by [`mise`](https://mise.jdx.dev/))
- **Ferrum** (CDP client, no Selenium baggage)
- **ImageMagick** for image ops
- **Gemini API** (free tier) for CAPTCHA icon naming
- **Google Chrome** at the standard macOS path

Setup:

```bash
cp .env.example .env                          # fill in EREP_EMAIL, EREP_PASSWORD, GEMINI_API_KEY
cp config/countries.example.yml config/countries.yml  # fill in enemy/friend/priority IDs
mise install
bundle install
bin/train_once         # manual smoke test
```

`config/countries.yml` (gitignored) drives battle selection — which countries
to fight for, which to skip, and individual enemy citizen IDs. Each field is
documented in `config/countries.example.yml`.

Schedule via `launchd` (macOS): write a plist at
`~/Library/LaunchAgents/com.erep.trainer.plist` pointing at a shell wrapper
that `cd`s into the repo, activates `mise`, and runs `bundle exec ruby bin/train_once`.
Then `launchctl load` it.

Plist + wrapper templates are not in the repo because they hardcode absolute
paths to your home directory.

---

## License

Personal project. No license — fork freely, don't expect support.
