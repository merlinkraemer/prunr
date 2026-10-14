# R11 First-run / no-history patterns (2026-10-14)

How tools whose core is change over time handle day one. Rule of thumb: show the real
value now, and make the comparison slot visibly part of the layout before it has data.

1. **Calibration window with a dated unlock.** WHOOP greys out Recovery for the first 4 days, then shows the first score; Strain Coach unlocks after 5 days.
   Why: a concrete date ("ready Thu") reads as a plan, not as something missing.
   https://www.whoop.com/thelocker/podcast-40-whoop-recovery-maximize-readiness/ , https://community.whoop.com/t/how-long-does-it-take-for-whoop-to-learn-your-baseline-metrics/359
2. **"Learning your normal" framing.** Oura takes up to 2 weeks to learn your averages, then judges each day against them.
   Why: it sells the payoff ("unusual vs. normal"), not the waiting.
   https://support.ouraring.com/hc/articles/360057791533
3. **Notify when ready.** Apple Fitness needs 180 days for Trends and sends a notification when they are ready.
   Why: the user does not have to keep checking back. The wait happens in the background.
   https://apple.co/36ggRsf
4. **Oldest / Latest / Next status line.** Time Machine shows the latest backup and the time of the next one, with no chart.
   Why: one quiet time anchor says "this runs on a rhythm" without explaining it.
   https://eclecticlight.co/2016/11/12/how-to-check-that-time-machine-is-working-properly/
5. **Comparison column present from day one.** Screen Time and budget apps keep the "vs last week" slot in the layout; Withings shows a trend of the last N readings.
   Why: the structure teaches what the app compares before the numbers arrive. A neutral "±0" is honest data, not a placeholder.
   https://apps.apple.com/us/app/-/id1447330651 , https://support.withings.com/hc/en-us/community/posts/11241052474001--Official-Health-Mate-5-13?page=5
6. **Chart with a single point.** History graphs (Stats, Health Mate) start as one dot on an axis.
   Why: a line with one point implies the line it will become. The axis says "time".
   https://github.com/exelban/stats
7. **Unlock thresholds, not empty screens.** Copilot Money starts suggesting categories after 30 reviewed transactions; until then the core list is fully usable.
   Why: the app is useful right away, and the smart layer arrives later as a bonus.
   https://help.copilot.money/en/articles/11157550-quick-start-guide
8. **Explain the empty state, don't apologise.** SAP Fiori: say why it is empty and what happens next, and never make it feel like an error. Plausible's "Awaiting your first pageview" is calm and one line.
   Why: one calm sentence beats an illustration or ghost content.
   https://www.sap.com/design-system/fiori-design-web/v1-136/foundations/best-practices/global-patterns/designing-for-empty-states , https://station.railway.com/questions/plausible-analytics-not-working-with-str-e3842aa8

Caveats: the Screen Time first-week behaviour is not documented by Apple (unverified). The Copilot 90-day figure comes from a third-party review only.

Mockups built from 5, 6, 4 and 1+2+3: P1 since-column, P2 one-point, P3 next-status, P4 learning.
