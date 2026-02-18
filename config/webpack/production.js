const { merge } = require("webpack-merge")
const TerserPlugin = require("terser-webpack-plugin")
const baseConfig = require("./base")

module.exports = merge(baseConfig, {
  mode: "production",
  devtool: "source-map",
  optimization: {
    minimize: true,
    moduleIds: "deterministic",
    chunkIds: "deterministic",
    splitChunks: false,
    runtimeChunk: false,
    minimizer: [
      new TerserPlugin({
        extractComments: false,
        terserOptions: {
          compress: {
            passes: 2,
            drop_console: process.env.DROP_CONSOLE === "true",
          },
          format: {
            comments: false,
          },
        },
      }),
    ],
  },
})
