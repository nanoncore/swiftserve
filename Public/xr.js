// SwiftServe — the fence yard, v4. The /on/visionos page as a place: five
// DISTRICTS of capabilities arranged around the user — each under a floating
// totem that names it, tints it, and (pinched) brings the whole district
// around to face you. The hero tells the story up front, the OS shelf runs
// beneath it, and the fence line with its compiler receipts stays at the
// rear — the whole yard spinnable by pinch-drag, because Apple's spatial HIG
// says people bring content to themselves; they don't walk or crane.
//
// Interaction model (visionOS natural input, WebKit transient-pointer):
//   · pinch + drag anywhere  → spin the yard (the target ray tracks the hand)
//   · look + pinch a totem   → focus that district: the yard turns to face
//     it, everything else recedes; pinch the totem again to release
//   · look + pinch (no drag) → open an in-scene detail panel, spawned facing
//     wherever the user is looking RIGHT NOW — never at a fixed spot
//   · leaving the scene is always explicit: an "Open ↗" chip on a panel, the
//     exit chip, or the crown
//
// Hand-written WebGL + WebXR, no framework, no build step. Loaded on demand
// by xr-entry.js after immersive-vr support is proven. The scene is built
// ENTIRELY from /api/on/visionos.json — nothing hand-counted.

"use strict";

// House palette — mirrors :root in styles.css (kept in sync by hand, like
// site.js mirrors PlatformDisplay.order).
const INK = "#2c2724";
const INK_SOFT = "#5b534c";
const MUTED = "#93897f";
const HAIRLINE = "#efe7db";
const SURFACE = "#ffffff";
const ACCENT = "#ed8b3e";
const ACCENT_DEEP = "#d9742a";
const GOOD = "#5fb37a";
const WARN = "#e0a23a";
const LOW = "#d76b4e";
const BUILTIN = "#1d1d1f";
const SKY = [0.9647, 0.9333, 0.8824];        // #f6eee1 — the warm void
const SANS = "-apple-system, 'SF Pro', 'Helvetica Neue', sans-serif";
const MONO = "ui-monospace, 'SF Mono', Menlo, monospace";

const GLYPH = { supported: "✓", conditional: "◐", unsupported: "✕", unknown: "?" };
const GLYPH_COLOR = { supported: GOOD, conditional: WARN, unsupported: LOW, unknown: MUTED };

// Column order + labels mirror PlatformDisplay in the generator.
const PLATFORMS = ["iOS", "macOS", "watchOS", "tvOS", "visionOS", "linux", "macCatalyst"];
const PLATFORM_LABEL = { linux: "Linux", macCatalyst: "Catalyst" };

// Drag feel: hand-angle → yard-angle gain, and the movement past which a
// pinch stops being a tap. ~1.7 lets a small wrist arc walk the whole fence.
const DRAG_GAIN = 1.7;
const TAP_THRESHOLD = 0.035;   // radians of ray travel

// ---------- districts ----------
// The five taxonomy domains, as places. Capability ids carry sub-prefixes
// (the audio domain namespaces media./midi./speech./video./voice.), so
// district membership is an explicit map — never a guess from the id alone.
// An unmapped prefix becomes its own district with the default look, so a
// future domain degrades to "present but plain", never to "missing".

const DISTRICT_META = {
  audio:      { label: "Audio & Media", hue: "#7a63c9", wash: "#f1edfa", icon: drawWaveIcon },
  networking: { label: "Networking",    hue: "#2f8f8f", wash: "#e7f4f4", icon: drawGlobeIcon },
  images:     { label: "Images",        hue: "#c2618c", wash: "#f9ecf2", icon: drawPhotoIcon },
  storage:    { label: "Storage",       hue: "#4a7fb5", wash: "#eaf1f8", icon: drawDbIcon },
  ui:         { label: "UI & Motion",   hue: "#7d9440", wash: "#f0f4e4", icon: drawSlidersIcon },
};
const DOMAIN_OF = {
  audio: "audio", media: "audio", midi: "audio", speech: "audio", video: "audio", voice: "audio",
  image: "images", network: "networking", storage: "storage", ui: "ui",
};

// Group the feed's capabilities into districts, largest first (ties by key,
// so the layout is deterministic for a given feed).
function districtsFrom(capabilities) {
  const byKey = new Map();
  for (const entry of capabilities) {
    const prefix = String(entry.id).split(".")[0];
    const key = DOMAIN_OF[prefix] || prefix;
    if (!byKey.has(key)) {
      const meta = DISTRICT_META[key]
        || { label: prefix, hue: INK_SOFT, wash: HAIRLINE, icon: drawGazeIcon };
      byKey.set(key, Object.assign({ key, entries: [] }, meta));
    }
    byKey.get(key).entries.push(entry);
  }
  return [...byKey.values()].sort((a, b) =>
    (b.entries.length - a.entries.length) || (a.key < b.key ? -1 : 1));
}

// Pack districts around the hero: each takes cols = ceil(n / maxRows)
// columns of arc, and goes to whichever side is currently lighter — biggest
// district first, so the yard balances. Returns centers in degrees
// (negative = left of the hero), aligned with the input order.
function layoutDistricts(districts, colStepDeg, gapDeg, wingGapDeg, maxRows) {
  const sides = { left: wingGapDeg, right: wingGapDeg };
  return districts.map((district) => {
    const cols = Math.max(1, Math.ceil(district.entries.length / maxRows));
    const width = cols * colStepDeg;
    const side = sides.left <= sides.right ? "left" : "right";
    const center = sides[side] + width / 2;
    sides[side] += width + gapDeg;
    return { key: district.key, cols, centerDeg: side === "left" ? -center : center };
  });
}

// ---------- tiny mat4 (column-major, straight into uniformMatrix4fv) ----------

function mul(a, b) {
  const out = new Float32Array(16);
  for (let c = 0; c < 4; c++) {
    for (let r = 0; r < 4; r++) {
      out[c * 4 + r] = a[r] * b[c * 4] + a[4 + r] * b[c * 4 + 1]
                     + a[8 + r] * b[c * 4 + 2] + a[12 + r] * b[c * 4 + 3];
    }
  }
  return out;
}

// Unit XY quad → world: scale (w,h), yaw around Y, then translate. yaw = -φ
// makes a quad on the circle at angle φ face the center (where the user is).
function modelMatrix(x, y, z, yaw, w, h) {
  const c = Math.cos(yaw), s = Math.sin(yaw);
  return new Float32Array([
    w * c, 0, -w * s, 0,
    0, h, 0, 0,
    s, 0, c, 0,
    x, y, z, 1,
  ]);
}

function rotY(angle) {
  const c = Math.cos(angle), s = Math.sin(angle);
  return new Float32Array([
    c, 0, -s, 0,
    0, 1, 0, 0,
    s, 0, c, 0,
    0, 0, 0, 1,
  ]);
}

// The ground disc: unit quad rotated flat (local +Y becomes world -Z).
function groundMatrix(radius, y) {
  const d = radius * 2;
  return new Float32Array([
    d, 0, 0, 0,
    0, 0, -d, 0,
    0, 1, 0, 0,
    0, y, 0, 1,
  ]);
}

function wrapAngle(a) {
  while (a > Math.PI) a -= 2 * Math.PI;
  while (a < -Math.PI) a += 2 * Math.PI;
  return a;
}

// Where on the yard circle a direction points: pos = (r sinφ, y, -r cosφ),
// so φ = atan2(x, -z).
function azimuthOf(dx, dz) {
  return Math.atan2(dx, -dz);
}

// ---------- canvas → texture text panels ----------

