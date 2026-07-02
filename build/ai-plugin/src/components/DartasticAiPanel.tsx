// Licensed under the Dartastic Pro Commercial License.
// Copyright 2026, Mindful Software LLC, All rights reserved.

import React, { useState, useCallback } from 'react';
import { PanelProps } from '@grafana/data';
import { getBackendSrv } from '@grafana/runtime';
import { useStyles2, Button, TextArea, Alert, LoadingPlaceholder } from '@grafana/ui';
import { css } from '@emotion/css';

import { assembleRagContext } from '../rag';
import {
  ChatTurn,
  Citation,
  DartasticAiPanelOptions,
  GatewayAnswer,
  GatewayError,
} from '../types';

/// The single panel the plugin exposes.  Renders a chat surface
/// the customer's developer / on-call uses to ask questions about
/// their own telemetry.  Every fetch goes through Grafana's
/// plugin proxy (defined in plugin.json `routes:`) so the gateway
/// sees a 127.0.0.1 caller and grants under localhost-trust mode.
export const DartasticAiPanel: React.FC<PanelProps<DartasticAiPanelOptions>> = ({
  options,
  width,
  height,
}) => {
  const styles = useStyles2(getStyles);
  const [question, setQuestion] = useState(options.starterQuestion ?? '');
  const [turns, setTurns] = useState<ChatTurn[]>([]);
  const [pending, setPending] = useState(false);

  const ask = useCallback(async () => {
    const trimmed = question.trim();
    if (trimmed.length === 0 || pending) return;

    const turnId = `t_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
    const newTurn: ChatTurn = {
      id: turnId,
      question: trimmed,
      pending: true,
    };
    setTurns((prev) => [...prev, newTurn]);
    setPending(true);

    // Assemble RAG context from box-local Tempo (#85 P1.E).
    // Today: trace-id-by-mention.  If the question has a 16/32-hex
    // token we fetch the trace's spans and pass them through;
    // anything else lands at the gateway with an empty context and
    // the gateway's citation-enforcement layer refuses to answer.
    let rag: Awaited<ReturnType<typeof assembleRagContext>>;
    try {
      rag = await assembleRagContext(trimmed);
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      replaceTurn(setTurns, turnId, {
        sourcesUsed: [],
        error: {
          error: 'rag_assembly_failed',
          message: `couldn't read from Tempo: ${msg}`,
        },
      });
      setPending(false);
      setQuestion('');
      return;
    }

    setTurns((prev) =>
      prev.map((t) =>
        t.id === turnId ? { ...t, sourcesUsed: rag.sourcesUsed } : t,
      ),
    );

    try {
      const res = await getBackendSrv().fetch<GatewayAnswer | GatewayError>({
        url: '/api/plugins/dartastic-ai-panel/resources/ai/api/v1/query',
        method: 'POST',
        data: { question: trimmed, context: rag.context },
        showSuccessAlert: false,
        showErrorAlert: false,
      }).toPromise();

      const body = res?.data;
      if (!body) {
        replaceTurn(setTurns, turnId, {
          error: { error: 'empty_response', message: 'no body from gateway' },
        });
        return;
      }

      // 422 is "refuse to answer" — the gateway surfaces it as
      // a structured error with a `reason`.  Show the reason to
      // the user so they can widen the time range / pick a
      // specific trace_id.
      if ('error' in body) {
        replaceTurn(setTurns, turnId, { error: body });
        return;
      }

      replaceTurn(setTurns, turnId, { answer: body });
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      replaceTurn(setTurns, turnId, {
        error: { error: 'panel_fetch_failed', message: msg },
      });
    } finally {
      setPending(false);
      setQuestion('');
    }
  }, [question, pending]);

  return (
    <div className={styles.root} style={{ width, height }}>
      <div className={styles.history}>
        {turns.map((t) => (
          <Turn key={t.id} turn={t} showUsage={options.showUsage} />
        ))}
        {turns.length === 0 && (
          <div className={styles.empty}>
            <p>
              Ask anything about your telemetry. Every answer cites a
              span, source line, or metric in your data — Dartastic
              AI refuses to answer without grounded citations.
            </p>
            <p className={styles.subtle}>
              First time? Try: <em>"Why did the last trace drop frames?"</em>
            </p>
          </div>
        )}
      </div>
      <div className={styles.composer}>
        <TextArea
          value={question}
          onChange={(e) => setQuestion(e.currentTarget.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
              e.preventDefault();
              void ask();
            }
          }}
          placeholder="Ask about a trace, a regression, a slow widget…"
          rows={3}
          disabled={pending}
        />
        <Button
          onClick={ask}
          disabled={pending || question.trim().length === 0}
          icon={pending ? 'fa fa-spinner' : 'message'}
        >
          {pending ? 'Asking…' : 'Ask  (⌘↩)'}
        </Button>
      </div>
      <div className={styles.disclaimer}>
        AI suggestions are advisory. Review before applying any
        suggested change. Trained on Dartastic-owned data only —
        your telemetry never trains the model.
      </div>
    </div>
  );
};

interface TurnProps {
  turn: ChatTurn;
  showUsage: boolean;
}

