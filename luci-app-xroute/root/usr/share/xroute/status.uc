#!/usr/bin/ucode
// Status for the LuCI page, printed as JSON.
//   status.uc        service state, redirect, set sizes, counters, list info
//   status.uc test   additionally probe every server (and the auto group) through Xray's local SOCKS ports

'use strict';

import { popen, readfile } from 'fs';
import { cursor } from 'uci';

function sh(cmd) {
	let p = popen(cmd);
	if (!p)
		return '';
	let out = p.read('all') ?? '';
	p.close();
	return out;
}

function set_size(name) {
	let j = json(sh(`nft -j list set inet xroute ${name} 2>/dev/null`) || '{}');
	for (let o in j?.nftables ?? [])
		if (o.set)
			return length(o.set.elem ?? []);
	return 0;
}

let c = cursor();
let res = {
	enabled: c.get('xroute', 'main', 'enabled') == '1',
	running: false,
	redirect: false,
	dst_dns: 0,
	dst_net: 0,
	packets: 0,
	bytes: 0,
	lists: {},
	servers: [],
	mode: c.get('xroute', 'main', 'mode') ?? 'auto',
	subs: []
};

// installed version, for the page header (apk keeps "P:<name>" followed by "V:<version>")
let ver = match(readfile('/lib/apk/db/installed') ?? '', /\nP:luci-app-xroute\nV:([^\n-]+)/);
res.version = ver ? ver[1] : null;

let svc = json(sh(`ubus call service list '{"name":"xroute"}' 2>/dev/null`) || '{}');
let inst = svc?.xroute?.instances?.xray;
if (inst?.running) {
	res.running = true;
	res.pid = inst.pid;
}

let chain = sh('nft list chain inet xroute divert 2>/dev/null');
if (length(chain)) {
	res.redirect = (index(chain, 'tproxy') >= 0);
	for (let m in match(chain, /counter packets ([0-9]+) bytes ([0-9]+)/g)) {
		res.packets += int(m[1]);
		res.bytes += int(m[2]);
	}
	res.dst_dns = set_size('dst_dns');
	res.dst_net = set_size('dst_net');
}

for (let line in split(readfile('/tmp/xroute/lists.info') ?? '', '\n')) {
	let kv = match(line, /^([a-z]+)=(.*)$/);
	if (kv)
		res.lists[kv[1]] = int(kv[2]);
}

let tests = json(readfile('/var/etc/xroute/tests.json') ?? '{}') ?? {};
res.servers = tests.servers ?? [];
res.skipped = tests.skipped ?? [];

res.subs = [];
c.foreach('xroute', 'subscription', function(s) {
	let info = json(readfile(`/tmp/xroute/subs/${s['.name']}.json`) ?? 'null') ?? {};
	let stored = readfile(`/etc/xroute/subs/${s['.name']}.links`);
	push(res.subs, {
		name: s['.name'],
		label: s.label,
		enabled: s.enabled != '0',
		stored: stored ? length(filter(split(stored, '\n'), l => length(trim(l)))) : 0,
		...info
	});
});

// probes run in parallel, so the whole check takes at most ~8 s whatever the number of servers
if (ARGV[0] == 'test' && res.running) {
	let url = c.get('xroute', 'main', 'probe_url') ?? 'https://www.gstatic.com/generate_204';
	let qurl = "'" + replace(url, /'/g, "'\\''") + "'";
	let ports = map(res.servers, s => s.port);
	if (tests.auto_port)
		push(ports, tests.auto_port);

	let cmd = '';
	for (let p in ports)
		cmd += `( echo "${p} $(curl -s -o /dev/null -m 8 -w '%{http_code} %{time_total}' --socks5-hostname 127.0.0.1:${p} ${qurl} 2>/dev/null)" ) & `;
	let result = {};
	for (let line in split(sh(cmd + 'wait'), '\n')) {
		let m = match(line, /^([0-9]+) ([0-9]{3}) ([0-9.]+)$/);
		if (m)
			result[m[1]] = (int(m[2]) >= 200 && int(m[2]) < 400) ? { ok: true, ms: int(+m[3] * 1000) } : { ok: false };
	}

	for (let s in res.servers)
		s.test = result['' + s.port] ?? { ok: false };
	if (tests.auto_port)
		res.auto = result['' + tests.auto_port] ?? { ok: false };
}

printf('%J\n', res);
