# Agent feedback API

Feedback is persisted in Vercel KV / Upstash Redis for 90 days, then delivered
to Brevo as the existing human notification email. Redis is the source of truth;
Brevo remains a notification channel.

## Deployment configuration

Configure these Vercel environment variables before deploying:

```text
KV_REST_API_URL=https://…upstash.io
KV_REST_API_TOKEN=…
FEEDBACK_AGENT_TOKEN=<long, separate random secret>
```

`BREVO_API_KEY`, `BREVO_SENDER_EMAIL`, `BREVO_SENDER_NAME`, `NOTIFY_EMAIL`, and
`FEEDBACK_SHARED_TOKEN` remain as they are. The feedback endpoint fails closed
if KV is unavailable: it does not send an email that the agent cannot retrieve.
Once feedback is accepted, a transient Brevo failure is recorded as
`notificationStatus: "failed"` rather than asking the app to retry and duplicate
the feedback record.

Keep `FEEDBACK_AGENT_TOKEN` only in the CLI agent's environment; it is not the
app's public feedback token.

## Agent access

Set the token locally, without committing it:

```sh
export FEEDBACK_AGENT_TOKEN='…'
```

List recent submissions (diagnostics are deliberately omitted):

```sh
curl -sS -H "Authorization: Bearer $FEEDBACK_AGENT_TOKEN" \
  'https://prunr-web.vercel.app/api/agent/feedback?status=new&limit=25'
```

Read one submission including its diagnostics:

```sh
curl -sS -H "Authorization: Bearer $FEEDBACK_AGENT_TOKEN" \
  'https://prunr-web.vercel.app/api/agent/feedback/<id>'
```

Triage it:

```sh
curl -sS -X PATCH \
  -H "Authorization: Bearer $FEEDBACK_AGENT_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"status":"in_progress","labels":["scan","performance"],"agentSummary":"Reproduce after wake."}' \
  'https://prunr-web.vercel.app/api/agent/feedback/<id>'
```

Statuses are `new`, `in_progress`, `resolved`, and `ignored`. Labels, an agent
summary, and status are the only mutable fields.
