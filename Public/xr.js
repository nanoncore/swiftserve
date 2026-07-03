// SwiftServe — the fence yard. The /on/visionos page as a place you stand in:
// capability cards out front, the OS shelf at your knees, and the fence line
// behind you — every plank a compiler receipt. Hand-written WebGL + WebXR,
// no framework, no build step. Loaded on demand by xr-entry.js, only after
// immersive-vr support is proven, so no one else ever pays for it.
//
// The scene is built ENTIRELY from /api/on/visionos.json — the same one-fetch
// feed the flat page links. Nothing here is hand-counted.
//
// Comfort contract: local-floor space, everything static, no locomotion; the
// only motion is the reading card the user asks for by pinching a plank.

"use strict";

// House palette — mirrors :root in styles.css (keep in sync by hand, like
// site.js mirrors PlatformDisplay.order).
const INK = "#2c2724";
const INK_SOFT = "#5b534c";
const MUTED = "#93897f";
const HAIRLINE = "#efe7db";
const SURFACE = "#ffffff";
const ACCENT_DEEP = "#d9742a";
const GOOD = "#5fb37a";
const LOW = "#d76b4e";
const BUILTIN = "#1d1d1f";
const SKY = [0.9647, 0.9333, 0.8824];        // #f6eee1 — the warm void
const SANS = "-apple-system, 'SF Pro', 'Helvetica Neue', sans-serif";
const MONO = "ui-monospace, 'SF Mono', Menlo, monospace";

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
// makes a quad on the circle at angle φ face the origin (where the user is).
function modelMatrix(x, y, z, yaw, w, h) {
  const c = Math.cos(yaw), s = Math.sin(yaw);
  return new Float32Array([
    w * c, 0, -w * s, 0,
    0, h, 0, 0,
    s, 0, c, 0,
    x, y, z, 1,
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
// hard-split so nothing escapes the plank.
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
    const last = lines[lines.length - 1].replace(/.$/, "");
    lines[lines.length - 1] = last + "…";
  }
  return lines.slice(0, maxLines);
}

function cardBase(ctx, alpha, dashed) {
  const { width, height } = ctx.canvas;
  ctx.clearRect(0, 0, width, height);
  ctx.globalAlpha = alpha == null ? 1 : alpha;
  roundRect(ctx, 4, 4, width - 8, height - 8, Math.min(36, height / 5));
  ctx.fillStyle = SURFACE;
  ctx.fill();
  ctx.lineWidth = 3;
  if (dashed) ctx.setLineDash([14, 10]);
  ctx.strokeStyle = dashed ? MUTED : HAIRLINE;
  ctx.stroke();
  ctx.setLineDash([]);
}

// ---------- panel painters ----------

function paintTitle(stats) {
  const ctx = makeCtx(1792, 448);
  ctx.textBaseline = "alphabetic";
  ctx.textAlign = "center";
  ctx.fillStyle = INK;
  ctx.font = "700 108px " + SANS;
  ctx.fillText("The state of visionOS", 896, 150);

  // The stat line, hand-kerned segment by segment so each number keeps its
  // verdict color.
  ctx.font = "600 62px " + SANS;
  const parts = [
    [stats.supported + " serve it", GOOD],
    ["  ·  ", MUTED],
    [stats.unsupported + " fenced out", LOW],
    ["  ·  ", MUTED],
    [stats.unknown + " honest unknowns", MUTED],
  ];
  ctx.textAlign = "left";
  let total = 0;
  for (const [text] of parts) total += ctx.measureText(text).width;
  let x = 896 - total / 2;
  for (const [text, color] of parts) {
    ctx.fillStyle = color;
    ctx.fillText(text, x, 268);
    x += ctx.measureText(text).width;
  }

  ctx.textAlign = "center";
  ctx.fillStyle = MUTED;
  ctx.font = "500 40px " + SANS;
  ctx.fillText("across " + stats.records + " records · " + stats.packages + " packages — every verdict carries its receipt", 896, 360);
  return ctx.canvas;
}

function paintCapabilityCard(entry) {
  const ctx = makeCtx(640, 336);
  cardBase(ctx);
  const category = entry.id.split(".")[0].toUpperCase();
  ctx.fillStyle = MUTED;
  ctx.font = "600 30px " + SANS;
  ctx.fillText(category, 44, 74);

  ctx.fillStyle = INK;
  ctx.font = "600 48px " + SANS;
  const lines = wrap(ctx, entry.label, 552, 2);
  lines.forEach((line, i) => ctx.fillText(line, 44, 138 + i * 58));

  ctx.font = "600 38px " + SANS;
  let count;
  if (entry.packages === 0) {
    ctx.fillStyle = INK_SOFT;
    count = " built into the OS";
  } else if (entry.supported > 0) {
    ctx.fillStyle = GOOD;
    count = entry.supported + " of " + entry.packages + " package" + (entry.packages === 1 ? "" : "s");
  } else {
    ctx.fillStyle = MUTED;
    count = "0 of " + entry.packages + " package" + (entry.packages === 1 ? "" : "s");
  }
  ctx.fillText(count, 44, 286);
  if (entry.builtInCovers && entry.packages > 0) {
    // The  glyph is private-use and tofus off Apple devices — but this
    // scene only ever runs on one.
    const w = ctx.measureText(count).width;
    ctx.fillStyle = INK_SOFT;
    ctx.fillText("  ·   OS", 44 + w, 286);
  }
  return ctx.canvas;
}

function paintPlaque(framework) {
  const ctx = makeCtx(640, 336);
  const { width, height } = ctx.canvas;
  ctx.clearRect(0, 0, width, height);
  roundRect(ctx, 4, 4, width - 8, height - 8, 40);
  ctx.fillStyle = BUILTIN;
  ctx.fill();
  ctx.fillStyle = "#f5f5f7";
  ctx.font = "600 52px " + SANS;
  ctx.fillText(" " + framework.name, 44, 96);
  ctx.fillStyle = "#a1a1a6";
  ctx.font = "500 34px " + SANS;
  const caps = framework.capabilities.length;
  ctx.fillText(caps + " capabilit" + (caps === 1 ? "y" : "ies") + " · " + framework.version, 44, 162);
  ctx.font = "500 32px " + SANS;
  const names = framework.capabilities.map((c) => c.label).join(" · ");
  wrap(ctx, names, 552, 3).forEach((line, i) => ctx.fillText(line, 44, 224 + i * 42));
  return ctx.canvas;
}

function paintPlank(plank) {
  const ctx = makeCtx(320, 1344);
  cardBase(ctx);
  ctx.fillStyle = LOW;
  ctx.font = "700 36px " + SANS;
  wrap(ctx, plank.name, 248, 2).forEach((line, i) => ctx.fillText(line, 36, 78 + i * 44));
  ctx.fillStyle = INK_SOFT;
  ctx.font = "600 28px " + SANS;
  wrap(ctx, plank.capabilityLabel, 248, 2).forEach((line, i) => ctx.fillText(line, 36, 182 + i * 36));

  ctx.strokeStyle = HAIRLINE;
  ctx.lineWidth = 3;
  ctx.beginPath();
  ctx.moveTo(36, 268);
  ctx.lineTo(284, 268);
  ctx.stroke();

  ctx.fillStyle = INK;
  ctx.font = "26px " + MONO;
  wrap(ctx, plank.receipt, 248, 24).forEach((line, i) => ctx.fillText(line, 36, 322 + i * 36));

  if (plank.worksOn.length) {
    ctx.fillStyle = GOOD;
    ctx.font = "600 27px " + SANS;
    wrap(ctx, "✓ " + plank.worksOn.join(" · "), 248, 2)
      .forEach((line, i) => ctx.fillText(line, 36, 1240 + i * 34));
  }
  return ctx.canvas;
}

function paintGhostPlank(unknown) {
  const ctx = makeCtx(320, 1344);
  cardBase(ctx, 1, true);
  ctx.fillStyle = MUTED;
  ctx.font = "700 120px " + SANS;
  ctx.fillText("?", 36, 160);
  ctx.fillStyle = INK_SOFT;
  ctx.font = "700 36px " + SANS;
  wrap(ctx, unknown.name, 248, 2).forEach((line, i) => ctx.fillText(line, 36, 262 + i * 44));
  ctx.font = "600 28px " + SANS;
  wrap(ctx, unknown.capabilityLabel, 248, 2).forEach((line, i) => ctx.fillText(line, 36, 366 + i * 36));
  ctx.fillStyle = MUTED;
  ctx.font = "26px " + SANS;
  wrap(ctx, unknown.why || "no claim recorded yet", 248, 12)
    .forEach((line, i) => ctx.fillText(line, 36, 470 + i * 36));
  ctx.font = "600 26px " + SANS;
  wrap(ctx, "honestly unknown — never guessed", 248, 2)
    .forEach((line, i) => ctx.fillText(line, 36, 1260 + i * 34));
  return ctx.canvas;
}

function paintReadingCard(item) {
  const ctx = makeCtx(1280, 960);
  cardBase(ctx);
  ctx.fillStyle = item.tone === "low" ? LOW : INK_SOFT;
  ctx.font = "700 56px " + SANS;
  wrap(ctx, item.title, 1160, 2).forEach((line, i) => ctx.fillText(line, 60, 112 + i * 66));
  ctx.fillStyle = MUTED;
  ctx.font = "600 36px " + SANS;
  ctx.fillText(item.sub, 60, 236);

  ctx.strokeStyle = HAIRLINE;
  ctx.lineWidth = 3;
  ctx.beginPath();
  ctx.moveTo(60, 276);
  ctx.lineTo(1220, 276);
  ctx.stroke();

  ctx.fillStyle = INK;
  ctx.font = "34px " + MONO;
  wrap(ctx, item.body, 1160, 12).forEach((line, i) => ctx.fillText(line, 60, 348 + i * 48));

  if (item.footer) {
    ctx.fillStyle = GOOD;
    ctx.font = "600 34px " + SANS;
    ctx.fillText(item.footer, 60, 866);
  }
  ctx.fillStyle = MUTED;
  ctx.font = "500 30px " + SANS;
  ctx.textAlign = "right";
  ctx.fillText("pinch anywhere to put it back", 1220, 916);
  ctx.textAlign = "left";
  return ctx.canvas;
}

function paintExit() {
  const ctx = makeCtx(512, 192);
  cardBase(ctx);
  ctx.fillStyle = INK;
  ctx.font = "600 56px " + SANS;
  ctx.textAlign = "center";
  ctx.fillText("✕  Leave the yard", 256, 116);
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

  // One shared unit quad, interleaved pos+uv, drawn as a strip.
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
    // Crisp at distance: mipmaps matter when a plank is 3 m away.
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
    gl.generateMipmap(gl.TEXTURE_2D);
  } else {
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  }
  return texture;
}

