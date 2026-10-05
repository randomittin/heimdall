// GET /r/<id>: the receipt as an HTML page. A port of render_page() in
// bin/lib/runhmd_receipt_site.py (the page `hmd receipt serve` and `hmd receipt render` produce),
// with the three things only a service can add: each finding's human label, the "Request cloud
// access" link, and the Open Graph tags that make /r/<id>/card.png the link preview.
//
// Safety is the same as the local page: every value that came from the receipt goes through
// esc(); the template has no script, no external resource and no form; and it carries its own
// Content-Security-Policy (default-src 'none', the one inline <style> allowed by hash).

import type { JsonObject } from "./types";

const CSS = `body{font:16px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif;margin:0;background:#fafafa;color:#111}
main{max-width:46rem;margin:2rem auto;padding:0 1rem}
header p{margin:0;color:#555}
h1{margin:.2rem 0 1rem;font-size:2.2rem;letter-spacing:.04em}
.proven{color:#0a6b2d}.denied{color:#a31515}
dl{display:grid;grid-template-columns:max-content 1fr;gap:.35rem 1rem}
dt{color:#555}dd{margin:0;overflow-wrap:anywhere}
table{border-collapse:collapse;width:100%}
th,td{border-bottom:1px solid #ddd;padding:.4rem .5rem;text-align:left;vertical-align:top}
code,pre{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.85em;overflow-wrap:anywhere}
pre{background:#eee;padding:.6rem;white-space:pre-wrap}
.t{unicode-bidi:isolate}
.cta{border:2px solid #0a6b2d;border-radius:.4rem;padding:.2rem 1rem;margin-top:1.5rem}
.cta a{font-weight:600}
`;

let policy: Promise<string> | undefined;

/** The page's Content-Security-Policy value (the style is allowed by its own hash). */
export function pageCsp(): Promise<string> {
  policy ??= crypto.subtle.digest("SHA-256", new TextEncoder().encode(CSS)).then(
    (digest) =>
      `default-src 'none'; style-src 'sha256-${btoa(String.fromCharCode(...new Uint8Array(digest)))}'; base-uri 'none'; form-action 'none'`
  );
  return policy;
}

