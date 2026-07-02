// Licensed under the Dartastic Pro Commercial License.
// Copyright 2026, Mindful Software LLC, All rights reserved.

import { getBackendSrv } from '@grafana/runtime';

/// Assemble the RAG context block the gateway expects under
/// `context:`.  Grounded in real spans from the customer's box-local
/// Tempo so the gateway's citation-enforcement layer can resolve
/// the model's `span_id` claims.
///
/// P1.E MVP: trace-by-id only.  If the user's question contains a
/// 16- or 32-char hex string that looks like a span/trace id, we
/// fetch that trace from Tempo and ship its spans as context.
/// Anything else gets an empty context → gateway refuses-to-answer
/// because nothing is grounded.  That's the load-bearing
/// guardrail; future P1.E enrichments (recent-error search,
/// metric pulls, log slicing) layer on without changing the
/// refuse-by-default shape.

const TRACE_ID_RE = /\b[0-9a-fA-F]{16,32}\b/g;

export interface RagContext {
  spans: Array<{
    span_id: string;
    trace_id?: string;
    name?: string;
    attrs?: Record<string, unknown>;
  }>;
  logs: Array<{
    span_id?: string;
    body: string;
    severity?: string;
  }>;
  metrics: Array<{
    name: string;
    labels?: Record<string, string>;
    value?: number;
  }>;
  sources: Array<{ file: string; snippet?: string }>;
}

export interface RagAssembleResult {
  context: RagContext;
  sourcesUsed: string[];
}

/// Extract any trace-id-shaped tokens (16 or 32 hex chars,
/// word-bounded) from the question.  Filters out matches that
/// span across `_`, `-`, `.` etc. via the word-boundary regex.
export function extractTraceIds(question: string): string[] {
  const matches = Array.from(question.matchAll(TRACE_ID_RE)).map((m) => m[0]);
  // Dedup while preserving order.
  const seen = new Set<string>();
  return matches.filter((id) => {
    const k = id.toLowerCase();
    if (seen.has(k)) return false;
    seen.add(k);
    return id.length === 16 || id.length === 32;
  });
}

/// Build the gateway's `context:` payload for one question.
/// Returns the (possibly empty) context + a UI-friendly list of
/// which sources contributed.
export async function assembleRagContext(
  question: string,
): Promise<RagAssembleResult> {
  const traceIds = extractTraceIds(question);
  const spans: RagContext['spans'] = [];
  const sourcesUsed: string[] = [];

  for (const traceId of traceIds) {
    try {
      const fetched = await fetchTempoTrace(traceId);
      if (fetched.length > 0) {
        spans.push(...fetched);
        sourcesUsed.push(
          `trace ${traceId.slice(0, 8)}… (${fetched.length} span${fetched.length === 1 ? '' : 's'})`,
        );
      }
    } catch (_e) {
      // Best effort — Tempo unreachable or trace expired.  Gateway
      // will refuse-to-answer if context ends up empty, which is
      // the right user-facing failure mode (they see the reason in
      // the panel's Alert and can retry with a different question).
    }
  }

  return {
    context: { spans, logs: [], metrics: [], sources: [] },
    sourcesUsed,
  };
}

/// Tempo's `GET /api/traces/<traceId>` returns an OTLP-shaped
/// JSON: { batches: [ { resourceSpans: [...] } ] } across
/// versions, sometimes { resourceSpans: [...] } directly.
/// Normalise to a flat list of spans for the gateway.
async function fetchTempoTrace(
  traceId: string,
): Promise<RagContext['spans']> {
  const url = `/api/datasources/proxy/uid/tempo/api/traces/${traceId}`;
  const res = await getBackendSrv()
    .fetch<TempoTraceResponse>({ url, method: 'GET' })
    .toPromise();
  return parseTempoTrace(res?.data);
}

interface TempoTraceResponse {
  // Tempo's response wraps the OTLP shape; the wrapping varies
  // across Tempo versions.  Both shapes are handled below.
  resourceSpans?: TempoResourceSpan[];
  batches?: TempoResourceSpan[];
}

interface TempoResourceSpan {
  resource?: {
    attributes?: TempoKvAttribute[];
  };
  scopeSpans?: Array<{
    scope?: { name?: string };
    spans?: TempoSpan[];
  }>;
  // Some Tempo versions use the legacy `instrumentationLibrarySpans`.
  instrumentationLibrarySpans?: Array<{
    spans?: TempoSpan[];
  }>;
}

interface TempoSpan {
  traceId?: string;
  spanId?: string;
  name?: string;
  attributes?: TempoKvAttribute[];
  status?: { code?: number; message?: string };
}

interface TempoKvAttribute {
  key: string;
  value?: {
    stringValue?: string;
    intValue?: string | number;
    boolValue?: boolean;
    doubleValue?: number;
  };
}

export function parseTempoTrace(body: unknown): RagContext['spans'] {
  if (!body || typeof body !== 'object') return [];
  const data = body as TempoTraceResponse;
  const batches: TempoResourceSpan[] =
    data.resourceSpans ?? data.batches ?? [];
  const out: RagContext['spans'] = [];

  for (const rs of batches) {
    const resourceAttrs = flattenKv(rs.resource?.attributes ?? []);
    const scopeBatches = [
      ...(rs.scopeSpans ?? []),
      ...(rs.instrumentationLibrarySpans ?? []),
    ];
    for (const ss of scopeBatches) {
      for (const s of ss.spans ?? []) {
        if (!s.spanId) continue;
        out.push({
          span_id: s.spanId,
          trace_id: s.traceId,
          name: s.name,
          attrs: {
            ...resourceAttrs,
            ...flattenKv(s.attributes ?? []),
            ...(s.status?.code !== undefined
              ? { 'otel.status_code': s.status.code }
              : {}),
            ...(s.status?.message
              ? { 'otel.status_message': s.status.message }
              : {}),
          },
        });
      }
    }
  }
  return out;
}

function flattenKv(attrs: TempoKvAttribute[]): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const a of attrs) {
    const v =
      a.value?.stringValue ??
      a.value?.intValue ??
      a.value?.boolValue ??
      a.value?.doubleValue;
    if (v !== undefined && v !== null) {
      out[a.key] = v;
    }
  }
  return out;
}
