// Prunr — coming soon, v2: fake macOS desktop. A real menubar across the top with
// the Prunr "447.9 GB" indicator; the popover hangs open just beneath it.
// Composes DS primitives from window.PrunrDesignSystem_225e08 → window.PrunrComingSoonV2.
(function () {
  const DS = window.PrunrDesignSystem_225e08;
  const { Button, Icon } = DS;

  function AppleLogo({ size = 18, color = "currentColor" }) {
    return (
      <svg viewBox="0 0 384 512" width={size} height={size} fill={color} aria-hidden="true"
        style={{ display: "block", marginTop: -2 }}>
        <path d="M318.7 268.7c-.2-36.7 16.4-64.4 50-84.8-18.8-26.9-47.2-41.7-84.7-44.6-35.5-2.8-74.3 20.7-88.5 20.7-15 0-49.4-19.7-76.4-19.7C63.3 141.2 4 184.8 4 273.5q0 39.3 14.4 81.2c12.8 36.7 59 126.7 107.2 125.2 25.2-.6 43-17.9 75.8-17.9 31.8 0 48.3 17.9 76.4 17.9 48.6-.7 90.4-82.5 102.6-119.3-65.2-30.7-61.7-90-61.7-91.9zm-56.6-164.2c27.3-32.4 24.8-61.9 24-72.5-24.1 1.4-52 16.4-67.9 34.9-17.5 19.8-27.8 44.3-25.6 71.9 26.1 2 49.9-11.4 69.5-34.3z"/>
      </svg>
    );
  }

  function Wordmark({ size = 27 }) {
    return (
      <span style={{ display: "inline-flex", alignItems: "center", gap: 10 }}>
        <AppIcon size={size} />
        <span style={{ fontFamily: "var(--font-heading)", fontWeight: 700, fontSize: size * 0.8, letterSpacing: "var(--tracking-heading)", color: "var(--heading-color)" }}>Prunr</span>
      </span>
    );
  }

  function AppIcon({ size = 27 }) {
    return (
      <img src="assets/prunr-icon-128.png" alt="" style={{ width: size, height: size, borderRadius: size * 0.225, display: "block" }} />
    );
  }

  // San Francisco — the real macOS system font (resolves to SF Pro on Mac).
  const SF = '-apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro Display", system-ui, sans-serif';

  // Status glyphs — real SF Symbols (Regular weight) exported from SF Symbols app.
  function BatteryGlyph() {
    return (
      <svg width="26.7" height="13" viewBox="6.8 -64.8 121.3 59.1" fill="currentColor" aria-hidden="true" style={{ display: "block" }}>
        <path d="M30.6152-8.69141L91.2109-8.69141C97.5098-8.69141 103.32-9.22852 107.471-13.3301C111.572-17.4805 112.061-23.291 112.061-29.541L112.061-40.9668C112.061-47.2168 111.572-53.0273 107.471-57.1289C103.32-61.2793 97.5098-61.8164 91.2109-61.8164L30.6152-61.8164C24.3652-61.8164 18.5059-61.2793 14.3555-57.1289C10.2539-53.0273 9.76562-47.2168 9.76562-40.9668L9.76562-29.541C9.76562-23.291 10.2539-17.4805 14.3555-13.3301C18.5059-9.22852 24.3164-8.69141 30.6152-8.69141ZM29.541-15.7227C25.9766-15.7227 21.7773-16.1621 19.4824-18.457C17.1875-20.752 16.7969-24.9023 16.7969-28.4668L16.7969-41.9922C16.7969-45.6055 17.1875-49.707 19.4824-52.0508C21.7773-54.3457 25.9766-54.7363 29.5898-54.7363L92.2852-54.7363C95.8496-54.7363 100.049-54.3457 102.344-52.0508C104.639-49.707 105.029-45.6055 105.029-41.9922L105.029-28.4668C105.029-24.9023 104.639-20.752 102.344-18.457C100.049-16.1621 95.8496-15.7227 92.2852-15.7227ZM117.773-25C120.898-25.1953 125.098-29.1992 125.098-35.2539C125.098-41.3086 120.898-45.3125 117.773-45.5078Z" />
        <path d="M27.0996-20.5078L75.0488-20.5078C77.1973-20.5078 78.418-20.8008 79.3457-21.7285C80.2734-22.6562 80.5664-23.877 80.5664-25.9766L80.5664-44.5312C80.5664-46.6309 80.2734-47.8516 79.3457-48.7793C78.418-49.707 77.1973-49.9512 75.0488-49.9512L27.0996-49.9512C25-49.9512 23.7305-49.707 22.8516-48.7793C21.9238-47.8516 21.582-46.6309 21.582-44.4824L21.582-25.9766C21.582-23.877 21.9238-22.6562 22.8516-21.7285C23.7793-20.8008 25-20.5078 27.0996-20.5078Z" />
      </svg>
    );
  }
  function WifiGlyph() {
    return (
      <svg width="18.3" height="13.5" viewBox="4.6 -70.2 94.9 70.1" fill="currentColor" aria-hidden="true" style={{ display: "block" }}>
        <path d="M13.7207-39.9902C14.4531-39.209 15.625-39.209 16.4062-40.0391C25.8301-50.0488 38.1836-55.2734 52.002-55.2734C65.918-55.2734 78.3203-50 87.7441-39.9902C88.4277-39.2578 89.5508-39.3066 90.332-40.0879L95.8008-45.5078C96.4844-46.2402 96.4355-47.1191 95.8984-47.8027C86.9141-58.9355 69.9707-67.2363 52.002-67.2363C34.082-67.2363 17.1387-58.9355 8.10547-47.8027C7.56836-47.1191 7.56836-46.2402 8.25195-45.5078Z" />
        <path d="M29.5898-24.0234C30.4199-23.1445 31.543-23.291 32.373-24.1699C36.8652-29.248 44.2871-32.959 52.002-32.9102C59.8145-32.959 67.1875-29.1016 71.8262-24.0234C72.5586-23.1934 73.584-23.2422 74.4629-24.0723L80.5664-30.0781C81.2012-30.7129 81.25-31.6406 80.7129-32.373C74.8535-39.4531 64.1602-44.9219 52.002-44.9219C39.8438-44.9219 29.1504-39.4531 23.3398-32.373C22.7539-31.6406 22.7539-30.8105 23.4863-30.0781Z" />
        <path d="M52.002-3.17383C52.9297-3.17383 53.6621-3.56445 55.2246-5.07812L64.6484-14.1113C65.2344-14.6973 65.3809-15.6738 64.8438-16.3574C62.2559-19.6777 57.5195-22.5586 52.002-22.5586C46.2891-22.5586 41.5527-19.5312 39.0137-16.0645C38.623-15.4785 38.8184-14.6973 39.4531-14.1113L48.7793-5.07812C50.3418-3.61328 51.123-3.17383 52.002-3.17383Z" />
      </svg>
    );
  }
  function SoundGlyph() {
    return (
      <svg width="19.0" height="14" viewBox="9.1 -75.9 110.4 81.2" fill="currentColor" aria-hidden="true" style={{ display: "block" }}>
        <path d="M101.025 1.2207C102.539 2.34375 104.688 1.9043 105.859 0.146484C112.695-9.47266 116.504-22.0703 116.504-35.2539C116.504-48.4375 112.549-60.9863 105.859-70.6543C104.688-72.4609 102.539-72.8516 101.025-71.7285C99.4141-70.6055 99.1699-68.5547 100.391-66.748C106.299-58.2031 109.814-47.0215 109.814-35.2539C109.814-23.5352 106.299-12.2559 100.391-3.75977C99.1699-1.95312 99.4141 0.0976562 101.025 1.2207Z" />
        <path d="M86.2305-8.88672C87.8418-7.8125 89.8438-8.1543 91.0156-9.86328C95.8984-16.6504 98.7305-25.8789 98.7305-35.2539C98.7305-44.6289 95.9473-53.9551 91.0156-60.6445C89.8438-62.3535 87.8418-62.6953 86.2305-61.6211C84.6191-60.5469 84.3262-58.4961 85.5957-56.6895C89.6484-50.9277 91.9434-43.1641 91.9434-35.2539C91.9434-27.3438 89.5508-19.6289 85.5957-13.8184C84.375-12.0117 84.6191-9.96094 86.2305-8.88672Z" />
        <path d="M71.5332-18.7988C72.998-17.8223 75.0488-18.1152 76.2207-19.8242C79.1504-23.7305 80.8594-29.4922 80.8594-35.2539C80.8594-41.0156 79.1504-46.7285 76.2207-50.6836C75.0488-52.3926 72.998-52.6855 71.5332-51.6602C69.7754-50.4395 69.4824-48.291 70.8496-46.4844C72.9004-43.7012 74.0723-39.4531 74.0723-35.2539C74.0723-31.0547 72.8516-26.8555 70.8496-24.0234C69.5312-22.168 69.7754-20.0684 71.5332-18.7988Z" />
        <path d="M53.6621-1.02539C56.3477-1.02539 58.3984-2.97852 58.3984-5.71289L58.3984-64.4531C58.3984-67.1387 56.3477-69.3848 53.5645-69.3848C51.6113-69.3848 50.293-68.5547 48.0957-66.4551L32.0312-51.5137C31.8359-51.3184 31.543-51.1719 31.25-51.1719L20.5566-51.1719C14.9414-51.1719 12.0605-48.291 12.0605-42.2363L12.0605-28.125C12.0605-22.1191 14.9414-19.1895 20.5566-19.1895L31.25-19.1895C31.543-19.1895 31.8359-19.0918 32.0312-18.8965L48.0957-3.66211C50.0977-1.80664 51.709-1.02539 53.6621-1.02539Z" />
      </svg>
    );
  }
  function ControlCenterGlyph() {
    return (
      <svg width="16.2" height="16" viewBox="6.8 -74.7 79.9 78.9" fill="currentColor" aria-hidden="true" style={{ display: "block" }}>
        <path d="M26.5137 1.2207L66.8945 1.2207C76.123 1.2207 83.6914-5.22461 83.6914-14.8926C83.6914-24.5605 76.123-31.0059 66.8945-31.0059L26.5137-31.0059C17.2852-31.0059 9.76562-24.5605 9.76562-14.8926C9.76562-5.22461 17.2852 1.2207 26.5137 1.2207ZM56.0059-5.37109C50.4883-5.37109 46.0938-9.17969 46.0938-14.9414C46.0938-20.6543 50.4883-24.4629 56.0059-24.4629L67.5781-24.4629C73.1445-24.4629 77.4902-20.6543 77.4902-14.8926C77.4902-9.17969 73.1445-5.37109 67.5781-5.37109Z" />
        <path d="M28.2227-36.1816L65.1855-36.1816C75.4883-36.1816 83.6914-43.3105 83.6914-53.9551C83.6914-64.5996 75.4883-71.7285 65.1855-71.7285L28.2227-71.7285C17.9688-71.7285 9.76562-64.5996 9.76562-53.9551C9.76562-43.3105 17.9688-36.1816 28.2227-36.1816ZM28.2227-42.7734C21.7773-42.7734 16.6016-47.2168 16.6016-53.9551C16.6016-60.6934 21.7773-65.1367 28.2227-65.1367L65.1855-65.1367C71.6797-65.1367 76.8066-60.6934 76.8066-53.9551C76.8066-47.2168 71.6797-42.7734 65.1855-42.7734Z" />
        <path d="M28.2227-45.4102L39.1113-45.4102C44.043-45.4102 47.998-48.8281 47.998-53.9551C47.998-59.1309 44.043-62.5488 39.1113-62.5488L28.2227-62.5488C23.291-62.5488 19.3359-59.1309 19.3359-54.0039C19.3359-48.8281 23.291-45.4102 28.2227-45.4102Z" />
      </svg>
    );
  }
  function SpotlightGlyph() {
    return (
      <svg width="14.9" height="15" viewBox="5.8 -76.3 81.4 82.1" fill="currentColor" aria-hidden="true" style={{ display: "block" }}>
        <path d="M8.78906-42.2363C8.78906-25.0977 22.7051-11.2305 39.8438-11.2305C46.4355-11.2305 52.4902-13.2812 57.5195-16.7969L75.6836 1.41602C76.709 2.39258 77.9785 2.83203 79.2969 2.83203C82.1289 2.83203 84.1797 0.683594 84.1797-2.14844C84.1797-3.51562 83.6426-4.73633 82.8125-5.66406L64.7461-23.7793C68.6035-28.9551 70.8496-35.3027 70.8496-42.2363C70.8496-59.375 56.9824-73.291 39.8438-73.291C22.7051-73.291 8.78906-59.375 8.78906-42.2363ZM16.3086-42.2363C16.3086-55.2734 26.8066-65.7715 39.8438-65.7715C52.832-65.7715 63.3789-55.2734 63.3789-42.2363C63.3789-29.248 52.832-18.7012 39.8438-18.7012C26.8066-18.7012 16.3086-29.248 16.3086-42.2363Z" />
      </svg>
    );
  }

  // Fake macOS menu bar — right-side status only (the "447.9 GB" item is the Prunr indicator).
  function MenuBar() {
    const ink = "#1d1d1f";
    const [now, setNow] = React.useState(() => new Date());
    React.useEffect(() => {
      const t = setInterval(() => setNow(new Date()), 1000);
      return () => clearInterval(t);
    }, []);
    const day = now.toLocaleDateString("en-US", { day: "numeric", month: "short" });
    const time = now.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit", hour12: false });
    return (
      <div className="site-menubar" style={{ position: "absolute", top: 0, left: 0, right: 0, height: 28, zIndex: 20,
        display: "flex", alignItems: "center", justifyContent: "flex-end", padding: "0 14px",
        background: "rgba(250,250,247,0.62)", backdropFilter: "saturate(180%) blur(20px)", WebkitBackdropFilter: "saturate(180%) blur(20px)",
        fontFamily: SF }}>
        <div className="mb-items" style={{ display: "flex", alignItems: "center", gap: 22, color: ink }}>
          {/* Prunr indicator — shown in its active (clicked-open) state: dark liquid-glass pill */}
          <span style={{ display: "inline-flex", alignItems: "center", padding: "4px 9px", borderRadius: 999, marginRight: -10,
            background: "rgba(0,0,0,0.12)", backdropFilter: "saturate(180%) blur(14px)", WebkitBackdropFilter: "saturate(180%) blur(14px)",
            boxShadow: "inset 0 0 0 0.5px rgba(255,255,255,0.18)",
            fontSize: 14, fontWeight: 400, color: ink }}>447.9 GB</span>
          <WifiGlyph />
          <SoundGlyph />
          <BatteryGlyph />
          <ControlCenterGlyph />
          <span style={{ fontSize: 14, fontWeight: 400, color: ink, letterSpacing: "0.01em" }}>{day}&nbsp;&nbsp;{time}</span>
        </div>
      </div>
    );
  }

  function Nav() {
    return (
      <header className="site-nav" style={{ flex: "none", display: "flex", alignItems: "center", padding: "12px 34px" }}>
        <Wordmark />
      </header>
    );
  }

  const ERR = "#d92d20"; // inline error red

  function Signup() {
    const [open, setOpen] = React.useState(false);
    const [focus, setFocus] = React.useState(false);
    const [email, setEmail] = React.useState("");
    const [error, setError] = React.useState("");        // "" = no error
    const [status, setStatus] = React.useState("idle");  // idle | loading | done
    const inputRef = React.useRef(null);

    React.useEffect(() => { if (open && inputRef.current) inputRef.current.focus(); }, [open]);

    function validate(value) {
      const v = value.trim();
      if (!v) return "Please enter your email.";
      // Pragmatic email check — one @, a dot in the domain, no spaces.
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v)) return "That doesn’t look like a valid email.";
      return "";
    }

    async function submit(e) {
      e.preventDefault();
      const msg = validate(email);
      if (msg) { setError(msg); setFocus(true); inputRef.current && inputRef.current.focus(); return; }
      setError("");
      setStatus("loading");
      try {
        const res = await fetch("https://prunr-web.vercel.app/api/subscribe", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ email: email.trim() }),
        });
        if (res.ok) { setStatus("done"); return; }
        let data = {};
        try { data = await res.json(); } catch (_) {}
        if (res.status === 409) { setStatus("done"); return; } // already subscribed → treat as success
        setStatus("idle");
        setError(data.error || "Something went wrong. Please try again.");
      } catch (_) {
        setStatus("idle");
        setError("Network error — check your connection and try again.");
      }
    }

    if (status === "done") {
      return (
        <div className="signup-root reveal" style={{ marginTop: 32 }}>
          <div className="signup-success">
            <span style={{ flex: "none", width: 24, height: 24, borderRadius: "50%", background: "var(--theme-accent)", display: "inline-flex", alignItems: "center", justifyContent: "center" }}>
              <Icon name="check" size={14} color="var(--theme-accent-ink)" />
            </span>
            <span style={{ fontFamily: "var(--font-body)", fontWeight: 600, fontSize: 15, color: "var(--heading-color)" }}>
              You&rsquo;re on the list &mdash; we&rsquo;ll send a download link.
            </span>
          </div>
        </div>
      );
    }

    const hasError = !!error;
    const ring = hasError
      ? `inset 0 0 0 1.5px ${ERR}`
      : (focus ? "inset 0 0 0 1.5px var(--theme-accent), var(--focus-ring)" : "inset 0 0 0 1px var(--border)");
    const layer = (on) => "signup-layer " + (on ? "signup-layer--in" : "signup-layer--out");

    return (
      <div className="signup-root" style={{ marginTop: 32 }}>
        <div className={layer(!open) + " signup-layer--cta"} aria-hidden={open}>
          <span className="cta-nudge" style={{ display: "inline-block" }}>
            <Button variant="primary" type="button" onClick={() => setOpen(true)}
              style={{ height: 54, padding: "0 30px", fontSize: 16 }}
              iconLeft={<AppleLogo size={18} />}>
              Join the alpha
            </Button>
          </span>
        </div>

        <div className={layer(open) + " signup-layer--form"} aria-hidden={!open}>
          <form onSubmit={submit} noValidate style={{ display: "flex", gap: 10 }}>
            <input ref={inputRef} type="email" placeholder="you@example.com" value={email}
              aria-invalid={hasError} aria-describedby="signup-error"
              disabled={status === "loading" || !open}
              tabIndex={open ? 0 : -1}
              onChange={(e) => { setEmail(e.target.value); if (hasError) setError(""); }}
              onFocus={() => setFocus(true)} onBlur={() => setFocus(false)}
              style={{ flex: 1, minWidth: 0, height: 54, padding: "0 22px", borderRadius: "var(--radius-pill)",
                border: "none", outline: "none", background: "var(--card)", boxShadow: ring,
                fontFamily: "var(--font-body)", fontWeight: 500, fontSize: 15.5, color: "var(--body-color)",
                transition: "box-shadow var(--dur-fast) var(--ease)" }} />
            <Button variant="primary" type="submit" disabled={status === "loading" || !open}
              tabIndex={open ? 0 : -1}
              style={{ flex: "none", height: 54, padding: "0 24px", fontSize: 15.5, opacity: status === "loading" ? 0.7 : 1 }}
              iconRight={status === "loading" ? null : <Icon name="arrow-right" size={17} />}>
              {status === "loading" ? "Joining…" : "Join"}
            </Button>
          </form>
          <div id="signup-error" role="alert" aria-live="polite"
            style={{ height: 20, marginTop: 8, paddingLeft: 22, fontFamily: "var(--font-body)", fontWeight: 500,
              fontSize: 13.5, color: ERR, opacity: hasError ? 1 : 0, transition: "opacity var(--dur-fast) var(--ease)" }}>
            {error || " "}
          </div>
        </div>
      </div>
    );
  }

  function Hero() {
    return (
      <main className="hero-main" style={{ flex: 1, minHeight: 0, display: "flex", alignItems: "center", maxWidth: 1240, width: "100%", margin: "0 auto", padding: "0 56px 40px" }}>
        {/* Left — headline + subline + button */}
        <div className="hero-body" style={{ maxWidth: 660 }}>
          <h1 style={{ fontFamily: "var(--font-heading)", fontWeight: 700, fontSize: "clamp(40px, 5vw, 64px)", lineHeight: 1.07, letterSpacing: "var(--tracking-heading)", color: "var(--heading-color)", margin: 0 }}>
            <span style={{ display: "block", whiteSpace: "nowrap" }}>Who ate <span className="emoji-bug" style={{ display: "inline-block" }}>🐛</span><br className="m-br" /> my storage?</span>
            <span style={{ display: "block", whiteSpace: "nowrap" }}>Prunr <span className="emoji-leaf" style={{ display: "inline-block" }}>🍃</span><br className="m-br" /> keeps track.</span>
          </h1>

          <div className="hero-subtitle">
            <p style={{ fontFamily: "var(--font-body)", fontWeight: 500, fontSize: "clamp(15px, 1.4vw, 18px)", lineHeight: 1.5, color: "var(--body-color)", margin: "20px 0 0", maxWidth: 460 }}>
              I got tired of wondering where my storage went,<br />
              so I built a menubar app that remembers.
            </p>
          </div>

          <div className="hero-cta">
            <Signup />
          </div>
        </div>
      </main>
    );
  }

  function GitHubIcon({ size = 15 }) {
    return (
      <svg width={size} height={size} viewBox="0 0 16 16" fill="currentColor" aria-hidden="true" style={{ display: "block" }}>
        <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z" />
      </svg>
    );
  }

  function Footer() {
    const link = { display: "inline-flex", alignItems: "center", gap: 6, textDecoration: "none",
      fontFamily: "var(--font-body)", fontWeight: 500, fontSize: 13, color: "var(--body-color)", opacity: 0.45,
      transition: "opacity var(--dur-fast) var(--ease)" };
    const onLinkEnter = (e) => (e.currentTarget.style.opacity = "0.85");
    const onLinkLeave = (e) => (e.currentTarget.style.opacity = "0.45");
    return (
      <footer className="site-footer" style={{ flex: "none", display: "flex", alignItems: "center", justifyContent: "center", gap: 22, padding: "0 34px 18px" }}>
        <span className="footer-logo" style={{ display: "none", marginRight: "auto" }}><Wordmark size={22} /></span>
        <a className="footer-github" href="https://github.com/merlinkraemer/prunr" target="_blank" rel="noopener noreferrer" style={link}
          onMouseEnter={onLinkEnter} onMouseLeave={onLinkLeave}>
          <GitHubIcon /> /prunr
        </a>
        <a className="footer-handle" href="https://merlins-internet.com" target="_blank" rel="noopener noreferrer" style={link}
          onMouseEnter={onLinkEnter} onMouseLeave={onLinkLeave}>
          @merlinkraemer
        </a>
        <span className="footer-contact">
          <span className="footer-contact-label">contact me?</span>
          <a href="https://merlins-internet.com" target="_blank" rel="noopener noreferrer" style={link}
            onMouseEnter={onLinkEnter} onMouseLeave={onLinkLeave}>
            @merlinkraemer
          </a>
        </span>
      </footer>
    );
  }

  function Page() {
    return (
      <div className="v2-page" style={{ height: "100vh", position: "relative", overflow: "hidden", background: "var(--bg)" }}>
        <MenuBar />
        <div className="hero-mobile-logo" aria-hidden="true">
          <AppIcon size={48} />
        </div>
        <div style={{ height: "100%", paddingTop: 28, display: "flex", flexDirection: "column" }}>
          <Nav />
          {/* Popover hangs open from the "447.9 GB" indicator — coupled to the menubar.
              Desktop: absolute, top-right under the pill. Mobile: flows directly below the
              bar (still hanging from the right) so the bar + screenshot read as one unit. */}
          <img className="popover-open" src="assets/app-popover-page.png" alt="Prunr menu-bar popover"
            style={{ position: "absolute", top: 34, right: 64, width: "clamp(300px, 30vw, 380px)", height: "auto",
              maxHeight: "calc(100vh - 60px)", zIndex: 10 }} />
          <Hero />
          <Footer />
        </div>
      </div>
    );
  }

  window.PrunrComingSoonV2 = { Page, MenuBar, Nav, Hero, Signup, Footer };
})();