function makeCtx(w, h) {
  const canvas = document.createElement("canvas");
  canvas.width = w;
  canvas.height = h;
  return canvas.getContext("2d");
}

function roundRect(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}

// Greedy word wrap; long unbroken tokens (file paths in receipts) are
// hard-split so nothing escapes its panel.
function wrap(ctx, text, maxWidth, maxLines) {
  const words = String(text).split(/\s+/).filter(Boolean);
  const lines = [];
  let line = "";
  let truncated = false;
  for (let word of words) {
    while (ctx.measureText(word).width > maxWidth) {
      let cut = word.length;
      while (cut > 1 && ctx.measureText((line ? line + " " : "") + word.slice(0, cut)).width > maxWidth) cut--;
      lines.push((line ? line + " " : "") + word.slice(0, cut));
      line = "";
      word = word.slice(cut);
      if (lines.length >= maxLines) { truncated = true; break; }
    }
    if (truncated) break;
    const tryLine = line ? line + " " + word : word;
    if (ctx.measureText(tryLine).width > maxWidth && line) {
      lines.push(line);
      line = word;
      if (lines.length >= maxLines) { line = ""; truncated = true; break; }
    } else {
      line = tryLine;
    }
  }
  if (line && lines.length < maxLines) lines.push(line);
  if (truncated && lines.length) {
    lines[lines.length - 1] = lines[lines.length - 1].replace(/.$/, "") + "…";
  }
  return lines.slice(0, maxLines);
}

function cardBase(ctx, dashed, fill) {
  const { width, height } = ctx.canvas;
  ctx.clearRect(0, 0, width, height);
  roundRect(ctx, 5, 5, width - 10, height - 10, Math.min(44, height / 5));
  ctx.fillStyle = fill || SURFACE;
  ctx.fill();
  ctx.lineWidth = 4;
  if (dashed) ctx.setLineDash([18, 13]);
  ctx.strokeStyle = dashed ? MUTED : HAIRLINE;
  ctx.stroke();
  ctx.setLineDash([]);
}

// The compiler's message without its preamble — planks show the punchline,
// the detail panel shows the whole receipt.
function errorCore(receipt) {
  const afterPrefix = String(receipt).replace(/^does not compile[^:]*:\s*/, "");
  return afterPrefix.split(" — ")[0];
}

// ---------- panel painters ----------

// A round accent badge with a hand-drawn line icon — gesture hints need to
// catch the eye, not read as body text.
function iconBadge(ctx, cx, cy, r, draw) {
  ctx.save();
  ctx.beginPath();
  ctx.arc(cx, cy, r, 0, Math.PI * 2);
  ctx.fillStyle = "#fdf2e6";   // --accent-wash
  ctx.fill();
  ctx.strokeStyle = ACCENT_DEEP;
  ctx.fillStyle = ACCENT_DEEP;
  ctx.lineWidth = 9;
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  draw(ctx, cx, cy, r);
  ctx.restore();
}

function drawSpinIcon(ctx, cx, cy, r) {
  const a = r * 0.52;
  ctx.beginPath();
  ctx.arc(cx, cy, a, -Math.PI * 0.7, Math.PI * 0.75);
  ctx.stroke();
  // Arrowhead at the arc's end.
  const ex = cx + a * Math.cos(Math.PI * 0.75), ey = cy + a * Math.sin(Math.PI * 0.75);
  ctx.beginPath();
  ctx.moveTo(ex - 22, ey - 4);
  ctx.lineTo(ex, ey);
  ctx.lineTo(ex + 4, ey - 26);
  ctx.stroke();
}

function drawGazeIcon(ctx, cx, cy, r) {
  ctx.beginPath();
  ctx.arc(cx, cy, r * 0.5, 0, Math.PI * 2);
  ctx.stroke();
  ctx.beginPath();
  ctx.arc(cx, cy, r * 0.14, 0, Math.PI * 2);
  ctx.fill();
}

function drawCrownIcon(ctx, cx, cy, r) {
  // The Digital Crown: a disc with its winder on the side.
  ctx.beginPath();
  ctx.arc(cx - r * 0.08, cy, r * 0.42, 0, Math.PI * 2);
  ctx.stroke();
  const wx = cx + r * 0.42;
  ctx.beginPath();
  ctx.moveTo(wx, cy - r * 0.2);
  ctx.lineTo(wx + r * 0.22, cy - r * 0.2);
  ctx.lineTo(wx + r * 0.22, cy + r * 0.2);
  ctx.lineTo(wx, cy + r * 0.2);
  ctx.closePath();
  ctx.stroke();
}

function drawTotemIcon(ctx, cx, cy, r) {
  // A pennant on its pole — the district totem, in miniature.
  const px = cx - r * 0.3;
  ctx.beginPath();
  ctx.moveTo(px, cy - r * 0.52);
  ctx.lineTo(px, cy + r * 0.52);
  ctx.stroke();
  ctx.beginPath();
  ctx.moveTo(px, cy - r * 0.5);
  ctx.lineTo(px + r * 0.72, cy - r * 0.22);
  ctx.lineTo(px, cy + r * 0.06);
  ctx.closePath();
  ctx.fill();
}

// District icons — one stroke drawing each, in the district's hue.
function drawWaveIcon(ctx, cx, cy, r) {
  const heights = [0.34, 0.62, 0.94, 0.5, 0.72];
  heights.forEach((h, i) => {
    const x = cx + (i - 2) * r * 0.34;
    ctx.beginPath();
    ctx.moveTo(x, cy - r * h * 0.5);
    ctx.lineTo(x, cy + r * h * 0.5);
    ctx.stroke();
  });
}

function drawGlobeIcon(ctx, cx, cy, r) {
  const a = r * 0.52;
  ctx.beginPath();
  ctx.arc(cx, cy, a, 0, Math.PI * 2);
  ctx.stroke();
  ctx.beginPath();
  ctx.ellipse(cx, cy, a, a * 0.42, 0, 0, Math.PI * 2);
  ctx.stroke();
  ctx.beginPath();
  ctx.moveTo(cx, cy - a);
  ctx.lineTo(cx, cy + a);
  ctx.stroke();
}

function drawPhotoIcon(ctx, cx, cy, r) {
  const w = r * 1.1, h = r * 0.86;
  roundRect(ctx, cx - w / 2, cy - h / 2, w, h, r * 0.14);
  ctx.stroke();
  ctx.beginPath();
  ctx.moveTo(cx - w * 0.36, cy + h * 0.3);
  ctx.lineTo(cx - w * 0.08, cy - h * 0.1);
  ctx.lineTo(cx + w * 0.14, cy + h * 0.14);
  ctx.lineTo(cx + w * 0.3, cy - h * 0.04);
  ctx.stroke();
  ctx.beginPath();
  ctx.arc(cx - w * 0.16, cy - h * 0.22, r * 0.09, 0, Math.PI * 2);
  ctx.fill();
}

function drawDbIcon(ctx, cx, cy, r) {
  const w = r * 0.92, h = r * 1.0, e = r * 0.2;
  ctx.beginPath();
  ctx.ellipse(cx, cy - h / 2 + e, w / 2, e, 0, 0, Math.PI * 2);
  ctx.stroke();
  for (const dy of [0.5, 1]) {
    ctx.beginPath();
    ctx.ellipse(cx, cy - h / 2 + e + (h - e * 2) * dy, w / 2, e, 0, 0, Math.PI);
    ctx.stroke();
  }
  ctx.beginPath();
  ctx.moveTo(cx - w / 2, cy - h / 2 + e);
  ctx.lineTo(cx - w / 2, cy + h / 2 - e);
  ctx.moveTo(cx + w / 2, cy - h / 2 + e);
  ctx.lineTo(cx + w / 2, cy + h / 2 - e);
  ctx.stroke();
}

