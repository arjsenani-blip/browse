/*
 * Aegis autofill content script.
 *
 * Injected as a WKUserScript into the isolated WKContentWorld "aegis-autofill"
 * (never the page world), at document end, all frames. Because the world is isolated, the
 * page cannot see `window.__aegisFill` or read anything this script holds; DOM nodes and DOM
 * events are shared, so filled values and dispatched events reach the page normally.
 *
 * Messages posted to native via window.webkit.messageHandlers.aegisAutofill:
 *   { type: 'formsFound', host, hasPassword, isTopFrame }
 *   { type: 'submitted',  host, username, password, isTopFrame }
 *
 * Native fills with (evaluateJavaScript in the same content world):
 *   window.__aegisFill(username, password)  -> true if something was filled
 *
 * Fields with autocomplete="one-time-code" are ignored entirely: the system's
 * Security Code AutoFill handles them.
 */
(function () {
  'use strict';
  if (window.__aegisAutofillInstalled) return;
  window.__aegisAutofillInstalled = true;

  var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aegisAutofill;
  if (!handler) return;

  var HOST = location.hostname;
  var IS_TOP = (function () { try { return window.top === window; } catch (e) { return false; } })();
  var DEBOUNCE_MS = 250;
  var USER_HINT = /user|login|email|e-mail|account|identifier|ident|nick|member|phone|mobile|uid/i;
  var NOT_USER_HINT = /search|query|captcha|otp|code|token|coupon|promo|zip|postal|card|cvv|cvc/i;
  var TEXTUAL = { text: 1, email: 1, tel: 1, '': 1 };

  // Last username seen in an identifier-first step (e.g. Google/Microsoft two-page login).
  var lastIdentifier = '';
  var lastSignature = '';
  var lastSubmitKey = '';
  var lastSubmitAt = 0;

  function post(msg) {
    try { handler.postMessage(msg); } catch (e) { /* native side gone */ }
  }

  function ac(el) { return (el.getAttribute('autocomplete') || '').toLowerCase(); }
  function isOTP(el) { return ac(el).indexOf('one-time-code') !== -1; }

  function isVisible(el) {
    if (!el.isConnected || el.disabled) return false;
    if (el.type === 'hidden') return false;
    var r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) return false;
    var s = getComputedStyle(el);
    return s.visibility !== 'hidden' && s.display !== 'none' && parseFloat(s.opacity || '1') > 0.05;
  }

  function isPasswordField(el) {
    return el instanceof HTMLInputElement && el.type === 'password' && !isOTP(el) && isVisible(el);
  }

  function isUsernameCandidate(el) {
    if (!(el instanceof HTMLInputElement)) return false;
    if (!TEXTUAL.hasOwnProperty((el.type || '').toLowerCase())) return false;
    if (isOTP(el) || el.readOnly || !isVisible(el)) return false;
    var a = ac(el);
    if (a === 'off' && !USER_HINT.test(el.name + ' ' + el.id)) {
      // autocomplete=off is common on real username fields; only reject if nothing looks user-ish.
      return false;
    }
    var hints = [el.name, el.id, el.placeholder, el.getAttribute('aria-label') || ''].join(' ');
    if (NOT_USER_HINT.test(hints) && a.indexOf('username') === -1 && a.indexOf('email') === -1) return false;
    return true;
  }

  function usernameScore(el) {
    var a = ac(el);
    var hints = [el.name, el.id, el.placeholder, el.getAttribute('aria-label') || ''].join(' ');
    var score = 0;
    if (a.indexOf('username') !== -1) score += 10;
    if (a.indexOf('email') !== -1) score += 8;
    if (el.type === 'email') score += 6;
    if (USER_HINT.test(hints)) score += 4;
    return score;
  }

  function scopeOf(el) {
    return el.form || el.closest('[role="form"], form, dialog, [role="dialog"]') || document;
  }

  function inputsIn(scope) {
    return Array.prototype.slice.call(scope.querySelectorAll('input'));
  }

  // Nearest preceding username-like input in the same scope, preferring strong hints.
  function findUsernameFor(passwordEl) {
    var inputs = inputsIn(scopeOf(passwordEl));
    var idx = inputs.indexOf(passwordEl);
    var best = null, bestScore = -1, bestDist = Infinity;
    for (var i = 0; i < inputs.length; i++) {
      var el = inputs[i];
      if (el === passwordEl || !isUsernameCandidate(el)) continue;
      var dist = i < idx ? idx - i : (i - idx) + 100; // strongly prefer fields before the password
      var score = usernameScore(el);
      if (score > bestScore || (score === bestScore && dist < bestDist)) {
        best = el; bestScore = score; bestDist = dist;
      }
    }
    return best;
  }

  // Returns [{ password, newPassword, username, scope }] for visible login-ish forms.
  function scanForms() {
    var passwords = inputsIn(document).filter(isPasswordField);
    var groups = [];
    var seenScopes = [];
    passwords.forEach(function (pw) {
      var scope = scopeOf(pw);
      var g = null;
      for (var i = 0; i < seenScopes.length; i++) if (seenScopes[i] === scope) g = groups[i];
      if (!g) {
        g = { scope: scope, password: null, newPassword: null, username: null };
        groups.push(g); seenScopes.push(scope);
      }
      if (ac(pw).indexOf('new-password') !== -1) {
        if (!g.newPassword) g.newPassword = pw;
      } else if (!g.password) {
        g.password = pw;
      }
    });
    groups.forEach(function (g) {
      var anchor = g.password || g.newPassword;
      g.username = anchor ? findUsernameFor(anchor) : null;
    });
    return groups;
  }

  // Identifier-first step: a lone username/email field with no password on the page.
  function scanIdentifierOnly() {
    var fields = inputsIn(document).filter(function (el) {
      return isUsernameCandidate(el) && (ac(el).indexOf('username') !== -1 || ac(el).indexOf('webauthn') !== -1 || el.type === 'email');
    });
    return fields.length === 1 ? fields[0] : null;
  }

  function detect() {
    var groups = scanForms();
    var hasPassword = groups.length > 0;
    var identifier = hasPassword ? null : scanIdentifierOnly();
    var signature = hasPassword ? 'pw:' + groups.length : (identifier ? 'id' : '');
    if (signature && signature !== lastSignature) {
      post({ type: 'formsFound', host: HOST, hasPassword: hasPassword, isTopFrame: IS_TOP });
    }
    lastSignature = signature;
  }

  var timer = null;
  function scheduleDetect() {
    if (timer) clearTimeout(timer);
    timer = setTimeout(function () { timer = null; detect(); }, DEBOUNCE_MS);
  }

  // ---- Filling ----

  var nativeValueSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;

  // Sets the value through the native setter (bypassing framework value trackers so React/Vue
  // notice the change) and fires the events frameworks listen for.
  function setValue(el, value) {
    el.focus({ preventScroll: true });
    nativeValueSetter.call(el, value);
    try {
      el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertReplacementText', data: value }));
    } catch (e) {
      el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    }
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }

  function pickGroupForFill(groups) {
    var active = document.activeElement;
    for (var i = 0; i < groups.length; i++) {
      var g = groups[i];
      if (active && (active === g.password || active === g.username || (g.scope !== document && g.scope.contains(active)))) return g;
    }
    // Prefer a group with a current-password field (sign-in) over sign-up / change-password forms.
    for (var j = 0; j < groups.length; j++) if (groups[j].password) return groups[j];
    return null;
  }

  function fill(username, password) {
    username = username == null ? '' : String(username);
    password = password == null ? '' : String(password);
    var g = pickGroupForFill(scanForms());
    var filled = false;
    if (g) {
      if (g.username && username) { setValue(g.username, username); filled = true; }
      if (g.password && password) { setValue(g.password, password); filled = true; }
      if (g.password) g.password.blur();
    } else {
      var id = scanIdentifierOnly();
      if (id && username) { setValue(id, username); filled = true; }
    }
    return filled;
  }

  // Only visible inside the "aegis-autofill" content world.
  Object.defineProperty(window, '__aegisFill', { value: fill, writable: false, configurable: false, enumerable: false });

  // ---- Submit capture ----

  function report(scopeHint) {
    var groups = scanForms();
    var g = null;
    if (scopeHint) {
      for (var i = 0; i < groups.length; i++) {
        if (groups[i].scope === scopeHint || (groups[i].scope !== document && groups[i].scope.contains(scopeHint)) ||
            (scopeHint.contains && scopeHint.contains(groups[i].password || groups[i].newPassword))) { g = groups[i]; break; }
      }
    }
    if (!g) g = groups.length === 1 ? groups[0] : null;

    if (!g) {
      // Identifier-first step: remember the username for the password page.
      var id = scanIdentifierOnly();
      if (id && id.value) lastIdentifier = id.value.trim();
      return;
    }
    // New password wins on sign-up / change-password forms.
    var pwEl = (g.newPassword && g.newPassword.value) ? g.newPassword : g.password;
    var password = pwEl ? pwEl.value : '';
    if (!password) return;
    var username = g.username && g.username.value ? g.username.value.trim() : lastIdentifier;

    var key = username + '\u0000' + password.length + '\u0000' + password.charAt(0);
    var now = Date.now();
    if (key === lastSubmitKey && now - lastSubmitAt < 1500) return; // submit + click double-fire
    lastSubmitKey = key; lastSubmitAt = now;
    post({ type: 'submitted', host: HOST, username: username || '', password: password, isTopFrame: IS_TOP });
  }

  document.addEventListener('submit', function (e) { report(e.target); }, true);

  // SPAs often log in via a button click handler without a real form submission.
  document.addEventListener('click', function (e) {
    var t = e.target && e.target.closest && e.target.closest('button, input[type="submit"], input[type="button"], [role="button"]');
    if (!t) return;
    if (t.type === 'submit' && t.form) return; // the submit listener will handle it
    report(t.closest('form') || t);
  }, true);

  document.addEventListener('keydown', function (e) {
    if (e.key !== 'Enter' || e.isComposing) return;
    var t = e.target;
    if (!(t instanceof HTMLInputElement) || isOTP(t)) return;
    if (t.form) return; // implicit submission fires 'submit'
    if (t.type === 'password' || isUsernameCandidate(t)) report(t);
  }, true);

  // ---- SPA support ----

  var observer = new MutationObserver(function (mutations) {
    for (var i = 0; i < mutations.length; i++) {
      var m = mutations[i];
      if (m.type === 'attributes' || m.addedNodes.length || m.removedNodes.length) { scheduleDetect(); return; }
    }
  });
  observer.observe(document.documentElement || document, {
    childList: true, subtree: true, attributes: true, attributeFilter: ['type', 'style', 'class', 'hidden', 'autocomplete']
  });
  window.addEventListener('pageshow', scheduleDetect);
  window.addEventListener('popstate', scheduleDetect);
  window.addEventListener('hashchange', scheduleDetect);

  detect();
})();
