// Licensed under the Dartastic Pro Commercial License.
// Copyright 2026, Mindful Software LLC, All rights reserved.
//
// Plain CommonJS webpack config — dodges the ts-node ESM/CJS
// minefield (was webpack.config.ts originally; ts-node loaded it
// as an ES module because tsconfig.json's `module: ESNext`
// propagated, and __dirname / require become undefined in that
// mode).  Webpack configs don't benefit much from type-checking
// so the loss is minimal.
//
// Two outputs land in `dist/`:
//
//   module.js     panel + app entry, with react / @grafana/* /
//                 @emotion/css marked external (Grafana injects
//                 them at load time).
//   plugin.json   the manifest, copied verbatim.
//
// Plus README.md, LICENSE, CHANGELOG.md, img/logo.svg — Grafana
// expects these alongside the manifest for the plugin listing UI.

const path = require('path');
const CopyPlugin = require('copy-webpack-plugin');

module.exports = (env) => ({
  mode: env && env.production ? 'production' : 'development',
  context: path.join(__dirname, 'src'),
  entry: {
    module: path.join(__dirname, 'src/module.ts'),
    'panel/module': path.join(__dirname, 'src/panel/module.ts'),
  },
  output: {
    path: path.join(__dirname, 'dist'),
    filename: '[name].js',
    libraryTarget: 'amd',
    publicPath: 'public/plugins/dartastic-ai-panel/',
    clean: true,
  },
  externals: [
    'react',
    'react-dom',
    '@grafana/data',
    '@grafana/runtime',
    '@grafana/ui',
    '@emotion/css',
  ],
  resolve: {
    extensions: ['.ts', '.tsx', '.js', '.jsx'],
  },
  module: {
    rules: [
      {
        test: /\.tsx?$/,
        exclude: /node_modules/,
        use: { loader: 'ts-loader', options: { transpileOnly: true } },
      },
      { test: /\.css$/, use: ['style-loader', 'css-loader'] },
    ],
  },
  plugins: [
    new CopyPlugin({
      patterns: [
        { from: 'plugin.json', to: '.' },
        { from: 'img', to: 'img' },
        { from: 'panel/plugin.json', to: 'panel' },
        { from: 'img', to: 'panel/img' },
        { from: path.join(__dirname, 'README.md'), to: '.' },
        { from: path.join(__dirname, 'LICENSE'), to: '.' },
        { from: path.join(__dirname, 'CHANGELOG.md'), to: '.' },
      ],
    }),
  ],
  devtool: env && env.production ? false : 'source-map',
});
