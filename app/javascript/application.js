// Entry point for the build script in your package.json
import "@hotwired/turbo-rails"
import "./controllers"
import "./modal_manager"

// Import Bootstrap
import "bootstrap"

// Import Bootstrap CSS is handled by the Sass build

// Fallback function for generate comment button
window.generateCommentFallback = function(eventId, accountId) {
  console.log("Fallback function called", { eventId, accountId })
  
  if (!eventId || !accountId) {
    console.error("Missing eventId or accountId", { eventId, accountId })
    alert("Error: Missing required information")
    return
  }
  
  // Find the button
  const button = document.querySelector(`[data-event-id="${eventId}"]`)
  if (!button) {
    console.error("Button not found for event", eventId)
    return
  }
  
  // Show loading state
  button.disabled = true
  button.innerHTML = "Generating..."
  
  // Make the API call
  fetch(`/instagram_accounts/${accountId}/generate_llm_comment`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.getAttribute('content'),
      "Accept": "application/json"
    },
    body: JSON.stringify({
      event_id: eventId.toString(),
      provider: "ollama"
    })
  })
  .then(response => {
    if (!response.ok) {
      throw new Error(`HTTP error! status: ${response.status}`)
    }
    return response.json()
  })
  .then(data => {
    console.log("Comment generated successfully", data)
    // Refresh the story archive to show the new comment
    const storyArchive = document.querySelector('[data-controller="story-media-archive"]')
    if (storyArchive) {
      storyArchive.refresh()
    }
  })
  .catch(error => {
    console.error("Error generating comment", error)
    button.disabled = false
    button.innerHTML = "Generate Comment Locally"
    alert(`Failed to generate comment: ${error.message}`)
  })
}
