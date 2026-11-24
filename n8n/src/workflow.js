// Builds n8n/workflows/vault-loop.json - the loop's single n8n workflow.
// Edit THIS file, then regenerate:  bash n8n/build.sh
//
// One workflow on purpose: every trigger feeds the same queue chain, and no
// workflow has to reference another by an ID that changes on every import.
//
// Queue: the n8n data table `loop_jobs` (created by n8n/setup-n8n.sh).
//   job_key  kind:ref - at most one queued/running job per key
//   kind     triage | scan-inbox | plane-item
//   source   syncthing | run-now | sweep | plane
//   ref      vault-relative note path, or Plane work item id
//   status   queued | running | done | failed
//   attempts number of times a worker has claimed it
//   detail   free text: why it was queued, or the worker's report
'use strict';

const TABLE = { __rl: true, mode: 'name', value: 'loop_jobs' };
const HEADER_AUTH = { httpHeaderAuth: { id: '__WORKER_CRED_ID__', name: 'vault-loop worker' } };
const SYNCTHING_AUTH = { httpHeaderAuth: { id: '__SYNCTHING_CRED_ID__', name: 'Syncthing CT 107' } };

const nodes = [];
const connections = {};
let n = 0;
function node(name, type, typeVersion, parameters, pos, extra = {}) {
  nodes.push({ id: `vl-${String(++n).padStart(2, '0')}`, name, type, typeVersion, position: pos, parameters, ...extra });
  return name;
}
function link(from, to, output = 0) {
  connections[from] = connections[from] || { main: [] };
  while (connections[from].main.length <= output) connections[from].main.push([]);
  connections[from].main[output].push({ node: to, type: 'main', index: 0 });
}
function code(name, js, pos, extra = {}) {
  return node(name, 'n8n-nodes-base.code', 2, { mode: 'runOnceForAllItems', jsCode: js.trim() + '\n' }, pos, extra);
}
// Data table filter: all conditions must match.
function where(...conds) {
  return {
    matchType: 'allConditions',
    filters: { conditions: conds.map(([keyName, condition, keyValue]) => ({ keyName, condition, keyValue })) },
  };
}
function columns(values) {
  const schema = Object.keys(values).map((id) => ({
    id, displayName: id, required: false, defaultMatch: false, display: true,
    type: id === 'attempts' ? 'number' : 'string', canBeUsedToMatch: true,
  }));
  return { mappingMode: 'defineBelow', value: values, matchingColumns: [], schema };
}

// --- The shared queue chain --------------------------------------------------

code('Job', `
// Every trigger's job arrives here as { kind, source, ref, detail }.
// Normalise it and give it the dedupe key.
return $input.all().map((item) => {
  const j = item.json;
  const ref = String(j.ref || '').trim();
  return { json: { kind: j.kind, source: j.source, ref, detail: String(j.detail || ''), job_key: j.kind + ':' + ref } };
});
`, [1100, 300]);

node('Find open job', 'n8n-nodes-base.dataTable', 1, {
  resource: 'row', operation: 'get', dataTableId: TABLE,
  ...where(['job_key', 'eq', '={{ $json.job_key }}'], ['status', 'neq', 'done'], ['status', 'neq', 'failed']),
  returnAll: true,
}, [1320, 300], { alwaysOutputData: true });
link('Job', 'Find open job');

code('Only new jobs', `
// Drop jobs that already have a queued or running row with the same key.
const open = new Set($input.all().filter((i) => i.json.id).map((i) => i.json.job_key));
const seen = new Set();
const out = [];
for (const item of $('Job').all()) {
  const j = item.json;
  if (open.has(j.job_key) || seen.has(j.job_key)) continue;
  seen.add(j.job_key);
  out.push({ json: { ...j, status: 'queued', attempts: 0 } });
}
return out;
`, [1540, 300]);
link('Find open job', 'Only new jobs');

node('Queue job', 'n8n-nodes-base.dataTable', 1, {
  resource: 'row', operation: 'insert', dataTableId: TABLE,
  columns: columns({
    job_key: '={{ $json.job_key }}', kind: '={{ $json.kind }}', source: '={{ $json.source }}',
    ref: '={{ $json.ref }}', status: 'queued', attempts: '={{ 0 }}', detail: '={{ $json.detail }}',
  }),
  options: {},
}, [1760, 300]);
link('Only new jobs', 'Queue job');

// --- Trigger 1: Plane webhook ------------------------------------------------

