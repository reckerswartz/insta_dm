#!/usr/bin/env ruby

# Simple test script to verify AI Dashboard controller functionality

require_relative 'config/environment'

puts "🧪 Testing AI Dashboard Controller..."

# Test the controller directly
controller = AiDashboardController.new

puts "\n1. Testing check_ai_services method..."
service_status = controller.send(:check_ai_services)
puts "Service status: #{service_status[:status]}"
puts "Services: #{service_status[:services]}"

puts "\n2. Testing vision service..."
vision_result = controller.send(:test_vision_service, 'labels')
puts "Vision test result: #{vision_result[:success] ? '✅ Success' : '❌ Failed'}"
puts "Message: #{vision_result[:message]}" if vision_result[:message]

puts "\n3. Testing OCR service..."
ocr_result = controller.send(:test_ocr_service, 'text_extraction')
puts "OCR test result: #{ocr_result[:success] ? '✅ Success' : '❌ Failed'}"
puts "Message: #{ocr_result[:message]}" if ocr_result[:message]

puts "\n✅ Controller tests completed"