function drawSlidersIcon(ctx, cx, cy, r) {
  const knobs = [-0.2, 0.28, -0.02];
  knobs.forEach((k, i) => {
    const y = cy + (i - 1) * r * 0.42;
    ctx.beginPath();
    ctx.moveTo(cx - r * 0.55, y);
    ctx.lineTo(cx + r * 0.55, y);
    ctx.stroke();
    ctx.beginPath();
    ctx.arc(cx + k * r, y, r * 0.13, 0, Math.PI * 2);
    ctx.fill();
  });
}

// The district totem: its flag, floating above the wall — icon, name, count,
// and the one gesture it answers to.
function paintTotem(district) {
  const ctx = makeCtx(880, 480);
  cardBase(ctx);
  ctx.save();
  ctx.beginPath();
  ctx.arc(150, 240, 96, 0, Math.PI * 2);
  ctx.fillStyle = district.wash;
  ctx.fill();
  ctx.strokeStyle = district.hue;
  ctx.fillStyle = district.hue;
  ctx.lineWidth = 13;
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  district.icon(ctx, 150, 240, 96);
  ctx.restore();

  ctx.fillStyle = INK;
  ctx.font = "700 84px " + SANS;
  ctx.fillText(district.label, 300, 216);
  ctx.fillStyle = district.hue;
  ctx.font = "600 52px " + SANS;
  ctx.fillText(district.entries.length + " capabilities", 300, 306);
  ctx.fillStyle = MUTED;
  ctx.font = "500 42px " + SANS;
  ctx.fillText("pinch to bring it to you", 300, 384);
  return ctx.canvas;
}

function paintHero(stats) {
  const ctx = makeCtx(1900, 1000);
  cardBase(ctx);
  ctx.fillStyle = INK;
  ctx.font = "700 122px " + SANS;
  ctx.fillText("The state of visionOS", 90, 184);

  ctx.font = "600 72px " + SANS;
  const parts = [
    [stats.supported + " serve it", GOOD],
    ["   ", MUTED],
    [stats.unsupported + " fenced out", LOW],
    ["   ", MUTED],
    [stats.unknown + " unknown", MUTED],
  ];
  let x = 90;
  for (const [text, color] of parts) {
    ctx.fillStyle = color;
    ctx.fillText(text, x, 316);
    x += ctx.measureText(text).width;
  }

  const guide = [
    ["✓", GOOD, "Five districts around you — every capability, grouped by what it's for."],
    ["", INK_SOFT, "The dark shelf below — what the OS covers before any dependency."],
    ["✕", LOW, "The fence, around back — packages that don't compile, receipts nailed on."],
  ];
  guide.forEach(([glyph, color, text], i) => {
    ctx.fillStyle = color;
    ctx.font = "700 48px " + SANS;
    ctx.fillText(glyph, 90, 436 + i * 78);
    ctx.fillStyle = INK_SOFT;
    ctx.font = "500 48px " + SANS;
    ctx.fillText(text, 164, 436 + i * 78);
  });

  // Gesture hints, badged so they read as controls, not copy.
  const hints = [
    [drawTotemIcon, "Pinch a totem — bring that district to you"],
    [drawSpinIcon, "Pinch & drag — spin the yard"],
    [drawGazeIcon, "Look + pinch — open it right here"],
    [drawCrownIcon, "Crown — back to Safari"],
  ];
  hints.forEach(([icon, text], i) => {
    const y = 712 + i * 84;
    iconBadge(ctx, 132, y, 38, icon);
    ctx.fillStyle = i === 3 ? MUTED : ACCENT_DEEP;
    ctx.font = "600 52px " + SANS;
    ctx.fillText(text, 198, y + 18);
  });
  return ctx.canvas;
}

function paintCapabilityCard(entry, district) {
  const ctx = makeCtx(704, 416);
  cardBase(ctx);
  // A whisper of the district hue over the glass — enough that peripheral
  // vision groups the wall before any label is read.
  ctx.save();
  ctx.globalAlpha = 0.05;
  roundRect(ctx, 7, 7, 690, 402, 42);
  ctx.fillStyle = district.hue;
  ctx.fill();
  ctx.restore();

  ctx.fillStyle = district.hue;
  ctx.font = "600 36px " + SANS;
  ctx.fillText(entry.id.split(".")[0].toUpperCase(), 50, 84);

  ctx.fillStyle = INK;
  ctx.font = "600 62px " + SANS;
  wrap(ctx, entry.label, 604, 2).forEach((line, i) => ctx.fillText(line, 50, 168 + i * 72));

  ctx.font = "600 48px " + SANS;
  let count;
  if (entry.packages === 0) {
    ctx.fillStyle = INK_SOFT;
    count = " built into the OS";
  } else if (entry.supported > 0) {
    ctx.fillStyle = GOOD;
    count = entry.supported + " of " + entry.packages + " serve it";
  } else {
    ctx.fillStyle = MUTED;
    count = "0 of " + entry.packages + " serve it";
  }
  ctx.fillText(count, 50, 344);
  if (entry.builtInCovers && entry.packages > 0) {
    // The  glyph is private-use and tofus off Apple devices — but this
    // scene only ever runs on one.
    ctx.fillStyle = INK_SOFT;
    ctx.fillText("  ·  ", 50 + ctx.measureText(count).width, 344);
  }

  // Support density, as a bar you can read across the whole wall at once —
  // how much of this capability's package roster proves out here.
  if (entry.packages > 0) {
    roundRect(ctx, 50, 372, 604, 16, 8);
    ctx.fillStyle = HAIRLINE;
    ctx.fill();
    const share = Math.max(0, Math.min(1, entry.supported / entry.packages));
    if (share > 0) {
      roundRect(ctx, 50, 372, Math.max(24, 604 * share), 16, 8);
      ctx.fillStyle = GOOD;
      ctx.fill();
    }
  }
  return ctx.canvas;
}

function paintPlaque(framework) {
  const ctx = makeCtx(704, 416);
  cardBase(ctx, false, BUILTIN);
  ctx.fillStyle = "#f5f5f7";
  ctx.font = "600 64px " + SANS;
  ctx.fillText(" " + framework.name, 50, 110);
  ctx.fillStyle = "#a1a1a6";
  ctx.font = "500 42px " + SANS;
  const caps = framework.capabilities.length;
  ctx.fillText(caps + " capabilit" + (caps === 1 ? "y" : "ies") + " · " + framework.version, 50, 186);
  ctx.font = "500 40px " + SANS;
  wrap(ctx, framework.capabilities.map((c) => c.label).join(" · "), 604, 4)
    .forEach((line, i) => ctx.fillText(line, 50, 258 + i * 52));
  return ctx.canvas;
}

