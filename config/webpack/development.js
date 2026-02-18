const { merge } = require("webpack-merge")
const webpack = require("webpack")
const baseConfig = require("./base")

module.exports = merge(baseConfig, {
  mode: "development",
  devtool: "eval-cheap-module-source-map",
  optimization: {
    minimize: false,
    moduleIds: "named",
    chunkIds: "named",
  },
  plugins: [new webpack.HotModuleReplacementPlugin()],
  devServer: {
    host: process.env.WEBPACK_DEV_SERVER_HOST || "127.0.0.1",
    port: Number(process.env.WEBPACK_DEV_SERVER_PORT || 3035),
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
      publicPath: "/assets/",
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
