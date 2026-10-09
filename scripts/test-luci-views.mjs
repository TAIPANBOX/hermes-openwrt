// test-luci-views.mjs -- what the Providers and Settings pages do in the browser.
//
//   node test-luci-views.mjs <root> [check ...]
//
// <root> is the web root the package installed (…/www), so what runs is what shipped:
// gate-luci.sh copies it out of the container after `apk add`, and teeth-luci.sh plants
// its faults in the package, not in the repository. LuCI itself is replaced by the
// smallest stand-in the views need (view, form, rpc, ui, uci, poll, baseclass, E, _, L):
// these checks are about the page's own decisions, which call LuCI but are not LuCI's.
// The page as a whole was looked at in a browser on a Brume 2; this is what keeps it so.
//
// Each check prints PASS or FAIL with the check name gate-luci.sh binds scenarios to.

import fs from 'node:fs';
import path from 'node:path';

const root = process.argv[2];
const only = new Set(process.argv.slice(3));
if (!root || !fs.existsSync(path.join(root, 'luci-static/resources/view/hermes/providers.js'))) {
	console.log(`FAIL harness: no installed views under ${root}; measured nothing`);
	process.exit(1);
}

// ---- the stand-in ----------------------------------------------------------------

String.prototype.format = function (...a) { let i = 0; return this.replace(/%[sd]/g, () => String(a[i++])); };

function textOf(n) {
	if (n == null || n === false) return '';
	if (typeof n === 'string' || typeof n === 'number') return String(n);
	if (Array.isArray(n)) return n.map(textOf).join(' ');
	return textOf(n.children);
}

function E(tag, attrs, children) {
	if (children === undefined && (typeof attrs === 'string' || Array.isArray(attrs) || attrs?.tag)) { children = attrs; attrs = {}; }
	const node = { tag, attrs: attrs || {}, children: children == null ? [] : [].concat(children) };
	// What a form control carries in a browser and the page reads back: set from the attributes,
	// and writable, so a check can type into a field the way a person does. Not enumerable, so a
	// dump of the tree shows what the page rendered and not what was typed after.
	for (const p of ['value', 'checked', 'disabled'])
		Object.defineProperty(node, p, {
			get() { return node.attrs[p] === undefined ? (p === 'value' ? '' : false) : node.attrs[p]; },
			set(v) { node.attrs[p] = v; },
		});
	return node;
}

// Every node under n, nested arrays and text included, in document order.
function walk(n, out = []) {
	if (n == null || n === false) return out;
	if (Array.isArray(n)) { n.forEach(c => walk(c, out)); return out; }
	if (typeof n === 'object') { out.push(n); walk(n.children, out); }
	return out;
}
const find = (n, pred) => walk(n).filter(x => x && typeof x === 'object' && pred(x));
const byId = (n, id) => find(n, x => x.attrs?.id === id)[0];

function world(replies) {
	const w = { calls: [], notes: [], reloads: 0, polls: [], storage: new Map() };
	const sessionStorage = {
		getItem: k => (w.storage.has(k) ? w.storage.get(k) : null),
		setItem: (k, v) => { w.storage.set(k, String(v)); },
		removeItem: k => { w.storage.delete(k); },
	};
	const windowListeners = {};
	w.window = { sessionStorage, location: { reload: () => { w.reloads++; }, protocol: 'https:' }, setTimeout: (f) => f(),
		addEventListener: (t, f) => { (windowListeners[t] ||= []).push(f); },
		// What the browser does when the page is left: the page's own listeners run, then it is gone.
		fire: (t) => { for (const f of windowListeners[t] || []) f({ type: t }); } };
	// Listeners belong to one page: a reload starts with none, as a browser does.
	w.document = {
		listeners: {},
		addEventListener(t, f) { (this.listeners[t] ||= []).push(f); },
		removeEventListener(t, f) { this.listeners[t] = (this.listeners[t] || []).filter(g => g !== f); },
		dispatchEvent(ev) { for (const f of [...(this.listeners[ev.type] || [])]) f(ev); },
	};
	w.ui = {
		addNotification: (_t, node, kind) => { w.notes.push({ text: textOf(node), kind }); },
		createHandlerFn: (ctx, fn) => (ev) => (typeof fn === 'string' ? ctx[fn] : fn).call(ctx, ev),
		showModal() {}, hideModal() {},
	};
	w.rpc = {
		declare: (d) => (...args) => {
			w.calls.push({ method: `${d.object}.${d.method}`, args });
			const r = replies[`${d.object}.${d.method}`];
			// A call that fails is a rejected promise, as in LuCI, never a throw at the call site.
			try { return Promise.resolve(typeof r === 'function' ? r(...args) : (r ?? {})); }
			catch (e) { return Promise.reject(e); }
		},
	};
	// What LuCI would apply: by default one UCI change, so the apply goes through, announces
	// itself ('uci-applied') and reloads. {} is what a key alone leaves, since keys go past
	// UCI; LuCI then answers the apply with 204 and neither announces nor reloads.
	w.staged = { hermes: [['set', 'main', 'model', 'x']] };
	w.ui.changes = { apply: (checked) => { w.calls.push({ method: 'ui.changes.apply', args: [checked] }); } };
	w.poll = { add: (fn) => { w.polls.push(fn); }, remove: (fn) => { w.polls = w.polls.filter(f => f !== fn); } };
	w.uci = { load: () => Promise.resolve(), sections: () => [],
		changes: () => { w.calls.push({ method: 'uci.changes' }); return Promise.resolve(w.staged); } };

	class Option {
		constructor(section, name) { this.section = section; this.name = name; this.values = []; }
		value(key) { this.values.push(key); }
	}
	class Section {
		constructor(map, type) { this.map = map; this.sectiontype = type; this.options = {}; }
		option(Type, name) { const o = new Type(this, name); this.options[name] = o; return o; }
		handleAdd(_ev, name) { w.calls.push({ method: 'form.handleAdd', args: [name] }); return Promise.resolve(); }
		handleRemove(id) { w.calls.push({ method: 'form.handleRemove', args: [id] }); return Promise.resolve(); }
	}
	class TypedSection extends Section {}
	class NamedSection extends Section {}
	class FormMap {
		constructor(config) { this.config = config; this.sections = []; w.map = this; }
		section(Type, ...rest) { const s = new Type(this, rest[0]); this.sections.push(s); return s; }
		render() { return Promise.resolve(E('div', {}, [])); }
	}
	w.form = new Proxy({ Map: FormMap, TypedSection, NamedSection }, { get: (t, k) => t[k] ?? class extends Option {} });
	w.view = {
		extend: (o) => Object.assign(Object.create({
			super(name) { w.calls.push({ method: `view.${name}` }); return Promise.resolve(w.duringSuper?.()); },
			// LuCI's own: every map on the page saved, which is when a key field writes.
			handleSave() { w.calls.push({ method: 'view.handleSave' }); return Promise.resolve(w.duringSuper?.()); },
		}), o),
	};
	w.baseclass = { extend: (o) => o };
	w.L = { dom: { content: (box, c) => { box.children = [].concat(c); } }, bind: (fn, ctx) => fn.bind(ctx) };
	return w;
}

