const assert = require('node:assert/strict');
const model = require('../Model.js');
const sink = {id: 1, name: 'selected', isSink: true};
const other = {id: 2, name: 'other', isSink: true};
const app = {id: 3, name: 'app', isStream: true, isSink: true};
const unrelated = {id: 4, name: 'elsewhere', isStream: true, isSink: true};
const capture = {id: 5, name: 'quickshell-peak-monitor', isStream: true};
const chain = {id: 6, name: 'processor'};
const nodes = [sink, other, app, unrelated, capture, chain];
const links = [{source: app, target: chain}, {source: chain, target: sink},
  {source: unrelated, target: other}, {source: sink, target: capture},
  {source: sink, target: chain}]; // Include a cycle.
assert.deepEqual(model.outputMeterRows(nodes, links, sink), [{id: 3, name: 'app'}]);
assert.deepEqual(model.outputMeterRows(nodes, links, other), [{id: 4, name: 'elsewhere'}]);
assert.deepEqual(model.outputMeterRows(nodes, links, null), []);
assert.deepEqual(model.outputMeterRows(nodes, [], sink), []);
assert.deepEqual(model.rowSnapshot([{id: 7, name: '<img src="https://example.invalid">'}]),
  [{id: 7, name: '<img src="https://example.invalid">'}]);
console.log('Output routing, cycle handling, primitive snapshots: passed');
