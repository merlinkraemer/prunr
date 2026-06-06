// Prunr — coming soon / alpha signup one-pager (fullscreen, no scroll).
// Composes DS primitives from window.PrunrDesignSystem_225e08 → window.PrunrComingSoon.
(function () {
  const DS = window.PrunrDesignSystem_225e08;
  const { Button, Icon } = DS;

  function AppleLogo({ size = 18 }) {
    return (
      <svg viewBox="0 0 384 512" width={size} height={size} fill="currentColor" aria-hidden="true"
        style={{ display: "block", marginTop: -2 }}>
        <path d="M318.7 268.7c-.2-36.7 16.4-64.4 50-84.8-18.8-26.9-47.2-41.7-84.7-44.6-35.5-2.8-74.3 20.7-88.5 20.7-15 0-49.4-19.7-76.4-19.7C63.3 141.2 4 184.8 4 273.5q0 39.3 14.4 81.2c12.8 36.7 59 126.7 107.2 125.2 25.2-.6 43-17.9 75.8-17.9 31.8 0 48.3 17.9 76.4 17.9 48.6-.7 90.4-82.5 102.6-119.3-65.2-30.7-61.7-90-61.7-91.9zm-56.6-164.2c27.3-32.4 24.8-61.9 24-72.5-24.1 1.4-52 16.4-67.9 34.9-17.5 19.8-27.8 44.3-25.6 71.9 26.1 2 49.9-11.4 69.5-34.3z"/>
      </svg>
    );
  }

  function Wordmark({ size = 27 }) {
    return (
      <span style={{ display: "inline-flex", alignItems: "center", gap: 10 }}>
        <img src="assets/prunr-icon-128.png" alt="Prunr" style={{ width: size, height: size, borderRadius: size * 0.225 }} />
        <span style={{ fontFamily: "var(--font-heading)", fontWeight: 700, fontSize: size * 0.8, letterSpacing: "var(--tracking-heading)", color: "var(--heading-color)" }}>Prunr</span>
      </span>
    );
  }

  function Nav() {
    const [hover, setHover] = React.useState(false);
    return (
      <header style={{ flex: "none", display: "flex", alignItems: "center", justifyContent: "space-between", padding: "22px 34px" }}>
        <Wordmark />
        <a href="https://github.com/merlinkraemer/prunr" target="_blank" rel="noreferrer"
          onMouseEnter={() => setHover(true)} onMouseLeave={() => setHover(false)}
          style={{ display: "inline-flex", alignItems: "center", gap: 7, fontFamily: "var(--font-body)", fontWeight: 500, fontSize: 13,
            color: "var(--muted-color)", opacity: hover ? 1 : 0.62, textDecoration: "none", transition: "opacity var(--dur-fast) var(--ease)" }}>
          <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
            <path d="M15 22v-4a4.8 4.8 0 0 0-1-3.5c3 0 6-2 6-5.5.08-1.25-.27-2.48-1-3.5.28-1.15.28-2.35 0-3.5 0 0-1 0-3 1.5-2.64-.5-5.36-.5-8 0C6 2 5 2 5 2c-.3 1.15-.3 2.35 0 3.5A5.403 5.403 0 0 0 4 9c0 3.5 3 5.5 6 5.5-.39.49-.68 1.05-.85 1.65-.17.6-.22 1.23-.15 1.85v4"/>
            <path d="M9 18c-4.51 2-5-2-7-2"/>
          </svg>
          <span style={{ fontFamily: "var(--font-mono)", fontSize: 12.5, letterSpacing: "-0.01em" }}>/prunr</span>
        </a>
      </header>
    );
  }

  function Signup() {
    const [open, setOpen] = React.useState(false);
    const [focus, setFocus] = React.useState(false);
    const [email, setEmail] = React.useState("");
    const [done, setDone] = React.useState(false);
    const inputRef = React.useRef(null);

    React.useEffect(() => { if (open && inputRef.current) inputRef.current.focus(); }, [open]);

    function submit(e) {
      e.preventDefault();
      if (!/.+@.+\..+/.test(email)) { setFocus(true); return; }
      setDone(true);
    }

    if (done) {
      return (
        <div style={{ marginTop: 32, maxWidth: 466 }}>
          <div className="reveal" style={{ display: "inline-flex", alignItems: "center", gap: 11, background: "var(--accent-soft)", borderRadius: "var(--radius-pill)",
            padding: "12px 22px 12px 14px", boxShadow: "var(--shadow-hairline)" }}>
            <span style={{ flex: "none", width: 24, height: 24, borderRadius: "50%", background: "var(--theme-accent)", display: "inline-flex", alignItems: "center", justifyContent: "center" }}>
              <Icon name="check" size={14} color="var(--theme-accent-ink)" />
            </span>
            <span style={{ fontFamily: "var(--font-body)", fontWeight: 600, fontSize: 15, color: "var(--heading-color)" }}>
              Check your email &mdash; download link and install steps are on the way.
            </span>
          </div>
        </div>
      );
    }

    return (
      <div style={{ marginTop: 32, minHeight: 54 }}>
        {!open ? (
          <span className="cta-nudge" style={{ display: "inline-block" }}>
            <Button variant="primary" type="button" onClick={() => setOpen(true)}
              style={{ height: 54, padding: "0 30px", fontSize: 16 }}
              iconLeft={<AppleLogo size={18} />}>
              Join the alpha
            </Button>
          </span>
        ) : (
          <form className="reveal" onSubmit={submit} style={{ display: "flex", gap: 10, maxWidth: 466 }}>
            <input ref={inputRef} type="email" required placeholder="you@example.com" value={email}
              onChange={(e) => setEmail(e.target.value)} onFocus={() => setFocus(true)} onBlur={() => setFocus(false)}
              style={{ flex: 1, minWidth: 0, height: 54, padding: "0 22px", borderRadius: "var(--radius-pill)",
                border: "none", outline: "none", background: "var(--card)",
                boxShadow: focus ? "inset 0 0 0 1.5px var(--theme-accent), var(--focus-ring)" : "inset 0 0 0 1px var(--border)",
                fontFamily: "var(--font-body)", fontWeight: 500, fontSize: 15.5, color: "var(--body-color)",
                transition: "box-shadow var(--dur-fast) var(--ease)" }} />
            <Button variant="primary" type="submit" style={{ flex: "none", height: 54, padding: "0 24px", fontSize: 15.5 }}
              iconRight={<Icon name="arrow-right" size={17} />}>Join</Button>
          </form>
        )}
      </div>
    );
  }

  function Hero() {
    return (
      <main style={{ flex: 1, minHeight: 0, display: "grid", gridTemplateColumns: "auto auto", alignItems: "center", justifyContent: "center", gap: 56, maxWidth: 1180, width: "100%", margin: "0 auto", padding: "0 44px 48px" }} className="hero-grid">
        {/* product shot, baked on the page color (#fafaf7 ≈ page bg) so it sits seamlessly */}
        <div style={{ display: "flex", justifyContent: "center", alignItems: "center", minWidth: 0 }}>
          <img src="assets/app-popover-page.png" alt="Prunr menu-bar popover"
            style={{ display: "block", width: "100%", maxWidth: 360, maxHeight: "66vh", height: "auto" }} />
        </div>

        {/* Right column — headline + subline + button */}
        <div style={{ maxWidth: 540 }}>
          <h1 style={{ fontFamily: "var(--font-heading)", fontWeight: 700, fontSize: "clamp(40px, 5vw, 64px)", lineHeight: 1.06, letterSpacing: "var(--tracking-heading)", color: "var(--heading-color)", margin: 0 }}>
            <span style={{ display: "block", whiteSpace: "nowrap" }}>Who ate <span className="emoji-bug" style={{ display: "inline-block" }}>🐛</span></span>
            <span style={{ display: "block", whiteSpace: "nowrap" }}>my storage?</span>
            <span style={{ display: "block", whiteSpace: "nowrap" }}>Prunr <span className="emoji-leaf" style={{ display: "inline-block" }}>🍃</span></span>
            <span style={{ display: "block", whiteSpace: "nowrap" }}>keeps track.</span>
          </h1>

          <p style={{ fontFamily: "var(--font-body)", fontWeight: 500, fontSize: "clamp(15px, 1.4vw, 18px)", lineHeight: 1.5, color: "var(--body-color)", margin: "20px 0 0", maxWidth: 460 }}>
            I got tired of wondering where my storage went, so I built a menubar app that remembers.
          </p>

          <Signup />
        </div>
      </main>
    );
  }

  function Page() {
    return (
      <div style={{ height: "100vh", display: "flex", flexDirection: "column", overflow: "hidden" }}>
        <Nav />
        <Hero />
      </div>
    );
  }

  window.PrunrComingSoon = { Page, Nav, Hero, Signup };
})();
