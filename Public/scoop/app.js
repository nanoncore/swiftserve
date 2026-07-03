// SwiftServe frontend — hand-authored, no framework, no build step.
// The Scoop card is rendered entirely from the /analyze JSON. The mascot's mood
// is a first-class field in that JSON; everything visual derives from it.

"use strict";

// Mirror of SwiftServeCore's Mood — sprite + display label + a restrained tint.
// (Score/mood/voiceLine/headline all come from the JSON; this is just presentation.)
const MOOD = {
  partyMode:   { sprite: "swiftee-party",   label: "Party Mode",  tint: "#e0a23a" },
  freshSwirl:  { sprite: "swiftee-fresh",   label: "Fresh Swirl", tint: "#5fb37a" },
  softSqueeze: { sprite: "swiftee-squeeze", label: "Soft Squeeze", tint: "#ed8b3e" },
  meltdown:    { sprite: "swiftee-melt",    label: "Meltdown",    tint: "#e0703a" },
  dayOld:      { sprite: "swiftee-dayold",  label: "Day-Old",     tint: "#b98a6a" },
  idle:        { sprite: "swiftee-idle",    label: "",            tint: "#ed8b3e" },
};

const FLAG_LABELS = {
  branchPin: "branch pin",
  revisionPin: "commit pin",
  preRelease: "pre-1.0",
  nonCanonicalLocation: "off-forge host",
  localPath: "local path",
  registry: "registry",
  archived: "archived",
  noLicense: "no license",
  copyleftLicense: "copyleft",
};
const ALERT_FLAGS = new Set(["branchPin", "revisionPin", "archived", "noLicense"]);

// --- Resolved discovery (pure — everything above the boundary is node-testable)
//
// Xcode scatters Package.resolved: every local package keeps its own subgraph
// copy, while the FULL workspace resolution hides inside
// *.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/. People drop the wrong
// one and silently scan a partial graph — so the scoop accepts a whole project
// folder (or the .xcodeproj itself), finds every candidate, and picks the
// workspace resolution when one exists, the fullest graph otherwise.

const SKIP_DIRS = new Set([
  ".git", ".build", "DerivedData", "node_modules", "Pods", "Carthage",
  "checkouts", ".Trash",
]);

function pinCount(text) {
  try {
    const parsed = JSON.parse(text);
    return Array.isArray(parsed.pins) ? parsed.pins.length : -1;
  } catch {
    return -1;
  }
}

function pickResolved(candidates) {
  const valid = candidates.filter((c) => c.count >= 0);
  if (!valid.length) return null;
  const workspace = valid.filter((c) => c.path.includes("xcshareddata/swiftpm"));
  const pool = workspace.length ? workspace : valid;
  return pool.slice().sort((a, b) => (b.count - a.count) || (a.path.length - b.path.length))[0];
}

function trimPath(path) {
  const parts = String(path).split("/").filter(Boolean);
  return parts.length <= 4 ? parts.join("/") : "…/" + parts.slice(-4).join("/");
}

// __PURE_BOUNDARY__ — DOM and network only below this line.

const landing = document.getElementById("landing");
const scoop = document.getElementById("scoop");
const dropzone = document.getElementById("dropzone");
const fileInput = document.getElementById("file-input");
const errorEl = document.getElementById("error");
const scanningEl = document.getElementById("scanning");

// --- Upload wiring ---------------------------------------------------------

// The dropzone is a <div> (not a <label>), so JS owns activation — exactly one
// chooser opens. (A <label> would also open one natively, which double-fired.)
dropzone.addEventListener("click", () => fileInput.click());
dropzone.addEventListener("keydown", (e) => {
  if (e.key === "Enter" || e.key === " ") { e.preventDefault(); fileInput.click(); }
});
fileInput.addEventListener("change", () => {
  if (fileInput.files.length) handleFile(fileInput.files[0]);
});

["dragenter", "dragover"].forEach((evt) =>
  dropzone.addEventListener(evt, (e) => {
    e.preventDefault();
    dropzone.classList.add("dragging");
  })
);
["dragleave", "drop"].forEach((evt) =>
  dropzone.addEventListener(evt, (e) => {
    e.preventDefault();
    dropzone.classList.remove("dragging");
  })
);
dropzone.addEventListener("drop", (e) => {
  // Grab entries synchronously — the DataTransfer is neutered once the
  // handler yields, so this must happen before any await.
  const items = e.dataTransfer.items ? Array.from(e.dataTransfer.items) : [];
  const entries = items
    .map((item) => (item.webkitGetAsEntry ? item.webkitGetAsEntry() : null))
    .filter(Boolean);

  if (entries.some((entry) => entry.isDirectory) || entries.length > 1) {
    handleDroppedTree(entries);
    return;
  }
  const file = e.dataTransfer.files && e.dataTransfer.files[0];
  if (file) handleFile(file);
});

