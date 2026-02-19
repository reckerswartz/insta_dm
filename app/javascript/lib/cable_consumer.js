import { createConsumer } from "@rails/actioncable"

const NOOP_CONSUMER = {
  subscriptions: {
    create() {
      return {
        unsubscribe() {}
      }
    }
  }
}

let sharedConsumer = null

export function getCableConsumer() {
  if (sharedConsumer) return sharedConsumer

  try {
    sharedConsumer = createConsumer()
    return sharedConsumer
  } catch (_error) {
    // Fall back to a no-op subscription API so UI controllers keep working
    // even if cable assets are unavailable.
    sharedConsumer = NOOP_CONSUMER
    return sharedConsumer
  }
}
