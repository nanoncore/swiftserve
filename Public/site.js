"use strict";
// SwiftServe capability search — hand-authored, no framework, no build step.
// Everything here is sugar: the truth tables render fully without JavaScript.
// (The Scoop tool keeps its own app.js under /scoop/.)

(function () {
  const BASE = (document.querySelector('link[rel="stylesheet"][href*="styles.css"]') || { getAttribute: () => "/styles.css" })
    .getAttribute("href").replace(/\/styles\.css(\?.*)?$/, "");

  const PLATFORMS = [
    { key: "iOS", label: "iOS", q: ["ios", "iphone", "ipad"] },
    { key: "macOS", label: "macOS", q: ["macos", "mac", "osx"] },
    { key: "watchOS", label: "watchOS", q: ["watchos", "watch"] },
    { key: "tvOS", label: "tvOS", q: ["tvos", "tv", "appletv"] },
    { key: "visionOS", label: "visionOS", q: ["visionos", "vision", "visionpro"] },
    { key: "linux", label: "Linux", q: ["linux"] },
    { key: "macCatalyst", label: "Catalyst", q: ["catalyst", "maccatalyst"] },
  ];
  // Column order matches PlatformDisplay.order in the generator.
  const COLUMN_ORDER = ["iOS", "macOS", "watchOS", "tvOS", "visionOS", "linux", "macCatalyst"];

  const el = (tag, cls, text) => {
    const node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text != null) node.textContent = text;
    return node;
  };

  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;

  // ---------- Toast ("Scooped!") ----------

  let toastTimer = null;
  function toast(message) {
    document.querySelectorAll(".toast").forEach((t) => t.remove());
    const node = el("div", "toast", message);
    document.body.appendChild(node);
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => node.remove(), 1600);
  }

  document.addEventListener("click", (event) => {
    const copy = event.target.closest("[data-copy]");
    if (!copy) return;
    event.preventDefault();
    navigator.clipboard && navigator.clipboard.writeText(copy.getAttribute("data-copy"))
      .then(() => toast("Scooped!"));
  });

  // ---------- Evidence receipts: one open at a time, Esc/outside closes ----------
  // The receipt renders as a plain absolutely-positioned box without JS; with
  // JS it becomes position:fixed and gets measured into the viewport — never
  // clipped by the table's scroll container, flipping above/below the cell by
  // available space, clamped to the viewport edges.

  function closeAllEvidence(except) {
    document.querySelectorAll("details.evidence[open]").forEach((d) => {
      if (d !== except) { d.open = false; delete d.dataset.pinned; }
    });
  }

  function positionEvidence(details) {
    const pop = details.querySelector(".evidence-pop");
    if (!pop) return;
    const vw = innerWidth, vh = innerHeight;
    const width = Math.min(340, vw * 0.86);
    pop.style.position = "fixed";
    pop.style.transform = "none";
    pop.style.width = width + "px";
    pop.style.visibility = "hidden";
    pop.style.left = "0px";
    pop.style.top = "0px";
    // The no-JS stylesheet positions via top/bottom (incl. a bottom: rule on
    // the last row) — clear BOTH or the box gets stretched between them and
    // collapses to its padding.
    pop.style.bottom = "auto";
    pop.style.right = "auto";
    const popHeight = pop.offsetHeight;   // measured after width is set
    const cell = details.getBoundingClientRect();
    const left = Math.min(Math.max(cell.left + cell.width / 2 - width / 2, 12), vw - width - 12);
    const spaceBelow = vh - cell.bottom;
    let top;
    if (spaceBelow >= popHeight + 14 || spaceBelow >= cell.top) {
      top = Math.min(cell.bottom + 8, vh - popHeight - 8);   // open downward
    } else {
      top = Math.max(cell.top - popHeight - 8, 8);           // flip upward
    }
    pop.style.left = left + "px";
    pop.style.top = Math.max(top, 8) + "px";
    pop.style.visibility = "";
  }

  document.addEventListener("toggle", (event) => {
    const details = event.target;
    if (!(details instanceof HTMLElement) || !details.classList.contains("evidence") || !details.open) return;
    closeAllEvidence(details);
    positionEvidence(details);
  }, true);

  document.addEventListener("click", (event) => {
    if (event.target.closest("details.evidence")) return;
    closeAllEvidence();
  });

  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") closeAllEvidence();
  });

  // Fixed positioning drifts when anything scrolls — close instead of chasing.
  // (Scrolling inside the receipt itself is fine and shouldn't dismiss it.)
  addEventListener("scroll", (event) => {
    if (event.target instanceof Element && event.target.closest(".evidence-pop")) return;
    closeAllEvidence();
  }, { passive: true, capture: true });
  addEventListener("resize", () => closeAllEvidence());

  // ---------- Hover to reveal, click to pin (pointer devices only) ----------
  // The pop is a DOM child of its <details>, so pointer containment survives
  // the fixed positioning; the grace timer covers the visual gap between the
  // cell and the pop so the crossing never dismisses it. Touch and keyboard
  // keep the plain <details> toggle.

  if (matchMedia("(hover: hover) and (pointer: fine)").matches) {
    const mouseLike = (event) => !event.pointerType || event.pointerType === "mouse" || event.pointerType === "pen";
    let openTimer = null, closeTimer = null;

    function scheduleClose() {
      clearTimeout(closeTimer);
      closeTimer = setTimeout(() => {
        document.querySelectorAll("details.evidence[open]").forEach((d) => {
          if (!d.dataset.pinned) d.open = false;
        });
      }, 260);
    }

    document.addEventListener("pointerover", (event) => {
      if (!mouseLike(event)) return;
      const details = event.target.closest("details.evidence");
      clearTimeout(openTimer);
      if (!details) return;
      if (details.open) { clearTimeout(closeTimer); return; }  // back over it (or its pop) — keep alive
      openTimer = setTimeout(() => {
        clearTimeout(closeTimer);   // a close scheduled for a sibling must not swallow this open
        details.open = true;        // toggle handler positions it and closes the others
      }, 60);
    });

    document.addEventListener("pointerout", (event) => {
      if (!mouseLike(event)) return;
      const details = event.target.closest("details.evidence");
      if (!details) return;
      const to = event.relatedTarget;
      if (to instanceof Element && to.closest("details.evidence") === details) return;
      clearTimeout(openTimer);
      if (details.open && !details.dataset.pinned) scheduleClose();
    });

    // A hover-opened receipt would close on the very click that shows interest
    // in it — turn that click into a pin instead. Second click unpins & closes.
    document.addEventListener("click", (event) => {
      const summary = event.target.closest("details.evidence > summary");
      if (!summary) return;
      const details = summary.parentElement;
      if (details.open && !details.dataset.pinned) {
        event.preventDefault();
        details.dataset.pinned = "1";
      } else if (details.open) {
        delete details.dataset.pinned;  // default toggle closes it
      } else {
        details.dataset.pinned = "1";   // keyboard open counts as intent — pin it
      }
    });
  }

  // ---------- Search ----------

  const norm = (s) => s.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "")
    .replace(/[^a-z0-9]+/g, " ").trim();

  // "record audio on watchos" → { text: "record audio", platform: "watchOS" }
  function parseQuery(raw) {
    let text = norm(raw);
    let platform = null;
    for (const p of PLATFORMS) {
      for (const alias of p.q) {
        const tail = new RegExp("(?:^|\\s)(?:on\\s+|for\\s+)?" + alias + "$");
        if (tail.test(text)) {
          platform = p.key;
          text = text.replace(tail, "").trim();
          break;
        }
      }
      if (platform) break;
    }
    return { text, platform };
  }

  function subsequence(needle, haystack) {
    let i = 0;
    for (const ch of haystack) if (ch === needle[i]) i += 1;
    return i >= needle.length;
  }

  // Rank tiers: 0 exact · 1 label prefix · 2 alias/word prefix · 3 substring · 4 subsequence
  function tier(query, entry) {
    const label = norm(entry.label || entry.name);
    const names = [label, norm(entry.id || entry.slug || "")].concat((entry.aliases || []).map(norm));
    if (names.includes(query)) return 0;
    if (label.startsWith(query)) return 1;
    if (names.some((n) => n.startsWith(query) || n.split(" ").some((w) => w.startsWith(query)))) return 2;
    if (names.some((n) => n.includes(query))) return 3;
    if (query.length >= 4 && names.some((n) => subsequence(query, n))) return 4;
    return -1;
  }

  let indexPromise = null;
  const loadIndex = () => (indexPromise ||= fetch(BASE + "/api/search-index.json").then((r) => r.json()));

  function attachSearch(form) {
    const input = form.querySelector("input[type=search]");
    let slot = form.parentElement.querySelector("[data-results]");
    if (!slot) {
      slot = el("div", "results-slot");
      slot.setAttribute("data-results", "");
      form.insertAdjacentElement("afterend", slot);
    }
    form.hidden = false;
    let selected = -1;

    function close() { slot.hidden = true; slot.textContent = ""; selected = -1; }

    function render(index, raw) {
      const { text, platform } = parseQuery(raw);
      slot.hidden = false;
      slot.textContent = "";
      const box = el("div", "search-results");
      slot.appendChild(box);

      if (norm(raw) === "sprinkles") {
        const hero = document.querySelector(".hero-sprite");
        if (hero && !reducedMotion && !hero.dataset.party) {
          hero.dataset.party = "1";
          hero.src = BASE + "/swiftee/swiftee-party.png";
          toast("Immaculate. Sprinkles earned.");
        }
      }

      if (!text) { close(); return; }

      const caps = index.capabilities
        .map((c) => ({ c, t: tier(text, c) })).filter((x) => x.t >= 0)
        .sort((a, b) => a.t - b.t || b.c.n - a.c.n || a.c.label.localeCompare(b.c.label))
        .slice(0, 6);
      const pkgs = index.packages
        .map((p) => ({ p, t: tier(text, p) })).filter((x) => x.t >= 0)
        .sort((a, b) => a.t - b.t || a.p.name.localeCompare(b.p.name))
        .slice(0, 3);

      if (!caps.length && !pkgs.length) {
        const empty = el("div", "search-empty");
        empty.appendChild(el("p", null, "Nothing on the menu for that — yet."));
        const p = el("p");
        const a = el("a", null, "Tell us what you were looking for →");
        a.href = BASE + "/about/#contribute";
        p.appendChild(a);
        empty.appendChild(p);
        box.appendChild(empty);
        return;
      }

      if (caps.length) {
        box.appendChild(el("h3", null, "Capabilities"));
        for (const { c } of caps) {
          const a = el("a");
          a.href = BASE + "/can/" + c.id + "/" + (platform ? "?on=" + platform : "");
          a.setAttribute("role", "option");
          a.appendChild(el("span", null, c.label));
          const dots = el("span", "dots");
          for (const key of COLUMN_ORDER) {
            dots.appendChild(el("span", (c.p[key] || 0) > 0 ? "dot dot-on" : "dot"));
          }
          a.appendChild(dots);
          a.appendChild(el("span", "muted", c.n + " package" + (c.n === 1 ? "" : "s")));
          box.appendChild(a);
        }
      }
      if (pkgs.length) {
        box.appendChild(el("h3", null, "Packages"));
        for (const { p } of pkgs) {
          const a = el("a");
          a.href = BASE + "/package/" + p.slug + "/";
          a.setAttribute("role", "option");
          a.appendChild(el("span", null, p.name));
          if (p.fp) a.appendChild(el("span", "pill pill-builtin", "built in"));
          a.appendChild(el("span", "muted", p.caps + " capabilit" + (p.caps === 1 ? "y" : "ies") + " mapped"));
          box.appendChild(a);
        }
      }
    }

    input.addEventListener("focus", () => loadIndex(), { once: true });
    input.addEventListener("input", () => {
      loadIndex().then((index) => render(index, input.value)).catch(() => close());
    });
    input.addEventListener("keydown", (event) => {
      const options = Array.from(slot.querySelectorAll("a"));
      if (event.key === "Escape") { close(); input.blur(); return; }
      if (!options.length) return;
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        selected = event.key === "ArrowDown"
          ? Math.min(selected + 1, options.length - 1)
          : Math.max(selected - 1, 0);
        options.forEach((o, i) => o.classList.toggle("selected", i === selected));
        options[selected].scrollIntoView({ block: "nearest" });
      } else if (event.key === "Enter" && selected >= 0) {
        event.preventDefault();
        options[selected].click();
      }
    });
    document.addEventListener("click", (event) => {
      if (!form.contains(event.target) && !slot.contains(event.target)) close();
    });
    return input;
  }

  const searchInputs = Array.from(document.querySelectorAll("form[data-search]")).map(attachSearch);

  // `/` focuses the nearest search box from anywhere.
  document.addEventListener("keydown", (event) => {
    if (event.key !== "/" || event.target.closest("input, textarea, select")) return;
    const input = searchInputs[0];
    if (input) { event.preventDefault(); input.focus(); }
  });

  // ---------- ?on= platform focus + the near-miss card ----------

  const table = document.querySelector("table.truth-table[data-capability]");
  const params = new URLSearchParams(location.search);
  const onParam = params.get("on");
  if (table && onParam) {
    const platform = PLATFORMS.find((p) => p.key.toLowerCase() === onParam.toLowerCase()
      || p.q.includes(onParam.toLowerCase()));
    if (platform) focusPlatform(table, platform);
  }

  function focusPlatform(table, platform) {
    const column = COLUMN_ORDER.indexOf(platform.key) + 1; // +1 for the name column

    // Ask the user's own question back in the tab title.
    const capabilityName = document.querySelector(".page-head h1 em");
    if (capabilityName) {
      document.title = "Can Swift packages do " + capabilityName.textContent + " on " + platform.label + "? — SwiftServe";
    }

    // Tint the focused column.
    table.querySelectorAll("tr").forEach((row) => {
      const cell = row.children[column];
      if (cell) cell.classList.add("col-focus");
    });

    // Rank rows: serves here → conditional → near-miss → unknown → nowhere.
    const body = table.tBodies[0];
    const rows = Array.from(body.rows);
    function rank(row) {
      const cell = row.children[column];
      if (!cell) return 5;
      if (cell.classList.contains("cell-good")) return 0;
      if (cell.classList.contains("cell-warn")) return 1;
      const servesElsewhere = (row.dataset.supported || "").trim().length > 0;
      if (cell.classList.contains("cell-low")) return servesElsewhere ? 2 : 4;
      return 3;
    }
    rows.map((row, i) => ({ row, i, r: rank(row) }))
      .sort((a, b) => a.r - b.r || a.i - b.i)
      .forEach(({ row }) => body.appendChild(row));

    // The flagship state: the best near-miss, told warmly, with the receipt.
    const nearMiss = rows.map((row) => ({ row, r: rank(row) })).filter((x) => x.r === 2)
      .map((x) => x.row)[0];
    const slot = document.querySelector("[data-near-miss]");
    if (!nearMiss || !slot) return;

    const name = nearMiss.querySelector("th a")?.textContent || "This package";
    const served = (nearMiss.dataset.supported || "").split(" ").filter(Boolean);
    const cell = nearMiss.children[column];
    const guard = cell?.querySelector(".evidence-guard")?.textContent;
    const link = cell?.querySelector(".evidence-link")?.getAttribute("href");
    const location_ = cell?.querySelector(".evidence-loc")?.textContent;
    const servesHere = rows.filter((row) => rank(row) === 0).length;

    const card = el("div", "near-miss");
    const img = el("img");
    img.src = BASE + "/swiftee/swiftee-squeeze.png";
    img.alt = "";
    img.width = 72; img.height = 72;
    card.appendChild(img);
    const body_ = el("div");
    body_.appendChild(el("h2", null, "So close."));
    const fact = el("p");
    fact.append(el("strong", null, name),
      " serves this on " + served.join(", ") + " — ",
      el("strong", null, "not " + platform.label + "."));
    body_.appendChild(fact);
    if (served.length) {
      const pills = el("div", "serves-pills");
      served.forEach((s) => pills.appendChild(el("span", null, s)));
      body_.appendChild(pills);
    }
    if (guard) {
      const receipt = el("p");
      receipt.append("The line that decides it: ", el("code", null, guard));
      if (location_) receipt.append(" — " + location_);
      if (link) {
        const a = el("a", "evidence-link", " View on GitHub →");
        a.href = link;
        a.rel = "noopener";
        receipt.append(" ", a);
      }
      body_.appendChild(receipt);
    }
    if (servesHere > 0) {
      body_.appendChild(el("p", null,
        servesHere + " package" + (servesHere === 1 ? " does" : "s do") + " serve this on " + platform.label + " ↓"));
    }
    card.appendChild(body_);
    slot.appendChild(card);
    slot.hidden = false;
  }
})();