function paintPlank(plank) {
  const ctx = makeCtx(416, 1600);
  cardBase(ctx);
  ctx.fillStyle = LOW;
  ctx.font = "700 52px " + SANS;
  wrap(ctx, plank.name, 328, 3).forEach((line, i) => ctx.fillText(line, 44, 104 + i * 60));

  ctx.fillStyle = INK_SOFT;
  ctx.font = "600 38px " + SANS;
  const capNames = plank.fences.map((f) => f.capabilityLabel).join(" · ");
  wrap(ctx, capNames, 328, 3).forEach((line, i) => ctx.fillText(line, 44, 300 + i * 48));

  ctx.strokeStyle = HAIRLINE;
  ctx.lineWidth = 4;
  ctx.beginPath();
  ctx.moveTo(44, 470);
  ctx.lineTo(372, 470);
  ctx.stroke();

  ctx.fillStyle = INK;
  ctx.font = "36px " + MONO;
  wrap(ctx, errorCore(plank.fences[0].receipt), 328, 14)
    .forEach((line, i) => ctx.fillText(line, 44, 540 + i * 50));

  if (plank.worksOn.length) {
    ctx.fillStyle = GOOD;
    ctx.font = "600 36px " + SANS;
    wrap(ctx, "✓ " + plank.worksOn.join(" · "), 328, 2)
      .forEach((line, i) => ctx.fillText(line, 44, 1380 + i * 44));
  }
  ctx.fillStyle = ACCENT_DEEP;
  ctx.font = "600 34px " + SANS;
  ctx.fillText("pinch for the receipt" + (plank.fences.length > 1 ? "s" : ""), 44, 1510);
  return ctx.canvas;
}

function paintGhostCard(unknown) {
  const ctx = makeCtx(512, 480);
  cardBase(ctx, true);
  ctx.fillStyle = MUTED;
  ctx.font = "700 96px " + SANS;
  ctx.fillText("?", 46, 130);
  ctx.fillStyle = INK_SOFT;
  ctx.font = "700 44px " + SANS;
  wrap(ctx, unknown.name, 412, 2).forEach((line, i) => ctx.fillText(line, 46, 220 + i * 52));
  ctx.font = "500 36px " + SANS;
  ctx.fillStyle = MUTED;
  wrap(ctx, unknown.capabilityLabel, 412, 2).forEach((line, i) => ctx.fillText(line, 46, 348 + i * 44));
  return ctx.canvas;
}

// Detail panels: one shape, four fillings. 1408×1216 canvas → 1.1 × 0.95 m
// at arm-and-a-bit length; rows auto-truncate with an honest "more" note.
function paintPanel(detail) {
  const ctx = makeCtx(1408, 1216);
  cardBase(ctx);
  ctx.fillStyle = detail.tone === "low" ? LOW : detail.tone === "dark" ? BUILTIN : INK;
  ctx.font = "700 68px " + SANS;
  wrap(ctx, detail.title, 1280, 2).forEach((line, i) => ctx.fillText(line, 64, 128 + i * 80));

  ctx.fillStyle = MUTED;
  ctx.font = "600 44px " + SANS;
  ctx.fillText(detail.sub, 64, 286);

  ctx.strokeStyle = HAIRLINE;
  ctx.lineWidth = 4;
  ctx.beginPath();
  ctx.moveTo(64, 330);
  ctx.lineTo(1344, 330);
  ctx.stroke();

  let y = 410;
  for (const row of detail.rows) {
    if (y > 1100) {
      ctx.fillStyle = MUTED;
      ctx.font = "500 42px " + SANS;
      ctx.fillText("… more — pinch Open ↗", 64, y);
      break;
    }
    if (row.glyph) {
      ctx.fillStyle = row.glyphColor || INK_SOFT;
      ctx.font = "700 44px " + SANS;
      ctx.fillText(row.glyph, 64, y);
    }
    ctx.fillStyle = row.color || INK;
    ctx.font = (row.mono ? "38px " + MONO : "500 44px " + SANS);
    const lines = wrap(ctx, row.text, row.glyph ? 1180 : 1280, row.maxLines || 2);
    lines.forEach((line, i) => ctx.fillText(line, row.glyph ? 140 : 64, y + i * (row.mono ? 52 : 54)));
    y += lines.length * (row.mono ? 52 : 54) + (row.gap != null ? row.gap : 14);
  }
  return ctx.canvas;
}

// Chips size themselves to their label — a fixed canvas stretched into a
// differently-proportioned quad is exactly how buttons get mangled.
const CHIP_H = 160;                       // canvas px
const CHIP_SCALE = 0.115 / CHIP_H;        // metres per canvas px (chip is 0.115 m tall)

function paintChip(label, accent) {
  const measure = makeCtx(8, 8);
  measure.font = "600 58px " + SANS;
  const width = Math.ceil(measure.measureText(label).width) + 140;
  const ctx = makeCtx(width, CHIP_H);
  roundRect(ctx, 5, 5, width - 10, CHIP_H - 10, (CHIP_H - 10) / 2);
  ctx.fillStyle = accent ? ACCENT : SURFACE;
  ctx.fill();
  if (!accent) {
    ctx.lineWidth = 4;
    ctx.strokeStyle = HAIRLINE;
    ctx.stroke();
  }
  ctx.fillStyle = accent ? "#ffffff" : INK;
  ctx.font = "600 58px " + SANS;
  ctx.textAlign = "center";
  ctx.fillText(label, width / 2, 100);
  return ctx.canvas;
}

function paintGround() {
  const ctx = makeCtx(512, 512);
  const gradient = ctx.createRadialGradient(256, 256, 40, 256, 256, 256);
  gradient.addColorStop(0, "#f3ebde");
  gradient.addColorStop(0.8, "#ece2d2");
  gradient.addColorStop(1, "rgba(236, 226, 210, 0)");   // soft edge into the void
  ctx.fillStyle = gradient;
  ctx.beginPath();
  ctx.arc(256, 256, 256, 0, Math.PI * 2);
  ctx.fill();
  return ctx.canvas;
}

function paintRail() {
  const ctx = makeCtx(8, 8);
  ctx.fillStyle = "#e4d9c8";
  ctx.fillRect(0, 0, 8, 8);
  return ctx.canvas;
}

// ---------- WebGL plumbing ----------

const VS = `
attribute vec2 aPos;
attribute vec2 aUV;
uniform mat4 uMVP;
varying vec2 vUV;
void main() {
  vUV = aUV;
  gl_Position = uMVP * vec4(aPos, 0.0, 1.0);
}`;

const FS = `
precision mediump float;
uniform sampler2D uTex;
uniform float uOpacity;
varying vec2 vUV;
void main() {
  vec4 color = texture2D(uTex, vUV) * uOpacity;
  if (color.a < 0.01) discard;
  gl_FragColor = color;
}`;

function compile(gl, type, source) {
  const shader = gl.createShader(type);
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    throw new Error(gl.getShaderInfoLog(shader) || "shader compile failed");
  }
  return shader;
}

function setupGL(gl) {
  const program = gl.createProgram();
  gl.attachShader(program, compile(gl, gl.VERTEX_SHADER, VS));
  gl.attachShader(program, compile(gl, gl.FRAGMENT_SHADER, FS));
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
    throw new Error(gl.getProgramInfoLog(program) || "program link failed");
  }
  const buffer = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([
    -0.5, -0.5, 0, 1,
     0.5, -0.5, 1, 1,
    -0.5,  0.5, 0, 0,
     0.5,  0.5, 1, 0,
  ]), gl.STATIC_DRAW);
  return {
    program,
    buffer,
    aPos: gl.getAttribLocation(program, "aPos"),
    aUV: gl.getAttribLocation(program, "aUV"),
    uMVP: gl.getUniformLocation(program, "uMVP"),
    uTex: gl.getUniformLocation(program, "uTex"),
    uOpacity: gl.getUniformLocation(program, "uOpacity"),
  };
}

function texFromCanvas(gl, canvas, isWebGL2) {
  const texture = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, texture);
  gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, true);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, canvas);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  if (isWebGL2) {
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
    gl.generateMipmap(gl.TEXTURE_2D);
  } else {
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  }
  return texture;
}

// ---------- scene assembly ----------

