// Licensed under the Dartastic Pro Commercial License.
// Copyright 2026, Mindful Software LLC, All rights reserved.

import React from 'react';
import { AppRootProps } from '@grafana/data';

/// App-level root.  Empty for now — the plugin's value lands in
/// the included panel (`DartasticAiPanel`).  Grafana renders this
/// page when an operator clicks the plugin's "Configure" link;
/// future versions can put plugin-wide settings here (the
/// configurable gateway URL once we support multiple back-ends).
export const DartasticAiAppRoot: React.FC<AppRootProps> = () => {
  return (
    <div style={{ padding: '16px' }}>
      <h2>Dartastic AI</h2>
      <p>
        Add a <strong>Dartastic AI</strong> panel to any dashboard
        and start asking questions about your telemetry. Only
        organization admins can use it. The panel
        proxies to the bundled gateway at{' '}
        <code>localhost:8091</code> through Grafana's plugin proxy
        — no external network exit and no HMAC keys to manage.
      </p>
      <p>
        Settings live per-panel (composer placeholder, usage line).
        Cluster-wide settings will appear here in a later version.
      </p>
      <p style={{ marginTop: '24px', fontSize: '12px', color: '#888' }}>
        AI suggestions are advisory.  Trained on Dartastic-owned
        data only; your telemetry never trains the model.
      </p>
    </div>
  );
};
