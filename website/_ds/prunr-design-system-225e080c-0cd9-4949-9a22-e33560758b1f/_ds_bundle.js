/* @ds-bundle: {"format":3,"namespace":"PrunrDesignSystem_225e08","components":[{"name":"CategoryRow","sourcePath":"components/app/CategoryRow.jsx"},{"name":"DriveBar","sourcePath":"components/app/DriveBar.jsx"},{"name":"GrowthBadge","sourcePath":"components/app/GrowthBadge.jsx"},{"name":"Badge","sourcePath":"components/core/Badge.jsx"},{"name":"Button","sourcePath":"components/core/Button.jsx"},{"name":"Card","sourcePath":"components/core/Card.jsx"},{"name":"Icon","sourcePath":"components/core/Icon.jsx"},{"name":"IconButton","sourcePath":"components/core/IconButton.jsx"},{"name":"Input","sourcePath":"components/core/Input.jsx"},{"name":"Pill","sourcePath":"components/core/Pill.jsx"},{"name":"Switch","sourcePath":"components/core/Switch.jsx"},{"name":"Tabs","sourcePath":"components/core/Tabs.jsx"}],"sourceHashes":{"components/app/CategoryRow.jsx":"9526a9d964cc","components/app/DriveBar.jsx":"313633b0063b","components/app/GrowthBadge.jsx":"4e5f32fd8a04","components/core/Badge.jsx":"f8fab3ae934d","components/core/Button.jsx":"24909e2f8e03","components/core/Card.jsx":"2fde5276ed3c","components/core/Icon.jsx":"9fefd047a856","components/core/IconButton.jsx":"f1b9ebe85f10","components/core/Input.jsx":"2575b491ebdd","components/core/Pill.jsx":"e9d276a8a86a","components/core/Switch.jsx":"c72f89f9fe34","components/core/Tabs.jsx":"aa5ccc5260dc","ui_kits/macos-app/app-screens.jsx":"d45e6df77429","ui_kits/website/site-sections.jsx":"51c506e4b1a8"},"inlinedExternals":[],"unexposedExports":[]} */