const ENTITIES: Record<string, string> = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#x27;" };
export const esc = (value: unknown): string => String(value).replace(/[&<>"']/g, (ch) => ENTITIES[ch] as string);

const table = (head: string[], rows: string[][]): string =>
  `<table><thead><tr>${head.map((cell) => `<th>${cell}</th>`).join("")}</tr></thead><tbody>${rows
    .map((row) => `<tr>${row.map((cell) => `<td>${cell}</td>`).join("")}</tr>`)
    .join("")}</tbody></table>`;

/** The human reading of a rating: real -> true_positive (the CTA's trigger), false -> false_positive. */
export function humanLabel(label: string | undefined): "true_positive" | "false_positive" | null {
  return label === "real" ? "true_positive" : label === "false" ? "false_positive" : null;
}

const LABEL_TEXT = { true_positive: "real", false_positive: "false alarm" } as const;

export interface PageOptions {
  /** finding id -> "real" | "false", the service's ratings of this receipt's findings. */
  labels: Record<string, string>;
  /** The "Request cloud access" link target, or null when the service has none configured. */
  cta: string | null;
  /** https base URL of the service (no trailing slash). */
  base: string;
}

/** True when some finding of this receipt has been rated real: the one condition the CTA depends on. */
export function hasTruePositive(doc: JsonObject, labels: Record<string, string>): boolean {
  return (doc.findings as JsonObject[]).some((finding) => humanLabel(labels[finding.id as string]) === "true_positive");
}

export async function renderPage(doc: JsonObject, options: PageOptions): Promise<{ html: string; csp: string }> {
  const csp = await pageCsp();
  const subject = doc.subject as JsonObject;
  const attacks = doc.attacks as JsonObject;
  const agent = doc.agent as JsonObject;
  const tool = doc.tool as JsonObject;
  const findings = doc.findings as JsonObject[];
  const verdict = String(doc.verdict);
  const id = String(doc.id);
  const isPublic = doc.visibility === "public";

  const facts: [string, string][] = [
    ["Receipt", `<code>${esc(id)}</code>`],
    ["Issued", esc(doc.created_at)],
    ["Visibility", esc(doc.visibility)],
    ["Attacked", `${esc(subject.kind)} &middot; tree <code>${esc(subject.tree_sha256)}</code>${subject.head_sha ? ` &middot; git <code>${esc(subject.head_sha)}</code>` : ""}`],
    ["Attacks", `${esc(attacks.total)} total &middot; ${esc(attacks.survived)} survived &middot; ${esc(attacks.killed)} killed`],
    ["Agent", esc(agent.name) + (agent.model ? ` &middot; <span class="t">${esc(agent.model)}</span>` : "")],
    ["Cost", `$${esc(doc.cost_usd)} &middot; ${esc(doc.duration_s)}s`],
    ["Tool", `<span class="t">${esc(tool.name)} ${esc(tool.version)}</span>`],
  ];

  const found = findings.length
    ? table(
        ["Finding", "Severity", "Category", "Title", "Label", "Digest"],
        findings.map((f) => {
          const label = humanLabel(options.labels[f.id as string]);
          return [
            `<code>${esc(f.id)}</code>`, esc(f.severity), esc(f.category), `<span class="t">${esc(f.title)}</span>`,
            label ? LABEL_TEXT[label] : "unrated", `<code>${esc(f.digest)}</code>`,
          ];
        })
      )
    : "<p>No findings.</p>";
  const sections = [
    `<section><h2>Findings</h2>${found}<p>A finding is shown as a digest: the receipt commits to its counterexample without carrying it. Labels are the service's own ratings; they are not part of the signed receipt.</p></section>`,
  ];
  const gates = doc.gates as JsonObject[] | undefined;
  if (gates?.length) {
    sections.push(`<section><h2>Gates</h2>${table(
      ["Gate", "Type", "Status", "Falsified", "Score"],
      gates.map((g) => [`<span class="t">${esc(g.id)}</span>`, `<span class="t">${esc(g.gate_type)}</span>`, esc(g.status), g.falsified ? "yes" : "no", esc(g.falsify_score)])
    )}</section>`);
  }
  const regression = doc.regression_tests as JsonObject | undefined;
  if (regression) {
    sections.push(`<section><h2>Regression tests</h2><p>${esc(regression.passed)} passed &middot; ${esc(regression.failed)} failed</p></section>`);
  }
  sections.push(
    `<section><h2>Signature</h2><p>Ed25519 &middot; key <code>${esc(doc.key_id)}</code> &middot; checked against the service's pinned runhmd receipt keys when this page was served.</p>` +
      `<p>Check it yourself:</p><pre>curl -fsS ${esc(options.base)}/r/${esc(id)}.json -o ${esc(id)}.json\nhmd receipt verify ${esc(id)}.json</pre>` +
      `<p><a href="${esc(id)}.json">${esc(id)}.json</a> is the exact signed receipt.</p></section>`
  );
  if (options.cta && hasTruePositive(doc, options.labels)) {
    sections.push(
      `<section class="cta"><h2>Cloud access</h2><p>A finding on this receipt was confirmed real by a person.</p>` +
        `<p><a href="${esc(options.cta)}">Request cloud access for this team</a></p></section>`
    );
  }

  const found1 = `${esc(attacks.total)} attacks, ${esc(attacks.survived)} survived, ${esc(attacks.killed)} killed; ${findings.length} finding(s).`;
  const og = isPublic
    ? `<meta property="og:type" content="website">\n<meta property="og:title" content="runhmd receipt ${esc(id)}: ${esc(verdict)}">\n` +
      `<meta property="og:description" content="${found1}">\n<meta property="og:url" content="${esc(options.base)}/r/${esc(id)}">\n` +
      `<meta property="og:image" content="${esc(options.base)}/r/${esc(id)}/card.png">\n<meta property="og:image:width" content="1200">\n` +
      `<meta property="og:image:height" content="630">\n<meta name="twitter:card" content="summary_large_image">\n`
    : "";
  const html =
    `<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width, initial-scale=1">\n` +
    `<meta http-equiv="Content-Security-Policy" content="${csp}">\n<meta name="referrer" content="no-referrer">\n` +
    `<title>runhmd receipt ${esc(id)} &middot; ${esc(verdict)}</title>\n${og}<style>${CSS}</style>\n</head>\n<body>\n<main>\n` +
    `<header><p>runhmd receipt</p><h1 class="${verdict === "PROVEN" ? "proven" : "denied"}">${esc(verdict)}</h1></header>\n` +
    `<dl>\n${facts.map(([label, value]) => `<dt>${label}</dt><dd>${value}</dd>`).join("\n")}\n</dl>\n${sections.join("\n")}\n</main>\n</body>\n</html>\n`;
  return { html, csp };
}
