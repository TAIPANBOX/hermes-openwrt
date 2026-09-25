'use strict';
'require view';
'require form';
'require rpc';
'require ui';
'require uci';
'require poll';
'require hermes.flash as flash';

/* Providers.
 *
 * Every chat starts on the model from the Settings tab. The providers here are offered
 * beside it: in a chat, /model lists them and switches that chat only, so several
 * chats can run on several providers at the same time. Each one is a UCI `provider`
 * section whose key lives in a root-only file, exactly like the main key, and the key
 * field is write-only for the same reason: the page is never sent a key.
 *
 * A ChatGPT subscription is not a section. Signing in runs upstream's device-code flow
 * on the router; this page shows the address and the code to enter in a browser that
 * is signed in to ChatGPT, and the tokens stay on the router.
 */

var callStatus      = rpc.declare({ object: 'hermes', method: 'status' });
var callSetSecret   = rpc.declare({ object: 'hermes', method: 'set_secret', params: ['name', 'value'] });
var callLogin       = rpc.declare({ object: 'hermes', method: 'chatgpt_login' });
var callLoginStatus = rpc.declare({ object: 'hermes', method: 'chatgpt_login_status' });
var callLogout      = rpc.declare({ object: 'hermes', method: 'chatgpt_logout' });

/* Names the service refuses because upstream answers to them itself: listed here so
 * the page can say so before a save rather than after a restart. The service checks
 * the full set at every start; this is only the part people reach for. */
var TAKEN = ['anthropic', 'openrouter', 'openai', 'openai-api', 'openai-codex', 'custom',
	'auto', 'nous', 'gemini', 'deepseek', 'xai', 'provider'];
var NAME = /^[a-z][a-z0-9-]{0,30}$/;

/* Failures reported during a save, kept for the page that Save & Apply reloads into:
 * shown only before the reload, a failure is shown for a few seconds under LuCI's own
 * "applying" status and then gone. See hermes/flash.js. */
var failures = [];

function fail(text) {
	failures.push(text);
	ui.addNotification(null, E('p', {}, text), 'danger');
}

function reportSecretWrite(label, promise) {
	return promise.then(function (reply) {
		if (!reply || reply.ok === false)
			fail(_('The %s was not saved: %s').format(label, (reply && reply.error) || _('unknown error')));
		return reply;
	}, function () {
		fail(_('The %s was not saved: %s').format(label, _('unknown error')));
	});
}

function restartService() {
	return rpc.declare({
		object: 'luci', method: 'setInitAction',
		params: ['name', 'action'], expect: { result: false }
	})('hermes-agent', 'restart').catch(function () {});
}