(() => {

const __ds_ns = (window.PrunrDesignSystem_225e08 = window.PrunrDesignSystem_225e08 || {});

const __ds_scope = {};

(__ds_ns.__errors = __ds_ns.__errors || []);

// components/app/DriveBar.jsx
try { (() => {
/**
 * Segmented disk-usage bar — the macOS app's signature visualization.
 * Renders category-colored segments inside the "used" portion against a
 * gray track. Mirrors Prunr's DriveBarView (12px tall, pill ends).
 */
function DriveBar({
  segments = [],
  usedFraction = null,
  height = 12,
  hoveredId = null,
  onHover,
  onSelect,
  style = {}
}) {
  const total = segments.reduce((s, x) => s + (x.bytes || 0), 0) || 1;
  // If no explicit usedFraction, the segments fill the whole bar.
  const used = usedFraction == null ? 1 : Math.max(0.42, Math.min(1, usedFraction));
  return /*#__PURE__*/React.createElement("div", {
    style: {
      position: "relative",
      height,
      borderRadius: height / 2,
      background: "rgba(120,120,128,0.16)",
      overflow: "hidden",
      ...style
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      position: "absolute",
      inset: 0,
      right: `${(1 - used) * 100}%`,
      display: "flex",
      gap: 1,
      borderRadius: height / 2,
      overflow: "hidden"
    }
  }, segments.map(seg => {
    const dim = hoveredId && hoveredId !== seg.id;
    return /*#__PURE__*/React.createElement("div", {
      key: seg.id,
      onMouseEnter: () => onHover && onHover(seg.id),
      onMouseLeave: () => onHover && onHover(null),
      onClick: () => onSelect && onSelect(seg.id),
      title: seg.label,
      style: {
        flex: `${(seg.bytes || 0) / total} 0 0`,
        minWidth: 3,
        background: seg.color,
        opacity: dim ? 0.3 : 0.95,
        cursor: onSelect ? "pointer" : "default",
        transition: "opacity var(--dur-fast) var(--ease)"
      }
    });
  })));
}
Object.assign(__ds_scope, { DriveBar });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/app/DriveBar.jsx", error: String((e && e.message) || e) }); }

// components/app/GrowthBadge.jsx
try { (() => {
/**
 * Growth delta indicator — orange "↗ +1.2 GB" for growth (matches the app's
 * category rows), green "↘ −250 MB" for freed space. Monospaced numerals.
 */
function GrowthBadge({
  value,
  direction = "up",
  size = 10,
  style = {}
}) {
  const isUp = direction === "up";
  return /*#__PURE__*/React.createElement("span", {
    style: {
      display: "inline-flex",
      alignItems: "center",
      gap: 3,
      fontFamily: "var(--font-mono)",
      fontSize: size,
      fontWeight: 600,
      color: isUp ? "var(--growth-delta)" : "var(--growth-down)",
      whiteSpace: "nowrap",
      ...style
    }
  }, /*#__PURE__*/React.createElement("svg", {
    width: size,
    height: size,
    viewBox: "0 0 24 24",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: "3",
    strokeLinecap: "round",
    strokeLinejoin: "round",
    style: {
      transform: isUp ? "none" : "scaleY(-1)"
    }
  }, /*#__PURE__*/React.createElement("line", {
    x1: "7",
    y1: "17",
    x2: "17",
    y2: "7"
  }), /*#__PURE__*/React.createElement("polyline", {
    points: "8 7 17 7 17 16"
  })), value);
}
Object.assign(__ds_scope, { GrowthBadge });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/app/GrowthBadge.jsx", error: String((e && e.message) || e) }); }

// components/app/CategoryRow.jsx
try { (() => {
/**
 * A single category / file row in the menu-bar list. Mirrors Prunr's
 * CategoryInventoryRow: colored icon, semibold name, monospaced size,
 * optional growth delta, chevron. Hover fills with a soft gray, 8px round.
 */
function CategoryRow({
  icon,
  name,
  subtitle = null,
  size,
  growth = null,
  chevron = true,
  highlighted = false,
  onHover,
  onClick,
  style = {}
}) {
  const [hover, setHover] = React.useState(false);
  const lit = hover || highlighted;
  return /*#__PURE__*/React.createElement("div", {
    onClick: onClick,
    onMouseEnter: () => {
      setHover(true);
      onHover && onHover(true);
    },
    onMouseLeave: () => {
      setHover(false);
      onHover && onHover(false);
    },
    style: {
      display: "flex",
      alignItems: "center",
      gap: 10,
      padding: "7px 12px",
      margin: "0 6px",
      minHeight: 34,
      borderRadius: "var(--radius-md)",
      background: lit ? "var(--app-hover)" : "transparent",
      cursor: onClick ? "pointer" : "default",
      transition: "background var(--dur-fast) var(--ease)",
      ...style
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      width: 18,
      height: 18,
      display: "inline-flex",
      alignItems: "center",
      justifyContent: "center",
      flex: "none"
    }
  }, icon), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      minWidth: 0
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      fontFamily: "var(--font-ui)",
      fontWeight: 600,
      fontSize: 13,
      color: "var(--app-text)",
      whiteSpace: "nowrap",
      overflow: "hidden",
      textOverflow: "ellipsis"
    }
  }, name), subtitle && /*#__PURE__*/React.createElement("div", {
    style: {
      fontFamily: "var(--font-mono)",
      fontSize: 10,
      color: "var(--app-text-secondary)",
      whiteSpace: "nowrap",
      overflow: "hidden",
      textOverflow: "ellipsis"
    }
  }, subtitle)), /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      flexDirection: "column",
      alignItems: "flex-end",
      gap: 2,
      flex: "none"
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: "var(--font-mono)",
      fontSize: 12,
      color: "var(--app-text)"
    }
  }, size), growth && /*#__PURE__*/React.createElement(__ds_scope.GrowthBadge, {
    value: growth.value,
    direction: growth.direction || "up"
  })), chevron && /*#__PURE__*/React.createElement("svg", {
    width: "11",
    height: "11",
    viewBox: "0 0 24 24",
    fill: "none",
    stroke: "var(--app-text-tertiary)",
    strokeWidth: "3.5",
    strokeLinecap: "round",
    strokeLinejoin: "round",
    style: {
      flex: "none"
    }
  }, /*#__PURE__*/React.createElement("polyline", {
    points: "9 18 15 12 9 6"
  })));
}
Object.assign(__ds_scope, { CategoryRow });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/app/CategoryRow.jsx", error: String((e && e.message) || e) }); }

// components/core/Badge.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
function Badge({
  children,
  tone = "neutral",
  dot = false,
  style = {},
  ...rest
}) {
  const tones = {
    neutral: {
      bg: "var(--theme-bg)",
      fg: "var(--muted-color)"
    },
    accent: {
      bg: "var(--accent-soft)",
      fg: "var(--theme-accent)"
    },
    good: {
      bg: "color-mix(in srgb, var(--good) 14%, #fff)",
      fg: "var(--good)"
    },
    warn: {
      bg: "color-mix(in srgb, var(--warn) 16%, #fff)",
      fg: "var(--warn)"
    },
    bad: {
      bg: "color-mix(in srgb, var(--bad) 14%, #fff)",
      fg: "var(--bad)"
    }
  };
  const t = tones[tone] || tones.neutral;
  return /*#__PURE__*/React.createElement("span", _extends({
    style: {
      display: "inline-flex",
      alignItems: "center",
      gap: 5,
      fontFamily: "var(--font-body)",
      fontWeight: 700,
      fontSize: 11,
      letterSpacing: "0.01em",
      lineHeight: 1,
      padding: "5px 9px",
      borderRadius: "var(--radius-sm)",
      background: t.bg,
      color: t.fg,
      whiteSpace: "nowrap",
      ...style
    }
  }, rest), dot && /*#__PURE__*/React.createElement("span", {
    style: {
      width: 6,
      height: 6,
      borderRadius: "50%",
      background: t.fg,
      flex: "none"
    }
  }), children);
}
Object.assign(__ds_scope, { Badge });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/Badge.jsx", error: String((e && e.message) || e) }); }

// components/core/Button.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
function Button({
  children,
  variant = "primary",
  size = "md",
  iconLeft = null,
  iconRight = null,
  disabled = false,
  full = false,
  onClick,
  style = {},
  ...rest
}) {
  const [hover, setHover] = React.useState(false);
  const [active, setActive] = React.useState(false);
  const sizes = {
    sm: {
      fontSize: 13,
      padding: "8px 16px",
      gap: 6
    },
    md: {
      fontSize: 15,
      padding: "11px 22px",
      gap: 8
    },
    lg: {
      fontSize: 18,
      padding: "15px 30px",
      gap: 10
    }
  };
  const sz = sizes[size] || sizes.md;
  const base = {
    appearance: "none",
    border: "none",
    cursor: disabled ? "not-allowed" : "pointer",
    fontFamily: "var(--font-body)",
    fontWeight: 600,
    fontSize: sz.fontSize,
    lineHeight: 1,
    padding: sz.padding,
    borderRadius: "var(--radius-pill)",
    display: full ? "flex" : "inline-flex",
    width: full ? "100%" : "auto",
    alignItems: "center",
    justifyContent: "center",
    gap: sz.gap,
    position: "relative",
    overflow: "hidden",
    textDecoration: "none",
    whiteSpace: "nowrap",
    transition: "transform var(--dur-fast) var(--ease), opacity var(--dur-fast) var(--ease), background var(--dur-fast) var(--ease), box-shadow var(--dur-fast) var(--ease)",
    opacity: disabled ? 0.45 : 1,
    transform: !disabled && hover && !active ? "translateY(-1px)" : "translateY(0)"
  };
  const variants = {
    primary: {
      background: "var(--theme-accent)",
      color: "var(--theme-accent-ink)",
      boxShadow: hover && !disabled ? "var(--shadow-soft)" : "none"
    },
    secondary: {
      background: "var(--card)",
      color: "var(--heading-color)",
      boxShadow: hover && !disabled ? "var(--shadow-hairline), var(--shadow-soft)" : "var(--shadow-hairline)"
    },
    ghost: {
      background: hover && !disabled ? "var(--accent-soft)" : "transparent",
      color: "var(--theme-accent)"
    }
  };
  const merged = {
    ...base,
    ...(variants[variant] || variants.primary),
    ...style
  };
  if (hover && !disabled && variant === "primary") merged.opacity = 0.92;
  return /*#__PURE__*/React.createElement("button", _extends({
    type: "button",
    style: merged,
    disabled: disabled,
    onClick: onClick,
    onMouseEnter: () => setHover(true),
    onMouseLeave: () => {
      setHover(false);
      setActive(false);
    },
    onMouseDown: () => setActive(true),
    onMouseUp: () => setActive(false)
  }, rest), variant === "primary" && !disabled && /*#__PURE__*/React.createElement("span", {
    "aria-hidden": "true",
    className: "ds-glare",
    style: {
      position: "absolute",
      top: 0,
      width: "45%",
      height: "100%",
      background: "linear-gradient(105deg, transparent, rgba(255,255,255,0.16), transparent)",
      transform: "skewX(-18deg)",
      pointerEvents: "none"
    }
  }), iconLeft, children, iconRight);
}
Object.assign(__ds_scope, { Button });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/Button.jsx", error: String((e && e.message) || e) }); }

// components/core/Card.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
function Card({
  children,
  elevated = true,
  size = "lg",
  hover = false,
  style = {},
  ...rest
}) {
  const [isHover, setHover] = React.useState(false);
  const radii = {
    sm: "var(--radius-md)",
    md: "var(--radius-lg)",
    lg: "var(--radius-xl)"
  };
  const pads = {
    sm: "16px",
    md: "22px",
    lg: "28px"
  };
  return /*#__PURE__*/React.createElement("div", _extends({
    onMouseEnter: () => setHover(true),
    onMouseLeave: () => setHover(false),
    style: {
      background: "var(--card)",
      borderRadius: radii[size] || radii.lg,
      padding: pads[size] || pads.lg,
      boxShadow: elevated ? hover && isHover ? "var(--shadow-pop)" : "var(--shadow-elevated)" : "var(--shadow-hairline)",
      transition: "box-shadow var(--dur-base) var(--ease), transform var(--dur-base) var(--ease)",
      transform: hover && isHover ? "translateY(-2px)" : "none",
      ...style
    }
  }, rest), children);
}
Object.assign(__ds_scope, { Card });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/Card.jsx", error: String((e && e.message) || e) }); }

// components/core/Icon.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * Renders a Lucide icon by name. Requires the Lucide UMD script to be
 * loaded globally (window.lucide). Stroke width defaults to the brand's 1.6.
 */
function Icon({
  name,
  size = 18,
  strokeWidth = 1.6,
  color = "currentColor",
  style = {},
  ...rest
}) {
  const ref = React.useRef(null);
  React.useEffect(() => {
    if (ref.current && window.lucide) {
      ref.current.innerHTML = "";
      const el = document.createElement("i");
      el.setAttribute("data-lucide", name);
      ref.current.appendChild(el);
      try {
        window.lucide.createIcons({
          attrs: {
            width: size,
            height: size,
            "stroke-width": strokeWidth
          },
          nameAttr: "data-lucide"
        });
      } catch (e) {}
    }
  }, [name, size, strokeWidth]);
  return /*#__PURE__*/React.createElement("span", _extends({
    ref: ref,
    style: {
      display: "inline-flex",
      alignItems: "center",
      justifyContent: "center",
      width: size,
      height: size,
      color,
      flex: "none",
      ...style
    }
  }, rest));
}
Object.assign(__ds_scope, { Icon });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/Icon.jsx", error: String((e && e.message) || e) }); }

// components/core/IconButton.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
function IconButton({
  icon,
  label,
  variant = "ghost",
  size = 34,
  disabled = false,
  onClick,
  style = {},
  ...rest
}) {
  const [hover, setHover] = React.useState(false);
  const variants = {
    ghost: {
      background: hover && !disabled ? "var(--accent-soft)" : "transparent",
      color: "var(--theme-accent)",
      boxShadow: "none"
    },
    surface: {
      background: "var(--card)",
      color: "var(--heading-color)",
      boxShadow: hover && !disabled ? "var(--shadow-hairline), var(--shadow-soft)" : "var(--shadow-hairline)"
    },
    solid: {
      background: "var(--theme-accent)",
      color: "var(--theme-accent-ink)",
      boxShadow: "none"
    }
  };
  return /*#__PURE__*/React.createElement("button", _extends({
    type: "button",
    "aria-label": label,
    title: label,
    disabled: disabled,
    onClick: onClick,
    onMouseEnter: () => setHover(true),
    onMouseLeave: () => setHover(false),
    style: {
      appearance: "none",
      border: "none",
      cursor: disabled ? "not-allowed" : "pointer",
      width: size,
      height: size,
      borderRadius: "var(--radius-pill)",
      display: "inline-flex",
      alignItems: "center",
      justifyContent: "center",
      opacity: disabled ? 0.45 : 1,
      transition: "background var(--dur-fast) var(--ease), transform var(--dur-fast) var(--ease)",
      transform: hover && !disabled ? "translateY(-1px)" : "translateY(0)",
      ...(variants[variant] || variants.ghost),
      ...style
    }
  }, rest), icon);
}
Object.assign(__ds_scope, { IconButton });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/IconButton.jsx", error: String((e && e.message) || e) }); }

// components/core/Input.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
function Input({
  value,
  onChange,
  placeholder = "",
  type = "text",
  iconLeft = null,
  disabled = false,
  full = true,
  style = {},
  ...rest
}) {
  const [focus, setFocus] = React.useState(false);
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      alignItems: "center",
      gap: 8,
      width: full ? "100%" : "auto",
      background: "var(--card)",
      borderRadius: "var(--radius-md)",
      padding: "0 12px",
      height: 42,
      boxShadow: focus ? "var(--shadow-hairline), var(--focus-ring)" : "var(--shadow-hairline)",
      transition: "box-shadow var(--dur-fast) var(--ease)",
      opacity: disabled ? 0.5 : 1,
      ...style
    }
  }, iconLeft, /*#__PURE__*/React.createElement("input", _extends({
    type: type,
    value: value,
    onChange: onChange,
    placeholder: placeholder,
    disabled: disabled,
    onFocus: () => setFocus(true),
    onBlur: () => setFocus(false),
    style: {
      flex: 1,
      minWidth: 0,
      border: "none",
      outline: "none",
      background: "transparent",
      fontFamily: "var(--font-body)",
      fontWeight: 500,
      fontSize: 15,
      color: "var(--body-color)"
    }
  }, rest)));
}
Object.assign(__ds_scope, { Input });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/Input.jsx", error: String((e && e.message) || e) }); }

