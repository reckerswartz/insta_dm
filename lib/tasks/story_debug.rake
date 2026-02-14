namespace :story_debug do
  desc "Analyze captured story debug data to identify skipping issues"
  task analyze: :environment do
    require_relative '../tasks/story_debug_analyzer'
    
    analyzer = StoryDebugAnalyzer.new
    analyzer.analyze_all
  end

  desc "Clean up all story debug files"
  task cleanup: :environment do
    debug_dirs = [
      Rails.root.join('tmp', 'story_debug_snapshots'),
      Rails.root.join('tmp', 'story_reel_debug')
    ]
    
    debug_dirs.each do |dir|
      if Dir.exist?(dir)
        files = Dir.glob(File.join(dir, '*'))
        FileUtils.rm_rf(files)
        puts "Cleaned #{files.size} files from #{dir}"
      end
    end
    
    puts "Story debug cleanup completed."
  end

  desc "Show story debug statistics"
  task stats: :environment do
    debug_dir = Rails.root.join('tmp', 'story_debug_snapshots')
    reel_debug_dir = Rails.root.join('tmp', 'story_reel_debug')
    
    puts "=== Story Debug Statistics ==="
    puts "HTML snapshots: #{Dir.glob(File.join(debug_dir, '*.html')).size} files"
    puts "Raw reel data: #{Dir.glob(File.join(reel_debug_dir, '*.json')).size} files"
    
    if Dir.exist?(debug_dir)
      profiles = Dir.glob(File.join(debug_dir, '*.html')).map do |file|
        File.basename(file).split('_').first
      end.uniq
      
      puts "Profiles analyzed: #{profiles.join(', ')}"
    end
  end

  desc "Analyze Selenium performance logs and extract story-related endpoint patterns"
  task network_endpoints: :environment do
    require_relative "../tasks/story_network_analyzer"

    analyzer = StoryNetworkAnalyzer.new
    report = analyzer.analyze!

    output_dir = Rails.root.join("tmp", "story_debug_reports")
    FileUtils.mkdir_p(output_dir)

    timestamp = Time.current.utc.strftime("%Y%m%dT%H%M%SZ")
    json_path = output_dir.join("story_network_endpoints_#{timestamp}.json")

    File.write(json_path, JSON.pretty_generate(report))

    puts "=== Story Network Endpoint Analysis ==="
    puts "Generated: #{report[:generated_at]}"
    puts "Files scanned: #{report[:files_scanned]}"
    puts "Story GraphQL signatures: #{report[:story_graphql_signatures].length}"
    puts "Story API endpoints: #{report[:story_api_endpoints].length}"
    puts "Report saved to: #{json_path}"

    puts
    puts "--- Story GraphQL Signatures ---"
    report[:story_graphql_signatures].first(10).each do |entry|
      puts "count=#{entry[:count]} endpoint=#{entry[:endpoint]} friendly=#{entry[:friendly_name]} root=#{entry[:root_field]}"
    end

    puts
    puts "--- Story API Endpoints ---"
    report[:story_api_endpoints].first(10).each do |entry|
      puts "count=#{entry[:count]} endpoint=#{entry[:endpoint]}"
    end
  end
end
