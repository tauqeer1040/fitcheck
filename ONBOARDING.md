# StickerPants Onboarding — Design Doc & Spec

> Reference: `ramadan_app` onboarding (welcome → name → intention → journal →
> celebration → paywall), restructured for StickerPants' 60-second core loop.
> Principles: **Building a StoryBrand** (Donald Miller) for narrative framing,
> **Contagious** (Jonah Berger) for shareability baked into the flow itself.

---

## 1. The One-Liner (StoryBrand BrandScript, compressed)

| SB7 Element | StickerPants version |
|---|---|
| **A character** | The user — someone whose outfits, pets, and moments deserve to be *stickers* |
| **Has a problem** | Sending a photo of your fit as a plain photo feels flat; WhatsApp stickers are the fun, expressive layer of chat — but making them has always been a chore |
| **Meets a guide** | StickerPants. We're the tool, not the hero — we just cut, flick, and stick |
| **Who gives them a plan** | Pick a photo → subject is cut automatically → flick it home → it's a WhatsApp sticker. Four words: **Cut. Flick. Stick.** |
| **And calls them to action** | One button, first screen: **"Make my first sticker"** — direct, transitional CTA |
| **That helps them avoid failure** | No design skills. No cropping. No 20-step editor. If you can pick a photo, you can do this |
| **And ends in success** | Your face (or your cat's) sitting in WhatsApp's sticker tray, in the group chat, forever |

**The story the onboarding tells:** *You are the star. Your wardrobe is the
content. We're just the scissors.* The user is never "learning an app" —
they're one flick away from seeing themselves as a sticker.

---

## 2. Activation Definition (the "aha")

**Aha moment = the first cutout lifts off the photo.** That instant — subject
popping free from its background with the shimmer → melt → float reveal — is
the peak of the whole app (Peak-End Rule). Everything before it exists to get
the user there fast; everything after it celebrates it and asks for the share.

- **Activation event:** `first_sticker_created` (first successful cutout saved)
- **Target:** user hits it within **90 seconds** of first launch, in session one
- **Model:** freemium — first 3 stickers free, then soft paywall (RevenueCat)

---

## 3. Flow Overview (6 steps, ~60–90 seconds)

Modeled on ramadan_app's step-engine (`OnboardingStep` sealed class +
`OnboardingData` + progress dots + star rewards) but compressed — StickerPants
needs no account, no forms, no typing.

| # | Step | Purpose | Psychology |
|---|------|---------|-----------|
| 0 | **Welcome** | Storybrand frame in 3 lines + one CTA | Character/problem/guide in one glance |
| 1 | **See it work** | 3-card demo carousel: photo → cutout → sticker in chat | Show, don't tell — sells the *transformation*, not features |
| 2 | **Permission: notifications** | One honest sentence + the OS dialog | Prompt at peak motivation, minimal friction |
| 3 | **The first flick (DO the thing)** | Live mini-flow: pick → auto-cut → flick home | Do, don't show. The aha IS the onboarding |
| 4 | **Celebration** | Confetti + "You're a sticker now" + social proof | Peak-End + endowed progress |
| 5 | **Paywall (soft)** | RevenueCat paywall, dismissible | Ask when perceived value is highest |

### Why this order works

- **Steps 0–1 sell the dream** before asking anything (StoryBrand: the guide
  earns trust by showing the plan, not by demanding setup).
- **Step 2 asks for notifications at the highest-motivation moment and before
  the user has invested effort** — the classic ramadan_app placement — and the
  copy is honest ("we'll nudge you to log your fit — 8am & 10:30pm"), because
  dishonest permission asks poison retention.
- **Step 3 is the product itself.** The onboarding's final act is not a
  tutorial — it *is* the first use. This is the strongest possible "Do, don't
  show": the user's own photo becomes the demo.
- **Step 4 ends the session on the peak**, and engineers the first share —
  see §5.
- **Step 5 asks for money only after the user has created and *seen* value.**
  A dismissible paywall after the aha converts far better than a gate before
  it, and trains no resentment.

---

## 4. Step Specs

### Step 0 — Welcome
- Asset: logo3.png large, subtle float animation
- Headline (H1, w800): **"Your outfit. Now a sticker."**
- Sub (grey, 15sp): *"Cut yourself out of any photo. Flick. Stick. That's the
  whole app — and it takes 30 seconds."*
