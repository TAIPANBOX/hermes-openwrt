'use strict';
'require view';
'require form';
'require rpc';
'require ui';
'require uci';

/* Settings.
 *
 * Everything that is not a secret is ordinary UCI and handled by form.Map. The secrets
 * are not, and the difference is the point of this file.
 *
 * A key put into UCI ends up in /etc/config, which is world-readable, lands in every
 * support bundle, and is printed in full by `uci show`. So keys live in root-only files
 * instead, and the fields below are WRITE-ONLY: the page is never sent a key, so the
 * browser never holds one, no screenshot of this page can contain one, and reloading
 * shows only whether a key exists. The cost is that you cannot check a key by looking
 * at it, which is the same trade every password field on the internet makes.
 */

var callStatus    = rpc.declare({ object: 'hermes', method: 'status' });
var callSetSecret = rpc.declare({
	object: 'hermes',
	method: 'set_secret',
	params: ['name', 'value']
});

return view.extend({
	load: function () {
		return Promise.all([
			uci.load('hermes'),
			callStatus().catch(function () { return {}; })
		]);
	},

	render: function (data) {
		var st = data[1] || {};
		var m, s, o;

		m = new form.Map('hermes', _('Hermes Agent'),
			_('The agent runs here; the model runs elsewhere. Point it at a provider, give it a key, and turn it on.'));

		s = m.section(form.NamedSection, 'main', 'hermes', _('Service'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enable'),
			_('The service refuses to start until a model and a key are configured, and says which is missing in the log.'));
		o.rmempty = false;

		o = s.option(form.Value, 'data_dir', _('Data directory'),
			_('Sessions, memory and skills. This only grows. On a router with a small overlay, point it at external storage.'));
		o.default = '/srv/hermes';
		o.rmempty = false;

		o = s.option(form.Value, 'mem_max_mb', _('Memory limit (MB)'),
			_('A ceiling enforced by procd through cgroups rather than by trusting the process. Upstream\'s gateway is known to grow its memory over long uptimes, and on a router an unbounded process takes the whole box. About half the RAM is a sensible value; 0 disables the limit.'));
		o.datatype = 'uinteger';
		o.default = '512';

		/* ---- the model ---- */
		s = m.section(form.NamedSection, 'main', 'hermes', _('Model'));
		s.anonymous = true;

		o = s.option(form.Value, 'base_url', _('API endpoint'),
			_('Anything that speaks the OpenAI protocol. A local model on this router is not a supported configuration: the agent\'s own prompt is thousands of tokens and a router CPU takes minutes to read it before answering.'));
		o.default = 'https://openrouter.ai/api/v1';
		o.rmempty = false;
		/* Suggestions, not a closed list: the field stays free text because the whole
		 * point of the OpenAI protocol is that anything speaking it will do. What is
		 * listed is what people actually reach for first. */
		o.value('https://api.openai.com/v1', _('OpenAI, with your own API key'));
		o.value('https://openrouter.ai/api/v1', _('OpenRouter, one key for many models'));
		o.value('https://api.anthropic.com/v1', _('Anthropic'));
		o.value('https://api.mistral.ai/v1', _('Mistral'));
		o.value('https://api.deepseek.com/v1', _('DeepSeek'));
		o.value('http://192.168.1.10:11434/v1', _('Ollama on a machine in your LAN'));
		o.value('http://192.168.1.10:8080/v1', _('llama-server on a machine in your LAN'));

		o = s.option(form.Value, 'model', _('Model'),
			_('Whatever name the endpoint above uses. OpenRouter wants a vendor prefix such as anthropic/claude-haiku-4.5; OpenAI wants a bare name such as gpt-5.4-mini; a local server wants whatever it loaded.'));
		o.default = 'anthropic/claude-haiku-4.5';
		o.rmempty = false;
		o.value('gpt-5.4-mini');
		o.value('anthropic/claude-haiku-4.5');
		o.value('openai/gpt-5.4-mini');
		o.value('deepseek-chat');

		/* A note rather than a check. The two mistakes that cost a first-time user an
		 * afternoon are pointing at OpenAI with an OpenRouter-style model name and the
		 * reverse, and neither produces a useful error: the provider simply says the
		 * model does not exist. */
		o = s.option(form.DummyValue, '_model_note', ' ');
		o.rawhtml = true;
		o.cfgvalue = function () {
			return '<em>' + _('A key from one provider will not work against another\'s endpoint, and the error you get says only that the model was not found.') + '</em>';
		};

		/* Write-only. The value is never read back from the device, so what is typed
		 * here leaves the browser and does not return. */
		o = s.option(form.Value, '_provider_key', _('API key'),
			st.provider_key_set
				? _('A key is stored. Type a new one to replace it, or leave this empty to keep it.')
				: _('No key is stored. The service will refuse to start without one.'));
		o.password = true;
		o.rmempty = true;
		o.placeholder = st.provider_key_set ? '••••••••  ' + _('stored') : _('not set');
		/* cfgvalue returns nothing on purpose: populating the field would put the key in
		 * the page, which is the one thing this design exists to prevent. */
		o.cfgvalue = function () { return ''; };
		o.write = function (section_id, value) {
			if (!value) return;
			return callSetSecret('provider', value);
		};
		o.remove = function () { return; };

		/* ---- the router ---- */
		s = m.section(form.NamedSection, 'main', 'hermes', _('Access to this router'),
			_('The recommended way to let the agent see this router is not a shell. Run openwrt-mcp alongside it and grant a narrow, audited, expiring window over ubus. Every call is then policy-checked and logged, ungranted tools are refused by name, and configuration changes carry a rollback timer.'));
		s.anonymous = true;

		o = s.option(form.Value, 'router_mcp_url', _('openwrt-mcp endpoint'),
			_('Leave empty to keep the agent away from this router\'s configuration entirely.'));
		o.default = 'http://127.0.0.1:8730/mcp';

		o = s.option(form.Value, '_router_key', _('Pairing token'),
			st.router_mcp_key_set
				? _('A token is stored. Type a new one to replace it.')
				: _('Get one on the router with: openwrt-mcp pair hermes'));
		o.password = true;
		o.rmempty = true;
		o.placeholder = st.router_mcp_key_set ? '••••••••  ' + _('stored') : _('not set');
		o.cfgvalue = function () { return ''; };
		o.write = function (section_id, value) {
			if (!value) return;
			return callSetSecret('router_mcp', value);
		};
		o.remove = function () { return; };

		/* ---- tools ---- */
		s = m.section(form.NamedSection, 'main', 'hermes', _('Tools'),
			_('Which tool families the agent loads. Leaving this empty loads everything upstream enables by default, which on a router means importing vision, image generation and browser tools that cannot work here and cost memory to load.'));
		s.anonymous = true;

		o = s.option(form.DynamicList, 'toolsets', _('Toolsets'));
		o.value('file', 'file' + ' (' + _('read and edit files') + ')');
		o.value('terminal', 'terminal' + ' (' + _('run commands on this router') + ')');
		o.value('web', 'web' + ' (' + _('search and fetch pages') + ')');
		o.value('memory', 'memory' + ' (' + _('remember across sessions') + ')');
		o.value('skills', 'skills' + ' (' + _('save and reuse procedures') + ')');
		o.value('cronjob', 'cronjob' + ' (' + _('scheduled work') + ')');
		o.value('clarify', 'clarify' + ' (' + _('ask you before guessing') + ')');
		o.value('session_search', 'session_search');
		o.value('todo', 'todo');

		return m.render();
	},

	/* After the map is written, the service has to be restarted: every setting is read
	 * at start time and turned into an environment variable or an argument, so a
	 * running process would pick up none of it. Doing it here rather than telling the
	 * reader to do it means the page cannot be left in a state where what it shows and
	 * what is running disagree. */
	handleSaveApply: function (ev, mode) {
		var self = this;
		return this.super('handleSaveApply', [ev, mode]).then(function () {
			return rpc.declare({
				object: 'luci', method: 'setInitAction',
				params: ['name', 'action'], expect: { result: false }
			})('hermes-agent', 'restart').catch(function () {});
		}).then(function () {
			ui.addNotification(null, E('p', {},
				_('Saved. The service was restarted; check the Overview tab for whether it stayed up.')), 'info');
		});
	}
});