// components/core/Pill.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
function Pill({
  children,
  iconLeft = null,
  tone = "neutral",
  active = false,
  onClick,
  style = {},
  ...rest
}) {
  const [hover, setHover] = React.useState(false);
  const interactive = typeof onClick === "function";
  const tones = {
    neutral: {
      background: active ? "var(--heading-color)" : "var(--card)",
      color: active ? "#fff" : "var(--body-color)",
      boxShadow: "var(--shadow-hairline)"
    },
    accent: {
      background: active ? "var(--theme-accent)" : "var(--accent-soft)",
      color: active ? "var(--theme-accent-ink)" : "var(--theme-accent)",
      boxShadow: "none"
    }
  };
  const t = tones[tone] || tones.neutral;
  return /*#__PURE__*/React.createElement("span", _extends({
    role: interactive ? "button" : undefined,
    onClick: onClick,
    onMouseEnter: () => setHover(true),
    onMouseLeave: () => setHover(false),
    style: {
      display: "inline-flex",
      alignItems: "center",
      gap: 6,
      fontFamily: "var(--font-body)",
      fontWeight: 600,
      fontSize: 13,
      lineHeight: 1,
      padding: "7px 14px",
      borderRadius: "var(--radius-pill)",
      cursor: interactive ? "pointer" : "default",
      userSelect: "none",
      whiteSpace: "nowrap",
      transition: "transform var(--dur-fast) var(--ease), background var(--dur-fast) var(--ease)",
      transform: interactive && hover ? "translateY(-1px)" : "none",
      ...t,
      ...style
    }
  }, rest), iconLeft, children);
}
Object.assign(__ds_scope, { Pill });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/Pill.jsx", error: String((e && e.message) || e) }); }