function load(w, file) {
	const src = fs.readFileSync(file, 'utf8');
	const names = [], values = [];
	for (const [, mod, alias] of src.matchAll(/^'require ([\w.]+)(?: as (\w+))?';$/gm)) {
		names.push(alias || mod.split('.').pop());
		if (mod.startsWith('hermes.'))
			values.push(load(w, path.join(root, 'luci-static/resources', ...mod.split('.')) + '.js'));
		else
			values.push(w[mod] ?? (() => { throw new Error(`the stand-in has no ${mod}`); })());
	}
	return new Function(...names, 'E', '_', 'L', 'window', 'sessionStorage', 'document', src)(
		...values, E, (s) => s, w.L, w.window, w.window.sessionStorage, w.document);
}

const views = path.join(root, 'luci-static/resources/view/hermes');

// A page load in world w: load, render, return the view. A "reload" is another call
// with the same w, which keeps its sessionStorage and nothing else.
async function open(w, name) {
	w.notes = [];
	w.document.listeners = {};
	const v = load(w, path.join(views, `${name}.js`));
	const data = await v.load();
	w.page = await v.render(data);
	return v;
}

// ---- the checks --------------------------------------------------------------------

const checks = {};
let failed = 0, ran = 0;
function check(name, fn) { checks[name] = fn; }
function assert(cond, msg) { if (!cond) throw new Error(msg); }

check('check_removed_provider_takes_its_key', async () => {
	const status = { provider_keys: { claude: { set: true, managed: true }, custom: { set: true, managed: false } } };
	const w = world({ 'hermes.status': status, 'hermes.set_secret': { ok: true, action: 'cleared' } });
	await open(w, 'providers');
	const s = w.map.sections.find(x => x.sectiontype === 'provider');
	assert(s, 'the page has no provider section');

	await s.handleRemove('claude');
	const i = w.calls.findIndex(c => c.method === 'hermes.set_secret' && c.args[0] === 'provider:claude');
	assert(i >= 0, 'deleting claude left its key: no set_secret for provider:claude');
	assert(w.calls[i].args[1] === '', `deleting claude wrote "${w.calls[i].args[1]}" to its key instead of clearing it`);
	const j = w.calls.findIndex(c => c.method === 'form.handleRemove' && c.args[0] === 'claude');
	assert(j > i, 'the section was not removed, or was removed before its key');

	// A provider added in this visit, so not in the status the page loaded: its key was
	// written in this visit too, and goes the same way.
	w.calls = [];
	await s.handleRemove('fresh');
	assert(w.calls.some(c => c.method === 'hermes.set_secret' && c.args[0] === 'provider:fresh' && c.args[1] === ''),
		'a provider added in this visit was deleted without its key');

	// A key file UCI points elsewhere is the operator's: the section goes, the file stays.
	w.calls = [];
	await s.handleRemove('custom');
	assert(!w.calls.some(c => c.method === 'hermes.set_secret'), 'a key file this page does not manage was cleared');
	assert(w.calls.some(c => c.method === 'form.handleRemove' && c.args[0] === 'custom'), 'the unmanaged provider was not removed');

	// A clear the router refuses is said, and the section still goes.
	const w2 = world({ 'hermes.status': status, 'hermes.set_secret': { ok: false, error: 'disk full' } });
	await open(w2, 'providers');
	await w2.map.sections.find(x => x.sectiontype === 'provider').handleRemove('claude');
	assert(w2.notes.some(n => n.kind === 'danger' && n.text.includes('disk full')), 'a refused clear was not reported');
	assert(w2.calls.some(c => c.method === 'form.handleRemove'), 'a refused clear stopped the delete');
});

