// hosted#194 — tiny mock webhook receiver for the sanitizer end-to-end check.
// Accepts any POST, appends the raw body to OUT_FILE (one JSON line per
// request), answers 200 "ok" — stands in for hooks.slack.com.
//
//   node mock-receiver.mjs <port> <out-file>
import { createServer } from 'node:http';
import { appendFileSync } from 'node:fs';

const port = Number(process.argv[2] || 18099);
const outFile = process.argv[3] || 'forwarded.jsonl';

createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    if (req.method === 'POST') appendFileSync(outFile, body.replace(/\n/g, ' ') + '\n');
    res.writeHead(200, { 'content-type': 'text/plain' });
    res.end('ok');
  });
}).listen(port, '0.0.0.0', () => console.log(`mock receiver on :${port} -> ${outFile}`));
