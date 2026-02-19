import { cable } from "@hotwired/turbo-rails"

let sharedConsumer = null

export function getCableConsumer() {
  if (!sharedConsumer) {
    sharedConsumer = cable.createConsumer()
  }
  return sharedConsumer
}