// components/core/Switch.jsx
try { (() => {
function Switch({
  checked = false,
  onChange,
  disabled = false,
  label = null,
  style = {}
}) {
  const toggle = () => {
    if (!disabled && onChange) onChange(!checked);
  };
  const knob = /*#__PURE__*/React.createElement("span", {
    role: "switch",
    "aria-checked": checked,
    onClick: toggle,
    style: {
      position: "relative",
      width: 42,
      height: 26,
      borderRadius: "var(--radius-pill)",
      background: checked ? "var(--theme-accent)" : "color-mix(in srgb, var(--text-secondary) 28%, #fff)",
      cursor: disabled ? "not-allowed" : "pointer",
      transition: "background var(--dur-base) var(--ease)",
      flex: "none",
      boxShadow: "var(--shadow-inset)",
      opacity: disabled ? 0.5 : 1
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      position: "absolute",
      top: 3,
      left: checked ? 19 : 3,
      width: 20,
      height: 20,
      borderRadius: "50%",
      background: "#fff",
      boxShadow: "0 1px 3px rgba(0,0,0,0.25)",
      transition: "left var(--dur-base) var(--ease)"
    }
  }));
  if (!label) return knob;
  return /*#__PURE__*/React.createElement("label", {
    style: {
      display: "inline-flex",
      alignItems: "center",
      gap: 10,
      cursor: disabled ? "not-allowed" : "pointer",
      ...style
    }
  }, knob, /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: "var(--font-body)",
      fontWeight: 500,
      fontSize: 15,
      color: "var(--body-color)"
    }
  }, label));
}
Object.assign(__ds_scope, { Switch });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/Switch.jsx", error: String((e && e.message) || e) }); }

