// clickbait's page: the companion on a spring, its colour by section and its pills; the hero's
// windows you can drag; typing bubbles; the ring of screens that turns as you scroll; the colour
// field; the player; the cabinet and its easter eggs (sounds made here,
// no files); the clock. Everything reads without it.
(() => {
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  // Smooth scrolling: the wheel and the menu's links glide. Touch keeps its own scrolling; reduced motion gets none.
  const lenis = !reduce && window.Lenis ? new Lenis({ autoRaf: true, anchors: { offset: -40 }, syncTouch: false }) : null;
  const colours = { azure: "#007FFF", pumpkin: "#FF7518", lavender: "#B57EDC", strawberry: "#FA385C", shamrock: "#009E61" };

  // ---- The companion: a rounded triangle hanging off the pointer on a spring ----
  const companion = document.querySelector(".companion");
  const pill = companion.querySelector(".cpill");
  let target = { x: -100, y: -100 }, pos = { x: -100, y: -100 }, vel = { x: 0, y: 0 }, running = false;
  const offset = { x: 18, y: 22 };
  function step() {
    const k = 0.09, damping = 0.78;
    vel.x = (vel.x + (target.x + offset.x - pos.x) * k) * damping;
    vel.y = (vel.y + (target.y + offset.y - pos.y) * k) * damping;
    pos.x += vel.x; pos.y += vel.y;
    companion.style.transform = `translate(${pos.x}px, ${pos.y}px)`;
    if (Math.abs(vel.x) + Math.abs(vel.y) > 0.05) requestAnimationFrame(step); else running = false;
  }
  addEventListener("pointermove", (event) => {
    if (event.pointerType !== "mouse") return;
    target = { x: event.clientX, y: event.clientY };
    companion.classList.add("on");
    if (reduce) { pos = { x: target.x + offset.x, y: target.y + offset.y }; companion.style.transform = `translate(${pos.x}px, ${pos.y}px)`; return; }
    if (!running) { running = true; requestAnimationFrame(step); }
  });
  document.addEventListener("pointerleave", () => companion.classList.remove("on"));

  // Its colour: the innermost coloured thing at the middle of the screen.
  const coloured = [...document.querySelectorAll("[data-colour]")].reverse();
  function recolour() {
    const middle = innerHeight / 2;
    const here = coloured.find((s) => { const r = s.getBoundingClientRect(); return r.top <= middle && r.bottom >= middle; });
    if (here) companion.style.setProperty("--c", colours[here.dataset.colour]);
  }

  // Its pills: a few words beside it over things with something to say.
  document.querySelectorAll("[data-pill]").forEach((el) => {
    el.addEventListener("pointerenter", () => { pill.textContent = el.dataset.pill; companion.classList.add("talking"); });
    el.addEventListener("pointerleave", () => companion.classList.remove("talking"));
  });

  // ---- The hero's windows: pick one up and put it somewhere else ----
  document.querySelectorAll(".w.drag").forEach((win) => {
    let start = null, moved = { x: 0, y: 0 };
    win.addEventListener("pointerdown", (e) => {
      start = { x: e.clientX - moved.x, y: e.clientY - moved.y };
      win.setPointerCapture(e.pointerId); win.classList.add("held");
    });
    win.addEventListener("pointermove", (e) => {
      if (!start) return;
      moved = { x: e.clientX - start.x, y: e.clientY - start.y };
      win.style.translate = `${moved.x}px ${moved.y}px`;
    });
    const drop = () => { start = null; win.classList.remove("held"); };
    win.addEventListener("pointerup", drop); win.addEventListener("pointercancel", drop);
  });

  // ---- Typing bubbles: each types its line when it comes into view ----
  const bubbles = [...document.querySelectorAll(".bubble[data-type]")];
  if (!reduce && "IntersectionObserver" in window) {
    bubbles.forEach((b) => { b.querySelector("span").textContent = ""; });
    const typer = new IntersectionObserver((entries) => entries.forEach((e) => {
      if (!e.isIntersecting) return;
      typer.unobserve(e.target);
      const span = e.target.querySelector("span"), text = e.target.dataset.type;
      let i = 0; const t = setInterval(() => { span.textContent = text.slice(0, ++i); if (i >= text.length) clearInterval(t); }, 45);
    }), { threshold: 0.6 });
    bubbles.forEach((b) => typer.observe(b));
  }

  // ---- The ring: its own screens, edge-on at first, turning to face you as you scroll ----
  const ring = document.querySelector(".ring"), stage = document.querySelector(".ring-stage");
  const shots = ["home", "chat", "card-followup", "keys", "shelf", "sleep", "setup-welcome", "sky-30", "internet-switch", "setup-ready", "ask"];
  const count = 22;
  const tiles = Array.from({ length: count }, (_, i) => {
    const t = document.createElement("div"); t.className = "rt";
    const img = new Image(); img.src = `assets/ui/${shots[i % shots.length]}.png`; img.alt = ""; img.loading = "lazy";
    t.append(img); ring.append(t); return t;
  });
  let ringShown = -1, ringGoal = 0, ringGliding = false;
  function drawRing(p) {
    const radius = Math.min(innerWidth, innerHeight) * (innerWidth < 640 ? 0.42 : 0.4);
    const spin = p * 120 - 40, face = Math.min(1, p * 1.6);
    tiles.forEach((t, i) => {
      const a = (i / count) * 360 + spin, rad = (a * Math.PI) / 180;
      t.style.transform = `perspective(900px) translate3d(${(Math.cos(rad) * radius).toFixed(1)}px, ${(Math.sin(rad) * radius).toFixed(1)}px, 0) rotate(${(a + 90).toFixed(2)}deg) rotateY(${((1 - face) * 82).toFixed(2)}deg) scale(${(0.6 + face * 0.4).toFixed(3)})`;
      t.style.opacity = (0.25 + face * 0.75).toFixed(3);
    });
  }
  function glide() {
    ringShown += (ringGoal - ringShown) * (reduce || lenis ? 1 : 0.12); // eases each frame, unless Lenis already glides the scroll
    if (Math.abs(ringGoal - ringShown) < 0.0005) ringShown = ringGoal;
    drawRing(ringShown);
    ringGliding = ringShown !== ringGoal;
    if (ringGliding) requestAnimationFrame(glide);
  }
  function turnRing() {
    const r = stage.getBoundingClientRect();
    ringGoal = Math.min(1, Math.max(0, -r.top / (r.height - innerHeight)));
    if (ringShown < 0) { ringShown = ringGoal; drawRing(ringShown); return; }
    if (!ringGliding) { ringGliding = true; requestAnimationFrame(glide); }
  }

  let ticking = false;
  function onScroll() {
    if (ticking) return; ticking = true;
    requestAnimationFrame(() => { recolour(); turnRing(); ticking = false; });
  }
  addEventListener("scroll", onScroll, { passive: true });
  addEventListener("resize", onScroll);
  onScroll();

  // ---- The colour field: the whole screen turns the colour you pick ----
  const field = document.querySelector(".field");
  const tabs = [...document.querySelectorAll(".swatches [role=tab]")];
  const sayName = document.querySelector(".says-name"), sayText = document.querySelector(".says-text");
  // Where each colour looks in the triptych (fractions of the painting), with the picture at one fixed zoom
  const stops = { azure: [0.30, 0.17], pumpkin: [0.44, 0.10], lavender: [0.58, 0.17], strawberry: [0.72, 0.16], shamrock: [0.87, 0.12] }; // left to right in tab order: four even steps across the upper landscape, garden to hell
  const pan = field.querySelector(".pan"), RATIO = 4098 / 7200;
  let looking = "azure";
  function aim() {
    const w = field.clientWidth, h = field.clientHeight, phone = w / h < 0.8;
    const pw = phone ? (h / RATIO) * 2.6 : Math.max(w / 0.31, h / RATIO), ph = pw * RATIO; // about a third of the painting across (on phones, the upper landscape only)
    const [fx, fy] = stops[looking];
    const clamp = (v, lo, hi = 0) => Math.min(hi, Math.max(lo, v));
    // the spot sits right of the words; on phones, just below them (the painting may start lower: the wash covers the top)
    const tx = clamp(w * (phone ? 0.5 : 0.74) - fx * pw, w - pw), ty = clamp(h * (phone ? 0.86 : 0.52) - fy * ph, h - ph, phone ? h * 0.6 : 0);
    field.style.setProperty("--pw", `${pw}px`); field.style.setProperty("--tx", `${tx}px`); field.style.setProperty("--ty", `${ty}px`);
  }
  addEventListener("resize", aim);
  function choose(tab) {
    tabs.forEach((t) => { t.setAttribute("aria-selected", String(t === tab)); t.tabIndex = t === tab ? 0 : -1; });
    field.style.setProperty("--field", tab.dataset.swatch);
    looking = tab.dataset.name; aim();
    field.dataset.colour = tab.dataset.name; recolour(); // the companion by your cursor takes the colour too
    sayName.textContent = tab.dataset.name; sayText.textContent = tab.dataset.says;
  }
  tabs.forEach((tab, i) => {
    tab.addEventListener("click", () => choose(tab));
    tab.addEventListener("keydown", (e) => {
      const next = e.key === "ArrowRight" ? 1 : e.key === "ArrowLeft" ? -1 : 0;
      if (next) { const t = tabs[(i + next + tabs.length) % tabs.length]; choose(t); t.focus(); }
    });
  });
  choose(tabs[0]);

  // ---- Sounds, made on the spot ----
  let audio;
  function ctx() { audio ??= new AudioContext(); if (audio.state === "suspended") audio.resume(); return audio; } // made on a hover before any click, it starts suspended
  function pop() {
    const a = ctx(), o = a.createOscillator(), g = a.createGain();
    o.frequency.setValueAtTime(900, a.currentTime); o.frequency.exponentialRampToValueAtTime(180, a.currentTime + 0.09);
    g.gain.setValueAtTime(0.25, a.currentTime); g.gain.exponentialRampToValueAtTime(0.001, a.currentTime + 0.12);
    o.connect(g).connect(a.destination); o.start(); o.stop(a.currentTime + 0.13);
  }


  // ---- YouTube's own player, official uploads only, on the privacy-enhanced host ----
  // One thing plays at a time: the player, a folder's preview, or an open folder.
  let ytReady;
  const loadYT = () => ytReady ??= new Promise((resolve) => {
    window.onYouTubeIframeAPIReady = () => resolve(window.YT);
    const s = document.createElement("script"); s.src = "https://www.youtube.com/iframe_api"; document.head.append(s);
  });
  const players = new Set();
  function quietOthers(keep) { players.forEach((p) => { if (p !== keep) try { p.pauseVideo(); } catch {} }); if (keep !== music) setPlaying(false); }
  async function makePlayer(el, events = {}, vars = {}) {
    const YT = await loadYT();
    return new Promise((resolve) => {
      const p = new YT.Player(el, {
        host: "https://www.youtube-nocookie.com", width: "100%", height: "100%",
        playerVars: { playsinline: 1, rel: 0, modestbranding: 1, cc_load_policy: 0, iv_load_policy: 3, ...vars },
        events: { onReady: () => { players.add(p); resolve(p); }, ...events },
      });
    });
  }
  // Sound on hover needs one click somewhere on the page first; browsers allow muted play before that.
  const mayPlaySound = () => navigator.userActivation?.hasBeenActive ?? true;

  // ---- The cabinet ----
  const david = document.querySelector(".david");
  const popDavid = () => { if (david.classList.contains("popped")) return; david.classList.add("popped"); pop(); setTimeout(() => david.classList.remove("popped"), 1800); };
  david.addEventListener("pointerenter", popDavid);
  david.addEventListener("click", popDavid);
  const jersey = document.querySelector(".jersey");
  jersey.addEventListener("click", () => { jersey.classList.remove("hit"); void jersey.offsetWidth; jersey.classList.add("hit"); });

  // what plays in the little televisions: official uploads on YouTube
  const folders = {
    films: { title: "films i'd rewatch", items: [["The Prestige", "trailer", "RLtaA9fFNXU"], ["Eternal Sunshine of the Spotless Mind", "trailer", "07-QBnEkgXU"], ["Baashha (1995)", "a scene", "-tkows0DK9o"], ["Dorothy, Karthik Subbaraj", "trailer", "jcBG6U5iX8Y"]] },
    crime: { title: "crime classics", items: [["Heat (1995)", "trailer", "14oNcFxiVaQ"], ["Goodfellas", "trailer", "2ilzidi_J8Q"], ["The Godfather", "trailer", "eZHsmb4ezEk"], ["Taxi Driver", "trailer", "T5IligQP7Fo"]] },
    tamil: { title: "tamil cinema", items: [["Thenpandi Cheemayile, Nayagan", "song", "q9AJ0ITDL30"], ["Annamalai", "a scene", "fyybq67IF60"], ["Bloody Valentine, Anirudh", "song", "qgv9VBoK8po"]] },
    internet: { title: "internet artefacts", items: [["Like a Boss", "the original", "NisCkxU544c", "NBfy3pznTUKTN4nM4C"], ["Nyan Cat", "the original", "2yJgwwDcgV8", "ktW8FqKodoPUk"], ["South Park", "a clip", "RcoGzT9QrTI", "xTiTnKKeB9WDVpdnoc"], ["Rick and Morty", "a clip", "UV4c_PY-UgE", "3ov9jZcnT6S547u036"]] },
  };

  // ---- Little televisions all over the desktop: muted, and loud only while you hover ----
  const notes = {
    "RLtaA9fFNXU": "are you watching closely?", "07-QBnEkgXU": "meet me in montauk", "-tkows0DK9o": "one sun. one moon. one super star.",
    "jcBG6U5iX8Y": "two boys, one whistle, zero chill", "14oNcFxiVaQ": "the diner scene lives rent free", "2ilzidi_J8Q": "funny how?",
    "eZHsmb4ezEk": "i believe in america", "T5IligQP7Fo": "you talkin' to me?", "q9AJ0ITDL30": "ilaiyaraaja. that's it. that's the note.",
    "fyybq67IF60": "thalaivar has entered the chat", "qgv9VBoK8po": "congrats on kavya, bro", "NisCkxU544c": "like a boss, obviously",
    "2yJgwwDcgV8": "nyan nyan nyan nyan", "RcoGzT9QrTI": "screw you guys", "UV4c_PY-UgE": "wubba lubba dub dub",
  };
  const pool = Object.values(folders).flatMap((f) => f.items.filter(([, , id]) => id).map(([name, , id]) => ({ name, id })));
  for (let i = pool.length - 1; i > 0; i--) { const k = Math.floor(Math.random() * (i + 1)); [pool[i], pool[k]] = [pool[k], pool[i]]; }
  let nextInPool = 0;
  const takeNext = () => pool[nextInPool++ % pool.length];
  let musicWasPlaying = false;

  // Hero windows play on their own, muted; every other window waits for the pointer. Pointing at any window
  // opens it up a little (full title showing) and brings its sound in; leaving settles it back.
  // A tab in the background gives up its players (and the music pauses), so a page left open in
  // another tab never holds the Mac's video decoders; coming back starts the visible ones again.
  const tvSyncs = [];
  document.querySelectorAll(".tv-slot").forEach((slot) => {
    const auto = !!slot.closest(".hero");
    let item = takeNext(), yt = null, at = 6, hovering = false, onScreen = false, starting = false, stuck = 0, nudged = false, showing = 0;
    const musicOn = () => player.classList.contains("playing"); // YouTube may pause other players for the music: don't fight it
    const tv = document.createElement("figure");
    tv.className = "w tv"; tv.style.setProperty("--r", `${(Math.random() * 7 - 3.5).toFixed(1)}deg`);
    if (!auto) slot.style.setProperty("--dy", `${Math.round(Math.random() * 110 - 30)}px`); // scattered, never touching
    tv.innerHTML = `<div class="tb"><i></i><i></i><i></i><span></span></div><div class="screen"><div></div><div class="catch"></div></div>`;
    slot.append(tv);
    const label = tv.querySelector(".tb span"), catcher = tv.querySelector(".catch"), screenEl = tv.querySelector(".screen");
    const name = () => { label.textContent = item.name.toLowerCase(); screenEl.style.setProperty("--poster", `url(https://i.ytimg.com/vi/${item.id}/hq2.jpg)`); tv.classList.remove("live"); }; // a frame from the video, not the upload's title card
    name();
    // Every window on screen plays, muted. Hero ones are seen; the others stay hidden behind their still until
    // pointed at. (YouTube shows a big pause button over any video's first 5 s, started or resumed, so a window
    // can't start on hover without it: it has already played through it, out of sight.)
    const seen = () => auto || hovering;
    let since = 0, last = -1, rush = false; // when the current stretch of playing began, the last player state, and "show it the moment it plays"
    const reveal = () => { clearTimeout(showing); if (yt?.getPlayerState?.() === 1 && seen()) showing = setTimeout(() => tv.classList.add("live"), rush ? 300 : Math.max(300, since + 5200 - Date.now())); };
    const load = () => { // the current video, from where this window left it
      yt.loadVideoById({ videoId: item.id, startSeconds: at });
      watch();
    };
    const skip = () => { if (!yt) return; item = takeNext(); at = 6; name(); load(); };
    const watch = () => { // a window that should be playing but hasn't started in 9 s: nudge it once, then move on
      clearTimeout(stuck);
      stuck = setTimeout(() => {
        if (!yt || !onScreen || musicOn() && !hovering || yt.getPlayerState?.() === 1) return;
        if (!nudged) { nudged = true; load(); } else { nudged = false; skip(); }
      }, 9000);
    };
    async function start() {
      if (yt || starting) return;
      starting = true;
      const p = await makePlayer(tv.querySelector(".screen > div:not(.catch)"), {
        onStateChange: (e) => {
          // the picture shows only while it plays, past YouTube's own pause button
          if (e.data === 1) {
            if (last !== 1 && last !== 3) since = Date.now(); // a fresh start or a resume, not a buffering blip
            nudged = false; try { p.unloadModule("captions"); } catch {} reveal();
          }
          else if (e.data !== 3) { clearTimeout(showing); tv.classList.remove("live"); }
          if (e.data === 2 && onScreen && !(musicOn() && !hovering)) load();
          if (e.data === 0) skip();
          last = e.data;
        },
        onError: skip, // blocked here: next one
      }, { controls: 0, disablekb: 1, fs: 0 });
      starting = false;
      players.delete(p); // the windows run alongside everything else, muted unless hovered
      yt = p; p.mute(); load();
      if (hovering && mayPlaySound()) loud(true);
      if (!onScreen) stop(); // scrolled away while it was loading
    }
    // A window off screen gives its player up entirely: a Mac's Chrome only decodes so many videos at once.
    function stop() {
      clearTimeout(stuck); clearTimeout(showing);
      if (!yt) return;
      at = Math.max(6, yt.getCurrentTime?.() || at);
      try { yt.destroy(); } catch {}
      yt = null; last = -1; tv.classList.remove("live");
      if (!screenEl.querySelector(":scope > div:not(.catch)")) screenEl.prepend(document.createElement("div"));
    }
    const loud = (on) => {
      if (!yt) return;
      if (on) {
        musicWasPlaying = musicOn(); if (musicWasPlaying) music.pauseVideo();
        yt.unMute(); yt.setVolume(80);
      } else { yt.mute(); if (musicWasPlaying) { music.playVideo(); musicWasPlaying = false; } }
    };
    const say = () => {
      pill.textContent = mayPlaySound() ? (notes[item.id] || "shh, it's the good part") : "click once, then i'll talk";
      companion.classList.add("talking");
    };
    const enter = () => {
      hovering = true; tv.classList.add("open"); say();
      if (!yt) { rush = true; start(); return; }
      const state = yt.getPlayerState?.();
      if (state !== 1 && state !== 3) { rush = true; at = Math.max(6, yt.getCurrentTime?.() || at); load(); } // paused out of sight (Chrome saves power on hidden video): restart it now
      reveal();
      if (mayPlaySound()) loud(true);
    };
    const leave = () => {
      hovering = false; rush = false; tv.classList.remove("open"); companion.classList.remove("talking");
      if (yt) { loud(false); if (!auto) { clearTimeout(showing); tv.classList.remove("live"); } } // back behind its still, playing on muted
    };
    catcher.addEventListener("pointerenter", (e) => { if (e.pointerType !== "touch") enter(); });
    catcher.addEventListener("pointerleave", (e) => { if (e.pointerType !== "touch") leave(); });
    catcher.addEventListener("click", (e) => {
      if (e.pointerType === "touch") { hovering ? leave() : enter(); return; } // no hover on phones: a tap does it
      if (hovering) { say(); loud(true); } // the click itself unlocks sound
    });
    let inView = false;
    const sync = () => {
      onScreen = inView && !document.hidden;
      if (onScreen) start(); else { if (hovering) leave(); stop(); }
    };
    tvSyncs.push(sync);
    new IntersectionObserver(([entry]) => { inView = entry.isIntersecting; sync(); }, { rootMargin: "150px" }).observe(tv);
  });

  // ---- The player: it plays right here, and you can drag it anywhere ----
  const tracks = [
    // the official YouTube Music releases (album audio, cover art). Labels block them on localhost, so a
    // couple fall back to the band's own live upload there; on a real domain the release always plays.
    ["Enter Sandman", "Metallica", ["CHIWNDAwTqQ", "87by1DjfxLw"]], ["Loser", "Tame Impala", ["MX7FSAnRPug"]], ["Under the Bridge", "Red Hot Chili Peppers", ["4UnU3r0M3zg"]],
    ["Master of Puppets", "Metallica", ["E0ozmU9cJDg", "Mt5MCfJ5tZQ"]], ["Bad", "Michael Jackson", ["-DlMoJ2V6uk"]], ["Express Yourself", "N.W.A.", ["md4ujXhHzLs"]], ["I Will Survive", "Gloria Gaynor", ["nXMPx4DDVWM", "tB-c_rWj1H8"]],
    ["Like a Boss", "The Lonely Island", ["LECMbSipNu0", "NisCkxU544c"]],
  ];
  let attempt = 0, failedInARow = 0;
  let index = Math.floor(Math.random() * tracks.length), music, pausedForTab = false;
  const player = document.querySelector(".player"), screen = player.querySelector(".pl-screen");
  const title = player.querySelector(".track-title"), artist = player.querySelector(".track-artist"), playButton = player.querySelector(".play");
  function setPlaying(on) {
    player.classList.toggle("playing", on);
    playButton.textContent = on ? "❚❚" : "▶"; playButton.setAttribute("aria-label", on ? "Pause" : "Play");
  }
  function show() {
    const [t, a, ids] = tracks[index]; title.textContent = t; artist.textContent = a;
    screen.style.setProperty("--cover", `url(https://i.ytimg.com/vi/${ids[0]}/mqdefault.jpg)`); // the release's own cover
  }
  async function playTrack(next = 0) {
    attempt = next;
    music ??= await makePlayer(document.getElementById("pl-yt"), {
      onError: () => {
        // this version won't play here: try the track's next version, then the next track, and stop after a full lap
        if (attempt + 1 < tracks[index][2].length) return playTrack(attempt + 1);
        if (++failedInARow >= tracks.length) { setPlaying(false); return; }
        index = (index + 1) % tracks.length; show(); playTrack();
      },
      onStateChange: (e) => {
        if (e.data === 1) { failedInARow = 0; quietOthers(music); setPlaying(true); }
        else if (e.data === 2) setPlaying(false);
        else if (e.data === 0) { index = (index + 1) % tracks.length; show(); playTrack(); }
      },
    });
    music.unMute(); music.loadVideoById(tracks[index][2][attempt]);
  }
  playButton.addEventListener("click", () => {
    if (player.classList.contains("playing")) { music.pauseVideo(); return; }
    if (music && tracks[index][2].includes(music.getVideoData?.().video_id)) { music.playVideo(); return; }
    playTrack();
  });
  const skip = (d) => { index = (index + d + tracks.length) % tracks.length; show(); if (player.classList.contains("playing")) playTrack(); };
  player.querySelector(".next").addEventListener("click", () => skip(1));
  player.querySelector(".prev").addEventListener("click", () => skip(-1));
  show();
  const grip = player.querySelector(".grab");
  grip.addEventListener("pointerdown", (e) => {
    if (getComputedStyle(player).position !== "fixed") return; // tablets and phones: it sits in the page
    const start = { x: e.clientX, y: e.clientY }, box = player.getBoundingClientRect();
    grip.setPointerCapture(e.pointerId);
    const move = (m) => {
      const x = Math.min(Math.max(0, box.left + m.clientX - start.x), innerWidth - box.width);
      const y = Math.min(Math.max(30, box.top + m.clientY - start.y), innerHeight - 40);
      Object.assign(player.style, { left: `${x}px`, top: `${y}px`, right: "auto", bottom: "auto" });
    };
    grip.addEventListener("pointermove", move);
    grip.addEventListener("pointerup", () => grip.removeEventListener("pointermove", move), { once: true });
  });

  // ---- Demo windows: each loops through what ClickBait does, only while on screen ----
  // A step names what the triangle points at (or "home", by the cursor), its pill, how long it holds,
  // and whether the keys are down. The window's data-step drives the rest in CSS.
  const demos = {
    walk: [
      { at: null, ms: 1100 },
      { at: ".sf-history", pill: "1 of 3 · open History", ms: 1500 },
      { at: ".menu .hot", pill: "2 of 3 · click Clear History…", ms: 1700 },
      { at: ".sf-clear", pill: "3 of 3 · click Clear History", ms: 1700 },
      { at: null, pill: "✓ history cleared", ms: 1500 },
    ],
    point: [ // as on the site: idle, listening, thinking, pointing, back
      { at: null, tone: "azure", ms: 1400 },
      { at: null, tone: "pumpkin", keys: true, html: '<span class="wave"><i></i><i></i><i></i><i></i></span>Listening…', ms: 2300, step: 1 },
      { at: null, tone: "pumpkin", spin: true, pill: "“how do I share this?”", ms: 1700, step: 4 },
      { at: ".pg-share", ax: 0.2, tone: "azure", pill: "Share’s up here!", ms: 3200, step: 2 },
      { at: null, tone: "azure", ms: 1000, step: 0 },
    ],
    orders: [0, 1, 2, 3, 4, 5].map((n) => ({ ms: 1600, step: n })), // each order lit in turn, with what it did
    circle: [ // a red loop round the picture, then a tour of the planets
      { ms: 900 }, { ms: 2000 },
      { pt: [246, 132, 20], pill: "~ jupiter", ms: 1700, step: 2 }, { pt: [302, 96, 14], pill: "~ saturn", ms: 1700, step: 2 },
      { pt: [164, 148, 9], pill: "~ earth", ms: 1700, step: 2 }, { pt: [372, 48, 10], pill: "~ neptune", ms: 1700, step: 2 },
    ],
    chat: [
      { ms: 900 }, { keys: true, ms: 160 }, { ms: 140, step: 2 }, { keys: true, ms: 160, step: 2 }, { ms: 3200, step: 3 }, { ms: 600, step: 4 },
    ],
    explain: [
      { ms: 900 }, { ms: 900 }, { keys: true, ms: 220, step: 2 }, { ms: 3200, step: 3 }, { ms: 500, step: 4 },
    ],
  };
  const offsetIn = (el, root) => { let x = 0, y = 0; for (; el && el !== root; el = el.offsetParent) { x += el.offsetLeft; y += el.offsetTop; } return { x, y }; };
  document.querySelectorAll(".demo[data-demo]").forEach((root) => {
    const steps = demos[root.dataset.demo], pointer = root.querySelector(".pointer"), pill = root.querySelector(".pill"), cur = root.querySelector(".cur");
    let i = 0, timer = 0;
    const home = () => ({ x: root.clientWidth * 0.18, y: root.clientHeight - 70 });
    if (cur) { const h = home(); root.style.setProperty("--cx", `${h.x}px`); root.style.setProperty("--cy", `${h.y}px`); }
    const history = root.querySelector(".sf-history");
    if (history) root.style.setProperty("--mx", `${Math.min(history.offsetLeft - 8, root.clientWidth - 240)}px`);
    const show = (s, n) => {
      root.dataset.step = s.step ?? n;
      if (root.dataset.demo === "orders") root.querySelectorAll(".ord li").forEach((li, k) => li.classList.toggle("on", k === root.dataset.step * 1));
      root.classList.toggle("press", !!s.keys);
      root.classList.toggle("spin", !!s.spin);
      if (s.tone) root.style.setProperty("--c", `var(--${s.tone})`);
      if (!pointer) return;
      const target = s.at && root.querySelector(s.at), sv = s.pt && root.querySelector(".sv");
      let x, y;
      if (sv) { const o = offsetIn(sv, root), k = sv.offsetWidth / 400; x = o.x + (s.pt[0] + s.pt[2] * 0.6) * k; y = o.y + (s.pt[1] + s.pt[2] * 0.6) * k; } // a spot on the picture, in its own units
      else if (target) { const o = offsetIn(target, root); x = o.x + target.offsetWidth * (s.ax ?? 0.55); y = o.y + target.offsetHeight * 0.55; }
      else { const h = home(); x = h.x + 16; y = h.y + 2; } // tucked by the cursor
      pointer.style.setProperty("--px", `${x}px`); pointer.style.setProperty("--py", `${y}px`);
      pill.classList.toggle("on", !!(s.pill || s.html));
      if (s.pill || s.html) {
        if (s.html) pill.innerHTML = s.html; else pill.textContent = s.pill;
        const right = x + 26 + pill.offsetWidth < root.clientWidth - 10; // flip to the left near the window's edge
        pill.style.setProperty("--qx", `${right ? x + 26 : x - pill.offsetWidth - 6}px`); pill.style.setProperty("--qy", `${y + 22}px`);
      }
    };
    const tick = () => { show(steps[i], i); timer = setTimeout(tick, steps[i].ms); i = (i + 1) % steps.length; };
    if (reduce) { const still = { walk: 2, point: 3, chat: 4, explain: 3, circle: 2, orders: 2 }[root.dataset.demo]; show(steps[still], still); return; } // one telling moment, held
    show(steps[0], 0);
    new IntersectionObserver(([e]) => { clearTimeout(timer); if (e.isIntersecting) { i = 0; tick(); } }, { threshold: 0.3 }).observe(root);
  });

  // ---- The notch: tabs through what's in it; it plays through them until you pick one ----
  // Home, Ask and Shelf are the app's own renders. The bean's hyperspace, Music, Mirror and the two HUDs
  // are drawn here, matched to the app (SpaceScene, PhotoBooth, HUDWings, SkyPainter), in its points.
  const ntTabs = [...document.querySelectorAll(".nt-tabs [role=tab]")], ntShow = document.querySelector(".nt-show");
  const ntStage = document.querySelector(".nt-stage"), ntPanes = [...document.querySelectorAll(".nt-pane")], ntSays = [...document.querySelectorAll(".nt-says p")];
  let ntAt = 0, ntTimer = 0, ntPicked = false, ntSeen = false;
  const pane = (tab) => ntPanes.find((p) => p.dataset.tab === tab);
  function ntSize() { // 1pt is the stage's width over 700, the renders' width in points
    const pt = ntStage.clientWidth / 700;
    ntStage.style.setProperty("--pt", `${pt}px`);
    const p = pane(ntTabs[ntAt].dataset.tab);
    ntStage.style.height = `${p.classList.contains("hud") ? pt * 50 + Math.max(8, pt * 18) + 36 + 24 : pt * p.dataset.h}px`; // a HUD: its island, then real-size buttons under it
  }
  function ntChoose(i) {
    ntAt = i; const tab = ntTabs[i].dataset.tab;
    ntTabs.forEach((t, k) => { t.setAttribute("aria-selected", String(k === i)); t.tabIndex = k === i ? 0 : -1; });
    ntShow.setAttribute("aria-labelledby", ntTabs[i].id);
    ntPanes.forEach((p) => p.classList.toggle("on", p.dataset.tab === tab));
    ntSays.forEach((p) => { p.hidden = p.dataset.tab !== tab; });
    ntSize(); ntFrame();
  }
  const ntPlay = () => { clearTimeout(ntTimer); if (ntPicked || reduce || !ntSeen) return; ntTimer = setTimeout(() => { ntChoose((ntAt + 1) % ntTabs.length); ntPlay(); }, 4200); };
  const ntPick = (i) => { ntPicked = true; clearTimeout(ntTimer); ntChoose(i); }; // their choice stays
  ntTabs.forEach((t, i) => {
    t.addEventListener("click", () => ntPick(i));
    t.addEventListener("keydown", (e) => {
      const d = e.key === "ArrowRight" ? 1 : e.key === "ArrowLeft" ? -1 : 0;
      if (d) { e.preventDefault(); const n = (i + d + ntTabs.length) % ntTabs.length; ntPick(n); ntTabs[n].focus(); }
    });
  });
  if (ntShow) new IntersectionObserver(([e]) => { ntSeen = e.isIntersecting; if (ntSeen) { ntPlay(); ntFrame(); } else clearTimeout(ntTimer); }, { threshold: 0.3 }).observe(ntShow);
  addEventListener("resize", () => ntShow && ntSize());

  const hex = (n) => `#${n.toString(16).padStart(6, "0")}`;
  const blend = (a, b, t) => { t = Math.min(1, Math.max(0, t)); let o = 0; for (const s of [16, 8, 0]) { const x = (a >> s) & 255, y = (b >> s) & 255; o |= Math.round(x + (y - x) * t) << s; } return o; };
  const smooth = (lo, hi, x) => { const t = Math.min(1, Math.max(0, (x - lo) / (hi - lo))); return t * t * (3 - 2 * t); };
  // a canvas sized to its box in screen pixels, drawn in points
  function fit(canvas) {
    const r = canvas.getBoundingClientRect(), dpr = devicePixelRatio || 1, pt = ntStage.clientWidth / 700;
    if (canvas.width !== Math.round(r.width * dpr)) { canvas.width = Math.round(r.width * dpr); canvas.height = Math.round(r.height * dpr); }
    const g = canvas.getContext("2d"); g.setTransform(dpr * pt, 0, 0, dpr * pt, 0, 0); g.imageSmoothingEnabled = false;
    return { g, w: r.width / pt, h: r.height / pt };
  }

  // Home: the stars drift out from the bean, then now and then warp into streaks (SpaceScene)
  const space = document.querySelector(".nt-space canvas");
  const stars = (() => { let seed = 0x9E3779B97F4A7C15n; const next = () => { seed = (seed * 6364136223846793005n + 1442695040888963407n) & 0xFFFFFFFFFFFFFFFFn; return Number(seed >> 11n) / 2 ** 53; };
    return Array.from({ length: 90 }, () => ({ angle: next() * 2 * Math.PI, speed: 0.6 + next() * 0.8, phase: next(), size: 0.6 + next() * 1.2 })); })();
  const CYCLE = 9;
  const warpAt = (time) => { const t = (time / CYCLE) % 1, burst = Math.max(0, Math.sin((t - 0.6) / 0.4 * Math.PI)); return t < 0.6 ? 0 : burst * burst; };
  const distanceAt = (time) => { const cycles = Math.floor(time / CYCLE), t = (time - cycles * CYCLE) / CYCLE, span = 0.4 * CYCLE, u = Math.max(0, (t - 0.6) / 0.4);
    return 0.05 * time + 0.9 * (cycles * span / 2 + span * (u / 2 - Math.sin(2 * Math.PI * u) / (4 * Math.PI))); };
  function drawSpace(time) {
    const { g, w, h } = fit(space); g.clearRect(0, 0, w, h);
    const cx = w / 2, cy = h / 2, reach = Math.hypot(w, h) / 2, warp = warpAt(time), travelled = distanceAt(time);
    g.lineCap = "round";
    for (const s of stars) {
      const progress = (s.phase + travelled * s.speed) % 1, radius = progress * progress * reach;
      const dx = Math.cos(s.angle), dy = Math.sin(s.angle), hx = cx + dx * radius, hy = cy + dy * radius;
      const fade = Math.min(1, progress * 3), tail = radius * (0.02 + 0.45 * warp);
      g.globalAlpha = 0.35 + 0.65 * fade; g.fillStyle = g.strokeStyle = warp > 0.3 ? "#CFE3FF" : "#FFFFFF";
      if (tail > s.size * 1.5) { g.lineWidth = s.size; g.beginPath(); g.moveTo(hx - dx * tail, hy - dy * tail); g.lineTo(hx, hy); g.stroke(); }
      else { g.beginPath(); g.ellipse(hx, hy, s.size / 2, s.size / 2, 0, 0, 2 * Math.PI); g.fill(); }
    }
    g.globalAlpha = 1;
    const glow = 46 + 20 * warp, grad = g.createRadialGradient(cx, cy, 0, cx, cy, glow);
    grad.addColorStop(0, `rgba(127,168,255,${0.18 + 0.2 * warp})`); grad.addColorStop(1, "rgba(127,168,255,0)");
    g.fillStyle = grad; g.fillRect(cx - glow, cy - glow, glow * 2, glow * 2);
  }

  // Volume: the Pac-Man level (HUDWings) and Brightness: the pixel sky (SkyPainter)
  const PAC = { navy: "#0B0B6B", wall: "#2121DE", yellow: "#FFE600", red: "#FF3B3B", green: "#3BE36B" };
  const GHOSTS = ["#FF0000", "#FFB8FF", "#00FFFF", "#FFB852"];
  const GHOST_BODY = ["     ####     ", "   ########   ", "  ##########  ", " ############ ", " ############ ", " ############ ", ...Array(6).fill("##############")];
  const SKIRTS = [["##.###..###.##", "#...##..##...#"], ["####.####.####", ".##..####..##."]];
  const SKY = [[0, [0x05071A, 0x0B1033, 0x141B48]], [0.25, [0x120F38, 0x2A1E5C, 0x5A3577]], [0.5, [0x2B3A8C, 0xC4609A, 0xF59A5B]], [0.75, [0x2E7BD6, 0x6FB2EE, 0xB8E2F7]], [1, [0x1E7BFF, 0x5FB4FF, 0xA9E3FF]]];
  const CLOUD = ["...####.....", ".########...", "############", ".##########."];
  const huds = [...document.querySelectorAll(".nt-pane.hud")].map((p) => ({ el: p, kind: p.dataset.kind, canvas: p.querySelector("canvas"), icon: p.querySelector(".hud-icon"), pct: p.querySelector(".hud-pct"),
    level: p.dataset.kind === "volume" ? 0.6 : 0.5, from: 0, start: -1, muted: false, left: false }));
  huds.forEach((s) => { s.from = s.level; });
  const ICONS = {
    speaker: (n) => `<svg viewBox="0 0 24 24"><path d="M3 9h4l5-4v14l-5-4H3z"/>${[0, 1, 2].map((k) => k < n ? `<path d="M${14.5 + k * 3} ${8.5 - k * 2}a${4 + k * 3} ${4 + k * 3} 0 0 1 0 ${7 + k * 4}" fill="none" stroke="white" stroke-width="1.9" stroke-linecap="round"/>` : "").join("")}</svg>`,
    mute: '<svg viewBox="0 0 24 24"><path d="M3 9h4l5-4v14l-5-4H3z"/><path d="M15 9l6 6M21 9l-6 6" stroke="white" stroke-width="2" stroke-linecap="round"/></svg>',
    moon: '<svg viewBox="0 0 24 24"><path d="M14 3a8 8 0 1 0 7 11A7 7 0 0 1 14 3z"/><path d="M19 3l.7 1.6L21.3 5l-1.6.7L19 7.3l-.7-1.6L16.7 5l1.6-.7z"/></svg>',
    sunrise: '<svg viewBox="0 0 24 24"><path d="M6 17a6 6 0 0 1 12 0z"/><path d="M3 19h18M12 3v5M9.5 5.5L12 3l2.5 2.5" stroke="white" stroke-width="1.8" fill="none" stroke-linecap="round"/></svg>',
    sun: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="4.6"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M4.9 19.1L7 17M17 7l2.1-2.1" stroke="white" stroke-width="1.8" stroke-linecap="round"/></svg>',
  };
  function labels(s) {
    const pc = Math.round(s.level * 100);
    if (s.kind === "volume") { s.icon.innerHTML = s.muted ? ICONS.mute : ICONS.speaker(s.level < 0.34 ? 1 : s.level < 0.67 ? 2 : 3); s.pct.textContent = s.muted ? "MUTE" : `${pc}%`; s.pct.classList.toggle("muted", s.muted); }
    else { s.icon.innerHTML = s.level < 0.35 ? ICONS.moon : s.level < 0.55 ? ICONS.sunrise : ICONS.sun; s.pct.textContent = `${pc}%`; }
  }
  const travel = (s) => (s.kind === "volume" ? 0.32 : 0.45);
  const posAt = (s, now) => { const t = Math.min(1, Math.max(0, (now - s.start) / travel(s))); return s.from + (s.level - s.from) * (1 - (1 - t) * (1 - t)); };
  function rects(g, cells, p, colour) { g.fillStyle = colour; for (const [x, y] of cells) g.fillRect(x * p, y * p, p, p); }
  function drawVolume(s, now) {
    const { g, w, h } = fit(s.canvas); g.fillStyle = PAC.navy; g.fillRect(0, 0, w, h);
    const time = reduce ? 0 : now;
    // the ghosts, top middle, each on its own beat
    const gw = 14 * 1.5, total = 4 * gw + 3 * 7; let gx = (w - total) / 2; const gy = (26 - gw) / 2;
    GHOSTS.forEach((colour, i) => {
      const t = time + i * 0.73, skirt = Math.floor(t * 6) % 2, right = Math.sin(t * 0.9 + i) > 0;
      g.save(); g.translate(gx + Math.round(Math.sin(t * 1.1) * 2) * 1.5, gy + (Math.sin(t * 4) > 0 ? 1.5 : 0));
      const body = []; [...GHOST_BODY, ...SKIRTS[skirt]].forEach((row, y) => [...row].forEach((ch, x) => { if (ch === "#") body.push([x, y]); }));
      rects(g, body, 1.5, s.muted ? "#2121FF" : colour);
      if (s.muted) rects(g, [[3, 5], [4, 5], [9, 5], [10, 5], ...[2, 3, 4, 5, 6, 7, 8, 9, 10, 11].map((x, k) => [x, k % 2 === 0 ? 9 : 8])], 1.5, "#FFB8AE");
      else { const whites = [], pupils = [];
        for (const l of [2, 8]) { for (let y = 3; y <= 7; y++) for (let x = l; x <= l + 3; x++) if (!((y === 3 || y === 7) && (x === l || x === l + 3))) whites.push([x, y]);
          const px = right ? l + 2 : l; for (let y = 5; y <= 6; y++) for (let x = px; x <= px + 1; x++) pupils.push([x, y]); }
        rects(g, whites, 1.5, "#FFFFFF"); rects(g, pupils, 1.5, "#2121DE"); }
      g.restore(); gx += gw + 7;
    });
    // the corridor: walls, pellets, Pac-Man
    const cy0 = h - 24, inset = 16, span = w - 2 * inset, mid = cy0 + 12, at = s.muted ? 0 : posAt(s, now), moving = now - s.start < 0.32;
    g.fillStyle = PAC.wall; g.fillRect(8, cy0 + 2, w - 16, 2); g.fillRect(8, cy0 + 20, w - 16, 2);
    for (let k = 0; k < 20; k++) { const x = (k + 0.5) / 20; if (x > at + 0.012 || x < at - 0.035) { g.fillStyle = x < at ? PAC.green : PAC.red; g.fillRect(Math.round(inset + span * x) - 1.5, Math.round(mid) - 1.5, 3, 3); } }
    const mouth = moving && !reduce ? 0.05 + 0.6 * Math.abs(Math.sin(now * 22)) : 0.45, r = 6.5, half = 40 * mouth * Math.PI / 180, cells = [];
    for (let y = 0; y < 13; y++) for (let x = 0; x < 13; x++) { const dx = x + 0.5 - r, dy = y + 0.5 - r; if (dx * dx + dy * dy > r * r - 0.6) continue; if (dx > 0 && Math.abs(Math.atan2(dy, dx)) < half) continue; cells.push([s.left ? 12 - x : x, y]); }
    g.save(); g.translate(inset + span * at - 9.75, mid - 9.75); rects(g, cells, 1.5, s.muted ? "#808080" : PAC.yellow); g.restore();
  }
  function drawSky(s, now) {
    const { g, w, h } = fit(s.canvas), level = posAt(s, now), time = reduce ? 0 : now;
    let up = SKY.findIndex(([k]) => k >= level); if (up < 1) up = Math.max(1, up);
    const [ka, a] = SKY[up - 1], [kb, b] = SKY[up], tt = (level - ka) / (kb - ka), stops = a.map((v, i) => blend(v, b[i], tt));
    for (let y = 0; y < h; y += 2) { const t = y / h; g.fillStyle = hex(t < 0.6 ? blend(stops[0], stops[1], t / 0.6) : blend(stops[1], stops[2], (t - 0.6) / 0.4)); g.fillRect(0, y, w, 2); }
    const night = Math.max(0, 1 - level / 0.35);
    if (night > 0) { let seed = 7n; for (let i = 0; i < 46; i++) { seed = (seed * 6364136223846793005n + 1442695040888963407n) & 0xFFFFFFFFFFFFFFFFn;
      const x = Number((seed >> 33n) % 10000n) / 10000 * w, sy = Number((seed >> 17n) % 1000n) / 1000 * (h - 12), tw = 0.55 + 0.45 * Math.sin(time * (1.3 + (i % 5) * 0.4) + i);
      g.fillStyle = `rgba(255,255,255,${night * tw})`; g.fillRect(Math.round(x), Math.round(sy), 1, 1); } }
    const x = Math.round(16 + (w - 32) * level), by = Math.round(h - 9 - 8 * level);
    const disc = (radius, colour, bite) => { g.fillStyle = colour; const sp = Math.ceil(radius);
      for (let dy = -sp; dy <= sp; dy++) for (let dx = -sp; dx <= sp; dx++) { const fx = dx + 0.5, fy = dy + 0.5; if (fx * fx + fy * fy > radius * radius) continue;
        if (bite > 0) { const bx = fx - bite, bY = fy + bite * 0.5; if (bx * bx + bY * bY <= radius * radius * 0.8) continue; } g.fillRect(x + dx, by + dy, 1, 1); } };
    const moon = 1 - smooth(0.28, 0.42, level); if (moon > 0) { g.globalAlpha = moon; disc(5, "#F4F1D0", 2.5); g.globalAlpha = 1; }
    const sun = smooth(0.36, 0.5, level);
    if (sun > 0) { g.globalAlpha = 0.28 * sun; disc(8, "#FFD27A", 0); g.globalAlpha = sun; disc(5.5, hex(blend(0xFF7A3D, 0xFFE680, smooth(0.4, 0.9, level))), 0); g.globalAlpha = 1; }
    const cloudy = smooth(0.3, 0.7, level);
    if (cloudy > 0) { const sunrise = Math.max(0, 1 - Math.abs(level - 0.5) / 0.2); g.fillStyle = hex(blend(0xFFFFFF, 0xFFB7CF, sunrise)); g.globalAlpha = 0.92 * cloudy;
      [[0.08, 6], [0.37, 3], [0.62, 9], [0.88, 5]].forEach(([c0, cyc], i) => { const drift = (time * (3 + i)) % (w + 40), cx = ((c0 * w + drift) % (w + 40)) - 20;
        CLOUD.forEach((line, row) => [...line].forEach((ch, col) => { if (ch === "#") g.fillRect(Math.round(cx) + col, cyc + row, 1, 1); })); }); g.globalAlpha = 1; }
    g.fillStyle = hex(blend(0x060914, 0x2E7D4F, smooth(0.3, 0.9, level)));
    for (let col = 0; col < w; col++) { const rise = Math.round(3 + 1.6 * Math.sin(col / 23) + 1.1 * Math.sin(col / 9)); g.fillRect(col, h - rise, 1, rise); }
    g.fillStyle = "rgba(0,0,0,0.16)"; for (let row = 1; row < h; row += 2) g.fillRect(0, row, w, 1);
    const rim = g.createRadialGradient(w / 2, h / 2, h * 0.6, w / 2, h / 2, w * 0.6); rim.addColorStop(0, "rgba(0,0,0,0)"); rim.addColorStop(1, "rgba(0,0,0,0.35)"); g.fillStyle = rim; g.fillRect(0, 0, w, h);
  }
  let ntRaf = 0;
  function ntFrame() { // draws only what's showing, and only while the section is on screen
    if (ntRaf || !ntShow) return;
    ntRaf = requestAnimationFrame(function loop(ms) {
      ntRaf = 0; const now = ms / 1000, tab = ntTabs[ntAt].dataset.tab;
      if (tab === "home") drawSpace(reduce ? 0 : now);
      const s = huds.find((x) => x.kind === tab); if (s) (s.kind === "volume" ? drawVolume : drawSky)(s, now);
      if (ntSeen && (tab === "home" || s) && !reduce) ntRaf = requestAnimationFrame(loop);
    });
  }
  huds.forEach((s) => {
    labels(s);
    const step = (d) => { const now = performance.now() / 1000; s.from = posAt(s, now); s.start = now; s.left = d < 0;
      s.level = Math.min(1, Math.max(0, Math.round((s.level + d / 16) * 16) / 16)); if (s.kind === "volume" && d) s.muted = false; labels(s); ntPick(ntAt); };
    s.el.querySelectorAll(".hud-ctl button").forEach((b) => {
      const act = b.dataset.act;
      if (act === "mute") { b.addEventListener("click", () => { s.muted = !s.muted; b.setAttribute("aria-pressed", String(s.muted)); labels(s); ntPick(ntAt); }); return; }
      let hold = 0, rep = 0; const d = act === "up" ? 1 : -1;
      const stop = () => { clearTimeout(hold); clearInterval(rep); };
      b.addEventListener("pointerdown", (e) => { e.preventDefault(); step(d); hold = setTimeout(() => { rep = setInterval(() => step(d), 110); }, 350); }); // hold to keep stepping
      ["pointerup", "pointerleave", "pointercancel"].forEach((ev) => b.addEventListener(ev, stop));
      b.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); step(d); } });
    });
    s.el.addEventListener("keydown", (e) => { if (e.key === "ArrowUp") { e.preventDefault(); step(1); } if (e.key === "ArrowDown") { e.preventDefault(); step(-1); } });
  });
  if (ntShow) { ntSize(); ntChoose(0); }

  document.addEventListener("visibilitychange", () => {
    tvSyncs.forEach((sync) => sync());
    if (document.hidden) { pausedForTab = player.classList.contains("playing"); if (pausedForTab) music.pauseVideo(); }
    else if (pausedForTab) { pausedForTab = false; music.playVideo(); } // the song picks up where it was
  });

  // ---- The GIF window: plays only while on screen, and holds still for reduced motion ----
  document.querySelectorAll(".gifwin video, .giftile video").forEach((v) => {
    if (reduce) { v.removeAttribute("autoplay"); v.pause(); return; }
    new IntersectionObserver(([e]) => { if (e.isIntersecting && !document.hidden) v.play().catch(() => {}); else v.pause(); }).observe(v);
  });

  // ---- The menu bar clock: Singapore time ----
  const clock = document.getElementById("sgtime");
  const tick = () => { clock.textContent = new Intl.DateTimeFormat("en-SG", { hour: "numeric", minute: "2-digit", timeZone: "Asia/Singapore" }).format(new Date()).toLowerCase(); };
  tick(); setInterval(tick, 15000);

  // ---- Entrances: each section's parts, staggered, once ----
  if (!reduce && "IntersectionObserver" in window) {
    const parts = document.querySelectorAll(".ways-head > *, .way-copy, .way .big, .walk-copy, .safari, .notch-head, .nt-tabs, .nt-show, .setup-copy, .w.note, .cabinet-head, .dfolder, .david, .jersey, .faq > *, .qs details, .field-inner > *");
    parts.forEach((el) => el.classList.add("reveal"));
    const seen = new IntersectionObserver((entries) => {
      entries.filter((e) => e.isIntersecting).forEach((e) => {
        const siblings = [...e.target.parentElement.children].filter((c) => c.classList.contains("reveal"));
        e.target.style.transitionDelay = `${Math.min(siblings.indexOf(e.target), 6) * 70}ms`;
        e.target.classList.add("in");
        seen.unobserve(e.target);
      });
    }, { rootMargin: "0px 0px -8% 0px" });
    parts.forEach((el) => seen.observe(el));
  }
})();
