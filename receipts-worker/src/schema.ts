// Validation of a runhmd.receipt/1 document. A port of bin/lib/runhmd_schema.py: the SAME schema
// files (schema/ is a byte-identical copy of docs/schemas/, checked by `npm test` and by
// test/receipts-worker-contract.test.sh) are enforced, so no rule of the contract lives in this
// code. Two layers, as in the Python:
//   1. structure  -- the JSON Schema subset the files use ($ref local or to the sibling file, type,
//                    const, enum, required, properties, additionalProperties, items, minItems,
//                    maxItems, minLength, maxLength, pattern, minimum, maximum). Any other
//                    validating keyword in a schema file stops the Worker loading: a rule this
//                    code cannot enforce must never pass silently.
//   2. invariants -- RC1-RC3 and the verdict rules V1-V4, G1 that JSON Schema cannot express.
// String lengths are counted in code points (Python's len), not UTF-16 units, so a title of 200
// astral characters is as valid here as there.

import receiptSchema from "../schema/runhmd.receipt.v1.json";
import verdictSchema from "../schema/runhmd.verdict.v1.json";
import type { JsonObject } from "./types";

type Node = { [key: string]: unknown };

export class SchemaError extends Error {}

const SIBLINGS: Record<string, Node> = {
  "runhmd.receipt.v1.json": receiptSchema as Node,
  "runhmd.verdict.v1.json": verdictSchema as Node,
};
const VALIDATING = new Set([
  "$ref", "type", "const", "enum", "required", "properties", "additionalProperties",
  "items", "minItems", "maxItems", "minLength", "maxLength", "pattern", "minimum", "maximum",
]);
const ANNOTATIONS = new Set(["$schema", "$id", "$defs", "$comment", "title", "description", "default", "examples"]);

const PATTERNS = new Map<string, RegExp>();
function pattern(source: string): RegExp {
  let compiled = PATTERNS.get(source);
  if (!compiled) {
    compiled = new RegExp(source, "u"); // no `m` flag: `$` is the end of input, like Python's \Z
    PATTERNS.set(source, compiled);
  }
  return compiled;
}

function audit(node: unknown, where: string): void {
  if (typeof node !== "object" || node === null || Array.isArray(node)) return;
  const record = node as Node;
  for (const key of Object.keys(record)) {
    if (VALIDATING.has(key) || ANNOTATIONS.has(key) || key.startsWith("x-")) continue;
    throw new SchemaError(`unsupported schema keyword '${key}' at ${where}`);
  }
  if (typeof record.pattern === "string") pattern(record.pattern);
  for (const [name, sub] of Object.entries((record.properties as Node | undefined) ?? {})) audit(sub, `${where}/properties/${name}`);
  for (const [name, sub] of Object.entries((record.$defs as Node | undefined) ?? {})) audit(sub, `${where}/$defs/${name}`);
  audit(record.items, `${where}/items`);
  audit(record.additionalProperties, `${where}/additionalProperties`);
}
for (const [name, schema] of Object.entries(SIBLINGS)) audit(schema, `${name}#`);

/** The receipt/verdict id grammar, read from the verdict schema: one definition for ids, URLs and DO names. */
export const ID_RE = pattern(((verdictSchema.$defs.id as Node).pattern) as string);
/** The finding id grammar, from the same file. */
export const FINDING_ID_RE = pattern((verdictSchema.$defs.finding.properties.id as Node).pattern as string);

function resolve(ref: string, root: Node): { node: Node; root: Node } {
  const hash = ref.indexOf("#");
  const name = hash < 0 ? ref : ref.slice(0, hash);
  const pointer = hash < 0 ? "" : ref.slice(hash + 1);
  let currentRoot = root;
  if (name) {
    const sibling = Object.hasOwn(SIBLINGS, name) ? SIBLINGS[name] : undefined;
    if (!sibling) throw new SchemaError(`only sibling runhmd.*.json $ref values are supported (never fetched): ${ref}`);
    currentRoot = sibling;
  }
  let node: unknown = currentRoot;
  for (const raw of pointer.split("/")) {
    if (raw === "") continue;
    const part = raw.replace(/~1/g, "/").replace(/~0/g, "~");
    if (typeof node !== "object" || node === null || !Object.hasOwn(node, part)) throw new SchemaError(`unresolvable $ref: ${ref}`);
    node = (node as Node)[part];
  }
  return { node: node as Node, root: currentRoot };
}

