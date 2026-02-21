const { merge } = require("webpack-merge")
const webpack = require("webpack")
const baseConfig = require("./base")

const DEV_SERVER_HOST = process.env.WEBPACK_DEV_SERVER_HOST || "127.0.0.1"
const DEV_SERVER_PORT = Number(process.env.WEBPACK_DEV_SERVER_PORT || 3035)

const configuredPublicPath = process.env.WEBPACK_PUBLIC_PATH || "/assets/"
const USE_DEV_SERVER = process.env.WEBPACK_SERVE === "true"
const normalizedPublicPath = (() => {
  let value = configuredPublicPath
  if (!value.startsWith("/")) value = `/${value}`
  if (!value.endsWith("/")) value = `${value}/`
  return value
})()

module.exports = merge(baseConfig, {
  mode: "development",
  devtool: "eval-cheap-module-source-map",
  output: {
    // Resolve lazy chunks relative to the currently loaded script URL.
    publicPath: "auto",
  },
  optimization: {
    minimize: false,
    moduleIds: "named",
    chunkIds: "named",
  },
  plugins: USE_DEV_SERVER ? [new webpack.HotModuleReplacementPlugin()] : [],
  devServer: {
    host: DEV_SERVER_HOST,
    port: DEV_SERVER_PORT,
    hot: USE_DEV_SERVER,
    liveReload: true,
    compress: true,
    allowedHosts: "all",
    headers: {
      "Access-Control-Allow-Origin": "*",
    },
    client: {
      overlay: {
        errors: true,
        warnings: false,
      },
      logging: "info",
      progress: true,
    },
    static: false,
    devMiddleware: {
      publicPath: normalizedPublicPath,
      // Keep on-disk fallback assets free of dev-server/HMR runtime clients.
      // Use `yarn build:development` for fallback bundle generation.
      writeToDisk: false,
    },
    watchFiles: {
      paths: ["app/javascript/**/*", "app/views/**/*"],
      options: {
        usePolling: false,
      },
    },
  },
})
