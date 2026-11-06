#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// Every msgid the LuCI view uses must have a zh_Hans translation. luci.mk turns
// the .po into .lmo without complaint even when strings are missing, so the UI
// would silently ship half-translated.
//
// Run locally: node scripts/check-translations.js

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const VIEW = path.join(ROOT, 'luci-app-dnswatchd/htdocs/luci-static/resources/view/dnswatchd/main.js');
const PO = path.join(ROOT, 'luci-app-dnswatchd/po/zh_Hans/dnswatchd.po');

const src = fs.readFileSync(VIEW, 'utf8');
const po = fs.readFileSync(PO, 'utf8');

const used = [...new Set(
	[...src.matchAll(/_\((['"])((?:\\.|(?!\1).)*)\1\)/g)].map(m => m[2])
)].sort();

const entries = [...po.matchAll(/^msgid "(.*)"\nmsgstr "(.*)"$/gm)]
	.filter(m => m[1] !== '')                 // skip the header entry
	.map(m => ({ id: m[1], str: m[2] }));

const byId = new Map(entries.map(e => [e.id, e.str]));

const missing = used.filter(id => !byId.has(id));
const empty = used.filter(id => byId.has(id) && byId.get(id) === '');
const orphan = entries.filter(e => !used.includes(e.id)).map(e => e.id);

console.log(`view msgids: ${used.length}`);
console.log(`po entries:  ${entries.length}`);

let bad = false;

if (missing.length) {
	console.error('missing from po:', missing);
	bad = true;
}
if (empty.length) {
	console.error('present but untranslated:', empty);
	bad = true;
}
if (orphan.length) {
	// Not fatal on its own, but it means a string was edited in one place only.
	console.warn('in po but no longer used:', orphan);
}

if (bad) {
	process.exit(1);
}

console.log('translations OK');