node('Plane webhook', 'n8n-nodes-base.webhook', 2, {
  httpMethod: 'POST', path: 'vault-loop/plane', responseMode: 'onReceived', options: {},
}, [200, 100], { webhookId: '6b0c3f9e-1d1a-4c55-9a51-0f3b7a2d1001' });

code('Plane: approved items', `
// Plane sends every work item event. Keep only items whose state is
// "Approved" (by name). If the payload carries no state name, queue a
// plane-item job anyway and let the worker read the item from Plane's API:
// a missed approval costs more than an extra check.
const out = [];
for (const item of $input.all()) {
  const body = item.json.body || item.json;
  if (body.event !== 'issue' && body.event !== 'work_item') continue;
  if (body.action === 'deleted') continue;
  const d = body.data || {};
  const stateName = (d.state && d.state.name) || (d.state_detail && d.state_detail.name) || d.state__name || '';
  if (stateName && stateName.toLowerCase() !== 'approved') continue;
  if (!d.id) continue;
  out.push({ json: {
    kind: 'plane-item', source: 'plane', ref: d.id,
    detail: stateName ? 'moved to Approved' : 'state not in payload; worker checks it',
  } });
}
return out;
`, [420, 100]);
link('Plane webhook', 'Plane: approved items');
link('Plane: approved items', 'Job');

// --- Trigger 2: Run now form -------------------------------------------------

// formTrigger 2.2 reads its custom path from options.path; a top-level `path`
// is dropped and the form ends up at /form/<webhookId>.
node('Run now', 'n8n-nodes-base.formTrigger', 2.2, {
  formTitle: 'Vault loop: run now',
  formDescription: 'Queue work for the PC worker now instead of waiting for the next sync or sweep.',
  formFields: { values: [
    { fieldLabel: 'Action', fieldType: 'dropdown', requiredField: true,
      fieldOptions: { values: [{ option: 'Scan Inbox' }, { option: 'Process one note' }, { option: 'Retry a failed job' }] } },
    { fieldLabel: 'Note path or job id', placeholder: 'Inbox/my-note.md  or  42' },
  ] },
  options: {
    path: 'vault-loop/run-now',
    respondWithOptions: { values: { formSubmittedText: 'Queued. The PC worker picks it up on its next poll.' } },
  },
}, [200, 300], { webhookId: '6b0c3f9e-1d1a-4c55-9a51-0f3b7a2d1002' });

code('Run now: route', `
const f = $input.first().json;
const action = f['Action'];
const arg = String(f['Note path or job id'] || '').trim();
if (action === 'Retry a failed job') {
  if (!/^\\d+$/.test(arg)) throw new Error('Retry needs a job id (a number), got: ' + arg);
  return [{ json: { retry_id: Number(arg) } }];
}
if (action === 'Process one note') {
  if (!arg.endsWith('.md')) throw new Error('Process one note needs a vault path ending in .md, got: ' + arg);
  return [{ json: { kind: 'triage', source: 'run-now', ref: arg.replace(/^\\/+/, ''), detail: 'Run now' } }];
}
return [{ json: { kind: 'scan-inbox', source: 'run-now', ref: 'Inbox', detail: 'Run now' } }];
`, [420, 300]);
link('Run now', 'Run now: route');

node('Is retry?', 'n8n-nodes-base.switch', 3.2, {
  rules: { values: [
    { conditions: { options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 },
        conditions: [{ id: 'r1', leftValue: '={{ $json.retry_id }}', rightValue: '', operator: { type: 'number', operation: 'exists', singleValue: true } }],
        combinator: 'and' }, renameOutput: true, outputKey: 'retry' },
  ] },
  options: { fallbackOutput: 'extra', renameFallbackOutput: 'new job' },
}, [640, 300]);
link('Run now: route', 'Is retry?');
link('Is retry?', 'Job', 1);

node('Requeue failed job', 'n8n-nodes-base.dataTable', 1, {
  resource: 'row', operation: 'update', dataTableId: TABLE,
  ...where(['id', 'eq', '={{ $json.retry_id }}'], ['status', 'eq', 'failed']),
  columns: columns({ status: 'queued', detail: 'requeued by Run now' }),
  options: {},
}, [860, 200]);
link('Is retry?', 'Requeue failed job', 0);

// --- Trigger 3: 15-minute sweep ----------------------------------------------

node('Every 15 minutes', 'n8n-nodes-base.scheduleTrigger', 1.2, {
  rule: { interval: [{ field: 'minutes', minutesInterval: 15 }] },
}, [200, 500]);

