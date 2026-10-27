# Download stats

Every site download goes through `https://prunr-web.vercel.app/api/download`.
It counts the click in Vercel KV / Upstash Redis (the feedback store) and
302-redirects to the latest release's `-macos.dmg` (the GitHub lookup is cached
for 5 minutes per function instance; on failure it redirects to
`https://github.com/merlinkraemer/prunr/releases/latest`). A storage failure
never blocks the download.

## Tagging links

Add `?src=<tag>` (lowercase `a-z0-9_-`, max 32 chars) to tell channels apart:

```text
https://prunr-web.vercel.app/api/download?src=reddit
https://merlinkraemer.github.io/prunr/download.html?src=x
```

`download.html` forwards its own `?src=` to the endpoint and defaults to `site`.
A link without `src` counts as `direct`; an invalid one as `other`.

## What is stored

Per download: ISO timestamp, `src`, referrer **host** only (`none` if absent),
and a user-agent class (`mac`, `bot`, or `other`). No IP, full user agent, full
referrer URL, cookie, or identifier is stored, so counts are clicks, not unique
people.

Keys: `download:total` (all-time counter), `download:day:<YYYY-MM-DD>` (hash of
`total`, `src:*`, `ua:*`, `ref:*` counters), `download:days` (index), and
`download:events` (last 10,000 raw events). HEAD requests are not counted.
Link-preview bots that GET the URL count under `ua.bot`.

## Reading counts

Accepts `DOWNLOAD_STATS_TOKEN` (read-only, download stats only; give this one
to outside bots) or `FEEDBACK_AGENT_TOKEN` (`docs/feedback-agent-api.md`). The
stats token cannot read feedback.

```sh
curl -sS -H "Authorization: Bearer $DOWNLOAD_STATS_TOKEN" \
  'https://prunr-web.vercel.app/api/download-stats?days=30'
```

Response: `allTime`, then `total`, `src`, `ua`, `ref` summed over the returned
days, and `byDay` (newest first) with the same counters per day. `days` is
1–366, default 30.

## Deploying

`prunr-web` is deployed with the Vercel CLI from `website/` (the folder is
linked to the project). `KV_REST_API_URL`, `KV_REST_API_TOKEN`, and
`FEEDBACK_AGENT_TOKEN` and `DOWNLOAD_STATS_TOKEN` are set in production:

```sh
cd website && npx vercel deploy --prod
```

Deploy the API before `download.html` reaches GitHub Pages (a push to `main`),
otherwise the site's button points at a missing endpoint.
