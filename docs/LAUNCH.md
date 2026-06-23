# SnippAI launch runbook

Status as of this commit. Everything buildable without external accounts is **done and
verified**; the rest is gated on credentials/accounts only you can create.

## ✅ Done (in the repo)

- **Trial + soft paywall.** 7-day trial, then capturing opens a paywall. Users may
  "Maybe later" up to `LicenseConfig.graceDismissals` (5) times, then a license is
  required. License activated against Lemon Squeezy's public license API (no secret key
  shipped). Trial start is rollback-resistant and mirrored to Application Support.
  Files: `Sources/SnippAIKit/Support/Licensing.swift`, `LemonSqueezyClient.swift`,
  `Sources/SnippAI/License/*`. Settings has a License card; states screenshot-verified.
- **Lightweight update check.** On launch the app fetches `appcast.json` from the latest
  GitHub Release; if newer, a "Update to SnippAI X.Y…" menu item appears and opens the
  download. Files: `Sources/SnippAIKit/Support/VersionCheck.swift`,
  `Sources/SnippAI/Update/UpdateController.swift`.
- **Distribution build.** `scripts/release.sh` → Developer ID sign + hardened runtime +
  entitlements + DMG + notarize + staple, and writes `dist/appcast.json`. Signing + DMG
  verified with your real `Developer ID Application: Hammad Hai (WP368XBRDU)` cert.
- **App icon.** Placeholder mint/camera `Resources/SnippAI.icns` (swap with final art).
- **Website.** Download links point at the latest-release DMG. Railway deploy staged
  (`site/Dockerfile` + `Caddyfile` + `railway.json`); container verified serving locally.
- **Tests.** 105 passing (licensing + semver + decoding included).

## ⛳ Remaining — needs your accounts/credentials

### 1. Lemon Squeezy
1. Create a store + a **one-time $8.99 product** with **License keys enabled**
   (activation limit 1 is fine). The 7-day trial is enforced in-app, not in LS.
2. Send me / fill in `Sources/SnippAIKit/Support/Licensing.swift`:
   - `LicenseConfig.storeId` — your numeric store id
   - `LicenseConfig.variantId` — the product's variant id
   - `LicenseConfig.checkoutURL` — the product's checkout URL
3. (Optional) Put the same checkout URL on a "Buy" button on the site if desired.
   Until the IDs are set, store/variant matching is skipped so the flow still works.

### 2. Notarization credential (one-time)
```
xcrun notarytool store-credentials snippai-notary \
  --apple-id <your-apple-id-email> --team-id WP368XBRDU \
  --password <app-specific-password from appleid.apple.com>
```
Then `scripts/release.sh` (no flag) signs **and** notarizes + staples.

### 3. Cut the first GitHub Release
```
scripts/release.sh                       # produces dist/SnippAI.dmg + dist/appcast.json
gh release create v0.1.0 dist/SnippAI.dmg dist/appcast.json \
  --title "SnippAI v0.1.0" --generate-notes
```
Asset names must stay `SnippAI.dmg` and `appcast.json` (the site link + in-app feed use
the stable `releases/latest/download/...` URLs). Bump `CFBundleShortVersionString` in
`Resources/Info.plist` for each subsequent release.

### 4. Deploy the website (Railway)
```
railway login            # interactive — run yourself (e.g. `! railway login`)
cd site && railway up     # builds the Dockerfile, deploys Caddy static server
```
Point `snippai.dev` DNS at the Railway domain. `VersionConfig.downloadPageURL` is
`https://snippai.dev`.

### 5. Final icon
Replace `Resources/SnippAI.icns` with real art (1024px source → `iconutil`), or hand me a
1024×1024 PNG and I'll regenerate it.

## Debug hooks (dev only)
- `SNIPPAI_FAKE_ENTITLEMENT=expired|trial|licensed` — force a license state.
- See `snippai-ui-screenshots` memory for window-id screenshotting.
