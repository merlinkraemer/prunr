# Releasing alphas from GitHub (CI)

Releases run entirely on GitHub's macOS runners via
`.github/workflows/release.yml`. After the one-time secret setup below, shipping
a new alpha is just:

```
gh workflow run release.yml -f version=0.1.5-alpha.6 -f build=7
```

…or say **"push this as a new alpha"** to Claude (the `/ship-alpha` skill).

The runner bumps the version, archives + codesigns, notarizes via Apple, staples,
regenerates the Sparkle appcast, commits the bump + appcast to `main`, tags it,
and publishes the GitHub Release that testers' updaters download from.

Your Mac's only jobs after setup: write code, push to `main`, trigger the release.

---

## One-time setup: 7 repository secrets

Add these under **GitHub → repo → Settings → Secrets and variables → Actions →
New repository secret**. Commands below produce each value (run on your Mac,
where the keys already live).

### 1. `MACOS_CERT_P12_BASE64` + 2. `MACOS_CERT_PASSWORD`

Your **Developer ID Application** certificate *and its private key*, exported as
a password-protected `.p12`.

1. Open **Keychain Access** → **login** keychain → **My Certificates**.
2. Find **"Developer ID Application: … (PM5QWB5426)"**, expand it to confirm it
   has a private key, right-click → **Export** → save as `developer-id.p12`,
   set a strong password.
3. Encode it:
   ```
   base64 -i developer-id.p12 | pbcopy   # → paste as MACOS_CERT_P12_BASE64
   ```
4. The password you chose → `MACOS_CERT_PASSWORD`.
5. Delete the local `developer-id.p12` afterward.

### 3. `NOTARY_API_KEY_P8_BASE64` + 4. `NOTARY_KEY_ID` + 5. `NOTARY_ISSUER_ID`

App Store Connect API key used by `notarytool` (CI can't use your local keychain
notary profile). Create at
**App Store Connect → Users and Access → Integrations → App Store Connect API**:

- Generate a key with the **Developer** role (or higher). Download the `.p8`
  **once** (Apple only lets you download it a single time).
- `NOTARY_KEY_ID` = the **Key ID** shown in the list (e.g. `ABCD1234XY`).
- `NOTARY_ISSUER_ID` = the **Issuer ID** at the top of the Keys tab (a UUID).
- Encode the `.p8`:
  ```
  base64 -i AuthKey_ABCD1234XY.p8 | pbcopy   # → NOTARY_API_KEY_P8_BASE64
  ```

### 6. `SPARKLE_ED_PRIVATE_KEY`

The EdDSA private key Sparkle uses to sign updates — the **same key** already
trusted by installed alpha builds (its public key is baked into the app's
`SUPublicEDKey`). **Do not generate a new one** or existing testers can't update.

Export the private key from your keychain using Sparkle's tool:

```
# from wherever your Sparkle bin tools live (SPARKLE_BIN_DIR):
./generate_keys -x sparkle_private_key.txt
cat sparkle_private_key.txt | pbcopy   # → SPARKLE_ED_PRIVATE_KEY
rm sparkle_private_key.txt
```

`generate_keys -x` exports the existing private key (base64 string) without
creating a new one. Paste the file's contents verbatim.

> The workflow downloads the Sparkle CLI tools itself (pinned `SPARKLE_VERSION`
> in `release.yml`), so there's no Sparkle binary to commit.

---

## How a release flows

```
gh workflow run release.yml -f version=… -f build=…
        │
        ▼  macos-15 runner (clean, ephemeral)
  import Developer ID cert  →  archive + codesign
  decode notary .p8         →  notarize (Apple)  →  staple
  download Sparkle + key    →  regenerate docs/appcast.xml (signed)
  scripts/release.sh:
     commit "release: v… build …"  →  tag v…  →  push to main  →  gh release create
        │
        ▼
  GitHub Release (zip + dSYM + checksums)   GitHub Pages /docs/appcast.xml
        └──────────────► testers' Sparkle updater polls, sees new build, updates
```

Local releases still work exactly as before: with the new vars unset,
`make release VERSION=… BUILD=…` uses your keychain notary profile and keychain
Sparkle key. The CI hooks (`NOTARY_KEY*`, `SPARKLE_ED_KEY_FILE`, `PUSH_RELEASE`)
only activate when set.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `errSecInternalComponent` / no signing identity | `MACOS_CERT_P12_BASE64` missing the private key, or wrong `MACOS_CERT_PASSWORD`. Re-export the `.p12` ensuring the private key is included. |
| Notarization `Invalid` | Wrong `NOTARY_KEY_ID`/`NOTARY_ISSUER_ID`, or the API key lacks permission. Check `gh run view <id> --log-failed`. |
| Testers don't see the update | `SPARKLE_ED_PRIVATE_KEY` doesn't match the public key in shipped builds. Must be the original key. |
| `tag v… already exists on origin` | Bump `version`; each release needs a fresh tag. |
| `build N must be greater than current` | `build` must strictly increase over `CURRENT_PROJECT_VERSION` in `project.yml`. |
| `workflow not found` on dispatch | `release.yml` isn't on `main` yet — commit & push it first. |
