'use strict';
'require baseclass';
'require ui';

/* Messages that have to outlive a page reload.
 *
 * Save & Apply ends with LuCI reloading the page a few seconds after the apply, and the
 * ChatGPT sign-in and sign-out reload it themselves. Anything shown with
 * ui.addNotification before that reload is gone with it, and until LuCI r8 that was
 * every message these pages had for that moment, the failures included: a key that did
 * not save, a sign-out that did not happen. Seen on a Brume 2 on 2026-09-25, where
 * "Saved" and "Signed in to ChatGPT" never reached the screen.
 *
 * keep() puts a message in the tab's sessionStorage just before a reload, show() puts
 * it on the page after, once. A message older than a minute is dropped instead: it
 * belongs to an apply that never reloaded, and shown on a later visit it would describe
 * something that is no longer true. Storage can be absent or refuse (a private window,
 * blocked site data); the message is then lost, as it was before, and nothing breaks.
 */

var KEY = 'luci-app-hermes.flash';
var FRESH_MS = 60000;

function read() {
	try {
		var list = JSON.parse(window.sessionStorage.getItem(KEY) || '[]');
		return Array.isArray(list) ? list : [];
	} catch (e) {
		return [];
	}
}

return baseclass.extend({
	keep: function (text, kind) {
		try {
			var list = read();
			list.push({ text: String(text), kind: kind || 'info', at: Date.now() });
			window.sessionStorage.setItem(KEY, JSON.stringify(list));
		} catch (e) {}
	},

	show: function () {
		var list = read(), now = Date.now();
		try { window.sessionStorage.removeItem(KEY); } catch (e) {}
		list.forEach(function (m) {
			if (m && typeof m.text === 'string' && now - m.at >= 0 && now - m.at < FRESH_MS)
				ui.addNotification(null, E('p', {}, m.text), m.kind);
		});
	}
});
