import Foundation
import WebKit

/// Bundled JavaScript, loaded once.
enum Bundled {
    static func js(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "js", subdirectory: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    static let readability = js("Readability")
    static let readerable = js("Readability-readerable")
    static let purify = js("purify.min")
    static let autofill = js("autofill")
}

/// Isolated worlds: page scripts can't see or tamper with these.
public enum Worlds {
    @MainActor public static let reader = WKContentWorld.world(name: "aegis-reader")
    @MainActor public static let cosmetic = WKContentWorld.world(name: "aegis-cosmetic")
    @MainActor public static let autofill = WKContentWorld.world(name: "aegis-autofill")
    @MainActor public static let media = WKContentWorld.world(name: "aegis-media")
}

/// Fingerprinting defenses. These must run in the page world to take effect,
/// so they are detectable; noise is tiny and stable per site and session.
enum Farbling {
    static func source(seed: UInt32) -> String {
        """
        (() => {
          'use strict';
          const seed = \(seed) ^ [...location.hostname.split('.').slice(-2).join('.')].reduce((h, c) => Math.imul(h ^ c.charCodeAt(0), 16777619) >>> 0, 2166136261);
          let s = seed >>> 0;
          const rand = () => { s ^= s << 13; s >>>= 0; s ^= s >> 17; s ^= s << 5; s >>>= 0; return s / 4294967296; };
          const define = (obj, prop, value) => { try { Object.defineProperty(obj, prop, { get: () => value, configurable: true }); } catch (_) {} };

          // Normalize high-entropy hardware hints to common values.
          define(Navigator.prototype, 'hardwareConcurrency', 8);
          if ('deviceMemory' in Navigator.prototype) define(Navigator.prototype, 'deviceMemory', 8);

          // Canvas: flip the low bit of a sparse, seeded set of pixels in the
          // read-out only. The page's canvas is never modified, so repeated
          // reads on one site return the same value.
          const origGetImageData = CanvasRenderingContext2D.prototype.getImageData;
          const origToDataURL = HTMLCanvasElement.prototype.toDataURL;
          const origToBlob = HTMLCanvasElement.prototype.toBlob;
          const farble = (data) => {
            s = seed >>> 0;
            const n = Math.max(1, Math.floor(data.length / 4 / 2000));
            for (let i = 0; i < n; i++) { const p = Math.floor(rand() * (data.length / 4)) * 4; data[p] ^= 1; }
          };
          const noisyCopy = (canvas) => {
            const w = canvas.width, h = canvas.height;
            if (w * h === 0 || w * h > 4096 * 4096) return null;
            const ctx = canvas.getContext('2d');
            if (!ctx) return null;
            const img = origGetImageData.call(ctx, 0, 0, w, h);
            farble(img.data);
            const copy = document.createElement('canvas');
            copy.width = w; copy.height = h;
            copy.getContext('2d').putImageData(img, 0, 0);
            return copy;
          };
          CanvasRenderingContext2D.prototype.getImageData = function (x, y, w, h) {
            const img = origGetImageData.call(this, x, y, w, h);
            farble(img.data);
            return img;
          };
          HTMLCanvasElement.prototype.toDataURL = function (...a) {
            let copy = null;
            try { copy = noisyCopy(this); } catch (_) {}
            return origToDataURL.apply(copy || this, a);
          };
          HTMLCanvasElement.prototype.toBlob = function (...a) {
            let copy = null;
            try { copy = noisyCopy(this); } catch (_) {}
            return origToBlob.apply(copy || this, a);
          };

          // WebGL: report a generic renderer.
          for (const Ctx of [self.WebGLRenderingContext, self.WebGL2RenderingContext]) {
            if (!Ctx) continue;
            const orig = Ctx.prototype.getParameter;
            Ctx.prototype.getParameter = function (p) {
              if (p === 0x9245) return 'Apple Inc.';      // UNMASKED_VENDOR_WEBGL
              if (p === 0x9246) return 'Apple GPU';       // UNMASKED_RENDERER_WEBGL
              return orig.call(this, p);
            };
          }

          // Audio: tiny seeded offset on analysis read-outs.
          if (self.AudioBuffer) {
            const orig = AudioBuffer.prototype.getChannelData;
            AudioBuffer.prototype.getChannelData = function (c) {
              const data = orig.call(this, c);
              s = seed >>> 0;
              for (let i = 0; i < data.length; i += 997) data[i] += (rand() - 0.5) * 1e-7;
              return data;
            };
          }
        })();
        """
    }
}

/// Reader extraction: runs in the reader world against a clone of the page.
enum ReaderScript {
    static let extract = """
    (() => {
      if (typeof isProbablyReaderable === 'function' && !isProbablyReaderable(document)) return null;
      const doc = document.cloneNode(true);
      const article = new Readability(doc, { charThreshold: 500 }).parse();
      if (!article || !article.content) return null;
      const clean = DOMPurify.sanitize(article.content, { USE_PROFILES: { html: true }, FORBID_TAGS: ['style', 'form', 'input', 'button', 'iframe'] });
      return { title: article.title || document.title, byline: article.byline || '', site: article.siteName || location.hostname, content: clean, length: article.length || 0 };
    })();
    """

