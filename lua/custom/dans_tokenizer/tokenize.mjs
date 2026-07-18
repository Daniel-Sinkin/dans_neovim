// Byte-level BPE encoder for the bundled tokenizer vocab (tokenizer.json). A
// faithful port of js-tiktoken's
// algorithm: greedy lowest-rank merge over the pat_str pre-token pieces, ranks
// implied by token id. Reads UTF-8 text on stdin, writes a flat JSON array
// [start_byte, byte_len, token_id, ...] over the input's UTF-8 bytes on stdout.

import fs from 'node:fs';

const jsonPath = process.argv[2];
if (!jsonPath) {
  process.stderr.write('usage: tokenize.mjs <tokenizer.json>\n');
  process.exit(2);
}

const raw = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));

// bpe_ranks compression (js-tiktoken): per line, field 0 is a placeholder,
// field 1 is the base rank, the rest are base64 byte-sequences at base+offset.
const rankMap = new Map();
for (const line of raw.bpe_ranks.split('\n')) {
  if (!line) continue;
  const f = line.split(' ');
  const base = parseInt(f[1], 10);
  for (let i = 2; i < f.length; i++) {
    const bytes = Buffer.from(f[i], 'base64');
    rankMap.set(Array.prototype.join.call(bytes, ','), base + (i - 2));
  }
}

function bytePairMerge(piece) {
  const parts = [];
  for (let i = 0; i < piece.length; i++) parts.push({ start: i, end: i + 1 });
  while (parts.length > 1) {
    let minRank = null;
    let minI = -1;
    for (let i = 0; i < parts.length - 1; i++) {
      const slice = piece.slice(parts[i].start, parts[i + 1].end);
      const rank = rankMap.get(Array.prototype.join.call(slice, ','));
      if (rank == null) continue;
      if (minRank == null || rank < minRank) {
        minRank = rank;
        minI = i;
      }
    }
    if (minI === -1) break;
    parts[minI] = { start: parts[minI].start, end: parts[minI + 1].end };
    parts.splice(minI + 1, 1);
  }
  return parts;
}

const enc = new TextEncoder();
const text = fs.readFileSync(0, 'utf8');
const re = new RegExp(raw.pat_str, 'ug');

const out = [];
let byteCursor = 0;
let prevEnd = 0;
for (const m of text.matchAll(re)) {
  // Account for any text the pat_str did not claim (should be none), so byte
  // offsets stay aligned to the full input.
  if (m.index > prevEnd) byteCursor += enc.encode(text.slice(prevEnd, m.index)).length;

  const piece = enc.encode(m[0]);
  const matchStart = byteCursor;
  const direct = rankMap.get(Array.prototype.join.call(piece, ','));
  if (direct != null) {
    out.push(matchStart, piece.length, direct);
  } else {
    for (const p of bytePairMerge(piece)) {
      const sub = piece.slice(p.start, p.end);
      const id = rankMap.get(Array.prototype.join.call(sub, ','));
      out.push(matchStart + p.start, p.end - p.start, id == null ? -1 : id);
    }
  }
  byteCursor += piece.length;
  prevEnd = m.index + m[0].length;
}

process.stdout.write(JSON.stringify(out));