// components/core/Tabs.jsx
try { (() => {
function Tabs({
  tabs = [],
  value,
  onChange,
  style = {}
}) {
  const [internal, setInternal] = React.useState(tabs[0]?.id);
  const active = value !== undefined ? value : internal;
  const select = id => {
    if (value === undefined) setInternal(id);
    if (onChange) onChange(id);
  };
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: "inline-flex",
      gap: 4,
      padding: 4,
      background: "var(--theme-bg)",
      borderRadius: "var(--radius-pill)",
      ...style
    }
  }, tabs.map(t => {
    const isActive = t.id === active;
    return /*#__PURE__*/React.createElement("button", {
      key: t.id,
      type: "button",
      onClick: () => select(t.id),
      style: {
        appearance: "none",
        border: "none",
        cursor: "pointer",
        fontFamily: "var(--font-body)",
        fontWeight: 600,
        fontSize: 13,
        padding: "8px 16px",
        borderRadius: "var(--radius-pill)",
        background: isActive ? "var(--card)" : "transparent",
        color: isActive ? "var(--heading-color)" : "var(--muted-color)",
        boxShadow: isActive ? "var(--shadow-soft)" : "none",
        transition: "background var(--dur-fast) var(--ease), color var(--dur-fast) var(--ease)"
      }
    }, t.label);
  }));
}
Object.assign(__ds_scope, { Tabs });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/Tabs.jsx", error: String((e && e.message) || e) }); }