// A folder, an .xcodeproj, or several files at once: walk it, gather every
// Package.resolved, scan the best one, and say which one was used.
async function handleDroppedTree(entries) {
  hideError();
  setScanning(true);
  const found = await collectResolved(entries);
  setScanning(false);
  const best = pickResolved(found);
  if (!best) {
    return showError("No Package.resolved in there — point me at the project folder (or the .xcodeproj) that has one.");
  }
  await scan(best.text, {
    path: best.path,
    count: best.count,
    others: found.filter((c) => c !== best && c.count >= 0),
  });
}

async function collectResolved(entries) {
  const found = [];
  let budget = 5000;   // entries visited — a project tree, not a home folder

  async function walk(entry, depth) {
    if (!entry || budget-- <= 0 || depth > 12) return;
    if (entry.isFile) {
      if (entry.name !== "Package.resolved") return;
      const file = await new Promise((resolve) => entry.file(resolve, () => resolve(null)));
      if (!file) return;
      const text = await file.text().catch(() => null);
      if (text != null) found.push({ path: entry.fullPath || entry.name, text, count: pinCount(text) });
      return;
    }
    if (!entry.isDirectory || SKIP_DIRS.has(entry.name)) return;
    const reader = entry.createReader();
    for (;;) {   // readEntries hands back batches until an empty one
      const batch = await new Promise((resolve) => reader.readEntries(resolve, () => resolve([])));
      if (!batch.length) break;
      for (const child of batch) await walk(child, depth + 1);
    }
  }

  for (const entry of entries) await walk(entry, 0);
  return found;
}

async function handleFile(file) {
  hideError();
  let text;
  try {
    text = await file.text();
  } catch {
    return showError("Couldn't read that file. Mind trying again?");
  }
  await scan(text);
}

async function scan(text, source) {
  setScanning(true);
  try {
    const res = await fetch("/analyze", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: text,
    });
    const report = await res.json();
    if (!res.ok) {
      return showError(report.error || "Swiftee couldn't read that one.");
    }
    render(report);
    if (source) prependSourceNote(source);
  } catch {
    showError("Couldn't reach the scanner. Is the server running?");
  } finally {
    setScanning(false);
  }
}

// Which file the verdicts came from — a partial graph should LOOK partial.
function prependSourceNote(source) {
  const note = el("p", "fine-print source-note");
  let text = `Scanned ${trimPath(source.path)} — ${source.count} package${source.count === 1 ? "" : "s"}.`;
  if (source.others.length) {
    const alt = source.others.slice().sort((a, b) => b.count - a.count)[0];
    text += ` Also found ${trimPath(alt.path)} (${alt.count}) — drop it alone to scan that graph instead.`;
  }
  note.textContent = text;
  scoop.prepend(note);
}

function setScanning(on) {
  scanningEl.hidden = !on;
  dropzone.classList.toggle("busy", on);
}

function showError(message) {
  errorEl.textContent = message;
  errorEl.hidden = false;
}
function hideError() {
  errorEl.hidden = true;
}

// --- Rendering -------------------------------------------------------------

function render(report) {
  const o = report.overall;
  const mood = MOOD[o.mood] || MOOD.softSqueeze;

  scoop.replaceChildren(); // clear

  const card = el("div", "scoop-card");

  // Hero: sprite · mood pill · score ring + voice + headline
  const hero = el("div", "scoop-hero");
  hero.append(spriteEl(mood.sprite, `Swiftee — ${mood.label}`, "swiftee-sprite"));

  const heroText = el("div", "hero-text");
  const moodLabel = el("span", "mood-label", mood.label);
  moodLabel.style.background = mood.tint;

  const heroMain = el("div", "hero-main");
  heroMain.append(scoreRing(o.score, mood.tint));
  const voiceWrap = el("div", "voice-wrap");
  voiceWrap.append(el("p", "hero-voice", o.voiceLine), el("p", "hero-headline", o.headline));
  heroMain.append(voiceWrap);

  heroText.append(moodLabel, heroMain);
  hero.append(heroText);
  card.append(hero);

  // Graph metrics
  card.append(metricsEl(report.graph));

  // Dependencies (worst first, so attention lands where it's needed)
  if (report.packages.length) {
    const list = el("ul", "dep-list");
    [...report.packages].sort((a, b) => a.score - b.score).forEach((p) => list.append(depEl(p)));
    card.append(list);
  } else {
    card.append(el("p", "empty-note", "No dependencies to scan — nothing to melt. 🍦"));
  }

  scoop.append(card);

  const again = el("button", "scan-again", "Scan another");
  again.addEventListener("click", reset);
  scoop.append(again);

  landing.hidden = true;
  scoop.hidden = false;
  window.scrollTo({ top: 0, behavior: "smooth" });

  // Fill the ring after layout so the dash-offset transition plays.
  requestAnimationFrame(() => {
    const prog = scoop.querySelector(".ring-progress");
    if (prog) prog.style.strokeDashoffset = prog.dataset.target;
  });
}