// ---------- scene assembly ----------

// A quad: texture + static model matrix + pick geometry + optional action.
function quad(gl, isWebGL2, canvas, x, y, z, yaw, w, h, opts) {
  return Object.assign({
    tex: texFromCanvas(gl, canvas, isWebGL2),
    model: modelMatrix(x, y, z, yaw, w, h),
    x, y, z, yaw, w, h,
    opacity: 1,
  }, opts);
}

function buildScene(gl, isWebGL2, feed, yOff) {
  const quads = [];

  // The warm ground underfoot.
  quads.push({
    tex: texFromCanvas(gl, paintGround(), isWebGL2),
    model: groundMatrix(5, yOff + 0.002),
    x: 0, y: yOff, z: 0, w: 10, h: 10, opacity: 1, noPick: true,
  });

  // Title, floating front-high.
  quads.push(quad(gl, isWebGL2, paintTitle(feed.stats), 0, yOff + 2.05, -2.9, 0, 2.2, 0.55, { noPick: true }));

  // Capability cards: an arc of three rows, categories adjacent because the
  // feed is already sorted by capability id.
  const cards = feed.capabilities;
  const perRow = 16;
  const cardStep = 2 * Math.asin(0.165 / 2.4);
  const rowY = [1.62, 1.33, 1.04];
  cards.forEach((entry, i) => {
    const row = Math.floor(i / perRow);
    const inRow = Math.min(perRow, cards.length - row * perRow);
    const col = i % perRow;
    const phi = (col - (inRow - 1) / 2) * cardStep;
    quads.push(quad(gl, isWebGL2, paintCapabilityCard(entry),
      2.4 * Math.sin(phi), yOff + rowY[Math.min(row, rowY.length - 1)], -2.4 * Math.cos(phi), -phi,
      0.30, 0.16, { action: { type: "link", href: entry.truthTable } }));
  });

  // The OS shelf: dark plaques, low and close — the "before you add a
  // dependency" answer at a glance.
  const plaqueStep = 2 * Math.asin(0.185 / 1.95);
  feed.builtIn.forEach((framework, i) => {
    const phi = (i - (feed.builtIn.length - 1) / 2) * plaqueStep;
    quads.push(quad(gl, isWebGL2, paintPlaque(framework),
      1.95 * Math.sin(phi), yOff + 0.70, -1.95 * Math.cos(phi), -phi,
      0.34, 0.18, { action: { type: "link", href: "/package/" + framework.slug + "/" } }));
  });

  // The fence: solid planks (proven) then ghost planks (unknown), one arc
  // behind the user. Rails run between plank centers.
  const planks = [];
  for (const pkg of feed.fenced) {
    for (const fence of pkg.fences) {
      planks.push({
        name: pkg.name, version: pkg.version,
        capabilityLabel: fence.capabilityLabel,
        receipt: fence.receipt, worksOn: fence.worksOn, ghost: false,
      });
    }
  }
  for (const unknown of feed.unknowns) {
    planks.push(Object.assign({ ghost: true }, unknown));
  }
  const plankStep = 2 * Math.asin(0.12 / 2.7);
  const plankPhi = (i) => Math.PI + (i - (planks.length - 1) / 2) * plankStep;
  planks.forEach((plank, i) => {
    const phi = plankPhi(i);
    const canvas = plank.ghost ? paintGhostPlank(plank) : paintPlank(plank);
    quads.push(quad(gl, isWebGL2, canvas,
      2.7 * Math.sin(phi), yOff + 0.82, -2.7 * Math.cos(phi), -phi,
      0.20, 0.85, {
        opacity: plank.ghost ? 0.55 : 1,
        action: { type: "read", item: readingItem(plank) },
      }));
  });
  const railCanvas = paintRail();
  for (let i = 0; i + 1 < planks.length; i++) {
    const phi = (plankPhi(i) + plankPhi(i + 1)) / 2;
    for (const railY of [0.55, 1.12]) {
      quads.push(quad(gl, isWebGL2, railCanvas,
        2.73 * Math.sin(phi), yOff + railY, -2.73 * Math.cos(phi), -phi,
        0.26, 0.035, { noPick: true }));
    }
  }

  // The way out — the crown always works too.
  quads.push(quad(gl, isWebGL2, paintExit(), 0, yOff + 0.42, -1.5, 0, 0.26, 0.10,
    { action: { type: "exit" } }));

  return quads;
}