check('check_messages_survive_the_reload', async () => {
	// ChatGPT sign-in: the page polls, sees done, reloads; the reloaded page says so.
	let w = world({ 'hermes.status': {}, 'hermes.chatgpt_login': { ok: true },
		'hermes.chatgpt_login_status': { state: 'done' } });
	let v = await open(w, 'providers');
	v.watchLogin(() => {});
	assert(w.polls.length === 1, 'the sign-in is not watched');
	await w.polls[0]();
	assert(w.reloads === 1, 'a finished sign-in did not reload the page');
	await open(w, 'providers');
	assert(w.notes.some(n => /Signed in to ChatGPT/.test(n.text)), 'after the reload, nothing says the sign-in finished');
	await open(w, 'providers');
	assert(!w.notes.some(n => /Signed in to ChatGPT/.test(n.text)), 'the message is shown again on a later visit');

	// Sign-out that the router refuses: the reason is on the reloaded page.
	w = world({ 'hermes.status': { chatgpt_signed_in: true }, 'hermes.chatgpt_logout': { ok: false, error: 'auth.json is read-only' } });
	v = await open(w, 'providers');
	const box = v.renderChatGPT({ chatgpt_signed_in: true }, {});
	const out = JSON.stringify(box, (k, val) => (typeof val === 'function' ? undefined : val));
	assert(/Sign out/.test(out), 'the signed-in box has no sign-out button');
	const btn = (function find(n) { if (!n || typeof n !== 'object') return null;
		if (n.tag === 'button') return n; for (const c of n.children || []) { const f = find(c); if (f) return f; } return null; })(box);
	await btn.attrs.click();
	assert(w.reloads === 1, 'signing out did not reload the page');
	await open(w, 'providers');
	assert(w.notes.some(n => n.kind === 'danger' && n.text.includes('auth.json is read-only')), 'after the reload, a failed sign-out is not reported');

	// Save & Apply on both pages: a key that did not save, and the "Saved" line, both on
	// the page LuCI reloads into once it announces the apply ('uci-applied'). An apply
	// that is rolled back never announces it, and must leave no "Saved" behind.
	for (const [page, field] of [['providers', '_key'], ['settings', '_provider_key']]) {
		w = world({ 'hermes.status': { provider_keys: {} }, 'hermes.set_secret': { ok: false, error: 'the canary refusal' } });
		v = await open(w, page);
		const opt = w.map.sections.map(s => s.options[field]).find(Boolean);
		assert(opt && typeof opt.write === 'function', `${page}: no write-only key field ${field}`);
		w.duringSuper = () => opt.write(page === 'providers' ? 'claude' : 'main', 'sk-test');
		await v.handleSaveApply({}, '0');
		w.document.dispatchEvent({ type: 'uci-applied' });
		await open(w, page);
		assert(w.notes.some(n => n.kind === 'danger' && n.text.includes('the canary refusal')),
			`${page}: after Save & Apply's reload, the key that did not save is not reported`);
		assert(w.notes.some(n => /^Saved\./.test(n.text)), `${page}: after Save & Apply's reload, nothing says it saved`);

		v = await open(w, page);
		w.duringSuper = null;
		await v.handleSaveApply({}, '0');
		await open(w, page);
		assert(!w.notes.some(n => /^Saved\./.test(n.text)), `${page}: an apply that never went through left "Saved" for the next visit`);
	}
});

check('check_saved_when_only_a_key_changed', async () => {
	// Found on a Brume 2 on 2026-09-25 with LuCI r8: a new key typed alone, Save & Apply,
	// the key written, and the page said only LuCI's "There are no changes to apply",
	// because "Saved" waited for an announcement that an empty apply never makes; the next
	// real Save & Apply then showed "Saved" twice.
	const saved = (w) => w.notes.filter(n => /^Saved\./.test(n.text)).length;
	for (const [page, field, id] of [['providers', '_key', 'claude'], ['settings', '_provider_key', 'main']]) {
		const ok = { 'hermes.status': { provider_keys: {} }, 'hermes.set_secret': { ok: true, action: 'written' } };
		const keyField = (w) => w.map.sections.map(s => s.options[field]).find(Boolean);

		let w = world(ok);
		let v = await open(w, page);
		w.staged = {};
		w.duringSuper = () => keyField(w).write(id, 'sk-test');
		await v.handleSaveApply({}, '0');
		assert(saved(w) === 1, `${page}: a Save & Apply that changed only a key says "Saved" ${saved(w)} times on the page, not once`);
		assert(w.calls.some(c => c.method === 'ui.changes.apply'), `${page}: LuCI was not asked to apply`);
		assert(!w.storage.has('luci-app-hermes.flash'), `${page}: a key-only Save & Apply left a message for a reload that never comes`);

		// The next Save & Apply on the same page changes something, goes through and reloads.
		w.staged = { hermes: [['set', 'main', 'model', 'x']] };
		w.duringSuper = null;
		await v.handleSaveApply({}, '0');
		w.document.dispatchEvent({ type: 'uci-applied' });
		await open(w, page);
		assert(saved(w) === 1, `${page}: after the next Save & Apply that went through, "Saved" is shown ${saved(w)} times`);

		// A key that did not save, with nothing else to apply: the failure once, no "Saved".
		w = world({ ...ok, 'hermes.set_secret': { ok: false, error: 'the canary refusal' } });
		v = await open(w, page);
		w.staged = {};
		w.duringSuper = () => keyField(w).write(id, 'sk-test');
		await v.handleSaveApply({}, '0');
		const shown = w.notes.filter(n => n.kind === 'danger' && n.text.includes('the canary refusal')).length;
		assert(shown === 1, `${page}: the key that did not save is shown ${shown} times, not once`);
		assert(saved(w) === 0, `${page}: "Saved" shown beside a key that did not save, with nothing else saved`);

		// An apply that was rolled back (never announced), then one that goes through.
		w = world(ok);
		v = await open(w, page);
		await v.handleSaveApply({}, '0');
		await v.handleSaveApply({}, '0');
		w.document.dispatchEvent({ type: 'uci-applied' });
		await open(w, page);
		assert(saved(w) === 1, `${page}: after a rolled-back apply and one that went through, "Saved" is shown ${saved(w)} times`);
	}
});