code('Sweep: scan Inbox', `
// Safety net for missed events or a PC that was asleep. Dedupe in the queue
// chain means this never stacks up more than one scan-inbox job.
return [{ json: { kind: 'scan-inbox', source: 'sweep', ref: 'Inbox', detail: '15-minute sweep' } }];
`, [420, 500]);
link('Every 15 minutes', 'Sweep: scan Inbox');
link('Sweep: scan Inbox', 'Job');

node('Running jobs', 'n8n-nodes-base.dataTable', 1, {
  resource: 'row', operation: 'get', dataTableId: TABLE,
  ...where(['status', 'eq', 'running']), returnAll: true,
}, [420, 680], { alwaysOutputData: true });
link('Every 15 minutes', 'Running jobs');

code('Stuck for over 2 hours', `
// A job a worker claimed but never reported on. Mark it failed so it shows
// up for Run now's retry instead of blocking its key forever.
const cutoff = Date.now() - 2 * 60 * 60 * 1000;
return $input.all()
  .filter((i) => i.json.id && new Date(i.json.updatedAt).getTime() < cutoff)
  .map((i) => ({ json: { id: i.json.id } }));
`, [640, 680]);
link('Running jobs', 'Stuck for over 2 hours');

node('Mark stuck as failed', 'n8n-nodes-base.dataTable', 1, {
  resource: 'row', operation: 'update', dataTableId: TABLE,
  ...where(['id', 'eq', '={{ $json.id }}']),
  columns: columns({ status: 'failed', detail: 'no report from the worker within 2 hours' }),
  options: {},
}, [860, 680]);
link('Stuck for over 2 hours', 'Mark stuck as failed');

// --- Trigger 4: Syncthing sync finished --------------------------------------

node('Every minute', 'n8n-nodes-base.scheduleTrigger', 1.2, {
  rule: { interval: [{ field: 'minutes', minutesInterval: 1 }] },
}, [200, 880]);

code('Syncthing: settings', `
// Filled in by n8n/setup-n8n.sh (SYNCTHING_URL, SYNCTHING_FOLDER). Re-run
// setup to change them rather than editing here: setup overwrites this node.
const SYNCTHING_URL = '__SYNCTHING_URL__';
const FOLDER_ID = '__SYNCTHING_FOLDER__';
const s = $getWorkflowStaticData('global');
return [{ json: { url: SYNCTHING_URL, folder: FOLDER_ID, since: s.syncthingLastEvent || 0 } }];
`, [420, 880]);
link('Every minute', 'Syncthing: settings');

node('Syncthing events', 'n8n-nodes-base.httpRequest', 4.2, {
  url: '={{ $json.url }}/rest/events',
  authentication: 'genericCredentialType', genericAuthType: 'httpHeaderAuth',
  sendQuery: true,
  queryParameters: { parameters: [
    { name: 'since', value: '={{ $json.since }}' },
    { name: 'events', value: 'ItemFinished,FolderSummary' },
    { name: 'timeout', value: '1' },
  ] },
  options: { timeout: 15000, response: { response: { responseFormat: 'json' } } },
}, [640, 880], { credentials: SYNCTHING_AUTH });
link('Syncthing: settings', 'Syncthing events');

code('Syncthing: notes after idle', `
// Collect notes CT 107 received, and queue them only once the folder is idle
// again: one job per note per sync, never a half-written file.
const s = $getWorkflowStaticData('global');
const cfg = $('Syncthing: settings').first().json;
let events = $input.all().map((i) => i.json);
if (events.length === 1 && Array.isArray(events[0])) events = events[0];
if (events.length === 1 && Array.isArray(events[0].data)) events = events[0].data;
s.pending = s.pending || {};
let idle = false;
for (const e of events) {
  if (typeof e.id === 'number' && e.id > (s.syncthingLastEvent || 0)) s.syncthingLastEvent = e.id;
  const d = e.data || {};
  if (d.folder !== cfg.folder) continue;
  if (e.type === 'ItemFinished' && !d.error && d.type === 'file' && /\\.md$/i.test(d.item || '')) {
    if (d.action === 'delete') delete s.pending[d.item]; else s.pending[d.item] = true;
  }
  if (e.type === 'FolderSummary' && d.summary && d.summary.state === 'idle' && !d.summary.needTotalItems) idle = true;
}
if (!idle) return [];
const notes = Object.keys(s.pending).filter((p) => !p.startsWith('.') && !p.startsWith('_agent/'));
s.pending = {};
return notes.map((ref) => ({ json: { kind: 'triage', source: 'syncthing', ref, detail: 'synced to CT 107' } }));
`, [860, 880]);
link('Syncthing events', 'Syncthing: notes after idle');
link('Syncthing: notes after idle', 'Job');

