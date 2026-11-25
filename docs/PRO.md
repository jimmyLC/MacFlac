# MacFlac Pro (NT$90 lifetime) — design and release runbook

Modeled on MacMP4. All conversion features stay free; **Pro only adds appearance** (dark mode and follow-system; Free is light only) and the Pro badge.

## How it works

- **App** (`Sources/ProLicense.swift`, `AppAccess.swift`, `AppearanceView.swift`): the entitlement comes only from a server receipt signed with ECDSA P-256 and verified against the public key in `Resources/ProConfiguration.json`. The tier is never read from UserDefaults or the environment. The receipt, Email and serial live in the Keychain; offline use keeps a verified lifetime receipt and the server is asked again when online (revocation, device check). One active device per serial, switch allowed once per 24 h.
- **Payments Worker** (`payments/`, Cloudflare Worker + D1): SHOPLINE Payments redirect checkout (Apple Pay / card), fixed server-side price NT$90, webhook verified by signature and then confirmed by querying SHOPLINE, serial email after payment (zh/en by app language), reconcile-on-poll fallback. Order ids start with `F` (MacMP4 uses `M`), serials look like `FLC-XXXXXXXX-…`.
- **Pay hub** (`pay.jimmy-tools.com`, code in the MacMP4 repo `payments-hub/`): SHOPLINE allows only a few webhooks, so the single webhook goes to the hub, which routes by order id prefix. MacFlac needs `F → MACFLAC` there.
- Differences from MacMP4: the Worker is served on `macflac-pay.jimmy-tools.com` (a custom domain, `workers_dev: false`) so no Cloudflare account name appears in URLs; the email icon is hosted on the site (`/MacFlac/img/icon.png`) so the hub needs no new asset; the "Taiwan-issued cards only" notice was dropped (it came from ECPay and is unverified for SHOPLINE); contact is `contact@jimmy-tools.com`.

## Local state (nothing is deployed yet)

- `payments/.dev.vars.production` (git-ignored, mode 600) holds the **generated** `LICENSE_SIGNING_JWK`, `DATA_KEY`, `LOOKUP_KEY`. The three `SHOPLINE_*` values are still empty. **Back up this file privately**: losing the signing key means existing licenses can no longer be verified; losing the data keys means stored serials can't be decrypted.
- `Resources/ProConfiguration.json` has the matching public key and `"enabled": false`, so the app shows "payment service not ready" until the release flips it to `true`.
- `Tests/run.sh` runs the whole suite (entitlements, license signatures/Keychain/device binding, backend, CLI bit-exactness). `-D MACFLAC_PREVIEW_PRO` builds a Pro preview for UI checks; `build.sh` never sets it.

## Release gates (each needs the owner's explicit OK)

1. Create D1 databases `macflac-payments` (and staging if wanted), put the ids in `payments/wrangler.jsonc`, apply `payments/migrations`.
2. Fill `SHOPLINE_MERCHANT_ID / API_KEY / SIGN_KEY` in `.dev.vars.production`, then `node scripts/upload-secrets.mjs production`.
3. Deploy the Worker (`wrangler deploy --env production`); check `https://macflac-pay.jimmy-tools.com/health`.
4. Add `F: 'MACFLAC'` to the hub `ROUTES` and a `MACFLAC` service binding in the hub `wrangler.jsonc`, deploy the hub **after** the Worker exists. This touches the live MacMP4 webhook path: verify MacMP4 payments still route.
5. Set `"enabled": true` in `Resources/ProConfiguration.json`, build the DMG, tag and release v1.1.0.
6. Real payment test (card and Apple Pay), serial email received, restore on a second Mac, then refund the test payments in the SHOPLINE backend.
7. Deploy the site page with the pricing section and terms (`jimmy-tools-site`).
