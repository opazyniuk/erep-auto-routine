# Captcha Solver — Implementation

## How eRepublik captcha works

- Single composite image (400x230px): photo scene with semi-transparent icon overlays + reference icon strip at bottom (y>200)
- User must click overlay icons in the scene in the **same order** they appear in the bottom strip (left to right)
- `minCnt` field tells how many clicks required (typically 3-4)
- 4 API endpoints: `sessionCaptcha`, `sessionUnlockPopup`, `sessionGetChallenge`, `sessionUnlock`

## Solving approach: Hybrid (LLM naming + CV template matching)

### Step 1: Split image
- Top scene: `magick captcha.png -crop 400x200+0+0`
- Bottom strip: `magick captcha.png -crop 400x30+0+200 -trim`
- Grayscale scene: `-colorspace Gray -contrast-stretch 2%x2%`

### Step 2: LLM identifies icon names from bottom strip
- Send bottom strip image to Gemini 2.5 Flash (free tier)
- Returns comma-separated icon names, e.g. "snowflake, sparkle, person with crosshair, target"
- Fallback: Ollama llama3.2-vision (local, slower, less accurate naming)

### Step 3: Map names to templates via alias dictionary
- LLM names are fuzzy ("sparkle" → `cross_star`, "target" → `circular_arrows`)
- Dedup: if a template was already matched, try next unused template

### Step 4: Edge-based template matching (ImageMagick NCC)
- Convert both scene and template to edges: `magick -edge 2`
- Edge detection strips the photo background, preserving only icon outlines
- NCC subimage-search: `magick compare -metric NCC -subimage-search scene_edge template_edge`
- Real matches score 0.98+, false matches score 0.15-0.22
- Threshold: reject anything below 0.8

### Step 5: Click coordinates in browser
- Map matched positions to page coordinates (scale by rendered image size)
- Click each position via Ferrum `browser.mouse.click`
- Press Verify button

## Template library

Located in `test/fixtures/captchas/templates/` — 50x50 grayscale crops from known scene positions.

Current templates (7):
- `bomb.png` — rocket/bomb icon (35x35)
- `circular_arrows.png` — refresh/rotate icon
- `cross_star.png` — sparkle/asterisk icon
- `hourglass.png` — timer/sand clock icon
- `mountains.png` — mountain peaks icon
- `person_target.png` — person with crosshair icon
- `snowflake.png` — snowflake/ice icon

**Need ~20-30 templates total.** New ones are collected from live captchas as they appear.

## Key files

| File | Purpose |
|------|---------|
| `lib/erep/template_matcher.rb` | Edge-based NCC matching engine |
| `lib/erep/captcha_solver.rb` | LLM backend (Gemini/Ollama/Anthropic) for icon naming |
| `lib/erep/browser.rb` | `solve_captcha` — browser integration (open popup, capture image, click, verify) |
| `test/fixtures/captchas/templates/*.png` | Template library |
| `bin/test_captcha` | Test script: split → solve → draw dots on result |

## What works
- Template matching: 7/7 icons detected at score 0.98+ on test captchas
- Edge detection makes matching robust to different backgrounds (theory — needs live validation)
- LLM naming via Gemini: identifies icons in ~3s
- Full browser flow: open popup → capture image → split → solve → click → verify

## What's missing
- Only 7 of ~20-30 icon templates collected
- Cross-scene matching not validated (same icon, different background photo)
- Gemini free tier rate limits (1500 req/day)
- Integration of hybrid solver into `browser.rb` `solve_captcha` method (still uses old LLM-only approach)

## TODO
1. Integrate `TemplateMatcher` into `browser.rb` `solve_captcha`
2. Run live — collect new captchas, extract templates for unknown icons
3. Validate cross-scene matching; if scores drop, crop templates tighter (35x35 → 25x25)
4. Add fallback: if template match fails, use LLM coordinates as last resort