// Mood-colored circular score gauge, built as inline SVG (no deps).
function scoreRing(score, color) {
  const NS = "http://www.w3.org/2000/svg";
  const size = 104, sw = 9, r = (size - sw) / 2, circ = 2 * Math.PI * r;

  const wrap = el("div", "ring-wrap");
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("class", "score-ring");
  svg.setAttribute("viewBox", `0 0 ${size} ${size}`);
  svg.setAttribute("width", size);
  svg.setAttribute("height", size);

  const circle = (cls) => {
    const c = document.createElementNS(NS, "circle");
    c.setAttribute("class", cls);
    c.setAttribute("cx", size / 2);
    c.setAttribute("cy", size / 2);
    c.setAttribute("r", r);
    c.setAttribute("fill", "none");
    c.setAttribute("stroke-width", sw);
    return c;
  };
  const track = circle("ring-track");
  const prog = circle("ring-progress");
  prog.setAttribute("stroke", color);
  prog.setAttribute("stroke-linecap", "round");
  prog.setAttribute("stroke-dasharray", circ);
  prog.style.strokeDashoffset = circ;                 // start empty
  prog.dataset.target = circ * (1 - clampPct(score) / 100); // animate to here
  svg.append(track, prog);

  const num = el("div", "ring-num");
  num.append(el("span", "ring-score", String(score)), el("span", "ring-max", "/ 100"));

  wrap.append(svg, num);
  return wrap;
}

function clampPct(n) {
  return Math.max(0, Math.min(100, n));
}

function metricsEl(graph) {
  const wrap = el("div", "metrics");
  wrap.append(metric(graph.total, graph.total === 1 ? "dependency" : "dependencies"));
  if (graph.duplicates && graph.duplicates.length) {
    wrap.append(metric(graph.duplicates.length, "duplicate name" + (graph.duplicates.length === 1 ? "" : "s")));
  }
  if (graph.conflicts && graph.conflicts.length) {
    wrap.append(metric(graph.conflicts.length, "version conflict" + (graph.conflicts.length === 1 ? "" : "s")));
  }
  const note = el("p", "metrics-note",
    "Direct vs. transitive and graph depth need your Package.swift — a resolved file is a flat list, so SwiftServe doesn't guess.");
  const container = el("div");
  container.append(wrap, note);
  return container;
}

function metric(num, label) {
  const m = el("div", "metric");
  m.append(el("div", "metric-num", String(num)), el("div", "metric-label", label));
  return m;
}

function depEl(p) {
  const li = el("li", "dep");

  const main = el("div", "dep-main");
  main.append(el("div", "dep-name", p.name));

  let version = p.resolvedVersion || (p.branch ? `@${p.branch}` : "—");
  if (p.latestVersion && p.latestVersion !== p.resolvedVersion) {
    version += ` → ${p.latestVersion}`;
  }
  main.append(el("div", "dep-version", version));
  main.append(el("div", "dep-reason", p.reason));

  if (p.flags && p.flags.length) {
    const flags = el("div", "dep-flags");
    for (const f of p.flags) {
      const pill = el("span", "pill", FLAG_LABELS[f] || f);
      if (ALERT_FLAGS.has(f)) pill.classList.add("alert");
      flags.append(pill);
    }
    main.append(flags);
  }
  li.append(main);

  const score = el("div", "dep-score", String(p.score));
  score.style.background = scoreColor(p.score);
  li.append(score);

  return li;
}

function scoreColor(score) {
  if (score >= 80) return "#5fb37a";
  if (score >= 55) return "#ed8b3e";
  if (score >= 30) return "#e0703a";
  return "#d76b4e";
}

function reset() {
  scoop.hidden = true;
  scoop.replaceChildren();
  landing.hidden = false;
  fileInput.value = "";
  hideError();
}

// --- Helpers ---------------------------------------------------------------

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

// Sprite with graceful fallback to a labeled placeholder box if the file is missing.
function spriteEl(spriteName, alt, className) {
  const img = document.createElement("img");
  img.className = className;
  img.alt = alt;
  img.src = `/swiftee/${spriteName}.png`;
  img.onerror = () => {
    const box = el("div", "sprite-fallback", `[${spriteName}]`);
    img.replaceWith(box);
  };
  return img;
}