    static let probe = """
    (() => typeof isProbablyReaderable === 'function' && isProbablyReaderable(document))();
    """
}

/// Reports play/pause of any audio or video on the page (media events don't
/// bubble, so listen in the capture phase). Runs isolated from the page.
enum MediaScript {
    static let source = """
    (() => {
      const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aegisMedia;
      if (!h) return;
      let last = null, timer = 0;
      const report = () => {
        clearTimeout(timer);
        timer = setTimeout(() => {
          const els = [...document.querySelectorAll('video, audio')];
          const playing = els.find(m => !m.paused && !m.ended && m.readyState > 2 && !m.muted && m.volume > 0);
          const state = playing ? 'playing' : (els.some(m => !m.ended && m.currentTime > 0) ? 'paused' : 'none');
          const kind = playing ? (playing.videoWidth > 0 ? 'video' : 'audio') : '';
          const md = navigator.mediaSession && navigator.mediaSession.metadata;
          const og = document.querySelector('meta[property="og:image"]');
          const art = (md && md.artwork && md.artwork.length ? md.artwork[md.artwork.length - 1].src : '') || (og ? og.content : '');
          const title = (md && md.title) || '';
          const artist = (md && (md.artist || md.album)) || '';
          const key = state + kind + title + art;
          if (key === last) return;
          last = key;
          try { h.postMessage({ type: 'media', state, kind, title, artist, art, top: window === window.top }); } catch (_) {}
        }, 150);
      };
      for (const e of ['play', 'playing', 'pause', 'ended', 'emptied', 'volumechange'])
        document.addEventListener(e, report, true);
    })();
    """

    static let togglePlayback = """
    (() => {
      const els = [...document.querySelectorAll('video, audio')];
      const playing = els.filter(m => !m.paused && !m.ended);
      if (playing.length) { playing.forEach(m => m.pause()); return 'paused'; }
      const last = els.find(m => m.currentTime > 0 && !m.ended) || els[0];
      if (last) { last.play(); return 'playing'; }
      return 'none';
    })();
    """

    static let pictureInPicture = """
    (() => {
      const v = [...document.querySelectorAll('video')].find(v => !v.paused) || document.querySelector('video');
      if (!v) return false;
      if (v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode('picture-in-picture')) {
        v.webkitSetPresentationMode(v.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture');
        return true;
      }
      return false;
    })();
    """
}

/// Without Apple's browser-passkey entitlement, macOS rejects every WebAuthn
/// request from the app (ASAuthorizationError 1004). Sites like Google then hang
/// or show a vague error. This page-world shim makes the browser honestly report
/// "no passkeys", so sites skip straight to password / "Try another way", and
/// reports explicit (non-conditional) attempts so the app can explain.
enum PasskeyShim {
    static let source = """
    (() => {
      if (!window.PublicKeyCredential || !navigator.credentials) return;
      const P = window.PublicKeyCredential;
      const no = () => Promise.resolve(false);
      try { P.isUserVerifyingPlatformAuthenticatorAvailable = no; } catch (_) {}
      try { if (P.isConditionalMediationAvailable) P.isConditionalMediationAvailable = no; } catch (_) {}
      try {
        if (P.getClientCapabilities) P.getClientCapabilities = () => Promise.resolve({
          conditionalCreate: false, conditionalGet: false, hybridTransport: false,
          passkeyPlatformAuthenticator: false, userVerifyingPlatformAuthenticator: false });
      } catch (_) {}
      const tell = (op) => {
        try { window.webkit.messageHandlers.aegisPasskey.postMessage({ type: 'passkeyBlocked', op, host: location.hostname }); } catch (_) {}
      };
      for (const op of ['get', 'create']) {
        const orig = navigator.credentials[op] && navigator.credentials[op].bind(navigator.credentials);
        if (!orig) continue;
        navigator.credentials[op] = function (options) {
          if (options && options.publicKey) {
            // Conditional (autofill) requests are silent background probes: just decline.
            if (options.mediation !== 'conditional') tell(op);
            return Promise.reject(new DOMException('Passkeys are not available in this browser yet.', 'NotAllowedError'));
          }
          return orig(options);
        };
      }
    })();
    """
}

/// Per-site fixes for sites that misbehave with Aegis's Safari-style user agent.
enum SiteQuirks {
    static let base = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"

    /// Google Docs/Sheets/Slides see "Version/x Safari" and take a Safari-only
    /// path that, outside Safari, renders the document canvas at half
    /// resolution (408 px for 816 pt on a 2x display: blurry text). Without the
    /// Version token they render at full resolution (verified in a bare WKWebView).
    static func userAgent(for host: String?) -> String? {
        guard let host else { return nil }
        if host == "docs.google.com" { return base + " Safari/605.1.15" }
        return nil
    }
}