// ui_kits/macos-app/app-screens.jsx
try { (() => {
// Prunr — interactive product mock for marketing (dark "liquid glass").
// Mirrors the REAL macOS app popover (see assets/app-popover-dark.png).
// Composes design-system primitives from window.PrunrDesignSystem_225e08.
// Assigns to window.PrunrUI (loaded via babel <script src>).
(function () {
  const DS = window.PrunrDesignSystem_225e08;
  const {
    Icon
  } = DS;
  const CATEGORIES = [{
    id: "other",
    name: "Other",
    color: "var(--cat-other)",
    icon: "more-horizontal",
    size: "421.1 GB",
    bytes: 421,
    growth: "+146 MB"
  }, {
    id: "caches",
    name: "Caches & System",
    color: "var(--cat-caches)",
    icon: "settings",
    size: "228.0 GB",
    bytes: 228,
    growth: "+1.2 GB"
  }, {
    id: "media",
    name: "Media & Documents",
    color: "var(--cat-media)",
    icon: "image",
    size: "119.5 GB",
    bytes: 119,
    growth: "+8.9 GB"
  }, {
    id: "developer",
    name: "Developer",
    color: "var(--cat-developer)",
    icon: "hammer",
    size: "71.5 GB",
    bytes: 71,
    growth: "+4.9 GB"
  }, {
    id: "downloads",
    name: "Downloads",
    color: "var(--cat-downloads)",
    icon: "download",
    size: "7.1 GB",
    bytes: 7,
    growth: "+10 MB"
  }, {
    id: "audio",
    name: "Audio Production",
    color: "var(--cat-audio)",
    icon: "music",
    size: "522.4 MB",
    bytes: 5,
    growth: null
  }, {
    id: "applications",
    name: "Applications",
    color: "var(--cat-applications)",
    icon: "layout-grid",
    size: "18.9 GB",
    bytes: 19,
    growth: null
  }];
  const FILES = {
    developer: [{
      name: "node_modules",
      path: "~/dev/room/web",
      size: "8.9 GB",
      growth: "+820 MB",
      big: true,
      icon: "package"
    }, {
      name: "Docker.raw",
      path: "~/Library/Containers/com.docker",
      size: "6.2 GB",
      growth: "+1.1 GB",
      big: true,
      icon: "container"
    }, {
      name: "target",
      path: "~/dev/c-seq",
      size: "3.4 GB",
      big: true,
      icon: "folder"
    }, {
      name: "DerivedData",
      path: "~/Library/Developer/Xcode",
      size: "2.1 GB",
      big: true,
      icon: "folder"
    }, {
      name: ".venv",
      path: "~/dev/factory",
      size: "740 MB",
      icon: "folder"
    }],
    media: [{
      name: "Photos Library",
      path: "~/Pictures",
      size: "44 GB",
      growth: "+5.1 GB",
      big: true,
      icon: "image"
    }, {
      name: "trip-se-asia.mov",
      path: "~/Movies",
      size: "12 GB",
      growth: "+3.0 GB",
      big: true,
      icon: "video"
    }, {
      name: "renders",
      path: "~/Documents/work",
      size: "6.2 GB",
      big: true,
      icon: "folder"
    }],
    caches: [{
      name: "com.spotify.client",
      path: "~/Library/Caches",
      size: "9.4 GB",
      growth: "+1.0 GB",
      big: true,
      icon: "music"
    }, {
      name: "Google/Chrome",
      path: "~/Library/Caches",
      size: "3.1 GB",
      big: true,
      icon: "globe"
    }, {
      name: "Mail Downloads",
      path: "~/Library/Containers",
      size: "880 MB",
      icon: "mail"
    }]
  };
  function GrowthDelta({
    value,
    size = 11
  }) {
    return /*#__PURE__*/React.createElement("span", {
      style: {
        display: "inline-flex",
        alignItems: "center",
        gap: 3,
        fontFamily: "var(--font-mono)",
        fontSize: size,
        fontWeight: 600,
        color: "var(--growth-delta)",
        whiteSpace: "nowrap"
      }
    }, /*#__PURE__*/React.createElement(Icon, {
      name: "arrow-up-right",
      size: size,
      color: "var(--growth-delta)"
    }), value);
  }
  function FooterButton({
    icon,
    label,
    onClick
  }) {
    const [h, setH] = React.useState(false);
    return /*#__PURE__*/React.createElement("button", {
      type: "button",
      "aria-label": label,
      title: label,
      onClick: onClick,
      onMouseEnter: () => setH(true),
      onMouseLeave: () => setH(false),
      style: {
        appearance: "none",
        border: "none",
        cursor: "pointer",
        width: 30,
        height: 30,
        borderRadius: "var(--radius-sm)",
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        background: h ? "var(--glass-dark-hover)" : "transparent",
        color: "var(--glass-dark-text-secondary)",
        transition: "background var(--dur-fast) var(--ease)"
      }
    }, /*#__PURE__*/React.createElement(Icon, {
      name: icon,
      size: 16
    }));
  }
  function Row({
    icon,
    color,
    name,
    size,
    growth,
    subtitle,
    big,
    chevron = true,
    onClick
  }) {
    const [h, setH] = React.useState(false);
    return /*#__PURE__*/React.createElement("div", {
      onClick: onClick,
      onMouseEnter: () => setH(true),
      onMouseLeave: () => setH(false),
      style: {
        display: "flex",
        alignItems: "center",
        gap: 12,
        padding: "9px 14px",
        margin: "0 7px",
        minHeight: 40,
        borderRadius: 10,
        background: h ? "var(--glass-dark-hover)" : "transparent",
        cursor: onClick ? "pointer" : "default",
        transition: "background var(--dur-fast) var(--ease)"
      }
    }, /*#__PURE__*/React.createElement("span", {
      style: {
        width: 24,
        display: "inline-flex",
        justifyContent: "center",
        flex: "none"
      }
    }, /*#__PURE__*/React.createElement(Icon, {
      name: icon,
      size: 20,
      color: color
    })), /*#__PURE__*/React.createElement("div", {
      style: {
        flex: 1,
        minWidth: 0
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        fontFamily: "var(--font-ui)",
        fontWeight: 600,
        fontSize: 15,
        color: "var(--glass-dark-text)",
        whiteSpace: "nowrap",
        overflow: "hidden",
        textOverflow: "ellipsis"
      }
    }, name), subtitle && /*#__PURE__*/React.createElement("div", {
      style: {
        fontFamily: "var(--font-mono)",
        fontSize: 11,
        color: "var(--glass-dark-text-secondary)",
        whiteSpace: "nowrap",
        overflow: "hidden",
        textOverflow: "ellipsis"
      }
    }, subtitle)), /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        flexDirection: "column",
        alignItems: "flex-end",
        gap: 1,
        flex: "none"
      }
    }, /*#__PURE__*/React.createElement("span", {
      style: {
        fontFamily: "var(--font-mono)",
        fontSize: 14,
        color: "var(--glass-dark-text)"
      }
    }, size), growth && /*#__PURE__*/React.createElement(GrowthDelta, {
      value: growth
    })), chevron && /*#__PURE__*/React.createElement(Icon, {
      name: "chevron-right",
      size: 15,
      color: "var(--glass-dark-text-tertiary)",
      style: {
        flex: "none"
      }
    }));
  }
  function Popover() {
    const [drill, setDrill] = React.useState(null);
    const cat = CATEGORIES.find(c => c.id === drill);
    const files = drill ? FILES[drill] || [] : null;
    const total = CATEGORIES.reduce((s, c) => s + c.bytes, 0);
    return /*#__PURE__*/React.createElement("div", {
      style: {
        width: 340,
        height: 500,
        borderRadius: 18,
        overflow: "hidden",
        display: "flex",
        flexDirection: "column",
        fontFamily: "var(--font-ui)",
        background: "var(--glass-dark-bg)",
        border: "0.5px solid var(--glass-dark-border)",
        boxShadow: "0 24px 70px rgba(0,0,0,0.5)"
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        padding: "16px 16px 0"
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        position: "relative",
        height: 14,
        borderRadius: 7,
        background: "rgba(255,255,255,0.12)",
        overflow: "hidden"
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        position: "absolute",
        inset: 0,
        right: "16%",
        display: "flex",
        gap: 1,
        borderRadius: 7,
        overflow: "hidden"
      }
    }, CATEGORIES.map(c => /*#__PURE__*/React.createElement("div", {
      key: c.id,
      title: c.name,
      style: {
        flex: `${c.bytes / total} 0 0`,
        minWidth: 3,
        background: c.color,
        opacity: drill && drill !== c.id ? 0.3 : 0.95,
        transition: "opacity var(--dur-fast) var(--ease)"
      }
    }))))), /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        alignItems: "center",
        gap: 10,
        padding: "16px 16px 8px"
      }
    }, drill ? /*#__PURE__*/React.createElement("button", {
      type: "button",
      onClick: () => setDrill(null),
      style: {
        appearance: "none",
        border: "none",
        background: "transparent",
        cursor: "pointer",
        color: "var(--cat-downloads)",
        display: "inline-flex",
        alignItems: "center",
        gap: 4,
        fontSize: 14,
        fontWeight: 600,
        padding: 0
      }
    }, /*#__PURE__*/React.createElement(Icon, {
      name: "chevron-left",
      size: 16,
      color: "var(--cat-downloads)"
    }), " ", cat.name) : /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement("span", {
      style: {
        display: "inline-flex",
        alignItems: "center",
        gap: 5,
        padding: "7px 13px",
        borderRadius: "var(--radius-pill)",
        background: "color-mix(in srgb, var(--growth-delta) 20%, transparent)",
        color: "var(--growth-delta)",
        fontFamily: "var(--font-mono)",
        fontWeight: 700,
        fontSize: 15
      }
    }, /*#__PURE__*/React.createElement(Icon, {
      name: "arrow-up-right",
      size: 15,
      color: "var(--growth-delta)"
    }), " +15.1 GB"), /*#__PURE__*/React.createElement("span", {
      style: {
        fontSize: 14,
        color: "var(--glass-dark-text-secondary)"
      }
    }, "since 1 day ago"))), /*#__PURE__*/React.createElement("div", {
      className: "prunr-scroll",
      style: {
        flex: 1,
        overflowY: "auto",
        paddingBottom: 6
      }
    }, !drill && CATEGORIES.map(c => /*#__PURE__*/React.createElement(Row, {
      key: c.id,
      icon: c.icon,
      color: c.color,
      name: c.name,
      size: c.size,
      growth: c.growth,
      onClick: () => FILES[c.id] && setDrill(c.id)
    })), drill && files.map((f, i) => /*#__PURE__*/React.createElement(Row, {
      key: i,
      icon: f.icon,
      color: f.big ? "rgba(235,235,245,0.6)" : "rgba(235,235,245,0.35)",
      name: f.name,
      subtitle: f.path,
      size: f.size,
      growth: f.growth,
      chevron: false
    }))), /*#__PURE__*/React.createElement("div", {
      style: {
        height: 0.5,
        background: "var(--glass-dark-sep)"
      }
    }), /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        alignItems: "center",
        padding: "10px 14px"
      }
    }, /*#__PURE__*/React.createElement(FooterButton, {
      icon: "refresh-cw",
      label: "Rescan now"
    }), /*#__PURE__*/React.createElement("span", {
      style: {
        flex: 1,
        textAlign: "center",
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        gap: 7,
        fontSize: 13,
        color: "var(--glass-dark-text-secondary)"
      }
    }, /*#__PURE__*/React.createElement("span", {
      style: {
        width: 6,
        height: 6,
        borderRadius: "50%",
        background: "var(--growth-delta)"
      }
    }), " Changes pending"), /*#__PURE__*/React.createElement(FooterButton, {
      icon: "settings",
      label: "Settings"
    })));
  }
  function Scene() {
    return /*#__PURE__*/React.createElement("div", {
      style: {
        minHeight: 640,
        display: "flex",
        flexDirection: "column"
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        flex: "none",
        height: 28,
        background: "rgba(20,22,26,0.55)",
        display: "flex",
        alignItems: "center",
        justifyContent: "flex-end",
        gap: 16,
        padding: "0 16px",
        borderBottom: "0.5px solid rgba(255,255,255,0.10)"
      }
    }, /*#__PURE__*/React.createElement("span", {
      style: {
        display: "inline-flex",
        alignItems: "center",
        gap: 5,
        fontFamily: "var(--font-mono)",
        fontSize: 11,
        fontWeight: 600,
        color: "var(--growth-delta)"
      }
    }, /*#__PURE__*/React.createElement("img", {
      src: "../../assets/prunr-icon-128.png",
      alt: "Prunr",
      style: {
        width: 17,
        height: 17,
        borderRadius: 4
      }
    }), " +15.1 GB"), /*#__PURE__*/React.createElement(Icon, {
      name: "wifi",
      size: 15,
      color: "rgba(255,255,255,0.85)"
    }), /*#__PURE__*/React.createElement(Icon, {
      name: "battery-full",
      size: 17,
      color: "rgba(255,255,255,0.85)"
    }), /*#__PURE__*/React.createElement("span", {
      style: {
        fontSize: 12,
        color: "rgba(255,255,255,0.9)",
        fontWeight: 500
      }
    }, "Fri 09:41")), /*#__PURE__*/React.createElement("div", {
      style: {
        flex: 1,
        display: "flex",
        justifyContent: "flex-end",
        alignItems: "flex-start",
        padding: "10px 14px 40px"
      }
    }, /*#__PURE__*/React.createElement(Popover, null)));
  }
  window.PrunrUI = {
    Scene,
    Popover
  };
})();
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/macos-app/app-screens.jsx", error: String((e && e.message) || e) }); }