check('check_stale_message_not_shown', async () => {
	const w = world({ 'hermes.status': {} });
	w.storage.set('luci-app-hermes.flash', JSON.stringify([
		{ text: 'from an apply that never reloaded', kind: 'info', at: Date.now() - 11 * 60000 },
		{ text: 'from a tab that took minutes to load', kind: 'info', at: Date.now() - 5 * 60000 },
	]));
	await open(w, 'providers');
	assert(!w.notes.some(n => n.text.includes('never reloaded')), 'a message eleven minutes old was shown');
	assert(w.notes.some(n => n.text.includes('took minutes')), 'a message five minutes old was dropped, so a page loaded slowly in the background loses it');
	w.storage.set('luci-app-hermes.flash', 'not json');
	await open(w, 'providers');
	assert(!w.storage.has('luci-app-hermes.flash'), 'unreadable storage was left for every later visit');
});

// The profile field writes hermes.main.profile on every save of the page. If it offered or
// defaulted to the old root profile, saving the page with no profile set would silently put
// the agent back to running as root, undoing the package's own default.
check('check_profile_field_defaults_to_owner', async () => {
	const w = world({ 'hermes.status': {} });
	await open(w, 'settings');
	const field = w.map.sections.map(s => s.options.profile).find(Boolean);
	assert(field, 'the settings page has no profile field');
	assert(field.default === 'owner', `the profile field defaults to '${field.default}', not 'owner'`);
	for (const v of ['owner', 'assistant', 'root'])
		assert(field.values.includes(v), `the profile field does not offer '${v}'`);
	assert(!field.values.includes('admin'), "the profile field still offers 'admin', the old name of root");
	assert(field.values[0] === 'owner', `the first choice is '${field.values[0]}', not 'owner'`);
});

// ---- the Security page --------------------------------------------------------------------
//
// What the page itself decides, as against what the rpcd backend decides (gate-luci.sh, gate-unlock.sh):
// that a PIN field is never filled in from the server, that the QR of a phone being added is on the
// page once and then gone, that a factor the router could not honour cannot be chosen, and that
// outside the owner profile, or with nothing to talk to, the page offers nothing.

const READY = { applies: true, profile: 'owner', mcp_ok: true, paired: true, factor: 'none', factor_ready: true,
	window: '15m', max_failures: 5, lockout: '15m', pin_set: false, totp_enrolled: false, totp_pending: false, packages: 'off' };
const statusOf = (over) => ({ ...READY, ...over });
const clickOf = (w, id) => { const n = byId(w.page, id); assert(n, `the page has no #${id}`); return n; };
const press = (w, id) => clickOf(w, id).attrs.click({ currentTarget: {}, target: {} });
const dump = (w) => JSON.stringify(w.page, (k, val) => (typeof val === 'function' ? undefined : val));

