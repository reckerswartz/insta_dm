#!/usr/bin/env ruby

# Story Debug Analyzer
# This script analyzes the captured HTML snapshots and debug data to identify story skipping issues

require 'json'
require 'fileutils'

class StoryDebugAnalyzer
  def initialize
    @debug_dir = Rails.root.join('tmp', 'story_debug_snapshots')
    @reel_debug_dir = Rails.root.join('tmp', 'story_reel_debug')
  end

  def analyze_all
    puts "=== Story Debug Analysis ==="
    puts "Analyzing captured data at #{Time.current}"
    puts

    analyze_html_snapshots
    analyze_reel_data
    generate_summary_report
  end

  private

  def analyze_html_snapshots
    puts "--- HTML Snapshots Analysis ---"
    
    return unless Dir.exist?(@debug_dir)
    
    html_files = Dir.glob(File.join(@debug_dir, '*.html')).sort
    puts "Found #{html_files.size} HTML snapshot files"
    
    html_files.each do |file|
      filename = File.basename(file)
      match = filename.match(/^(.+)_story_(\d+)_(\d+)_(.+)\.html$/)
      
      if match
        username = match[1]
        story_index = match[2].to_i
        story_id = match[3]
        timestamp = match[4]
        
        puts "\n📸 #{username} - Story #{story_index} (ID: #{story_id})"
        
        # Extract key information from HTML
        content = File.read(file)
        
        # Check if story was marked as already processed
        if content.include?('Already Processed: true')
          puts "  ⚠️  Story was marked as ALREADY PROCESSED"
        else
          puts "  ✅ Story was processed normally"
        end
        
        # Extract story count info
        if content.match(/Story Index:\s*(\d+)\s*\/\s*(\d+)/)
          current_index, total = $1.to_i, $2.to_i
          puts "  📊 Position: #{current_index}/#{total} stories"
          
          if current_index > 0 && content.include?('Already Processed: true')
            puts "  🔍 ISSUE: Story #{current_index} was skipped but it's not the first story!"
          end
        end
        
        # Look for recent events that might indicate duplicate processing
        if content.match(/"kind":\s*"story_uploaded"/)
          puts "  📝 Found previous story_upload events"
        end
      end
    end
    
    puts
  end

  def analyze_reel_data
    puts "--- Raw Reel Data Analysis ---"
    
    return unless Dir.exist?(@reel_debug_dir)
    
    json_files = Dir.glob(File.join(@reel_debug_dir, '*.json')).sort
    puts "Found #{json_files.size} reel data files"
    
    json_files.each do |file|
      filename = File.basename(file)
      match = filename.match(/^(.+)_reel_(\d+)_(.+)\.json$/)
      
      if match
        username = match[1]
        user_id = match[2]
        timestamp = match[3]
        
        puts "\n🎥 #{username} (User ID: #{user_id})"
        
        begin
          data = JSON.parse(File.read(file))
          
          puts "  📊 Items in reel: #{data['items_count']}"
          puts "  📊 Reels count: #{data['reels_count']}"
          puts "  📊 Reels media count: #{data['reels_media_count']}"
          
          # Analyze raw response structure
          raw = data['raw_response']
          if raw['reels']&.is_a?(Hash)
            raw['reels'].each do |reel_id, reel_data|
              if reel_data.is_a?(Hash) && reel_data['items'].is_a?(Array)
                puts "    📹 Reel #{reel_id}: #{reel_data['items'].size} items"
                
                # Show story IDs for debugging
                story_ids = reel_data['items'].map { |item| item['pk'] || item['id'] }.compact
                puts "    🆔 Story IDs: #{story_ids.join(', ')}"
                
                # Check for duplicate IDs
                if story_ids.size != story_ids.uniq.size
                  puts "    ⚠️  DUPLICATE STORY IDs DETECTED!"
                end
              end
            end
          end
          
        rescue JSON::ParserError => e
          puts "  ❌ Failed to parse JSON: #{e.message}"
        end
      end
    end
    
    puts
  end

  def generate_summary_report
    puts "--- Summary Report ---"
    
    # Count total stories processed vs skipped
    total_snapshots = 0
    skipped_stories = 0
    
    if Dir.exist?(@debug_dir)
      html_files = Dir.glob(File.join(@debug_dir, '*.html'))
      total_snapshots = html_files.size
      
      html_files.each do |file|
        content = File.read(file)
        if content.include?('Already Processed: true')
          skipped_stories += 1
        end
      end
    end
    
    puts "📊 Total story snapshots: #{total_snapshots}"
    puts "📊 Stories skipped: #{skipped_stories}"
    puts "📊 Stories processed: #{total_snapshots - skipped_stories}"
    
    if skipped_stories > 0
      skip_percentage = (skipped_stories.to_f / total_snapshots * 100).round(1)
      puts "⚠️  Skip rate: #{skip_percentage}%"
      
      if skip_percentage > 50
        puts "🚨 HIGH skip rate detected! This indicates a potential issue with story processing logic."
      elsif skip_percentage > 25
        puts "⚠️  Elevated skip rate detected. Review the skipping logic."
      end
    end
    
    puts
    puts "📁 Debug files location:"
    puts "   HTML snapshots: #{@debug_dir}"
    puts "   Raw reel data: #{@reel_debug_dir}"
    puts
    puts "💡 Recommendations:"
    puts "   1. Check if stories are being incorrectly marked as duplicates"
    puts "   2. Verify story_id uniqueness in the raw reel data"
    puts "   3. Review the already_processed_story? method logic"
    puts "   4. Consider using force_analyze_all: true to bypass skipping for testing"
  end
end

# Run the analysis if this script is executed directly
if __FILE__ == $0
  analyzer = StoryDebugAnalyzer.new
  analyzer.analyze_all
end
