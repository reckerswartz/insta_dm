const path = require("path")

const ROOT = path.resolve(__dirname, "../..")

module.exports = {
  context: ROOT,
  entry: {
    application: "./app/javascript/application.js",
  },
  output: {
    path: path.resolve(ROOT, "app/assets/builds"),
    filename: "[name].js",
    chunkFilename: "[name].chunk.js",
    sourceMapFilename: "[file].map",
    clean: false,
    publicPath: process.env.WEBPACK_PUBLIC_PATH || "/assets/",
  },
  resolve: {
    extensions: [".js", ".json"],
    alias: {
      "@": path.resolve(ROOT, "app/javascript"),
      // Force the bundled turbo build to avoid runtime-split ActionCable chunk loading.
      "@hotwired/turbo-rails": path.resolve(ROOT, "node_modules/@hotwired/turbo-rails/app/assets/javascripts/turbo.js"),
    },
  },
  cache: {
    type: "filesystem",
    cacheDirectory: path.resolve(ROOT, "tmp/cache/webpack"),
    buildDependencies: {
      config: [__filename],
    },
  },
  plugins: [],
  stats: "errors-warnings",
  infrastructureLogging: {
    level: "warn",
  },
  performance: {
    hints: false,
  },
}