check('check_security_pin_fields_never_prefilled', async () => {
	// A PIN is set, and the page is told so: it must say so without a field holding anything.
	const w = world({ 'hermes.security_status': statusOf({ factor: 'pin', pin_set: true }), 'hermes.set_pin': { ok: true } });
	await open(w, 'security');
	const pins = find(w.page, n => n.tag === 'input' && n.attrs.type === 'password');
	assert(pins.length === 2, `the page has ${pins.length} password fields, not the PIN and its confirmation`);
	for (const f of pins) {
		assert(f.value === '', `a PIN field is filled in on load: "${f.value}"`);
		assert(f.attrs.autocomplete === 'new-password', `a PIN field has autocomplete "${f.attrs.autocomplete}", which lets a browser fill it from a saved password`);
	}
	assert(/PIN is set/i.test(textOf(w.page)), 'the page does not say a PIN is set');

	// Typing a PIN twice sends it once, clears both fields, and echoes it nowhere.
	const PIN = '07310528';
	const [a, b] = [byId(w.page, 'hermes-sec-pin'), byId(w.page, 'hermes-sec-pin-again')];
	assert(a && b, 'the PIN fields are not #hermes-sec-pin and #hermes-sec-pin-again');
	a.value = PIN; b.value = PIN;
	await press(w, 'hermes-sec-pin-set');
	const call = w.calls.find(c => c.method === 'hermes.set_pin');
	assert(call && call.args[0] === PIN && call.args[1] === PIN, 'set_pin was not called with the PIN and its confirmation');
	assert(a.value === '' && b.value === '', 'the PIN stayed in its fields after it was sent');
	assert(!JSON.stringify([w.notes, [...w.storage.values()]]).includes(PIN), 'the PIN is in a message or in the tab\'s storage');
	assert(!dump(w).includes(PIN), 'the PIN is in the page after it was sent');

	// A PIN the router refuses is cleared too, and the reason is shown without the PIN.
	const w2 = world({ 'hermes.security_status': statusOf(), 'hermes.set_pin': { ok: false, error: 'the router said no' } });
	await open(w2, 'security');
	byId(w2.page, 'hermes-sec-pin').value = PIN; byId(w2.page, 'hermes-sec-pin-again').value = PIN;
	await press(w2, 'hermes-sec-pin-set');
	assert(byId(w2.page, 'hermes-sec-pin').value === '' && byId(w2.page, 'hermes-sec-pin-again').value === '', 'a refused PIN stayed in its field');
	assert(w2.notes.some(n => n.kind === 'danger' && n.text.includes('the router said no')), 'a refused PIN was not reported');
	assert(!JSON.stringify(w2.notes).includes(PIN), 'a message repeats the PIN');

	// And one that is not 4 to 8 digits, or not typed twice the same, never leaves the page.
	for (const [x, y] of [['123', '123'], ['123456789', '123456789'], ['12ab', '12ab'], ['4821', '4822'], ['', '']]) {
		const w3 = world({ 'hermes.security_status': statusOf(), 'hermes.set_pin': { ok: true } });
		await open(w3, 'security');
		byId(w3.page, 'hermes-sec-pin').value = x; byId(w3.page, 'hermes-sec-pin-again').value = y;
		await press(w3, 'hermes-sec-pin-set');
		assert(!w3.calls.some(c => c.method === 'hermes.set_pin'), `the PIN "${x}" / "${y}" was sent`);
		assert(w3.notes.some(n => n.kind === 'danger'), `the PIN "${x}" / "${y}" was refused without a word`);
	}
});

check('check_security_pin_saved_points_to_the_factor', async () => {
	// The PIN and the factor have a Save each. On 2026-10-08 a person set the PIN, missed the
	// factor's Save, and the router went on refusing every change. With the factor at none, a saved
	// PIN says, after the reload, where to choose it and which Save to press.
	const w = world({ 'hermes.security_status': statusOf({ factor: 'none' }), 'hermes.set_pin': { ok: true } });
	await open(w, 'security');
	assert(/What unlocking asks for/.test(textOf(w.page)), 'the page has no section "What unlocking asks for" for the message to point at');
	byId(w.page, 'hermes-sec-pin').value = '4821'; byId(w.page, 'hermes-sec-pin-again').value = '4821';
	await press(w, 'hermes-sec-pin-set');
	assert(w.reloads === 1, 'a saved PIN did not reload the page');
	await open(w, 'security');   // the reload: what was kept is shown now
	const hint = w.notes.find(n => /What unlocking asks for/.test(n.text) && /\bSave\b/.test(n.text) && /\bPIN\b/.test(n.text));
	assert(hint, `after the reload the page does not tell the owner to choose PIN under "What unlocking asks for" and press Save: ${JSON.stringify(w.notes)}`);
	assert(hint.kind !== 'info', `the message that the PIN is not asked for yet is shown as "${hint.kind}", like any other note`);
	assert(!JSON.stringify(w.notes).includes('4821'), 'a message repeats the PIN');
	// With a factor in force that asks for the PIN, a changed PIN needs no such message.
	for (const factor of ['pin', 'pin+totp']) {
		const w2 = world({ 'hermes.security_status': statusOf({ factor, pin_set: true, totp_enrolled: true }), 'hermes.set_pin': { ok: true } });
		await open(w2, 'security');
		byId(w2.page, 'hermes-sec-pin').value = '4821'; byId(w2.page, 'hermes-sec-pin-again').value = '4821';
		await press(w2, 'hermes-sec-pin-set');
		await open(w2, 'security');
		assert(w2.notes.some(n => /PIN saved/.test(n.text)), `with the factor ${factor} a saved PIN says nothing`);
		assert(!w2.notes.some(n => /What unlocking asks for/.test(n.text)), `with the factor ${factor} the page still says to choose PIN`);
	}
	// And a PIN the router refused does not send the owner to the factor.
	const w3 = world({ 'hermes.security_status': statusOf({ factor: 'none' }), 'hermes.set_pin': { ok: false, error: 'no' } });
	await open(w3, 'security');
	byId(w3.page, 'hermes-sec-pin').value = '4821'; byId(w3.page, 'hermes-sec-pin-again').value = '4821';
	await press(w3, 'hermes-sec-pin-set');
	assert(![...w3.storage.values()].join('').includes('What unlocking asks for'), 'a refused PIN still kept the message to choose it');
});