function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isType(value: unknown, name: string): boolean {
  switch (name) {
    case "object": return isObject(value);
    case "array": return Array.isArray(value);
    case "string": return typeof value === "string";
    case "boolean": return typeof value === "boolean";
    case "null": return value === null;
    case "number": return typeof value === "number";
    case "integer": return typeof value === "number" && Number.isInteger(value);
    default: throw new SchemaError(`unsupported type name '${name}'`);
  }
}

function jsonEq(a: unknown, b: unknown): boolean {
  if (Array.isArray(a) && Array.isArray(b)) return a.length === b.length && a.every((item, i) => jsonEq(item, b[i]));
  if (isObject(a) && isObject(b)) {
    const keys = Object.keys(a);
    return keys.length === Object.keys(b).length && keys.every((key) => Object.hasOwn(b, key) && jsonEq(a[key], b[key]));
  }
  return a === b;
}

const codePoints = (text: string): number => Array.from(text).length;
const show = (value: unknown): string => (JSON.stringify(value) ?? String(value)).slice(0, 80);

function check(value: unknown, schema: Node, root: Node, path: string, errors: string[]): void {
  if (typeof schema.$ref === "string") {
    const target = resolve(schema.$ref, root);
    check(value, target.node, target.root, path, errors);
  }
  const where = path || "/";
  if (Object.hasOwn(schema, "type")) {
    const names = Array.isArray(schema.type) ? (schema.type as string[]) : [schema.type as string];
    if (!names.some((name) => isType(value, name))) {
      errors.push(`${where}: ${show(value)} is not of type ${names.join(" or ")}`);
      return;
    }
  }
  if (Object.hasOwn(schema, "const") && !jsonEq(value, schema.const)) {
    errors.push(`${where}: ${show(value)} is not the required constant ${show(schema.const)}`);
  }
  if (Array.isArray(schema.enum) && !schema.enum.some((member) => jsonEq(value, member))) {
    errors.push(`${where}: ${show(value)} is not one of ${show(schema.enum)}`);
  }
  if (typeof value === "string") {
    const length = codePoints(value);
    if (typeof schema.minLength === "number" && length < schema.minLength) errors.push(`${where}: string is shorter than ${schema.minLength}`);
    if (typeof schema.maxLength === "number" && length > schema.maxLength) errors.push(`${where}: string is longer than ${schema.maxLength}`);
    if (typeof schema.pattern === "string" && !pattern(schema.pattern).test(value)) {
      errors.push(`${where}: ${show(value)} does not match pattern ${schema.pattern}`);
    }
  }
  if (typeof value === "number") {
    if (typeof schema.minimum === "number" && value < schema.minimum) errors.push(`${where}: ${show(value)} is below the minimum ${schema.minimum}`);
    if (typeof schema.maximum === "number" && value > schema.maximum) errors.push(`${where}: ${show(value)} is above the maximum ${schema.maximum}`);
  }
  if (Array.isArray(value)) {
    if (typeof schema.minItems === "number" && value.length < schema.minItems) errors.push(`${where}: fewer than ${schema.minItems} items`);
    if (typeof schema.maxItems === "number" && value.length > schema.maxItems) errors.push(`${where}: more than ${schema.maxItems} items`);
    if (isObject(schema.items)) value.forEach((item, index) => check(item, schema.items as Node, root, `${path}/${index}`, errors));
  }
  if (isObject(value)) {
    for (const key of (schema.required as string[] | undefined) ?? []) {
      if (!Object.hasOwn(value, key)) errors.push(`${where}: missing required property '${key}'`);
    }
    const props = (schema.properties as Node | undefined) ?? {};
    for (const [key, item] of Object.entries(value)) {
      if (Object.hasOwn(props, key)) check(item, props[key] as Node, root, `${path}/${key}`, errors);
      else if (schema.additionalProperties === false) errors.push(`${where}: unexpected property '${key}'`);
      else if (isObject(schema.additionalProperties)) check(item, schema.additionalProperties as Node, root, `${path}/${key}`, errors);
    }
  }
}

