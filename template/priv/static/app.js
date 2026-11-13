import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

// AutoResize: text inputs grow with their content (design-sprite
// standing requirement — no fixed-height boxes, no drag handles).
const AutoResize = {
  mounted() {
    const grow = () => {
      this.el.style.height = "auto";
      this.el.style.height = this.el.scrollHeight + "px";
    };
    this.grow = grow;
    this.el.addEventListener("input", grow);
    grow();
  },
  updated() {
    this.grow();
  },
};

// Composer: receives element attachments from the artifact iframe
// (the inspector bridge — the iframe posts a descriptor, we forward
// it to the LiveView, which shows it as a chip on the composer).
const Composer = {
  mounted() {
    this.onMessage = (event) => {
      const data = event.data;
      if (data && data.type === "ds-element" && data.element) {
        this.pushEvent("attach_element", { element: data.element });
      }
    };
    window.addEventListener("message", this.onMessage);
  },
  destroyed() {
    window.removeEventListener("message", this.onMessage);
  },
};

// DraftFlush: the pagehide safety net for half-answers. Beacons the
// answer form's current values to POST /api/draft, which lands them
// as a draft through the same server-side path as the socket save.
const DraftFlush = {
  mounted() {
    this.flush = () => {
      const data = new FormData(this.el);
      navigator.sendBeacon("/api/draft", data);
    };
    this.onVisibility = () => {
      if (document.visibilityState === "hidden") this.flush();
    };
    document.addEventListener("visibilitychange", this.onVisibility);
    window.addEventListener("pagehide", this.flush);
  },
  destroyed() {
    document.removeEventListener("visibilitychange", this.onVisibility);
    window.removeEventListener("pagehide", this.flush);
  },
};

// Dial: a preview question's range slider. Sliding it (or picking a
// variant radio) writes the value into the form's dialed_value text
// input — the field the server records verbatim — and fires a change
// so the draft autosave picks it up like any other keystroke.
const Dial = {
  mounted() {
    const form = this.el.closest("form");
    if (!form) return;
    const out = form.querySelector("input[name='answer[dialed_value]']");
    const sync = (value) => {
      if (!out) return;
      out.value = value;
      out.dispatchEvent(new Event("change", { bubbles: true }));
    };
    this.onInput = () => sync(this.el.value);
    this.onFormChange = (event) => {
      if (event.target.name === "answer[choice]") sync(event.target.value);
    };
    this.el.addEventListener("input", this.onInput);
    form.addEventListener("change", this.onFormChange);
  },
  destroyed() {
    this.el.removeEventListener("input", this.onInput);
  },
};

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  // Sprite edge + mobile Safari kill long-lived websockets (~1-2 min
  // in soak tests); fall back to longpoll instead of losing saves.
  longPollFallbackMs: 2500,
  hooks: { AutoResize, Composer, DraftFlush, Dial },
});

liveSocket.connect();
window.liveSocket = liveSocket;