check('check_security_qr_shown_once', async () => {
	const SECRET = 'JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP', PNG = 'iVBORw0KGgoQRPNGBASE64';
	const MORE = 'MFRGGZDFMZTWQ2LKNNWG23TPOBYXE43U', MOREPNG = 'iVBORw0KGgoSECONDPNG';
	let started = 0;
	const replies = () => ({
		'hermes.security_status': statusOf(),
		'hermes.enrol_start': () => (++started === 1
			? { ok: true, uri: `otpauth://totp/openwrt-mcp:hermes-main@r?secret=${SECRET}`, secret: SECRET, qr_png_base64: PNG }
			: { ok: true, uri: `otpauth://totp/openwrt-mcp:hermes-main@r?secret=${MORE}`, secret: MORE, qr_png_base64: MOREPNG }),
		'hermes.enrol_activate': (code) => (code === '123456' ? { ok: true } : { ok: false, error: 'that code is not valid right now' }),
	});
	const shown = (w, secret, png) => dump(w).includes(secret) || dump(w).includes(png);
	const nowhereElse = (w, ...needles) => {
		const rest = JSON.stringify([w.notes, [...w.storage.values()], w.calls.filter(c => c.method !== 'hermes.enrol_start').map(c => c.args)]);
		for (const n of needles) assert(!rest.includes(n), 'the QR material is in a message, in the tab\'s storage or in a call');
	};

	let w = world(replies());
	await open(w, 'security');
	assert(!shown(w, SECRET, PNG) && !find(w.page, n => n.tag === 'img').length, 'a QR is on the page before anyone asked for one');
	await press(w, 'hermes-sec-enrol');
	const img = find(w.page, n => n.tag === 'img')[0];
	assert(img && String(img.attrs.src).includes(PNG), 'asking to add a phone shows no QR');
	assert(String(img.attrs.src).startsWith('data:image/png;base64,'), 'the QR is not a data: image, so it would be fetched from somewhere');
	assert(textOf(w.page).includes(SECRET), 'the secret is not shown for manual entry');
	assert(byId(w.page, 'hermes-sec-code'), 'the page asks for no code');
	nowhereElse(w, SECRET, PNG);

	// a code that is wrong leaves the QR where it is, so the owner can try again from the same scan
	byId(w.page, 'hermes-sec-code').value = '654321';
	await press(w, 'hermes-sec-activate');
	assert(w.notes.some(n => n.kind === 'danger' && n.text.includes('not valid')), 'a wrong code was not reported');
	assert(shown(w, SECRET, PNG), 'a wrong code took the QR away, so the scan cannot be tried again');
	assert(w.reloads === 0, 'a wrong code reloaded the page');

	// the right code: activated, and the QR is gone from the page, with the secret
	byId(w.page, 'hermes-sec-code').value = '123456';
	await press(w, 'hermes-sec-activate');
	assert(w.calls.some(c => c.method === 'hermes.enrol_activate' && c.args[0] === '123456'), 'enrol_activate was not called with the code');
	assert(!shown(w, SECRET, PNG), 'the QR or the secret is still on the page after the phone was activated');
	assert(!find(w.page, n => n.tag === 'img').length, 'an image is still on the page after activation');
	nowhereElse(w, SECRET, PNG);
	assert(w.reloads === 1 && /phone/i.test([...w.storage.values()].join('')), 'activation did not reload the page with a message saying so');

	// leaving the page without a code: gone from the page, nothing kept
	started = 0; w = world(replies());
	await open(w, 'security');
	await press(w, 'hermes-sec-enrol');
	assert(shown(w, SECRET, PNG), 'the QR did not show');
	w.window.fire('pagehide');
	assert(!shown(w, SECRET, PNG), 'the QR is still on the page after it was left');
	nowhereElse(w, SECRET, PNG);

	// cancelling does the same, and says the old state is in force
	started = 0; w = world(replies());
	await open(w, 'security');
	await press(w, 'hermes-sec-enrol');
	await press(w, 'hermes-sec-cancel');
	assert(!shown(w, SECRET, PNG), 'the QR is still on the page after Cancel');
	assert(/still in force|nothing changed/i.test(textOf(w.page) + JSON.stringify(w.notes)), 'Cancel does not say that what was in force stays in force');

	// asking again shows the new material and none of the old
	started = 0; w = world(replies());
	await open(w, 'security');
	await press(w, 'hermes-sec-enrol');
	await press(w, 'hermes-sec-enrol');
	assert(shown(w, MORE, MOREPNG), 'a second start did not show the new QR');
	assert(!shown(w, SECRET, PNG), 'the first QR is still on the page beside the second');
});