function quad(gl, isWebGL2, canvas, x, y, z, yaw, w, h, opts) {
  return Object.assign({
    tex: texFromCanvas(gl, canvas, isWebGL2),
    model: modelMatrix(x, y, z, yaw, w, h),
    x, y, z, yaw, w, h,
    opacity: 1,
    pulseAt: 0,
  }, opts);
}

// The yard: everything positioned on circles around the user, in yard space —
// the global spin rotates it as one piece. Angles in degrees for sanity.
function buildYard(gl, isWebGL2, feed, yOff) {
  const quads = [];
  const deg = Math.PI / 180;
  const at = (r, phiDeg, y) => [r * Math.sin(phiDeg * deg), y + yOff, -r * Math.cos(phiDeg * deg), -phiDeg * deg];
  const place = (canvas, r, phiDeg, y, w, h, opts) => {
    const [x, py, z, yaw] = [...at(r, phiDeg, y)];
    quads.push(quad(gl, isWebGL2, canvas, x, py, z, yaw, w, h, opts));
  };

  quads.push({
    tex: texFromCanvas(gl, paintGround(), isWebGL2),
    model: groundMatrix(8, yOff + 0.002),
    x: 0, y: yOff, z: 0, yaw: 0, w: 16, h: 16, opacity: 1, pulseAt: 0, noPick: true,
  });

  // Hero — front and center, slightly below eye line per the HIG.
  place(paintHero(feed.stats), 3.0, 0, 1.5, 1.9, 1.0, { noPick: true });

  // The districts: each domain's capabilities as a block of columns under
  // its totem, packed left/right of the hero so the yard balances. Cards
  // fill top-to-bottom, column by column, so a district reads as one shape.
  const cardW = 0.38, cardH = 0.235, cardR = 2.6;
  const colStep = 9.9, districtGap = 6, wingGap = 25, maxRows = 5;
  const rowY = (row) => 2.06 - row * 0.29;
  const districts = districtsFrom(feed.capabilities);
  const centers = layoutDistricts(districts, colStep, districtGap, wingGap, maxRows);
  districts.forEach((district, d) => {
    const { cols, centerDeg } = centers[d];
    const n = district.entries.length;
    const rows = Math.ceil(n / cols);
    place(paintTotem(district), cardR, centerDeg, 2.44, 0.55, 0.30,
      { district: district.key, action: { type: "district", key: district.key, centerDeg } });
    district.entries.forEach((entry, i) => {
      const row = Math.floor(i / cols);
      const inRow = Math.min(cols, n - row * cols);
      const col = (i % cols) + (cols - inRow) / 2;
      const phi = centerDeg + (col - (cols - 1) / 2) * colStep;
      place(paintCapabilityCard(entry, district), cardR, phi, rowY(Math.min(row, rows - 1)),
        cardW, cardH, { district: district.key, action: { type: "capability", entry } });
    });
  });

  // The OS shelf: dark plaques under the hero — "before you add a
  // dependency" at a glance.
  feed.builtIn.forEach((framework, i) => {
    place(paintPlaque(framework), 2.35, (i - (feed.builtIn.length - 1) / 2) * 11.5, 0.62,
      0.46, 0.27, { action: { type: "plaque", framework } });
  });

  // The fence: one plank per fenced package, receipts nailed on, around the
  // back — spin the yard to walk it. The step tightens as the fence grows so
  // it never eats into the districts' arc.
  const planks = feed.fenced.map((pkg) => ({
    name: pkg.name, slug: pkg.slug, version: pkg.version,
    fences: pkg.fences,
    worksOn: pkg.fences[0] ? pkg.fences[0].worksOn : [],
  }));
  const plankStep = Math.min(5.6, 112 / Math.max(1, planks.length));
  const plankPhi = (i) => 180 + (i - (planks.length - 1) / 2) * plankStep;
  planks.forEach((plank, i) => {
    place(paintPlank(plank), 3.0, plankPhi(i), 1.02, 0.26, 1.0,
      { action: { type: "plank", plank } });
  });
  const railCanvas = paintRail();
  for (let i = 0; i + 1 < planks.length; i++) {
    for (const railY of [0.62, 1.32]) {
      place(railCanvas, 3.02, (plankPhi(i) + plankPhi(i + 1)) / 2, railY, 0.30, 0.035, { noPick: true });
    }
  }

  // The honest unknowns hover above the fence — unresolved, translucent,
  // never nailed down. Seven to a row now that there are more of them.
  feed.unknowns.forEach((unknown, i) => {
    const row = Math.floor(i / 7), col = i % 7;
    place(paintGhostCard(unknown), 3.0, 180 + (col - 3) * 6.2, 1.92 + row * 0.36,
      0.30, 0.28, { opacity: 0.6, baseOpacity: 0.6, action: { type: "ghost", unknown } });
  });

  return quads;
}

// ---------- detail panels (overlay, spawned facing the user) ----------

function detailFor(action) {
  if (action.type === "capability") {
    const entry = action.entry;
    const rows = [];
    for (const name of entry.builtInNames || []) {
      rows.push({ glyph: "", glyphColor: INK_SOFT, text: name + " — built into the OS", color: INK_SOFT });
    }
    for (const v of (entry.verdicts || []).slice(0, 8)) {
      rows.push({ glyph: GLYPH[v.status] || "?", glyphColor: GLYPH_COLOR[v.status] || MUTED, text: v.name });
    }
    if ((entry.verdicts || []).length > 8) {
      rows.push({ text: "+ " + (entry.verdicts.length - 8) + " more — pinch Open", color: MUTED });
    }
    return {
      title: entry.label,
      sub: entry.supported + " of " + entry.packages + " packages serve this on visionOS",
      rows,
      sheet: { kind: "capability", id: entry.id, title: entry.label, href: entry.truthTable },
    };
  }
  if (action.type === "plank") {
    const plank = action.plank;
    const rows = [];
    for (const fence of plank.fences.slice(0, 2)) {
      rows.push({ text: fence.capabilityLabel, color: LOW, gap: 4 });
      rows.push({ text: fence.receipt, mono: true, maxLines: 4 });
    }
    if (plank.fences.length > 2) {
      rows.push({ text: "+ " + (plank.fences.length - 2) + " more — pinch Open", color: MUTED });
    }
    if (plank.worksOn.length) {
      rows.push({ glyph: "✓", glyphColor: GOOD, text: "serves it on " + plank.worksOn.join(" · "), color: GOOD });
    }
    return {
      tone: "low",
      title: plank.name,
      sub: "proven off visionOS · as of " + plank.version,
      rows,
      sheet: { kind: "package", slug: plank.slug, title: plank.name, href: "/package/" + plank.slug + "/" },
    };
  }
  if (action.type === "ghost") {
    const unknown = action.unknown;
    return {
      title: unknown.name + " — " + unknown.capabilityLabel,
      sub: "honestly unknown — not verified yet, never guessed",
      rows: [
        { text: unknown.why || "no claim recorded for this platform yet", maxLines: 6 },
        { text: "When the toolchain or the extractor catches up, this gets a verdict.", color: MUTED, maxLines: 3 },
      ],
      sheet: { kind: "package", slug: unknown.slug, title: unknown.name, href: "/package/" + unknown.slug + "/" },
    };
  }
  // plaque
  const framework = action.framework;
  return {
    tone: "dark",
    title: " " + framework.name,
    sub: "ships with visionOS · " + framework.version,
    rows: framework.capabilities.map((c) => ({
      glyph: "✓", glyphColor: GOOD,
      text: c.label + (c.floor ? "  —  " + c.floor : ""),
    })),
    sheet: { kind: "package", slug: framework.slug, title: framework.name, href: "/package/" + framework.slug + "/" },
  };
}

