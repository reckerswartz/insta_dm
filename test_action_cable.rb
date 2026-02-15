#!/usr/bin/env ruby

puts "Testing ActionCable LLM Comment Generation..."

# Test direct broadcasting using Rails runner
account = InstagramAccount.find(2)
event = InstagramProfileEvent.find(380)

puts "Account ID: #{account.id}"
puts "Event ID: #{event.id}"
puts "Event has LLM comment: #{event.has_llm_generated_comment?}"

# Simulate broadcasting
puts "\nTesting ActionCable broadcast..."

ActionCable.server.broadcast(
  "llm_comment_generation_#{account.id}",
  {
    event_id: event.id,
    status: 'test',
    message: 'Test broadcast from Rails console'
  }
)

puts "Broadcast sent successfully!"
puts "Check the browser console for ActionCable connection logs."