// ── invariants ───────────────────────────────────────────────────────────────────────────────

function daysIn(year: number, month: number): number {
  if (month === 2) return year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0) ? 29 : 28;
  return [4, 6, 9, 11].includes(month) ? 30 : 31;
}

/** RC1: strptime("%Y-%m-%dT%H:%M:%SZ") succeeds: a real calendar instant (no 30 February, no hour 25, year >= 1). */
function isRealUtc(text: string): boolean {
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/.exec(text);
  if (!m) return false;
  const [year, month, day, hour, minute, second] = m.slice(1).map(Number) as [number, number, number, number, number, number];
  return year >= 1 && month >= 1 && month <= 12 && day >= 1 && day <= daysIn(year, month) && hour <= 23 && minute <= 59 && second <= 59;
}

function unprovenReasons(gates: JsonObject[], regression: JsonObject | undefined): string[] {
  const reasons: string[] = [];
  for (const g of gates) {
    if (g.status !== "pass") reasons.push(`gate '${g.id}' failed`);
    else if (!g.falsified) reasons.push(`gate '${g.id}' is not falsified (it passes, but was never shown to fail)`);
  }
  if (regression && Number(regression.failed) > 0) reasons.push(`${regression.failed} regression test(s) failed`);
  return reasons;
}

function verdictInvariants(doc: JsonObject): string[] {
  const errors: string[] = [];
  const attacks = doc.attacks as { total: number; survived: number; killed: number };
  const findings = doc.findings as JsonObject[];
  const gates = (doc.gates as JsonObject[] | undefined) ?? [];
  const regression = doc.regression_tests as JsonObject | undefined;
  if (attacks.total !== attacks.survived + attacks.killed) {
    errors.push(`attacks.total (${attacks.total}) must equal attacks.survived + attacks.killed (${attacks.survived + attacks.killed})`);
  }
  const ids = findings.map((f) => f.id);
  for (const dup of [...new Set(ids.filter((id, i) => ids.indexOf(id) !== i))].sort()) errors.push(`duplicate finding id '${dup}'`);
  if (doc.verdict === "DENIED" && findings.length === 0) errors.push("verdict DENIED requires at least one finding");
  if (doc.verdict === "PROVEN") {
    if (attacks.killed) errors.push(`verdict PROVEN but attacks.killed is ${attacks.killed}`);
    if (findings.length) errors.push("verdict PROVEN but findings is non-empty");
    if (attacks.total === 0 && gates.length === 0) errors.push("verdict PROVEN over zero attacks and zero gates proves nothing (false green)");
    for (const reason of unprovenReasons(gates, regression)) errors.push(`verdict PROVEN but ${reason}`);
  }
  for (const g of gates) {
    if (g.falsified && g.falsify_score !== 1) errors.push(`gate '${g.id}' is marked falsified but falsify_score is ${g.falsify_score}, not 1.0`);
  }
  return errors;
}

function receiptInvariants(doc: JsonObject): string[] {
  const errors: string[] = [];
  if (!isRealUtc(doc.created_at as string)) errors.push(`created_at ${show(doc.created_at)} is not a real UTC timestamp`);
  for (const [field, places] of [["cost_usd", 4], ["duration_s", 2]] as const) {
    const value = doc[field] as number;
    if (!Number.isFinite(value) || Number(value.toFixed(places)) !== value) {
      errors.push(`${field} ${value} is not a finite number with at most ${places} decimal places`);
    }
  }
  errors.push(...verdictInvariants(doc));
  return errors;
}

/** The problems with `doc` as a runhmd.receipt/1 document (empty list == valid). */
export function validateReceipt(doc: unknown): string[] {
  if (!isObject(doc) || doc.schema !== "runhmd.receipt/1") {
    return ["/: document must be an object whose 'schema' is runhmd.receipt/1"];
  }
  const errors: string[] = [];
  check(doc, SIBLINGS["runhmd.receipt.v1.json"] as Node, SIBLINGS["runhmd.receipt.v1.json"] as Node, "", errors);
  return errors.length ? errors : receiptInvariants(doc);
}