function readingItem(plank) {
  if (plank.ghost) {
    return {
      tone: "muted",
      title: plank.name + " — " + plank.capabilityLabel,
      sub: "honestly unknown — not verified yet, never guessed",
      body: plank.why || "no claim recorded for this platform yet",
      footer: null,
    };
  }
  return {
    tone: "low",
    title: plank.name + " — " + plank.capabilityLabel,
    sub: "as of " + plank.version,
    body: plank.receipt,
    footer: plank.worksOn.length ? "✓ serves it on " + plank.worksOn.join(" · ") : null,
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
    // Into quad-local space: undo translate, then yaw, then scale.
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

// ---------- session ----------

let sharedCanvas = null;
let sharedGL = null;
let sceneCache = null;   // survives re-entry: textures are expensive to bake

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
      // No floor: 'local' puts the origin at head height — drop the yard.
      space = await session.requestReferenceSpace("local");
      yOff = -1.35;
    }

    if (!sceneCache || sceneCache.feed !== feed || sceneCache.yOff !== yOff) {
      sceneCache = { feed, yOff, plumbing: setupGL(gl), quads: buildScene(gl, isWebGL2, feed, yOff) };
    }
    const { plumbing, quads } = sceneCache;

    // Reading card state: one at a time, pinched planks come to you.
    let reading = null;
    let readingOpenedAt = 0;
    let navigateTo = null;

    const closeReading = () => {
      if (reading) gl.deleteTexture(reading.tex);   // baked per pinch — don't hoard
      reading = null;
    };

    session.addEventListener("selectstart", (event) => {
      const pose = event.frame.getPose(event.inputSource.targetRaySpace, space);
      if (!pose) return;
      if (reading) {
        // Any pinch puts the plank back — unless it's the exit chip.
        const hit = pick(pose.transform.matrix, quads);
        closeReading();
        if (hit && hit.action.type === "exit") session.end();
        return;
      }
      const hit = pick(pose.transform.matrix, quads);
      if (!hit) return;
      const action = hit.action;
      if (action.type === "exit") {
        session.end();
      } else if (action.type === "link") {
        navigateTo = action.href.indexOf("/") === 0 && action.href.indexOf(BASE) !== 0
          ? BASE + action.href : action.href;
        session.end();
      } else if (action.type === "read") {
        reading = quad(gl, isWebGL2, paintReadingCard(action.item),
          0, yOff + 1.45, -1.15, 0, 1.15, 0.86, { noPick: true });
        readingOpenedAt = performance.now();
      }
    });

    session.addEventListener("end", () => {
      closeReading();
      if (navigateTo) location.href = navigateTo;
    });

    const draw = (q, pv, opacityScale) => {
      gl.uniformMatrix4fv(plumbing.uMVP, false, mul(pv, q.model));
      gl.uniform1f(plumbing.uOpacity, q.opacity * (opacityScale == null ? 1 : opacityScale));
      gl.bindTexture(gl.TEXTURE_2D, q.tex);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    };

    const onFrame = (time, frame) => {
      session.requestAnimationFrame(onFrame);
      const pose = frame.getViewerPose(space);
      if (!pose) return;

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

      // Painter's sort, back to front from the head — alpha edges stay clean.
      const head = pose.transform.position;
      const sorted = quads.slice().sort((a, b) =>
        ((b.x - head.x) ** 2 + (b.y - head.y) ** 2 + (b.z - head.z) ** 2)
        - ((a.x - head.x) ** 2 + (a.y - head.y) ** 2 + (a.z - head.z) ** 2));

      for (const view of pose.views) {
        const vp = layer.getViewport(view);
        gl.viewport(vp.x, vp.y, vp.width, vp.height);
        const pv = mul(view.projectionMatrix, view.transform.inverse.matrix);
        for (const q of sorted) draw(q, pv);
        if (reading) {
          // Ease the card in over 140 ms; it renders last, always on top.
          gl.disable(gl.DEPTH_TEST);
          const t = Math.min(1, (performance.now() - readingOpenedAt) / 140);
          draw(reading, pv, t);
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
