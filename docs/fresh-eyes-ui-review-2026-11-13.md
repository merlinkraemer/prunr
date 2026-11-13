# Fresh-eyes UI review - 2026-11-13

Reviewer: Fable 5.1, fresh context, screenshots only (Merlin's 4 shots of drain/O49 on his Mac: main panel, Developer group, Simulators, 3-Resources). Brief: new user after first scan, knows the app tracks what ate storage.

Verdict: readable and good-looking, but it answers "what changed on which day", not "what ate my disk and what do I do"; several labels and colours need guessing.

1. No disk total or free space; bar segments have no legend or numbers.
2. Headline "This week -79.7 GB" is a shrink; growth rows are small; unclear what is big.
3. No action on any screen; leaf screens are dead ends (no Reveal in Finder).
4. "This week" lists Wed 4 / Tue 3 Nov (last week); visible rows sum to -73.9, not -79.7 (rest behind "Show all (6)").
5. "found by scan · since Wed 4..." meaningless, truncated on 3 of 7 rows, "since Wed 4" under Mon 9 reads contradictory.
6. Categories inconsistent: "Build files" top-level on Thu 12 but a Developer child on Mon 9; ccache/fourfour outside Developer while "Build files · fourfour" inside; plain "Build files" next to "Build files · herdr".
7. Amount colours unexplained: some growth orange, some white, +3.0 grey.
8. Simulators shows change per row, 3-Resources shows size now and never says which subfolder caused "grew 26.9 GB".
9. Simulators is a wasted level: one row repeating -34.8 GB, no chevron.
10. Left triangles in group view look like expand toggles next to drill-in chevrons.
11. Layout: footer overlaps scrolling content ("Tue 3 Nov", "Documents"); footer centre text changes meaning; "Show all (6)" / "in 402 smaller changes" wording; chevrons on screens 1-2 only; folder icon colours vary; Simulators icon hammer vs Xcode; "151.722 files" German separators in English UI; "up +6.6 · down -86.8 GB" double signs, unit once.

Works: Developer breakdown adds up exactly; 3-Resources children sum to ~400 of 401 GB; day grouping and right-aligned amounts scan easily.
