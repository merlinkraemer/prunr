# Brevo welcome email (alpha download link)

Signup adds contacts to your Brevo list, then sends a transactional welcome email with the download link — **once you add a template ID to Vercel**.

## 1. Stable download URL (use in the email)

```
https://merlinkraemer.github.io/prunr/download.html
```

This page always resolves to the latest signed macOS zip from GitHub Releases. No manual updates when you ship a new alpha.

Optional template variable (set automatically by the API):

```
{{ params.DOWNLOAD_URL }}
```

## 2. Create the email template in Brevo

1. [Brevo → Transactional → Templates](https://app.brevo.com/templates/listing/transactional) → **New template**
2. Subject idea: `Your Prunr alpha download`
3. Body — suggested structure:
   - Thanks for joining the alpha
   - Big button/link: `{{ params.DOWNLOAD_URL }}` (label: **Download Prunr for Mac**)
   - Install steps:
     - Unzip, drag to Applications
     - First open: right-click → **Open** (Gatekeeper)
     - Updates install automatically via Sparkle after that
   - Link to contact you: merlins-internet.com / @merlinkraemer
4. Save → note the **Template ID** (number in URL or template settings)

Sender must be a [verified sender](https://app.brevo.com/senders) in Brevo.

## 3. Vercel env vars (`prunr-web` project)

| Variable | Example | Required |
|----------|---------|----------|
| `BREVO_API_KEY` | *(already set)* | yes |
| `BREVO_LIST_ID` | `6` | yes |
| `BREVO_WELCOME_TEMPLATE_ID` | `12` | yes (after template exists) |
| `BREVO_SENDER_EMAIL` | `helloo@merlins-internet.com` | yes |
| `BREVO_SENDER_NAME` | `Merlin` | optional |
| `DOWNLOAD_PAGE_URL` | `https://merlinkraemer.github.io/prunr/download.html` | optional (default above) |
| `NOTIFY_EMAIL` | `merlinkraemer@gmail.com` | optional (default above) |

Owner notifications go to `NOTIFY_EMAIL` on each **new** signup (not re-submits).

Add via CLI:

```bash
cd website
npx vercel env add BREVO_WELCOME_TEMPLATE_ID production
npx vercel env add BREVO_SENDER_EMAIL production
npx vercel env add BREVO_SENDER_NAME production
```

Redeploy after adding vars:

```bash
npx vercel deploy --prod
```

Until `BREVO_WELCOME_TEMPLATE_ID` is set, signups still work (contact added) but no email is sent — check Vercel logs for `Welcome email skipped`.

## 4. Test

```bash
curl -X POST https://prunr-web.vercel.app/api/subscribe \
  -H "Content-Type: application/json" \
  -H "Origin: https://merlinkraemer.github.io" \
  -d '{"email":"you@example.com"}'
```

Expect `{"ok":true}` and the welcome email in your inbox.

## 5. Landing page copy

Success state says to check email for the download link. Matches this flow.
