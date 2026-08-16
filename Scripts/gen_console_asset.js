#!/usr/bin/env node
"use strict";
const fs = require("fs");
const [, , inPath, outPath] = process.argv;
if (!inPath || !outPath) {
  console.error("usage: node gen_console_asset.js <input.html> <output.h>");
  process.exit(2);
}
let src = fs.readFileSync(inPath, "utf8");
let out = "";
for (const ch of src) {
  const code = ch.charCodeAt(0);
  if (ch === "\\") out += "\\\\";
  else if (ch === '"') out += '\\"';
  else if (ch === "\n") out += "\n";
  else if (ch === "\r") out += "";
  else if (ch === "\t") out += "\t";
  else if (code < 0x20) out += "\\x" + code.toString(16).padStart(2, "0");
  else out += ch;
}
const header = `// 自动生成，勿手改！由 Scripts/gen_console_asset.js 生成。
static const char * const kLCProxyConsoleHTML =
"${out}";
`;
fs.writeFileSync(outPath, header, "utf8");
console.log(`generated ${outPath} (${src.length} chars -> ${out.length} escaped)`);