// ---------- the sub-page window (native-feeling, distinct from the modal) ----------
// A visionOS-style window: glass surface, soft shadow, a real header, the
// truth table as a grid — and its controls DETACHED beneath it (round ✕ +
// a Safari pill), the way the system hangs a window bar under real windows.

const WINDOW_W = 2048, WINDOW_H = 1310;   // canvas px → 1.8 × 1.15 m quad
const WINDOW_INSET = 56;                  // canvas margin that holds the shadow

function windowBase(ctx, title, sub) {
  const { width, height } = ctx.canvas;
  ctx.clearRect(0, 0, width, height);
  ctx.save();
  ctx.shadowColor = "rgba(74, 52, 30, 0.30)";
  ctx.shadowBlur = 44;
  ctx.shadowOffsetY = 16;
  roundRect(ctx, WINDOW_INSET, WINDOW_INSET - 16, width - WINDOW_INSET * 2, height - WINDOW_INSET * 2 - 16, 64);
  ctx.fillStyle = "rgba(255, 255, 255, 0.90)";   // glass, not card
  ctx.fill();
  ctx.restore();

  ctx.fillStyle = INK;
  ctx.font = "700 88px " + SANS;
  wrap(ctx, title, width - 300, 1).forEach((line) => ctx.fillText(line, 130, 196));
  ctx.fillStyle = MUTED;
  ctx.font = "600 42px " + SANS;
  ctx.fillText(sub, 130, 272);
  ctx.strokeStyle = HAIRLINE;
  ctx.lineWidth = 4;
  ctx.beginPath();
  ctx.moveTo(130, 316);
  ctx.lineTo(width - 130, 316);
  ctx.stroke();
}

function paintWindowLoading(title) {
  const ctx = makeCtx(WINDOW_W, WINDOW_H);
  windowBase(ctx, title, "fetching the receipts…");
  return ctx.canvas;
}

// rows: [{ name, firstParty, cells: {platform → status|undefined} }]
function paintWindowSheet(title, sub, rows, note) {
  const ctx = makeCtx(WINDOW_W, WINDOW_H);
  windowBase(ctx, title, sub);
  const colX = (i) => 820 + i * 168;
  const topY = 380, rowH = 74, maxRows = 10;

  // The visionOS column wears the accent — this is, after all, its page.
  const visionIndex = PLATFORMS.indexOf("visionOS");
  roundRect(ctx, colX(visionIndex) - 76, topY - 60, 152, Math.min(rows.length, maxRows) * rowH + 96, 26);
  ctx.fillStyle = "#fdf2e6";   // --accent-wash
  ctx.fill();

  ctx.textAlign = "center";
  PLATFORMS.forEach((platform, i) => {
    ctx.fillStyle = i === visionIndex ? ACCENT_DEEP : MUTED;
    ctx.font = "600 34px " + SANS;
    ctx.fillText(PLATFORM_LABEL[platform] || platform, colX(i), topY - 14);
  });
  ctx.textAlign = "left";

  rows.slice(0, maxRows).forEach((row, r) => {
    const y = topY + 44 + r * rowH;
    if (r % 2 === 1) {
      ctx.fillStyle = "rgba(251, 247, 240, 0.75)";   // --surface-2 wash
      ctx.fillRect(120, y - 46, colX(0) - 200, 62);
    }
    ctx.fillStyle = INK;
    ctx.font = "600 42px " + SANS;
    ctx.fillText((row.firstParty ? " " : "") + wrap(ctx, row.name, 620, 1)[0], 130, y);
    ctx.textAlign = "center";
    PLATFORMS.forEach((platform, i) => {
      const status = row.cells[platform];
      ctx.fillStyle = GLYPH_COLOR[status] || MUTED;
      ctx.font = "700 46px " + SANS;
      ctx.fillText(status ? GLYPH[status] : "?", colX(i), y);
    });
    ctx.textAlign = "left";
  });

  ctx.fillStyle = MUTED;
  ctx.font = "500 36px " + SANS;
  const legend = "✓ serves it · ◐ with conditions · ✕ proven no · ? not verified"
    + (rows.length > maxRows ? "   ·   +" + (rows.length - maxRows) + " more in Safari" : "")
    + (note ? "   ·   " + note : "");
  ctx.fillText(legend, 130, WINDOW_H - 130);
  return ctx.canvas;
}

function paintCloseCircle() {
  const ctx = makeCtx(160, 160);
  ctx.beginPath();
  ctx.arc(80, 80, 72, 0, Math.PI * 2);
  ctx.fillStyle = SURFACE;
  ctx.fill();
  ctx.lineWidth = 4;
  ctx.strokeStyle = HAIRLINE;
  ctx.stroke();
  ctx.strokeStyle = INK;
  ctx.lineWidth = 10;
  ctx.lineCap = "round";
  ctx.beginPath();
  ctx.moveTo(56, 56); ctx.lineTo(104, 104);
  ctx.moveTo(104, 56); ctx.lineTo(56, 104);
  ctx.stroke();
  return ctx.canvas;
}

// Turn fetched JSON into window rows.
function windowRows(sheet, json) {
  if (sheet.kind === "capability") {
    return (json.packages || []).map((p) => {
      const cells = {};
      for (const platform of PLATFORMS) {
        cells[platform] = p.platforms && p.platforms[platform] && p.platforms[platform].status;
      }
      return { name: p.packageName, firstParty: String(p.package || "").indexOf("developer.apple.com") >= 0, cells };
    });
  }
  return (Array.isArray(json) ? json : []).map((record) => {
    const cells = {};
    for (const platform of PLATFORMS) {
      cells[platform] = record.platforms && record.platforms[platform] && record.platforms[platform].status;
    }
    return { name: record.capability.label, firstParty: false, cells };
  });
}

function windowSub(sheet, json) {
  if (sheet.kind === "capability") {
    return "who serves it, where — receipts on the flat page";
  }
  const first = Array.isArray(json) && json[0];
  return first ? "as of " + first.package.version + " — what it serves, where" : "";
}

// ---------- picking (transient-pointer ray vs quads) ----------

function pick(rayMatrix, quads) {
  const ox = rayMatrix[12], oy = rayMatrix[13], oz = rayMatrix[14];
  const dx = -rayMatrix[8], dy = -rayMatrix[9], dz = -rayMatrix[10];
  let best = null;
  let bestT = Infinity;
  for (const q of quads) {
    if (q.noPick || !q.action) continue;
    const px = ox - q.x, py = oy - q.y, pz = oz - q.z;
    const c = Math.cos(q.yaw), s = Math.sin(q.yaw);
    const lox = c * px - s * pz, loy = py, loz = s * px + c * pz;
    const ldx = c * dx - s * dz, ldy = dy, ldz = s * dx + c * dz;
    if (Math.abs(ldz) < 1e-6) continue;
    const t = -loz / ldz;
    if (t <= 0 || t >= bestT) continue;
    const hx = (lox + t * ldx) / q.w, hy = (loy + t * ldy) / q.h;
    if (Math.abs(hx) <= 0.5 && Math.abs(hy) <= 0.5) {
      best = q;
      bestT = t;
    }
  }
  return best;
}

// Rotate a target-ray matrix into yard space (undo the current spin) so the
// yard quads' stored coordinates stay valid however far the user has spun.
function rayInYard(rayMatrix, spin) {
  const c = Math.cos(spin), s = Math.sin(spin);
  const m = new Float32Array(rayMatrix);
  const rot = (ix, iz) => {
    const x = m[ix], z = m[iz];
    m[ix] = c * x - s * z;
    m[iz] = s * x + c * z;
  };
  rot(8, 10);    // direction column
  rot(12, 14);   // origin
  return m;
}

