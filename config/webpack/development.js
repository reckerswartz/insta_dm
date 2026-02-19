const { merge } = require("webpack-merge")
const webpack = require("webpack")
const baseConfig = require("./base")

const DEV_SERVER_HOST = process.env.WEBPACK_DEV_SERVER_HOST || "127.0.0.1"
const DEV_SERVER_PORT = Number(process.env.WEBPACK_DEV_SERVER_PORT || 3035)
const DEV_SERVER_PROTOCOL = process.env.WEBPACK_DEV_SERVER_PROTOCOL || "http"
const DEV_SERVER_ORIGIN = process.env.WEBPACK_DEV_SERVER_ORIGIN || `${DEV_SERVER_PROTOCOL}://${DEV_SERVER_HOST}:${DEV_SERVER_PORT}`

const configuredPublicPath = process.env.WEBPACK_PUBLIC_PATH || "/assets/"
const normalizedPublicPath = (() => {
  let value = configuredPublicPath
  if (!value.startsWith("/")) value = `/${value}`
  if (!value.endsWith("/")) value = `${value}/`
  return value
})()

const runningDevServer =
  process.env.WEBPACK_SERVE === "true" ||
  process.argv.includes("serve") ||
  process.argv.some((arg) => /webpack-dev-server/i.test(arg))
const runtimePublicPath = runningDevServer ? `${DEV_SERVER_ORIGIN}${normalizedPublicPath}` : normalizedPublicPath

module.exports = merge(baseConfig, {
  mode: "development",
  devtool: "eval-cheap-module-source-map",
  output: {
    publicPath: runtimePublicPath,
  },
  optimization: {
    minimize: false,
    moduleIds: "named",
    chunkIds: "named",
  },
  plugins: [new webpack.HotModuleReplacementPlugin()],
  devServer: {
    host: DEV_SERVER_HOST,
    port: DEV_SERVER_PORT,
    hot: true,
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
      writeToDisk: true,
    },
    watchFiles: {
      paths: ["app/javascript/**/*", "app/views/**/*"],
      options: {
        usePolling: false,
      },
    },
  },
})