const Turn: React.FC<TurnProps> = ({ turn, showUsage }) => {
  const styles = useStyles2(getStyles);
  return (
    <div className={styles.turn}>
      <div className={styles.question}>{turn.question}</div>
      {turn.pending && !turn.answer && !turn.error && (
        <LoadingPlaceholder text="Thinking…" />
      )}
      {turn.sourcesUsed && turn.sourcesUsed.length > 0 && (
        <div className={styles.sourcesUsed}>
          grounded in: {turn.sourcesUsed.join(' · ')}
        </div>
      )}
      {turn.answer && (
        <div className={styles.answer}>
          <div className={styles.answerBody}>{turn.answer.answer}</div>
          <CitationsList citations={turn.answer.citations} />
          {showUsage && (
            <div className={styles.usage}>
              {turn.answer.usage.input_tokens} in / {turn.answer.usage.output_tokens} out
              {' '}· {turn.answer.model}
              {turn.answer.rate.warn && (
                <span className={styles.warn}>
                  {' '}· at {turn.answer.rate.used}/{turn.answer.rate.limit} daily queries
                </span>
              )}
            </div>
          )}
        </div>
      )}
      {turn.error && (
        <Alert
          title={
            turn.error.error === 'refuse_to_answer'
              ? "Couldn't answer safely"
              : 'Request failed'
          }
          severity="warning"
        >
          {turn.error.reason ?? turn.error.message ?? turn.error.error}
        </Alert>
      )}
    </div>
  );
};

interface CitationsListProps {
  citations: Citation[];
}

const CitationsList: React.FC<CitationsListProps> = ({ citations }) => {
  const styles = useStyles2(getStyles);
  if (citations.length === 0) return null;
  return (
    <ul className={styles.citations}>
      {citations.map((c, i) => (
        <li key={i}>
          <CitationChip citation={c} />
        </li>
      ))}
    </ul>
  );
};

const CitationChip: React.FC<{ citation: Citation }> = ({ citation }) => {
  switch (citation.type) {
    case 'span':
      // Tempo's trace-explore URL.  Browser navigates to the trace
      // when the user clicks.  Falls back to a non-link span_id
      // when there's no trace_id (rare — usually present).
      if (citation.trace_id) {
        return (
          <a
            href={`/explore?left=${encodeURIComponent(
              JSON.stringify({
                datasource: 'tempo',
                queries: [{ query: citation.trace_id, queryType: 'traceql' }],
              })
            )}`}
            target="_blank"
            rel="noopener noreferrer"
          >
            span {citation.span_id.slice(0, 8)}…
          </a>
        );
      }
      return <span>span {citation.span_id.slice(0, 8)}…</span>;
    case 'source':
      return (
        <span>
          {citation.file}:{citation.line}
        </span>
      );
    case 'metric':
      return <span>metric {citation.name}</span>;
  }
};

function replaceTurn(
  setTurns: React.Dispatch<React.SetStateAction<ChatTurn[]>>,
  id: string,
  patch: Partial<ChatTurn>,
) {
  setTurns((prev) =>
    prev.map((t) => (t.id === id ? { ...t, ...patch, pending: false } : t)),
  );
}

// Suppress the unused-import warning while keeping the import
// available for future P1.E (queries Tempo via Grafana's data-
// source proxy).
void getDataSourceSrv;

const getStyles = () => ({
  root: css({
    display: 'flex',
    flexDirection: 'column',
    height: '100%',
    padding: '12px',
    gap: '12px',
  }),
  history: css({
    flex: 1,
    overflow: 'auto',
    display: 'flex',
    flexDirection: 'column',
    gap: '12px',
  }),
  empty: css({
    color: 'var(--text-secondary, #888)',
    fontSize: '13px',
    padding: '12px 0',
  }),
  subtle: css({
    color: 'var(--text-disabled, #999)',
    fontSize: '12px',
  }),
  turn: css({
    display: 'flex',
    flexDirection: 'column',
    gap: '6px',
  }),
  question: css({
    fontWeight: 600,
    color: '#0175C2', // Dartastic Flutter Blue
  }),
  sourcesUsed: css({
    fontSize: '11px',
    color: 'var(--text-disabled, #888)',
    fontStyle: 'italic',
  }),
  answer: css({
    display: 'flex',
    flexDirection: 'column',
    gap: '6px',
  }),
  answerBody: css({
    whiteSpace: 'pre-wrap',
    lineHeight: 1.5,
  }),
  citations: css({
    listStyle: 'none',
    padding: 0,
    margin: 0,
    display: 'flex',
    flexWrap: 'wrap',
    gap: '6px',
    '& li': {
      background: 'var(--background-tertiary, #2a2a2a)',
      padding: '2px 8px',
      borderRadius: '12px',
      fontSize: '11px',
    },
  }),
  usage: css({
    fontSize: '11px',
    color: 'var(--text-disabled, #888)',
  }),
  warn: css({
    color: '#FF9800',
    fontWeight: 600,
  }),
  composer: css({
    display: 'flex',
    flexDirection: 'column',
    gap: '6px',
  }),
  disclaimer: css({
    fontSize: '10px',
    color: 'var(--text-disabled, #888)',
    lineHeight: 1.3,
  }),
});
