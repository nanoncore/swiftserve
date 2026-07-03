"use strict";
// SwiftServe — immersive entry for /on/visionos. Progressive enhancement
// only: the flat page is complete without this file, and the entry chip
// appears only where an immersive session can actually start (visionOS
// Safari, in practice). Everyone else — including JS-off — sees nothing.

(function () {
  const slot = document.querySelector("[data-xr]");
  if (!slot || !navigator.xr || !navigator.xr.isSessionSupported) return;

  const styleHref = (document.querySelector('link[rel="stylesheet"][href*="styles.css"]') || { getAttribute: () => "/styles.css" })
    .getAttribute("href");
  const BASE = styleHref.replace(/\/styles\.css(\?.*)?$/, "");
  // Same content-derived ?v= the shared assets carry — a changed xr.js must
  // never be served from a stale cache.
  const VERSION = (styleHref.match(/\?v=[^&]*/) || [""])[0];

  navigator.xr.isSessionSupported("immersive-vr").then(function (supported) {
    if (!supported) return;

    // Preload the scene module and the feed NOW, so the click handler only
    // awaits settled promises — requestSession stays inside the
    // user-activation window.
    const modulePromise = import(BASE + "/xr.js" + VERSION);
    const feedPromise = fetch(BASE + "/api/on/visionos.json").then(function (r) {
      if (!r.ok) throw new Error("feed " + r.status);
      return r.json();
    });

    feedPromise.then(function (feed) {
      const card = document.createElement("div");
      card.className = "xr-invite";

      const text = document.createElement("div");
      const head = document.createElement("p");
      head.className = "xr-invite-head";
      head.textContent = "Walk the fence line";
      const body = document.createElement("p");
      body.className = "xr-invite-body";
      body.textContent = "This page as a place: the capability wall, the OS shelf, and "
        + feed.fenced.length + " packages nailed to the fence with their compiler receipts. "
        + "Pinch and drag to spin the yard; look at anything and pinch to open it.";
      text.appendChild(head);
      text.appendChild(body);

      const button = document.createElement("button");
      button.type = "button";
      button.className = "xr-enter";
      button.textContent = "Step inside →";
      button.addEventListener("click", function () {
        button.disabled = true;
        Promise.all([modulePromise, feedPromise])
          .then(function (loaded) { return loaded[0].default(feed, BASE); })
          .catch(function () { body.textContent = "Couldn't start the immersive scene — the flat page has everything."; })
          .finally(function () { button.disabled = false; });
      });

      card.appendChild(text);
      card.appendChild(button);
      slot.appendChild(card);
      slot.hidden = false;
    }).catch(function () { /* no feed, no invite — the page stands alone */ });
  }).catch(function () {});
})();