// --- Trigger 5: the PC worker asks for the next job --------------------------

node('Worker: next job', 'n8n-nodes-base.webhook', 2, {
  httpMethod: 'POST', path: 'vault-loop/jobs/next', authentication: 'headerAuth',
  responseMode: 'responseNode', options: {},
}, [200, 1100], { webhookId: '6b0c3f9e-1d1a-4c55-9a51-0f3b7a2d1005', credentials: HEADER_AUTH });

node('Queued jobs', 'n8n-nodes-base.dataTable', 1, {
  resource: 'row', operation: 'get', dataTableId: TABLE,
  ...where(['status', 'eq', 'queued']),
  returnAll: false, limit: 1, orderBy: true, orderByColumn: 'id', orderByDirection: 'ASC',
}, [420, 1100], { alwaysOutputData: true });
link('Worker: next job', 'Queued jobs');

code('Pick oldest', `
const row = $input.all().map((i) => i.json).find((j) => j.id);
if (!row) return [{ json: { job: null, id: -1, attempts: 0 } }];
const job = { id: row.id, kind: row.kind, source: row.source, ref: row.ref, detail: row.detail, attempts: (row.attempts || 0) + 1 };
return [{ json: { job, id: row.id, attempts: job.attempts } }];
`, [640, 1100]);
link('Queued jobs', 'Pick oldest');

node('Claim it', 'n8n-nodes-base.dataTable', 1, {
  resource: 'row', operation: 'update', dataTableId: TABLE,
  ...where(['id', 'eq', '={{ $json.id }}'], ['status', 'eq', 'queued']),
  columns: columns({ status: 'running', attempts: '={{ $json.attempts }}' }),
  options: {},
}, [860, 1100], { alwaysOutputData: true });
link('Pick oldest', 'Claim it');

node('Send job', 'n8n-nodes-base.respondToWebhook', 1.1, {
  respondWith: 'json', responseBody: "={{ JSON.stringify({ job: $('Pick oldest').first().json.job }) }}", options: {},
}, [1080, 1100]);
link('Claim it', 'Send job');

// --- Trigger 6: the PC worker reports a result -------------------------------

node('Worker: report', 'n8n-nodes-base.webhook', 2, {
  httpMethod: 'POST', path: 'vault-loop/jobs/report', authentication: 'headerAuth',
  responseMode: 'responseNode', options: {},
}, [200, 1300], { webhookId: '6b0c3f9e-1d1a-4c55-9a51-0f3b7a2d1006', credentials: HEADER_AUTH });

code('Check report', `
const b = $input.first().json.body || {};
const id = Number(b.id);
if (!Number.isInteger(id) || id < 1) return [{ json: { ok: false, error: 'id must be a positive integer', id: -1 } }];
if (b.status !== 'done' && b.status !== 'failed') return [{ json: { ok: false, error: 'status must be done or failed', id: -1 } }];
return [{ json: { ok: true, id, status: b.status, detail: String(b.detail || '').slice(0, 2000) } }];
`, [420, 1300]);
link('Worker: report', 'Check report');

node('Record result', 'n8n-nodes-base.dataTable', 1, {
  resource: 'row', operation: 'update', dataTableId: TABLE,
  ...where(['id', 'eq', '={{ $json.id }}'], ['status', 'eq', 'running']),
  columns: columns({ status: '={{ $json.status }}', detail: '={{ $json.detail }}' }),
  options: {},
}, [640, 1300], { alwaysOutputData: true });
link('Check report', 'Record result');

node('Acknowledge', 'n8n-nodes-base.respondToWebhook', 1.1, {
  respondWith: 'json',
  responseBody: "={{ JSON.stringify({ ok: $('Check report').first().json.ok, error: $('Check report').first().json.error || null }) }}",
  options: { responseCode: "={{ $('Check report').first().json.ok ? 200 : 400 }}" },
}, [860, 1300]);
link('Record result', 'Acknowledge');

const workflow = {
  name: 'vault-loop',
  nodes,
  connections,
  settings: { executionOrder: 'v1', saveDataSuccessExecution: 'all', saveManualExecutions: true },
};
process.stdout.write(JSON.stringify(workflow, null, 2) + '\n');
