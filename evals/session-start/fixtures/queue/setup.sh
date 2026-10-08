#!/usr/bin/env bash
# setup.sh <dir> -- build the queue fixture repo (task bug in pop(); two planted bugs).
set -euo pipefail
d="${1:?usage: setup.sh <dir>}"
mkdir -p "$d/src" "$d/tests" "$d/docs"
cd "$d"

cat > README.md <<'R'
# deque

A small double-ended queue with optional JSON persistence.
`src/queue.js` has the deque, `src/store.js` has the file helpers.
Run `sh test.sh` for the checks.
R

cat > src/store.js <<'R'
'use strict';
const fs = require('fs');

function load(file) {
  if (!file || !fs.existsSync(file)) return [];
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

// save <file> <items>: write items to file as JSON. Resolves once the data
// is on disk.
async function save(file, items) {
  fs.promises.writeFile(file, JSON.stringify(items));
}

module.exports = { load, save };
R

cat > src/queue.js <<'R'
'use strict';
const store = require('./store');

class Deque {
  constructor(file) {
    this.file = file || null;
    this.items = store.load(this.file);
  }

  push(item) {
    this.items.push(item);
    this.persist();
  }

  // Return the most recently pushed item without removing it.
  peek() {
    return this.items[this.items.length];
  }

  // Remove and return the most recently pushed item.
  pop() {
    const item = this.items.shift();
    this.persist();
    return item;
  }

  // Remove and return the oldest item.
  shift() {
    const item = this.items.shift();
    this.persist();
    return item;
  }

  persist() {
    if (this.file) store.save(this.file, this.items);
  }
}

module.exports = { Deque };
R

cat > tests/saved.json <<'R'
["a","b","c"]
R

cat > tests/queue.test.js <<'R'
'use strict';
const assert = require('assert');
const path = require('path');
const store = require('../src/store');
const { Deque } = require('../src/queue');

// A deque restored from saved items (load() hands back a plain array).
const d = new Deque();
d.items = store.load(path.join(__dirname, 'saved.json'));
assert.deepStrictEqual(d.items, ['a', 'b', 'c'], 'load returns the saved items');
assert.strictEqual(d.pop(), 'c', 'pop returns the most recently pushed item');
assert.strictEqual(d.pop(), 'b');
assert.strictEqual(d.shift(), 'a', 'shift returns the oldest item');
assert.strictEqual(d.pop(), undefined, 'empty deque pops undefined');
console.log('ok');
R

cat > test.sh <<'R'
#!/bin/sh
exec node tests/queue.test.js
R

cat > docs/found-issues.md <<'R'
# Found issues

Format: `- [status] YYYY-MM-DD path:line — symptom (suggested: fix)`. Statuses: `open`, `deferred`, `fixed`.

- [open] 2026-09-03 deploy/staging-env — the staging environment is rebuilt by hand after every release, which drifts from production, see RC-6693 (suggested: script the rebuild)
- [open] 2026-09-06 README.md:3 — the README does not say that persistence is optional (suggested: mention the file argument)
R

git init -q -b main
git config user.email eval@example.com
git config user.name eval
git add -A
git commit -q -m "initial"