// ui_kits/website/site-sections.jsx
try { (() => {
// Prunr — one-page alpha landing (fullscreen, no scroll). Clean + minimal.
// Composes DS primitives from window.PrunrDesignSystem_225e08 → window.PrunrSite.
(function () {
  const DS = window.PrunrDesignSystem_225e08;
  const {
    Button,
    Icon
  } = DS;
  function Wordmark({
    size = 26
  }) {
    return /*#__PURE__*/React.createElement("span", {
      style: {
        display: "inline-flex",
        alignItems: "center",
        gap: 9
      }
    }, /*#__PURE__*/React.createElement("img", {
      src: "../../assets/prunr-icon-128.png",
      alt: "Prunr",
      style: {
        width: size,
        height: size,
        borderRadius: size * 0.225
      }
    }), /*#__PURE__*/React.createElement("span", {
      style: {
        fontFamily: "var(--font-heading)",
        fontWeight: 700,
        fontSize: size * 0.8,
        letterSpacing: "var(--tracking-heading)",
        color: "var(--heading-color)"
      }
    }, "Prunr"));
  }
  function Nav() {
    return /*#__PURE__*/React.createElement("header", {
      style: {
        flex: "none",
        display: "flex",
        alignItems: "center",
        justifyContent: "space-between",
        padding: "20px 30px"
      }
    }, /*#__PURE__*/React.createElement(Wordmark, null), /*#__PURE__*/React.createElement("a", {
      href: "https://github.com/merlinkraemer/prunr",
      target: "_blank",
      rel: "noreferrer",
      style: {
        display: "inline-flex",
        alignItems: "center",
        gap: 7,
        fontFamily: "var(--font-body)",
        fontWeight: 600,
        fontSize: 14,
        color: "var(--muted-color)",
        textDecoration: "none"
      }
    }, /*#__PURE__*/React.createElement(Icon, {
      name: "github",
      size: 16
    }), " Source"));
  }
  function Signup() {
    const [focus, setFocus] = React.useState(false);
    return /*#__PURE__*/React.createElement("form", {
      style: {
        marginTop: 32,
        maxWidth: 440
      },
      onSubmit: e => e.preventDefault()
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        alignItems: "center",
        gap: 10,
        background: "var(--card)",
        borderRadius: "var(--radius-pill)",
        padding: "6px 6px 6px 18px",
        transition: "box-shadow var(--dur-fast) var(--ease)",
        boxShadow: focus ? "var(--shadow-hairline), var(--shadow-soft), var(--focus-ring)" : "var(--shadow-hairline), var(--shadow-soft)"
      }
    }, /*#__PURE__*/React.createElement(Icon, {
      name: "mail",
      size: 17,
      color: "var(--muted-color)"
    }), /*#__PURE__*/React.createElement("input", {
      type: "email",
      placeholder: "you@example.com",
      onFocus: () => setFocus(true),
      onBlur: () => setFocus(false),
      style: {
        flex: 1,
        minWidth: 0,
        border: "none",
        outline: "none",
        background: "transparent",
        fontFamily: "var(--font-body)",
        fontWeight: 500,
        fontSize: 15,
        color: "var(--body-color)"
      }
    }), /*#__PURE__*/React.createElement(Button, {
      variant: "primary",
      size: "md",
      style: {
        flex: "none"
      }
    }, "Join the alpha")), /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        alignItems: "center",
        gap: 8,
        marginTop: 13,
        paddingLeft: 4,
        fontFamily: "var(--font-body)",
        fontSize: 13,
        fontWeight: 500,
        color: "var(--muted-color)"
      }
    }, /*#__PURE__*/React.createElement("span", {
      style: {
        width: 7,
        height: 7,
        borderRadius: "50%",
        background: "var(--theme-accent)",
        flex: "none"
      }
    }), "Free during the alpha \xB7 no spam, just a download link."));
  }
  function Hero() {
    return /*#__PURE__*/React.createElement("main", {
      style: {
        flex: 1,
        minHeight: 0,
        display: "grid",
        gridTemplateColumns: "1.06fr 0.94fr",
        alignItems: "center",
        gap: 52,
        maxWidth: 1180,
        width: "100%",
        margin: "0 auto",
        padding: "0 40px 40px"
      },
      className: "hero-grid"
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        maxWidth: 560
      }
    }, /*#__PURE__*/React.createElement("h1", {
      style: {
        fontFamily: "var(--font-heading)",
        fontWeight: 700,
        fontSize: "clamp(40px, 4.6vw, 60px)",
        lineHeight: 1.05,
        letterSpacing: "var(--tracking-heading)",
        color: "var(--heading-color)",
        margin: 0,
        textWrap: "balance"
      }
    }, "See what\u2019s ", /*#__PURE__*/React.createElement("span", {
      style: {
        whiteSpace: "nowrap"
      }
    }, "growing \uD83C\uDF31"), " on disk."), /*#__PURE__*/React.createElement("p", {
      style: {
        fontFamily: "var(--font-heading)",
        fontWeight: 600,
        fontSize: "clamp(19px, 1.9vw, 25px)",
        lineHeight: 1.34,
        letterSpacing: "var(--tracking-tight)",
        color: "var(--body-color)",
        margin: "20px 0 0",
        maxWidth: 500
      }
    }, "Build caches, ", /*#__PURE__*/React.createElement("code", {
      style: {
        fontFamily: "var(--font-mono)",
        fontSize: "0.8em",
        fontWeight: 600
      }
    }, "node_modules"), " ", /*#__PURE__*/React.createElement("span", {
      style: {
        whiteSpace: "nowrap"
      }
    }, "\uD83D\uDCE6 and"), " old downloads ", /*#__PURE__*/React.createElement("span", {
      style: {
        whiteSpace: "nowrap"
      }
    }, "\u2B07\uFE0F pile"), " up fast. Prunr ", /*#__PURE__*/React.createElement("span", {
      style: {
        whiteSpace: "nowrap"
      }
    }, "\uD83C\uDF43 lives"), " in your menu bar and catches them before your SSD is full."), /*#__PURE__*/React.createElement(Signup, null)), /*#__PURE__*/React.createElement("div", {
      style: {
        position: "relative",
        display: "flex",
        justifyContent: "center",
        alignItems: "center",
        minWidth: 0
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        position: "absolute",
        width: "78%",
        height: "72%",
        borderRadius: "44%",
        filter: "blur(54px)",
        opacity: 0.6,
        background: "conic-gradient(from 210deg, var(--tint-rose), var(--tint-amber), var(--tint-leaf), var(--tint-blue), var(--tint-lavender), var(--tint-rose))"
      }
    }), /*#__PURE__*/React.createElement("div", {
      style: {
        position: "relative",
        background: "#0c0d10",
        borderRadius: 26,
        padding: 14,
        boxShadow: "0 34px 80px rgba(0,0,0,0.38), inset 0 0 0 1px rgba(255,255,255,0.06)"
      }
    }, /*#__PURE__*/React.createElement("img", {
      src: "../../assets/app-popover-black.png",
      alt: "Prunr menu-bar popover",
      style: {
        display: "block",
        maxHeight: "60vh",
        maxWidth: "100%",
        width: "auto",
        borderRadius: 14
      }
    }))));
  }
  function Page() {
    return /*#__PURE__*/React.createElement("div", {
      style: {
        height: "100vh",
        display: "flex",
        flexDirection: "column",
        overflow: "hidden"
      }
    }, /*#__PURE__*/React.createElement(Nav, null), /*#__PURE__*/React.createElement(Hero, null));
  }
  window.PrunrSite = {
    Page,
    Nav,
    Hero
  };
})();
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/website/site-sections.jsx", error: String((e && e.message) || e) }); }

__ds_ns.CategoryRow = __ds_scope.CategoryRow;

__ds_ns.DriveBar = __ds_scope.DriveBar;

__ds_ns.GrowthBadge = __ds_scope.GrowthBadge;

__ds_ns.Badge = __ds_scope.Badge;

__ds_ns.Button = __ds_scope.Button;

__ds_ns.Card = __ds_scope.Card;

__ds_ns.Icon = __ds_scope.Icon;

__ds_ns.IconButton = __ds_scope.IconButton;

__ds_ns.Input = __ds_scope.Input;

__ds_ns.Pill = __ds_scope.Pill;

__ds_ns.Switch = __ds_scope.Switch;

__ds_ns.Tabs = __ds_scope.Tabs;

})();
