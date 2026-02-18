const development = require("./config/webpack/development")
const test = require("./config/webpack/test")
const production = require("./config/webpack/production")

const ENV_CONFIGS = {
  development,
  test,
  production,
}

const selectedEnv = process.env.NODE_ENV || "development"

if (!Object.prototype.hasOwnProperty.call(ENV_CONFIGS, selectedEnv)) {
  throw new Error(`Unsupported NODE_ENV: ${selectedEnv}`)
}

module.exports = ENV_CONFIGS[selectedEnv]