return view.extend({
	load: function () {
		return Promise.all([
			uci.load('hermes'),
			callStatus().catch(function () { return {}; }),
			callLoginStatus().catch(function () { return {}; })
		]);
	},

	renderChatGPT: function (st, login) {
		var box = E('div', { 'class': 'cbi-section', 'id': 'hermes-chatgpt' });
		var self = this, dom = L.dom;

		function paint(state) {
			var body = [];
			if (state && (state.state === 'starting' || state.state === 'waiting')) {
				body.push(E('p', {}, _('Signing in. Open the address below in a browser where you are signed in to ChatGPT and enter the code. This page notices when it is done.')));
				if (state.url)
					body.push(E('p', {}, E('a', { 'href': state.url, 'target': '_blank', 'rel': 'noopener' }, state.url)));
				body.push(E('p', { 'style': 'font-size:1.6em;font-family:monospace;letter-spacing:.1em' },
					state.code || _('waiting for a code...')));
			} else if (st.chatgpt_signed_in) {
				body.push(E('p', {}, _('Signed in. /model in a chat offers the ChatGPT subscription beside the other providers.')));
				body.push(E('button', { 'class': 'cbi-button cbi-button-remove', 'click': ui.createHandlerFn(self, function () {
					return callLogout().then(function (r) {
						if (!r || r.ok === false)
							flash.keep((r && r.error) || _('Signing out failed.'), 'danger');
						else
							flash.keep(_('Signed out of ChatGPT.'), 'info');
						window.location.reload();
					});
				}) }, _('Sign out')));
			} else {
				if (state && state.state === 'failed')
					body.push(E('p', { 'class': 'alert-message warning' }, _('The last sign-in did not finish: %s').format(state.message || _('unknown error'))));
				body.push(E('p', {}, _('Not signed in. ChatGPT has to allow it first: Settings, Security, device code sign-in. Signing in restarts the service if it is running.')));
				body.push(E('button', { 'class': 'cbi-button cbi-button-action', 'click': ui.createHandlerFn(self, function () {
					return callLogin().then(function (r) {
						if (!r || r.ok === false) {
							ui.addNotification(null, E('p', {}, (r && r.error) || _('Signing in could not start.')), 'danger');
							return;
						}
						self.watchLogin(paint);
					});
				}) }, _('Sign in to ChatGPT')));
			}
			dom.content(box, [E('h3', {}, _('ChatGPT subscription'))].concat(body));
		}

		paint(login);
		if (login && (login.state === 'starting' || login.state === 'waiting'))
			this.watchLogin(paint);
		return box;
	},

	watchLogin: function (paint) {
		var fn = function () {
			return callLoginStatus().then(function (state) {
				if (state.state === 'done') {
					poll.remove(fn);
					flash.keep(_('Signed in to ChatGPT. The service was restarted if it was running.'), 'info');
					window.location.reload();
					return;
				}
				if (state.state === 'failed' || state.state === 'none')
					poll.remove(fn);
				paint(state);
			});
		};
		poll.add(fn, 3);
	},

	render: function (data) {
		var st = data[1] || {}, login = data[2] || {};
		var keys = st.provider_keys || {};
		var m, s, o;

		m = new form.Map('hermes', _('Providers'),
			_('Every chat starts on the model from the Settings tab. The providers here are offered beside it: in a chat, /model lists them and switches that chat only. Anyone allowed to talk to the bot can switch to any of them, keys that cost money per call included.'));

		s = m.section(form.TypedSection, 'provider', _('Further providers'),
			_('The section name is the provider\'s name in /model: lower-case letters, digits and "-". Names upstream already uses for a provider of its own, such as anthropic or openrouter, are refused; pick your own, such as claude. Deleting a provider deletes its key as well.'));
		s.addremove = true;
		s.anonymous = false;
		s.handleAdd = function (ev, name) {
			if (!NAME.test(name || '')) {
				ui.addNotification(null, E('p', {}, _('A provider name is lower-case letters, digits and "-", starting with a letter.')), 'danger');
				return;
			}
			if (TAKEN.indexOf(name) >= 0) {
				ui.addNotification(null, E('p', {}, _('"%s" is a name upstream already uses; choose another, such as claude.').format(name)), 'danger');
				return;
			}
			return form.TypedSection.prototype.handleAdd.apply(this, [ev, name]);
		};
		/* The key goes with the provider. Left behind, it was invisible here and came back
		 * as "stored" the moment a provider of the same name was added, with a key nobody
		 * had typed into it (found on a Brume 2, 2026-09-25). Removed at the delete rather
		 * than at the apply: a delete that is then reverted brings the provider back
		 * without a key and says so, which is the safe way round. A key file UCI points
		 * elsewhere is the operator's and stays where it is. */
		s.handleRemove = function (section_id, ev) {
			var self = this, k = keys[section_id];
			var gone = (k && k.managed === false) ? Promise.resolve() :
				callSetSecret('provider:' + section_id, '').then(function (reply) {
					if (!reply || reply.ok === false)
						fail(_('The key for %s was not removed: %s').format(section_id, (reply && reply.error) || _('unknown error')));
				}, function () {
					fail(_('The key for %s was not removed: %s').format(section_id, _('unknown error')));
				});
			return gone.then(function () {
				return form.TypedSection.prototype.handleRemove.apply(self, [section_id, ev]);
			});
		};

		o = s.option(form.Flag, 'enabled', _('Offer it'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'label', _('Shown as'), _('The name /model shows. Optional.'));
		o.optional = true;

		o = s.option(form.Value, 'base_url', _('API endpoint'));
		o.rmempty = false;
		o.value('https://api.anthropic.com/v1', _('Anthropic'));
		o.value('https://openrouter.ai/api/v1', _('OpenRouter'));
		o.value('https://api.openai.com/v1', _('OpenAI'));
		o.value('https://api.mistral.ai/v1', _('Mistral'));
		o.value('https://api.deepseek.com/v1', _('DeepSeek'));
		o.validate = function (section_id, value) {
			return /^https?:\/\/[^\s@|;]+$/.test(value || '') ? true : _('An http(s) address, without credentials in it.');
		};

		o = s.option(form.Value, 'model', _('Model'), _('The model a chat gets when it switches here, as this endpoint names it, such as claude-haiku-4-5.'));
		o.rmempty = false;
		o.validate = function (section_id, value) {
			return (value && !/[|;]/.test(value)) ? true : _('A model name, without "|" or ";".');
		};

		/* Presence only, per section: whether a key is stored and whether this page
		 * manages its file. Never the key. */
		o = s.option(form.DummyValue, '_key_state', _('Key'));
		o.cfgvalue = function (section_id) {
			var k = keys[section_id];
			if (k && k.managed === false)
				return _('read from a custom file this page does not manage; set it on the router');
			return (k && k.set) ? _('stored') : _('not set: until one is, this provider is left out and the log says so');
		};

		/* Write-only, like the main key: the value is never read back. */
		o = s.option(form.Value, '_key', _('API key'), _('Type a key to store or replace it; leave empty to keep what is stored.'));
		o.password = true;
		o.rmempty = true;
		o.placeholder = _('type to set or replace');
		o.cfgvalue = function () { return ''; };
		o.write = function (section_id, value) {
			if (!value) return;
			return reportSecretWrite(_('key for %s').format(section_id), callSetSecret('provider:' + section_id, value));
		};
		o.remove = function () { return; };

		return m.render().then(L.bind(function (node) {
			flash.show();
			return E('div', {}, [node, this.renderChatGPT(st, login)]);
		}, this));
	},

	/* LuCI reloads the page a few seconds after the apply, so what this has to say is
	 * kept for the page it reloads into rather than shown here. */
	handleSaveApply: function (ev, mode) {
		failures = [];
		return this.super('handleSaveApply', [ev, mode]).then(function () {
			return restartService();
		}).then(function () {
			failures.forEach(function (text) { flash.keep(text, 'danger'); });
			flash.keep(_('Saved. The service was restarted; the Overview tab shows whether it stayed up and which providers it left out.'), 'info');
		});
	}
});
