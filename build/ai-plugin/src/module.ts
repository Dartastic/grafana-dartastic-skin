// Licensed under the Dartastic Pro Commercial License.
// Copyright 2026, Mindful Software LLC, All rights reserved.

import { AppPlugin } from '@grafana/data';

import { DartasticAiAppRoot } from './components/AppRoot';

/// The app plugin is a thin shell: it owns the proxy route to the
/// gateway (plugin.json `routes:`, admins only) and the config page.
/// The chat panel is the nested panel plugin in `src/panel/`.
export const plugin = new AppPlugin().setRootPage(DartasticAiAppRoot);
