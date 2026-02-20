#!/usr/bin/env ruby

require 'net/http'
require 'uri'
require 'json'

# Test the AI Dashboard endpoints
base_url = "http://localhost:3000"

puts "Testing AI Dashboard endpoints..."
puts "=" * 50

# Test 1: Check if the page loads
puts "\n1. Testing page load..."
uri = URI("#{base_url}/ai_dashboard")
response = Net::HTTP.get_response(uri)
if response.code == '200'
  puts "✅ Page loads successfully"
else
  puts "❌ Page load failed: #{response.code}"
end

# Test 2: Test individual service
puts "\n2. Testing individual service test..."
uri = URI("#{base_url}/ai_dashboard/test_service")
http = Net::HTTP.new(uri.host, uri.port)
request = Net::HTTP::Post.new(uri)
request.set_form_data({'service_name' => 'vision', 'test_type' => 'labels'})
request['X-Requested-With'] = 'XMLHttpRequest'
request['Accept'] = 'application/json'

response = http.request(request)
if response.code == '200'
  data = JSON.parse(response.body)
  puts "✅ Individual service test works"
  puts "   Result: #{data['message']}"
else
  puts "❌ Individual service test failed: #{response.code}"
end

# Test 3: Test all services
puts "\n3. Testing all services test..."
uri = URI("#{base_url}/ai_dashboard/test_all_services")
http = Net::HTTP.new(uri.host, uri.port)
request = Net::HTTP::Post.new(uri)
request['X-Requested-With'] = 'XMLHttpRequest'
request['Accept'] = 'application/json'

response = http.request(request)
if response.code == '200'
  data = JSON.parse(response.body)
  puts "✅ All services test works"
  data.each do |service, result|
    puts "   #{service}: #{result['success'] ? '✅' : '❌'} - #{result['message']}"
  end
else
  puts "❌ All services test failed: #{response.code}"
end

puts "\n" + "=" * 50
puts "Testing completed!"