check('check_security_factor_needs_its_prerequisite', async () => {
	const radios = (w) => Object.fromEntries(['none', 'pin', 'totp', 'pin+totp'].map(f => [f, byId(w.page, `hermes-sec-factor-${f}`)]));
	const cases = [
		['nothing set up', {}, { none: 1, pin: 0, totp: 0, 'pin+totp': 0 }],
		['a PIN', { pin_set: true }, { none: 1, pin: 1, totp: 0, 'pin+totp': 0 }],
		['a phone', { totp_enrolled: true }, { none: 1, pin: 0, totp: 1, 'pin+totp': 0 }],
		['a phone only being added', { totp_pending: true }, { none: 1, pin: 0, totp: 0, 'pin+totp': 0 }],
		['a PIN and a phone being added', { pin_set: true, totp_pending: true }, { none: 1, pin: 1, totp: 0, 'pin+totp': 0 }],
		['both', { pin_set: true, totp_enrolled: true }, { none: 1, pin: 1, totp: 1, 'pin+totp': 1 }],
	];
	for (const [what, over, allowed] of cases) {
		const w = world({ 'hermes.security_status': statusOf(over), 'hermes.set_factor': { ok: true } });
		await open(w, 'security');
		const r = radios(w);
		for (const f of Object.keys(allowed)) {
			assert(r[f], `no choice for factor ${f}`);
			assert(!r[f].disabled === !!allowed[f], `with ${what}, the choice "${f}" is ${r[f].disabled ? 'disabled' : 'open'}, want ${allowed[f] ? 'open' : 'disabled'}`);
		}
		// Choosing what is disabled anyway (a browser lets a script, an old tab or a stale page do it) sends nothing.
		for (const f of Object.keys(allowed).filter(f => !allowed[f])) {
			for (const g of Object.keys(r)) r[g].checked = (g === f);
			await press(w, 'hermes-sec-save');
			assert(!w.calls.some(c => c.method === 'hermes.set_factor'), `with ${what}, saving "${f}" asked the router for it`);
		}
	}

	// What is open can be saved, with the settings next to it, as the number and the durations the backend takes.
	const w = world({ 'hermes.security_status': statusOf({ pin_set: true, totp_enrolled: true, factor: 'none' }), 'hermes.set_factor': { ok: true } });
	await open(w, 'security');
	const r = radios(w);
	for (const g of Object.keys(r)) r[g].checked = (g === 'pin+totp');
	byId(w.page, 'hermes-sec-window').value = '30m';
	byId(w.page, 'hermes-sec-max').value = '3';
	byId(w.page, 'hermes-sec-lockout').value = '1h';
	await press(w, 'hermes-sec-save');
	const call = w.calls.find(c => c.method === 'hermes.set_factor');
	assert(call, 'an open choice was not saved');
	assert(JSON.stringify(call.args) === JSON.stringify(['pin+totp', '30m', 3, '1h']), `set_factor was called with ${JSON.stringify(call.args)}`);
	assert(w.reloads === 1, 'a saved factor did not reload the page to show what is now in force');

	// Settings the backend would refuse do not leave the page.
	for (const [win, max, lock] of [['15', '5', '15m'], ['', '5', '15m'], ['15m', '0', '15m'], ['15m', 'five', '15m'], ['15m', '5', 'a day']]) {
		const w2 = world({ 'hermes.security_status': statusOf({ pin_set: true }), 'hermes.set_factor': { ok: true } });
		await open(w2, 'security');
		byId(w2.page, 'hermes-sec-window').value = win; byId(w2.page, 'hermes-sec-max').value = max; byId(w2.page, 'hermes-sec-lockout').value = lock;
		await press(w2, 'hermes-sec-save');
		assert(!w2.calls.some(c => c.method === 'hermes.set_factor'), `window "${win}", failures "${max}", lockout "${lock}" were sent`);
		assert(w2.notes.some(n => n.kind === 'danger'), `window "${win}", failures "${max}", lockout "${lock}" were refused without a word`);
	}

	// A PIN cannot be cleared while the factor in force asks for it: that is how the owner locks themselves out.
	for (const [factor, may] of [['none', true], ['totp', true], ['pin', false], ['pin+totp', false]]) {
		const w3 = world({ 'hermes.security_status': statusOf({ pin_set: true, totp_enrolled: true, factor }), 'hermes.clear_pin': { ok: true } });
		await open(w3, 'security');
		const clear = byId(w3.page, 'hermes-sec-pin-clear');
		assert(clear, 'a PIN is set and the page offers no way to clear it');
		assert(!clear.disabled === may, `with the factor ${factor} the Clear PIN button is ${clear.disabled ? 'disabled' : 'open'}`);
	}
	const w4 = world({ 'hermes.security_status': statusOf() });
	await open(w4, 'security');
	assert(!byId(w4.page, 'hermes-sec-pin-clear') || byId(w4.page, 'hermes-sec-pin-clear').disabled, 'Clear PIN is offered when no PIN is set');
});

