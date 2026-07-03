// SwiftServe — the fence yard, v2. The /on/visionos page as a place: a hero
// panel that tells the story, the capability wall as two wings beside it, the
// OS shelf beneath, and the fence line with its compiler receipts at the rear
// — with the whole yard spinnable by pinch-drag, because Apple's spatial HIG
// says people bring content to themselves; they don't walk or crane.
//
// Interaction model (visionOS natural input, WebKit transient-pointer):
//   · pinch + drag anywhere  → spin the yard (the target ray tracks the hand)
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

// Drag feel: hand-angle → yard-angle gain, and the movement past which a
// pinch stops being a tap. ~1.7 lets a small wrist arc walk the whole fence.
const DRAG_GAIN = 1.7;
const TAP_THRESHOLD = 0.035;   // radians of ray travel

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

function paintHero(stats) {
  const ctx = makeCtx(1900, 1000);
  cardBase(ctx);
  ctx.fillStyle = INK;
  ctx.font = "700 128px " + SANS;
  ctx.fillText("The state of visionOS", 90, 190);

  ctx.font = "600 74px " + SANS;
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
    ctx.fillText(text, x, 330);
    x += ctx.measureText(text).width;
  }

  ctx.font = "500 52px " + SANS;
  ctx.fillStyle = INK_SOFT;
  const guide = [
    ["✓", GOOD, "The green wall, both sides — what packages serve, capability by capability."],
    ["", INK_SOFT, "The dark shelf below — what the OS covers before any dependency."],
    ["✕", LOW, "The fence, around back — packages that don't compile, receipts nailed on."],
  ];
  guide.forEach(([glyph, color, text], i) => {
    ctx.fillStyle = color;
    ctx.font = "700 52px " + SANS;
    ctx.fillText(glyph, 90, 470 + i * 92);
    ctx.fillStyle = INK_SOFT;
    ctx.font = "500 52px " + SANS;
    ctx.fillText(text, 170, 470 + i * 92);
  });

  ctx.fillStyle = ACCENT_DEEP;
  ctx.font = "600 52px " + SANS;
  ctx.fillText("Pinch & drag anywhere to spin the yard.", 90, 796);
  ctx.fillText("Look at anything, pinch to open it.", 90, 868);
  ctx.fillStyle = MUTED;
  ctx.fillText("The crown takes you home.", 90, 940);
  return ctx.canvas;
}

