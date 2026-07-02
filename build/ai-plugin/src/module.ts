// Licensed under the Dartastic Pro Commercial License.
// Copyright 2026, Mindful Software LLC, All rights reserved.

import { PanelPlugin, AppPlugin } from '@grafana/data';

import { DartasticAiPanel } from './components/DartasticAiPanel';
import { DartasticAiAppRoot } from './components/AppRoot';
import { DartasticAiPanelOptions, defaultPanelOptions } from './types';

/// The app plugin itself is a thin shell — the real content lives
/// in the bundled panel.  Grafana still needs an app root for the
/// admin UI to render the plugin's config page (currently empty).
export const plugin = new AppPlugin().setRootPage(DartasticAiAppRoot);

/// Bundled panel plugin.  Grafana's plugin-loader walks the
/// `includes` array in plugin.json and registers each included
/// panel under <appPluginId>-<panelName>.
export const panelPlugin = new PanelPlugin<DartasticAiPanelOptions>(
  DartasticAiPanel,
)
  .setPanelOptions((builder) => {
    builder
      .addTextInput({
        path: 'starterQuestion',
        name: 'Starter question',
        description:
          'Optional pre-filled text the panel shows in the composer on first render. Useful for the demo dashboard.',
        defaultValue: defaultPanelOptions.starterQuestion,
      })
      .addBooleanSwitch({
        path: 'showUsage',
        name: 'Show usage line',
        description:
          'Show tokens-in / tokens-out and the daily rate-limit warning under each answer.',
        defaultValue: defaultPanelOptions.showUsage,
      });
  });
