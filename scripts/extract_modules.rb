require 'fileutils'

class Extractor
  def initialize(file_path)
    @lines = File.readlines(file_path)
  end

  def extract_methods!(method_names)
    extracted = []
    
    method_names.each do |method_name|
      start_idx = nil
      end_idx = nil
      found = false
      
      @lines.each_with_index do |line, idx|
        if line.nil?
          next
        end
        if line =~ /^\s*def\s+#{method_name}(\(|\s|$)/
          start_idx = idx
          found = true
          break
        end
      end
      
      unless found
        puts "WARNING: method #{method_name} not found!"
        next
      end
      
      indent_str = @lines[start_idx].match(/^\s*/)[0]
      indent = indent_str.length
      
      # we assume that 'end' appears at the same indentation level
      # this is standard for rails
      stack = 0
      ((start_idx)...@lines.length).each do |idx|
        line = @lines[idx]
        next if line.nil?
        
        # very simple block detection - if we see a line at the exact original indentation that is `end`, it might be the end.
        if idx > start_idx && line =~ /^#{indent_str}end\s*(\#.*)?$/
            end_idx = idx
            break
        end
      end
      
      if end_idx
        extracted.concat(@lines[start_idx..end_idx])
        extracted << "\n"
        
        @lines[start_idx..end_idx] = Array.new(end_idx - start_idx + 1, nil)
      else
        puts "ERROR: Could not find end for #{method_name}"
      end
    end
    
    extracted
  end
  
  def write_back!(file_path)
    File.write(file_path, @lines.compact.join)
  end
end

def process_module(client_file, module_name, service_name, method_names)
  extractor = Extractor.new(client_file)
  extracted_lines = extractor.extract_methods!(method_names)
  extractor.write_back!(client_file)
  
  if extracted_lines.any?
    content = <<~RUBY
module Instagram
  class Client
    module #{module_name}
#{extracted_lines.join.rstrip}
    end
  end
end
    RUBY
    
    File.write("app/services/instagram/client/#{service_name}", content)
    puts "Created #{service_name} with methods: #{method_names.join(', ')}"
  end
end

client_file = "app/services/instagram/client.rb"

# 1. Direct Messaging
process_module(client_file, "DirectMessagingService", "direct_messaging_service.rb", %w[
  send_messages!
  send_message_to_user!
  send_direct_message_via_api!
  verify_messageability!
  verify_messageability_from_api
  verify_messageability_from_driver
  open_dm_from_profile
  open_dm
  open_dm_via_direct_new
  wait_for_dm_composer_or_thread!
  dm_textbox_css
  send_text_message_from_driver!
  find_visible_dm_textbox
  read_dm_textbox_text
  verify_dm_send
  click_dm_send_button
  extract_conversation_users_from_inbox_html
  dm_interaction_retry_pending?
  mark_profile_dm_state!
  apply_dm_state_from_send_result
].compact)

# 2. Profile Fetching
process_module(client_file, "ProfileFetchingService", "profile_fetching_service.rb", %w[
  fetch_profile_details!
  fetch_profile_details_and_verify_messageability!
  fetch_eligibility
  fetch_web_profile_info
  fetch_profile_details_from_driver
  fetch_profile_details_via_api
].compact)

# 3. Comment Posting
process_module(client_file, "CommentPostingService", "comment_posting_service.rb", %w[
  post_comment_to_media!
  post_comment_via_api_from_browser_context
  parse_comment_api_payload
].compact)

# 4. Follow Graph Fetching
process_module(client_file, "FollowGraphFetchingService", "follow_graph_fetching_service.rb", %w[
  sync_follow_graph!
  fetch_mutual_friends
  collect_follow_list
  upsert_follow_list!
  fetch_follow_list_via_api
  fetch_mutual_friends_via_api
].compact)

# 5. Feed Fetching
process_module(client_file, "FeedFetchingService", "feed_fetching_service.rb", %w[
  fetch_profile_feed_items_for_analysis
  fetch_profile_feed_items_via_http
  fetch_profile_feed_items_via_browser_context
  extract_latest_post_from_profile_html
  extract_latest_post_from_profile_dom
  extract_latest_post_from_profile_http
  extract_feed_items_from_dom
  dedupe_profile_feed_items
  fetch_user_feed
  fetch_home_feed_items_via_api
  extract_home_feed_item_from_api
].compact)

puts "Extraction complete."