function paintCapabilityCard(entry) {
  const ctx = makeCtx(704, 416);
  cardBase(ctx);
  ctx.fillStyle = MUTED;
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
  ctx.fillText(count, 50, 356);
  if (entry.builtInCovers && entry.packages > 0) {
    // The  glyph is private-use and tofus off Apple devices — but this
    // scene only ever runs on one.
    ctx.fillStyle = INK_SOFT;
    ctx.fillText("  ·  ", 50 + ctx.measureText(count).width, 356);
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
      ctx.fillText("… more on the flat page", 64, y);
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

function paintChip(label, accent) {
  const ctx = makeCtx(576, 160);
  const { width, height } = ctx.canvas;
  ctx.clearRect(0, 0, width, height);
  roundRect(ctx, 5, 5, width - 10, height - 10, 75);
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
  ctx.textAlign = "left";
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

  // Capability wall: two wings flanking the hero, 12 virtual columns per row
  // (6 left + 6 right), filled in reading order. Categories stay adjacent
  // because the feed is sorted by capability id.
  const cardW = 0.44, cardH = 0.26, cardR = 2.6;
  const colStep = 11.3, wingGap = 24;   // degrees: inner edge of each wing
  const rowY = [1.98, 1.64, 1.30, 0.96];
  const perRow = 12;
  const colPhi = (col) => col < 6
    ? -(wingGap + (5 - col + 0.5) * colStep)
    : (wingGap + (col - 6 + 0.5) * colStep);
  feed.capabilities.forEach((entry, i) => {
    const row = Math.floor(i / perRow);
    const inRow = Math.min(perRow, feed.capabilities.length - row * perRow);
    const col = (i % perRow) + Math.floor((perRow - inRow) / 2);
    place(paintCapabilityCard(entry), cardR, colPhi(col), rowY[Math.min(row, rowY.length - 1)],
      cardW, cardH, { action: { type: "capability", entry } });
  });

  // The OS shelf: dark plaques under the hero — "before you add a
  // dependency" at a glance.
  feed.builtIn.forEach((framework, i) => {
    place(paintPlaque(framework), 2.35, (i - (feed.builtIn.length - 1) / 2) * 12.5, 0.62,
      0.46, 0.27, { action: { type: "plaque", framework } });
  });

  // The fence: one plank per fenced package, receipts nailed on, around the
  // back — spin the yard to walk it.
  const planks = feed.fenced.map((pkg) => ({
    name: pkg.name, slug: pkg.slug, version: pkg.version,
    fences: pkg.fences,
    worksOn: pkg.fences[0] ? pkg.fences[0].worksOn : [],
  }));
  const plankStep = 5.6, plankPhi = (i) => 180 + (i - (planks.length - 1) / 2) * plankStep;
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
  // never nailed down.
  feed.unknowns.forEach((unknown, i) => {
    const row = Math.floor(i / 4), col = i % 4;
    place(paintGhostCard(unknown), 3.0, 180 + (col - 1.5) * 7.5, 1.92 + row * 0.4,
      0.30, 0.28, { opacity: 0.6, action: { type: "ghost", unknown } });
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
      rows.push({ text: "+ " + (entry.verdicts.length - 8) + " more on the truth table", color: MUTED });
    }
    return {
      title: entry.label,
      sub: entry.supported + " of " + entry.packages + " packages serve this on visionOS",
      rows,
      link: { label: "Open the truth table ↗", href: entry.truthTable },
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
      rows.push({ text: "+ " + (plank.fences.length - 2) + " more on the package page", color: MUTED });
    }
    if (plank.worksOn.length) {
      rows.push({ glyph: "✓", glyphColor: GOOD, text: "serves it on " + plank.worksOn.join(" · "), color: GOOD });
    }
    return {
      tone: "low",
      title: plank.name,
      sub: "proven off visionOS · as of " + plank.version,
      rows,
      link: { label: "Open " + plank.name + " ↗", href: "/package/" + plank.slug + "/" },
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
      link: { label: "Open " + unknown.name + " ↗", href: "/package/" + unknown.slug + "/" },
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
    link: { label: "Open " + framework.name + " ↗", href: "/package/" + framework.slug + "/" },
  };
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
let yardCache = null;   // survives re-entry: textures are expensive to bake

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
    let lastHead = { x: 0, y: 1.5 + yOff, z: 0, fx: 0, fz: -1 };

    const closePanel = () => {
      for (const q of overlay) gl.deleteTexture(q.tex);
      overlay = [];
    };

    const openPanel = (action) => {
      closePanel();
      const detail = detailFor(action);
      // Spawn facing wherever the user is looking RIGHT NOW — the v1 bug was
      // a fixed spawn the user could have their back to.
      const phi = azimuthOf(lastHead.fx, lastHead.fz);
      const dirX = Math.sin(phi), dirZ = -Math.cos(phi);
      const px = lastHead.x + 1.35 * dirX;
      const pz = lastHead.z + 1.35 * dirZ;
      const py = Math.min(Math.max(lastHead.y - 0.06, 1.0 + yOff), 1.75 + yOff);
      const yaw = -phi;
      const openedAt = performance.now();
      const panel = quad(gl, isWebGL2, paintPanel(detail), px, py, pz, yaw, 1.1, 0.95,
        { noPick: true, openedAt });
      // Chips sit just under the panel, nudged toward the user so they
      // always pick first.
      const ax = Math.cos(phi), az = Math.sin(phi);   // panel's local X in world
      const chipY = py - 0.95 / 2 - 0.09;
      const nudgeX = -0.02 * dirX, nudgeZ = -0.02 * dirZ;
      overlay = [panel];
      if (detail.link) {
        overlay.push(quad(gl, isWebGL2, paintChip(detail.link.label, true),
          px - 0.24 * ax + nudgeX, chipY, pz - 0.24 * az + nudgeZ, yaw, 0.42, 0.115,
          { openedAt, action: { type: "link", href: detail.link.href } }));
      }
      overlay.push(quad(gl, isWebGL2, paintChip("Close ✕", false),
        px + 0.24 * ax + nudgeX, chipY, pz + 0.24 * az + nudgeZ, yaw, 0.28, 0.115,
        { openedAt, action: { type: "close" } }));
      tick(660);
    };

    const tapAt = (rayMatrix) => {
      const overlayHit = pick(rayMatrix, overlay);
      if (overlayHit) {
        overlayHit.pulseAt = performance.now();
        if (overlayHit.action.type === "close") {
          closePanel();
          tick(440);
        } else if (overlayHit.action.type === "link") {
          const href = overlayHit.action.href;
          navigateTo = href.indexOf("/") === 0 && href.indexOf(BASE) !== 0 ? BASE + href : href;
          session.end();
        }
        return;
      }
      const yardHit = pick(rayInYard(rayMatrix, spin), quads);
      if (yardHit) {
        yardHit.pulseAt = performance.now();
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
      if (q.pulseAt && now - q.pulseAt < 160) {
        // Tap feedback: a quick 6% swell, decaying — visible confirmation in
        // a world with no hover state.
        const k = 1 + 0.06 * (1 - (now - q.pulseAt) / 160);
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
