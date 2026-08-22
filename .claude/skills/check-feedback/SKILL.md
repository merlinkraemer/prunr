---
name: check-feedback
description: Check and triage feedback submitted from the Prunr macOS app. Use whenever the user asks whether feedback has arrived, asks to review/check/list/triage tester feedback, mentions the feedback inbox, or wants to retrieve diagnostics. Read feedback through the authenticated Vercel API; never use Brevo or email as the source of truth.
---

# Check Prunr feedback

Feedback is stored in the production feedback API for 90 days. Brevo is only a
human notification channel, so do not read email, Brevo, or diagnostic-mail
attachments to check feedback.

## Authentication

Use `FEEDBACK_AGENT_TOKEN` as a bearer token. It is a secret: never print it,
commit it, put it in a command response, or pass it as a URL parameter.

Prefer a token already present in the harness environment. If it is absent but
the Vercel CLI is authenticated, run the request from `website/` through
Vercel's production environment. This injects the secret only into the child
process and avoids writing an env file:

```sh
npx vercel env run -e production -- sh -c 'curl --fail-with-body -sS \
  -H "Authorization: Bearer $FEEDBACK_AGENT_TOKEN" \
  "https://prunr-web.vercel.app/api/agent/feedback?limit=25"'
```

If neither credential path is available, say that `FEEDBACK_AGENT_TOKEN` or an
authenticated Vercel CLI session is required. Do not fall back to email.

## Read feedback

With a token already in the environment, list recent feedback:

```sh
curl --fail-with-body -sS \
  -H "Authorization: Bearer $FEEDBACK_AGENT_TOKEN" \
  'https://prunr-web.vercel.app/api/agent/feedback?limit=25'
```

Filter by `new`, `in_progress`, `resolved`, or `ignored`:

```sh
curl --fail-with-body -sS \
  -H "Authorization: Bearer $FEEDBACK_AGENT_TOKEN" \
  'https://prunr-web.vercel.app/api/agent/feedback?status=new&limit=25'
```

Follow `nextCursor` with `&cursor=<value>` until it is `null`. The list omits
diagnostics intentionally. For a specific item, retrieve the detail record:

```sh
curl --fail-with-body -sS \
  -H "Authorization: Bearer $FEEDBACK_AGENT_TOKEN" \
  'https://prunr-web.vercel.app/api/agent/feedback/<id>'
```

Only decode `diagnosticsBase64` when it is relevant to the user's request. Do
not include raw diagnostics in a summary unless asked; summarize actionable
facts and redact anything sensitive.

## Triage

Only change feedback when the user asks to triage it. Valid statuses are `new`,
`in_progress`, `resolved`, and `ignored`. Labels and `agentSummary` are the only
other mutable fields.

```sh
curl --fail-with-body -sS -X PATCH \
  -H "Authorization: Bearer $FEEDBACK_AGENT_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"status":"in_progress","labels":["scan","performance"],"agentSummary":"Reproduce after wake."}' \
  'https://prunr-web.vercel.app/api/agent/feedback/<id>'
```

Report the number of items, their IDs, status, concise message summary, and
whether diagnostics are attached. If the inbox is empty, say so plainly.