// ---------- feedback ----------

let audio = null;
function tick(freq) {
  try {
    audio = audio || new (window.AudioContext || window.webkitAudioContext)();
    if (audio.state === "suspended") audio.resume().catch(function () {});
    const osc = audio.createOscillator();
    const gain = audio.createGain();
    osc.frequency.value = freq;
    gain.gain.setValueAtTime(0.05, audio.currentTime);
    gain.gain.exponentialRampToValueAtTime(0.001, audio.currentTime + 0.09);
    osc.connect(gain).connect(audio.destination);
    osc.start();
    osc.stop(audio.currentTime + 0.1);
  } catch (_) { /* feedback is sugar */ }
}

// ---------- session ----------

let sharedCanvas = null;
let sharedGL = null;
let yardCache = null;             // survives re-entry: textures are expensive to bake
const sheetJSONCache = new Map(); // fetched sub-page JSON, by URL

export default async function enter(feed, BASE) {
  // Session first — this call must stay inside the user-activation window.
  const session = await navigator.xr.requestSession("immersive-vr", {
    optionalFeatures: ["local-floor"],
  });

  try {
    if (!sharedGL) {
      sharedCanvas = document.createElement("canvas");
      sharedGL = sharedCanvas.getContext("webgl2", { xrCompatible: true, antialias: true })
              || sharedCanvas.getContext("webgl", { xrCompatible: true, antialias: true });
    }
    const gl = sharedGL;
    if (!gl) throw new Error("no WebGL");
    const isWebGL2 = (typeof WebGL2RenderingContext !== "undefined") && gl instanceof WebGL2RenderingContext;
    if (gl.makeXRCompatible) await gl.makeXRCompatible();

    const layer = new XRWebGLLayer(session, gl);
    session.updateRenderState({ baseLayer: layer });

    let space, yOff = 0;
    try {
      space = await session.requestReferenceSpace("local-floor");
    } catch (_) {
      space = await session.requestReferenceSpace("local");
      yOff = -1.35;   // no floor: origin sits at head height, drop the yard
    }

    if (!yardCache || yardCache.feed !== feed || yardCache.yOff !== yOff) {
      yardCache = { feed, yOff, plumbing: setupGL(gl), quads: buildYard(gl, isWebGL2, feed, yOff) };
    }
    const { plumbing, quads } = yardCache;

    // --- state ---
    let spin = 0, spinTarget = 0;
    let overlay = [];          // the open detail panel + its chips
    let navigateTo = null;
    let drag = null;           // the active transient-pointer, while pinched
    let focusKey = null;       // the district brought forward, if any
    let lastHead = { x: 0, y: 1.5 + yOff, z: 0, fx: 0, fz: -1 };

    let sheetSeq = 0;   // bumps on every overlay change; stale fetches check it

    const closePanel = () => {
      sheetSeq++;
      for (const q of overlay) gl.deleteTexture(q.tex);
      overlay = [];
    };

    // Spawn geometry facing wherever the user is looking RIGHT NOW — the v1
    // bug was a fixed spawn the user could have their back to.
    const facingSpot = (distance, dropY) => {
      const phi = azimuthOf(lastHead.fx, lastHead.fz);
      const dirX = Math.sin(phi), dirZ = -Math.cos(phi);
      return {
        phi, yaw: -phi,
        px: lastHead.x + distance * dirX,
        pz: lastHead.z + distance * dirZ,
        py: Math.min(Math.max(lastHead.y - dropY, 1.05 + yOff), 1.7 + yOff),
        ax: Math.cos(phi), az: Math.sin(phi),           // the panel's local X
        nx: -0.02 * dirX, nz: -0.02 * dirZ,             // nudge toward the user
      };
    };

    // A centered row of self-sized controls hung under a panel — chips are
    // never stretched into a shape their label didn't ask for.
    const hangControls = (spot, underY, controls, openedAt) => {
      const widths = controls.map((c) => c.canvas.width * CHIP_SCALE);
      const gap = 0.05;
      const total = widths.reduce((a, b) => a + b, 0) + gap * (controls.length - 1);
      let edge = -total / 2;
      controls.forEach((control, i) => {
        const center = edge + widths[i] / 2;
        overlay.push(quad(gl, isWebGL2, control.canvas,
          spot.px + center * spot.ax + spot.nx, underY, spot.pz + center * spot.az + spot.nz,
          spot.yaw, widths[i], control.canvas.height * CHIP_SCALE,
          { openedAt, action: control.action }));
        edge += widths[i] + gap;
      });
    };

    const openPanel = (action) => {
      closePanel();
      const detail = detailFor(action);
      const spot = facingSpot(1.35, 0.06);
      const openedAt = performance.now();
      overlay = [quad(gl, isWebGL2, paintPanel(detail), spot.px, spot.py, spot.pz, spot.yaw,
        1.1, 0.95, { noPick: true, openedAt })];
      const controls = [];
      if (detail.sheet) {
        controls.push({ canvas: paintChip("Open ↗", true), action: { type: "open", sheet: detail.sheet } });
      }
      controls.push({ canvas: paintChip("Close ✕", false), action: { type: "close" } });
      hangControls(spot, spot.py - 0.95 / 2 - 0.09, controls, openedAt);
      tick(660);
    };

    // The sub-page, as a window in the yard: the launching modal is
    // dismissed, the truth table renders in place, and Safari becomes the
    // explicit escape hatch — never the default.
    const openWindow = (sheet) => {
      closePanel();
      const seq = sheetSeq;
      const url = sheet.kind === "capability"
        ? BASE + "/api/capabilities/" + sheet.id + ".json"
        : BASE + "/api/packages/" + sheet.slug + ".json";
      const spot = facingSpot(1.9, 0.02);
      const openedAt = performance.now();
      const win = quad(gl, isWebGL2, paintWindowLoading(sheet.title), spot.px, spot.py, spot.pz,
        spot.yaw, 1.8, 1.15, { noPick: true, openedAt });
      overlay = [win];
      hangControls(spot, spot.py - 1.15 / 2 - 0.08, [
        { canvas: paintCloseCircle(), action: { type: "close" } },
        { canvas: paintChip("Open in Safari ↗", false), action: { type: "safari", href: sheet.href } },
      ], openedAt);
      tick(660);

      const show = (json) => {
        if (seq !== sheetSeq) return;   // the user moved on — drop it
        gl.deleteTexture(win.tex);
        win.tex = texFromCanvas(gl, paintWindowSheet(sheet.title, windowSub(sheet, json),
          windowRows(sheet, json)), isWebGL2);
      };
      if (sheetJSONCache.has(url)) {
        show(sheetJSONCache.get(url));
        return;
      }
      fetch(url).then((r) => { if (!r.ok) throw new Error("" + r.status); return r.json(); })
        .then((json) => { sheetJSONCache.set(url, json); show(json); })
        .catch(() => {
          if (seq !== sheetSeq) return;
          gl.deleteTexture(win.tex);
          win.tex = texFromCanvas(gl, paintWindowSheet(sheet.title,
            "couldn't fetch this here — Safari has it", []), isWebGL2);
        });
    };

    const tapAt = (rayMatrix) => {
      const overlayHit = pick(rayMatrix, overlay);
      if (overlayHit) {
        overlayHit.pulseAt = performance.now();
        const action = overlayHit.action;
        if (action.type === "close") {
          closePanel();
          tick(440);
        } else if (action.type === "open") {
          openWindow(action.sheet);
        } else if (action.type === "safari") {
          navigateTo = action.href.indexOf("/") === 0 && action.href.indexOf(BASE) !== 0
            ? BASE + action.href : action.href;
          session.end();
        }
        return;
      }
      const yardHit = pick(rayInYard(rayMatrix, spin), quads);
      if (yardHit) {
        yardHit.pulseAt = performance.now();
        if (yardHit.action.type === "district") {
          // Pinch the totem: bring the district around to wherever the user
          // is looking; pinch it again to let the yard go.
          const key = yardHit.action.key;
          if (focusKey === key) {
            focusKey = null;
            tick(440);
          } else {
            focusKey = key;
            const phiDistrict = yardHit.action.centerDeg * Math.PI / 180;
            const headPhi = azimuthOf(lastHead.fx, lastHead.fz);
            // Content at yard angle φ renders at world φ − spin, so facing
            // the head means spin = φ_district − φ_head — by the shortest way.
            spinTarget = spin + wrapAngle(phiDistrict - headPhi - spin);
            tick(660);
          }
          return;
        }
        openPanel(yardHit.action);
      } else if (overlay.length) {
        closePanel();
        tick(440);
      }
    };

    session.addEventListener("selectstart", (event) => {
      const pose = event.frame.getPose(event.inputSource.targetRaySpace, space);
      if (!pose || drag) return;
      const m = pose.transform.matrix;
      drag = {
        source: event.inputSource,
        startMatrix: new Float32Array(m),
        startAz: azimuthOf(-m[8], -m[10]),
        startSpin: spinTarget,
        moved: false,
      };
    });

    session.addEventListener("selectend", (event) => {
      if (!drag || event.inputSource !== drag.source) return;
      if (!drag.moved) tapAt(drag.startMatrix);
      drag = null;
    });

    // Transient inputs vanish when the pinch ends — if ours is removed
    // without a selectend (edge case), drop the drag instead of wedging.
    session.addEventListener("inputsourceschange", (event) => {
      if (drag && event.removed && Array.prototype.includes.call(event.removed, drag.source)) {
        drag = null;
      }
    });

    session.addEventListener("end", () => {
      closePanel();
      if (navigateTo) location.href = navigateTo;
    });

    // --- render loop ---
    const drawQuad = (q, pv, now) => {
      let model = q.model;
      let k = q.scaleK || 1;
      if (q.pulseAt && now - q.pulseAt < 160) {
        // Tap feedback: a quick 6% swell, decaying — visible confirmation in
        // a world with no hover state.
        k *= 1 + 0.06 * (1 - (now - q.pulseAt) / 160);
      }
      if (k !== 1) {
        model = new Float32Array(model);
        for (const i of [0, 1, 2, 4, 5, 6]) model[i] *= k;
      }
      let opacity = q.opacity;
      if (q.openedAt) opacity *= Math.min(1, (now - q.openedAt) / 140);
      gl.uniformMatrix4fv(plumbing.uMVP, false, mul(pv, model));
      gl.uniform1f(plumbing.uOpacity, opacity);
      gl.bindTexture(gl.TEXTURE_2D, q.tex);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    };

    let lastTime = 0;
    const onFrame = (time, frame) => {
      session.requestAnimationFrame(onFrame);
      const dt = lastTime ? Math.min(0.05, (time - lastTime) / 1000) : 0.016;
      lastTime = time;
      const pose = frame.getViewerPose(space);
      if (!pose) return;
      const now = performance.now();

      // Track the head: position + forward azimuth, for panel spawning.
      const hm = pose.transform.matrix;
      lastHead = { x: hm[12], y: hm[13], z: hm[14], fx: -hm[8], fz: -hm[10] };

      // Drag: the transient-pointer ray follows the hand — its azimuth delta
      // spins the yard, with smoothing so it never snaps.
      if (drag) {
        const dragPose = frame.getPose(drag.source.targetRaySpace, space);
        if (dragPose) {
          const dm = dragPose.transform.matrix;
          const delta = wrapAngle(azimuthOf(-dm[8], -dm[10]) - drag.startAz);
          if (Math.abs(delta) > TAP_THRESHOLD) drag.moved = true;
          // Content at yard angle φ renders at world angle φ − spin, so a
          // rightward hand (delta > 0) must DECREASE spin for the yard to
          // follow the hand — direct manipulation, not inverted.
          if (drag.moved) spinTarget = drag.startSpin - delta * DRAG_GAIN;
        }
      }
      spin += (spinTarget - spin) * Math.min(1, dt * 14);

      // District focus: the chosen district swells a touch and everything
      // else in the walls recedes — the hero, shelf, fence, and ghosts keep
      // their own weight. Eased every frame so focus never snaps.
      for (const q of quads) {
        if (!q.district) continue;
        const dimmed = focusKey && q.district !== focusKey;
        const opacityTarget = (q.baseOpacity || 1) * (dimmed ? 0.28 : 1);
        q.opacity += (opacityTarget - q.opacity) * Math.min(1, dt * 7);
        const scaleTarget = focusKey && q.district === focusKey ? 1.06 : 1;
        q.scaleK = (q.scaleK || 1) + (scaleTarget - (q.scaleK || 1)) * Math.min(1, dt * 7);
      }

      gl.bindFramebuffer(gl.FRAMEBUFFER, layer.framebuffer);
      gl.clearColor(SKY[0], SKY[1], SKY[2], 1);
      gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
      gl.enable(gl.DEPTH_TEST);
      gl.enable(gl.BLEND);
      gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);   // premultiplied canvases

      gl.useProgram(plumbing.program);
      gl.bindBuffer(gl.ARRAY_BUFFER, plumbing.buffer);
      gl.enableVertexAttribArray(plumbing.aPos);
      gl.enableVertexAttribArray(plumbing.aUV);
      gl.vertexAttribPointer(plumbing.aPos, 2, gl.FLOAT, false, 16, 0);
      gl.vertexAttribPointer(plumbing.aUV, 2, gl.FLOAT, false, 16, 8);
      gl.activeTexture(gl.TEXTURE0);
      gl.uniform1i(plumbing.uTex, 0);

      // Painter's sort in yard space: rotate the head into the yard instead
      // of rotating every quad out of it.
      const hc = Math.cos(spin), hs = Math.sin(spin);
      const hx = hc * lastHead.x - hs * lastHead.z;
      const hz = hs * lastHead.x + hc * lastHead.z;
      const hy = lastHead.y;
      const sortedYard = quads.slice().sort((a, b) =>
        ((b.x - hx) ** 2 + (b.y - hy) ** 2 + (b.z - hz) ** 2)
        - ((a.x - hx) ** 2 + (a.y - hy) ** 2 + (a.z - hz) ** 2));
      const spinMatrix = rotY(spin);

      for (const view of pose.views) {
        const vp = layer.getViewport(view);
        gl.viewport(vp.x, vp.y, vp.width, vp.height);
        const pv = mul(view.projectionMatrix, view.transform.inverse.matrix);
        const pvSpin = mul(pv, spinMatrix);
        for (const q of sortedYard) drawQuad(q, pvSpin, now);
        if (overlay.length) {
          gl.disable(gl.DEPTH_TEST);   // the panel always reads, never clips
          for (const q of overlay) drawQuad(q, pv, now);
          gl.enable(gl.DEPTH_TEST);
        }
      }
    };
    session.requestAnimationFrame(onFrame);
  } catch (error) {
    session.end();
    throw error;
  }
}
