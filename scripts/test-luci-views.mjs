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
	return { tag, attrs: attrs || {}, children: children == null ? [] : [].concat(children) };
}

function world(replies) {
	const w = { calls: [], notes: [], reloads: 0, polls: [], storage: new Map() };
	const sessionStorage = {
		getItem: k => (w.storage.has(k) ? w.storage.get(k) : null),
		setItem: (k, v) => { w.storage.set(k, String(v)); },
		removeItem: k => { w.storage.delete(k); },
	};
	w.window = { sessionStorage, location: { reload: () => { w.reloads++; } }, setTimeout: (f) => f() };
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
			return Promise.resolve(typeof r === 'function' ? r(...args) : (r ?? {}));
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
		constructor(section, name) { this.section = section; this.name = name; }
		value() {}
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
	await v.render(data);
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

for (const [name, fn] of Object.entries(checks)) {
	if (only.size && !only.has(name)) continue;
	ran++;
	try { await fn(); console.log(`PASS ${name}`); }
	catch (e) { failed++; console.log(`FAIL ${name}: ${e.message}`); }
}
if (ran === 0) { console.log('FAIL harness: no check ran; measured nothing'); process.exit(1); }
process.exit(failed ? 1 : 0);