check('check_security_page_offers_nothing_it_cannot_do', async () => {
	const nothing = (w, why) => {
		const controls = find(w.page, n => ['input', 'button', 'select', 'textarea'].includes(n.tag));
		assert(!controls.length, `${why}: the page offers ${controls.length} controls (${controls.map(c => c.attrs.id || c.tag).slice(0, 3)})`);
	};
	for (const [why, reply, words] of [
		['the profile is root', statusOf({ applies: false, profile: 'root' }), /owner profile/i],
		['the profile is assistant', statusOf({ applies: false, profile: 'assistant' }), /owner profile/i],
		['the status call failed', {}, /could not|cannot|can't/i],
		['openwrt-mcp does not answer', statusOf({ mcp_ok: false, paired: false }), /openwrt-mcp/i],
		['the agent was never started, so hermes-main is not paired', statusOf({ paired: false }), /start/i],
	]) {
		const w = world({ 'hermes.security_status': reply });
		await open(w, 'security');
		nothing(w, why);
		assert(words.test(textOf(w.page)), `${why}: the page does not say why it offers nothing: "${textOf(w.page).slice(0, 120)}"`);
	}
	// A call that fails outright is the same as no answer.
	const w2 = world({ 'hermes.security_status': () => { throw new Error('no such method'); } });
	await open(w2, 'security');
	nothing(w2, 'the status call threw');
	// And the control: the owner profile, with everything there, is not an empty page.
	const w3 = world({ 'hermes.security_status': statusOf() });
	await open(w3, 'security');
	assert(find(w3.page, n => n.tag === 'input').length >= 4 && find(w3.page, n => n.tag === 'button').length >= 3, 'the owner profile page offers nothing, so the checks above prove nothing');
	// The page says what it cannot show.
	assert(/\/lock/.test(textOf(w3.page)) && /window/i.test(textOf(w3.page)), 'the page does not say that the live window cannot be shown here and that /lock closes it');
});

check('check_security_packages_switch_needs_a_factor', async () => {
	// The owner's opt-in to package installs from the official OpenWrt feed (0.21.5-r13, LuCI r3).
	// An install waits for an unlock like any change, so the switch is turned on only with a factor in
	// force, and it is always open to turn off; what it sends is official or off and nothing else.
	const LABEL = 'Let the agent install packages from the official OpenWrt feed';
	const box = (w) => byId(w.page, 'hermes-sec-packages');
	const sent = (w) => w.calls.filter(c => c.method === 'hermes.set_packages').map(c => c.args[0]);

	// No factor: the switch is there, off and closed, and a tick a script makes anyway sends nothing.
	let w = world({ 'hermes.security_status': statusOf({ factor: 'none' }), 'hermes.set_packages': { ok: true } });
	await open(w, 'security');
	assert(box(w), 'the page has no #hermes-sec-packages switch');
	assert(textOf(w.page).includes(LABEL), `the switch is not labelled "${LABEL}"`);
	assert(!box(w).checked, 'the switch is on although packages is off');
	assert(box(w).disabled, 'with no factor in force the switch can be turned on');
	box(w).checked = true;
	await press(w, 'hermes-sec-packages-save');
	assert(!sent(w).length, `with no factor in force the page sent set_packages ${JSON.stringify(sent(w))}`);
	assert(w.notes.some(n => n.kind === 'danger' && /factor/i.test(n.text)), 'a refused switch says nothing about the factor it needs');

	// A factor whose prerequisite is gone counts as none.
	w = world({ 'hermes.security_status': statusOf({ factor: 'pin', factor_ready: false }), 'hermes.set_packages': { ok: true } });
	await open(w, 'security');
	assert(box(w).disabled, 'with a factor that cannot be satisfied the switch can be turned on');

	// Each factor: open, and on sends official, then reloads to show what is now set.
	for (const factor of ['pin', 'totp', 'pin+totp']) {
		w = world({ 'hermes.security_status': statusOf({ factor, pin_set: true, totp_enrolled: true }), 'hermes.set_packages': { ok: true } });
		await open(w, 'security');
		assert(!box(w).disabled, `with the factor ${factor} the switch cannot be turned on`);
		box(w).checked = true;
		await press(w, 'hermes-sec-packages-save');
		assert(JSON.stringify(sent(w)) === '["official"]', `with the factor ${factor} the switch sent ${JSON.stringify(sent(w))}, not official`);
		assert(w.reloads === 1, 'a saved switch did not reload the page');
	}

	// On, it shows on, and turning it off sends off.
	w = world({ 'hermes.security_status': statusOf({ factor: 'pin', pin_set: true, packages: 'official' }), 'hermes.set_packages': { ok: true } });
	await open(w, 'security');
	assert(box(w).checked, 'packages official is shown off');
	box(w).checked = false;
	await press(w, 'hermes-sec-packages-save');
	assert(JSON.stringify(sent(w)) === '["off"]', `turning the switch off sent ${JSON.stringify(sent(w))}`);

	// On with no factor (the factor was taken away since): it can be turned off, and the page says
	// the agent is given nothing to install with; saving it on is refused on the page.
	w = world({ 'hermes.security_status': statusOf({ factor: 'none', packages: 'official' }), 'hermes.set_packages': { ok: true } });
	await open(w, 'security');
	assert(box(w).checked && !box(w).disabled, 'an opt-in left on with no factor cannot be turned off');
	assert(/no second factor/i.test(textOf(w.page)), 'an opt-in with no factor in force is not said to give nothing');
	await press(w, 'hermes-sec-packages-save');
	assert(!sent(w).length, 'an opt-in with no factor in force was saved on again');
	box(w).checked = false;
	await press(w, 'hermes-sec-packages-save');
	assert(JSON.stringify(sent(w)) === '["off"]', `turning it off with no factor sent ${JSON.stringify(sent(w))}`);

	// What the router refuses is shown, and nothing reloads.
	w = world({ 'hermes.security_status': statusOf({ factor: 'pin', pin_set: true }), 'hermes.set_packages': { ok: false, error: 'the router said no' } });
	await open(w, 'security');
	box(w).checked = true;
	await press(w, 'hermes-sec-packages-save');
	assert(w.notes.some(n => n.kind === 'danger' && n.text.includes('the router said no')), 'a refused switch was not reported');
	assert(w.reloads === 0, 'a refused switch reloaded the page');

	// Outside the owner profile there is no switch either.
	w = world({ 'hermes.security_status': statusOf({ applies: false, profile: 'root' }) });
	await open(w, 'security');
	assert(!box(w), 'the root profile page offers the package switch');
});

for (const [name, fn] of Object.entries(checks)) {
	if (only.size && !only.has(name)) continue;
	ran++;
	try { await fn(); console.log(`PASS ${name}`); }
	catch (e) { failed++; console.log(`FAIL ${name}: ${e.message}`); }
}
if (ran === 0) { console.log('FAIL harness: no check ran; measured nothing'); process.exit(1); }
process.exit(failed ? 1 : 0);
