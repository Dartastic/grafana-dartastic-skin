// Licensed under the Dartastic Pro Commercial License.
// Copyright 2026, Mindful Software LLC, All rights reserved.

/// Citation shape — mirrors what the AI gateway returns and what
/// `ai-gateway/lib/src/citation.dart` enforces.
export type Citation =
  | { type: 'span'; span_id: string; trace_id?: string }
  | { type: 'source'; file: string; line: number }
  | { type: 'metric'; name: string; labels?: Record<string, string> };

/// Successful gateway response (HTTP 200/201).
export interface GatewayAnswer {
  answer: string;
  citations: Citation[];
  usage: { input_tokens: number; output_tokens: number };
  model: string;
  rate: { used: number; limit: number; warn: boolean };
}

/// 422 refuse-to-answer + 4xx/5xx error shape.
export interface GatewayError {
  error: string;
  reason?: string;
  message?: string;
}

/// One turn in the panel's local chat history.
export interface ChatTurn {
  id: string;
  question: string;
  pending: boolean;
  /// Human-readable list of RAG sources the bridge pulled in for
  /// this turn (e.g. `"trace abc12345… (12 spans)"`).  Rendered as
  /// chips beside the answer so the user sees what grounded it.
  sourcesUsed?: string[];
  answer?: GatewayAnswer;
  error?: GatewayError;
}

/// Panel options (set per-panel in the Grafana UI).
export interface DartasticAiPanelOptions {
  /// Optional: pre-fill the question textarea with a starter
  /// question on first render (useful for the demo dashboard).
  starterQuestion?: string;

  /// Show the per-answer token-usage line + the rate-limit
  /// warning when the gateway approaches the daily cap.
  showUsage: boolean;
}

export const defaultPanelOptions: DartasticAiPanelOptions = {
  starterQuestion: '',
  showUsage: true,
};
