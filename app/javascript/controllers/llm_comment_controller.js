import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"

export default class extends Controller {
  static values = { accountId: Number }
  static targets = ["generateButton", "commentSection", "statusMessage"]

  connect() {
    console.log("LLM Comment Controller connected", { accountId: this.accountIdValue })
    this.cable = cable.createConsumer()
    this.subscription = this.cable.subscriptions.create(
      "LlmCommentGenerationChannel",
      {
        channel: "LlmCommentGenerationChannel",
        account_id: this.accountIdValue
      }
    )
    
    this.subscription.received = this.handleReceived.bind(this)
  }

  disconnect() {
    if (this.subscription) {
      this.cable.subscriptions.remove(this.subscription)
    }
  }

  generateComment(event) {
    console.log("Generate comment button clicked!", event)
    const button = event.target
    const eventId = button.dataset.eventId
    
    console.log("Generate comment clicked", { eventId, accountId: this.accountIdValue })
    
    if (!eventId) {
      console.error("No event ID found on generate comment button")
      return
    }

    // Show immediate feedback
    button.disabled = true
    button.innerHTML = "Starting..."
    
    // Call the backend API to trigger generation
    this.callGenerateCommentApi(eventId)
  }

  async callGenerateCommentApi(eventId) {
    try {
      const response = await fetch(`/instagram_accounts/${this.accountIdValue}/generate_llm_comment`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.getCsrfToken(),
          "Accept": "application/json"
        },
        body: JSON.stringify({
          event_id: eventId,
          provider: "ollama"
        })
      })

      if (!response.ok) {
        const error = await response.json()
        throw new Error(error.error || "Failed to generate comment")
      }

      const result = await response.json()
      console.log("Comment generation initiated:", result)
      
      // The actual UI updates will come via ActionCable
    } catch (error) {
      console.error("Error calling generate comment API:", error)
      this.showNotification(`Failed to generate comment: ${error.message}`, 'error')
    }
  }

  handleReceived(data) {
    console.log("LLM Comment Controller received data:", data)
    const { event_id, status, comment, message, error } = data
    
    // Find the story card for this event
    const storyCard = document.querySelector(`[data-event-id="${event_id}"]`)
    console.log("Found story card:", storyCard)
    if (!storyCard) return

    const button = storyCard.querySelector('.generate-comment-btn')
    const commentSection = storyCard.querySelector('.llm-comment-section')
    console.log("Found elements:", { button, commentSection })

    switch (status) {
      case 'started':
        console.log("Handling generation start")
        this.handleGenerationStart(button, message)
        break
      case 'completed':
        console.log("Handling generation complete")
        this.handleGenerationComplete(storyCard, button, commentSection, comment, data)
        break
      case 'error':
        console.log("Handling generation error")
        this.handleGenerationError(button, message, error)
        break
    }
  }

  handleGenerationStart(button, message) {
    if (button) {
      button.disabled = true
      button.innerHTML = `
        <span class="loading-spinner"></span>
        Generating...
      `
      button.classList.add('loading')
    }
  }

  handleGenerationComplete(storyCard, button, commentSection, comment, data) {
    console.log("handleGenerationComplete called", { storyCard, button, commentSection, comment, data })
    
    if (button) {
      button.style.display = 'none'
      console.log("Button hidden")
    }

    if (commentSection) {
      const generatedAt = data.generated_at 
        ? new Date(data.generated_at).toLocaleString() 
        : "Unknown"
      
      const newContent = `
        <div class="llm-comment-section success">
          <p class="llm-generated-comment" title="AI-generated comment suggestion">
            <strong>AI Suggestion:</strong> ${this.esc(comment)}
          </p>
          <p class="meta llm-comment-meta">
            Generated ${this.esc(generatedAt)} 
            ${data.provider ? `via ${this.esc(data.provider)}` : ""}
            ${data.model ? `(${this.esc(data.model)})` : ""}
          </p>
          <div class="success-indicator">
            ✓ Comment generated successfully
          </div>
        </div>
      `
      
      commentSection.innerHTML = newContent
      console.log("Comment section updated with new content")
    }

    // Show success notification
    this.showNotification('Comment generated successfully!', 'success')

    // Update the story card data attributes
    storyCard.dataset.hasLlmComment = 'true'
    console.log("Story card updated")
  }

  handleGenerationError(button, message, error) {
    if (button) {
      button.disabled = false
      button.innerHTML = 'Generate Comment Locally'
      button.classList.remove('loading')
    }

    // Show error notification
    this.showNotification(`Failed to generate comment: ${error}`, 'error')
  }

  showNotification(message, type = 'notice') {
    // Create notification element
    const notification = document.createElement("div")
    notification.className = `notification ${type}`
    notification.textContent = message
    
    // Add to notifications container
    const container = document.getElementById("notifications")
    if (container) {
      container.appendChild(notification)
      
      // Auto-remove after 5 seconds
      setTimeout(() => {
        notification.remove()
      }, 5000)
    }
  }

  getCsrfToken() {
    const meta = document.querySelector('meta[name="csrf-token"]')
    return meta ? meta.getAttribute('content') : ''
  }

  esc(value) {
    return String(value)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#39;")
  }
}