- CTA (yellow, full-width, 56dp): **"Make my first sticker"**
- Footer link: "I'll explore on my own" (skip → straight to step 3's entry)
- StoryBrand check: user = hero, StickerPants = guide, plan = 4 verbs.

### Step 1 — See It Work (transformation carousel)
- 3 cards, swipeable or auto-advancing (2.4s):
  1. A photo → caption *"Pick any photo"*
  2. The cutout floating (use a pre-baked asset) → *"We cut you out. Magically."*
  3. WhatsApp sticker tray mockup → *"You're in the chat now."*
- Progress dots (ramadan_app `StepProgressDots` pattern).
- CTA: **"Show me"** → next step. "Skip" link always visible (blocker removal).

### Step 2 — Notifications (the honest ask)
- Copy: **"Nudges that don't nag"** / *"One ping at 8am, one at 10:30pm —
  'add your outfit today.' That's it. No marketing. Ever."*
- Primary: **"Sounds good"** → `NotificationService.requestPermissions()` →
  `scheduleDaily()` on grant → next
- Secondary: **"Not now"** → next (no guilt copy — blockers out of the lane)
- Fire-and-forget: never block the flow on the OS dialog result.

### Step 3 — The First Flick (MPTV: this is the whole point)
- Minimal chrome: the gallery sheet opens **directly** over a 1-card
  "starter" state (endowed progress: the grid isn't empty-empty — it shows a
  ghost card + "Your first sticker lands here").
- A one-time coach mark under the sheet: **"Pick a photo — we'll do the
  rest"** (auto-dismisses on first pick).
- The existing pipeline does the rest: shimmer → cut → melt → float → flick.
- Analytics: `first_cut_started`, `first_cut_succeeded` (or `_failed`),
  `first_flick_saved` with `time_to_first_sticker_ms`.

### Step 4 — Celebration + Social proof
- Confetti burst (reuse `ConfettiWidget` at the landing cell) + haptic
  milestone.
- Sheet, not screen (keeps the grid visible behind — the user *sees* their
  sticker at home):
  - H1: **"You're a sticker now."**
  - Sub: *"Your cat is judging your next outfit already."* (rotating fun
    lines — the Carrot voice is part of the brand)
  - Primary: **"Send it to WhatsApp"** → existing `WhatsAppStickerService.addPack`
  - Secondary: **"Share StickerPants"** → share sheet (Contagious trigger §5)
- This is the **End** the Peak-End rule wants: victory + laughter.

### Step 5 — Soft Paywall (RevenueCat)
- Shown right after celebration dismisses, session one, dismissible ("Keep
  making stickers" always visible).
- Offering: **StickerPants Pro** — unlimited stickers + all M3 shape packs +
  widget themes. First-3-free framing on the card itself.
- Use `purchases_ui_flutter` `PaywallWidget` (ramadan_app pattern) or a custom
  sheet driven by `Purchases.getOfferings()` — default to the native
  `PaywallWidget` for v1.
- Analytics: `paywall_shown`, `paywall_dismissed`, `purchase_completed`.

---

## 5. Contagious (STEPPS) — engineered into the flow, not bolted on

| STEPPS | Where it lives in StickerPants onboarding |
|---|---|
| **Social Currency** | "You're a sticker now" reframes the product as identity ("I have my own sticker") — inner-ring feeling. The celebration sheet says it out loud. |
| **Triggers** | The sticker itself IS the trigger: every WhatsApp message a friend sends with the user's sticker re-exposes the app. Onboarding step 4 pushes the pack to WhatsApp *immediately* so the loop starts day one. |
| **Emotion** | High-arousal positives: the aha of the cutout, confetti, the Carrot-voice lines ("Damn, you're a sexy being"). Humor + awe = most shareable emotions. |
| **Public** | Widgets put the user's latest sticker *on their homescreen* — the product becomes publicly visible to anyone who sees their phone. Offered in step 4's sheet and every 5th save. |
| **Practical Value** | The share copy leads with utility, not hype: *"Turn outfits into WhatsApp stickers in 10 seconds — free."* Deals-shaped framing: valuable + easy to try. |
| **Stories** | Step 1's carousel is a 3-frame story (photo → cutout → chat), told in the user's voice, not a feature list. |

**Share mechanics:** share copy is pre-written to be *forwardable*
("Cut, flick, stick 🩳✨" + store link), the WhatsApp pack-add makes the
product visible inside the world's biggest chat app, and the rotating fun
lines give every share a fresh, screenshot-able punchline.

---

## 6. Instrumentation (AnalyticsService)

All events fire through the new `AnalyticsService` (Firebase Analytics).
Funnel (mirrors ramadan_app's install→activation→purchase ladder):

```
onboarding_started
  onboarding_step { page, index }      ← every step view
  notification_permission_result { granted }
  first_cut_started / first_cut_succeeded / first_cut_failed
  first_flick_saved { time_to_first_sticker_ms }
  onboarding_completed
  whatsapp_pack_added
  share_invoked
  paywall_shown / paywall_dismissed / purchase_completed
```

**Dashboard targets:** ≥70% step-0 → step-3 start; ≥60% step-3 →
`first_flick_saved`; ≥40% of activated users open the pack-add flow; D7
retention of activated ≥ 2× non-activated.

---

## 7. Gate & Persistence

- `SharedPreferences` flag `onboarding_completed_v1` (+ version suffix so a
  redesigned flow can re-show).
- Splash routes: flag absent → `OnboardingFlow` (full-screen, no chrome);
  present → `GalleryScreen` as today.
- Re-entry: Settings/heart sheet can re-open the paywall; onboarding itself
  never re-shows (trap = churn).

---

## 8. Copy Bank (rotating, Carrot-voice)

Celebration subs (pick random):
- "Your cat is judging your next outfit already."
- "You're legally a sticker now. Congrats."
- "That fit deserved immortality. Done."
- "The group chat isn't ready for this."

Paywall headline: **"Make every fit a sticker."** Sub: *"Unlimited cuts, all
the shapes, widget themes. Your first 3 are on us."*
