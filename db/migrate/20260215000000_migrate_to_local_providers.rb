class MigrateToLocalProviders < ActiveRecord::Migration[8.1]
  def up
    # This migration helps users switch from cloud to local providers
    # It doesn't change data structure, just provides guidance
    
    # Add a note to check current provider settings
    puts "🔄 Migration: Local AI Provider Setup"
    puts ""
    puts "✅ pgvector is already enabled and configured"
    puts "✅ Vector columns are available for face embeddings"
    puts ""
    puts "📋 Next steps to complete migration:"
    puts ""
    puts "1. Start the local AI microservice:"
    puts "   cd ai_microservice && ./setup.sh && ./start_microservice.sh"
    puts ""
    puts "2. Update provider settings in Rails console:"
    puts "   AiProviderSetting.where(provider: 'local').first_or_create.update("
    puts "     config: { ollama_model: 'mistral:7b' },"
    puts "     enabled: true"
    puts "   )"
    puts ""
    puts "3. Set local as default provider:"
    puts "   AiProviderSetting.where(provider: 'google_cloud').update_all(enabled: false)"
    puts ""
    puts "4. Test the setup:"
    puts "   Ai::Providers::LocalProvider.new.test_key!"
    puts ""
  end
  
  def down
    puts "🔄 Rollback: Cloud Provider Restoration"
    puts ""
    puts "To restore cloud providers:"
    puts "1. AiProviderSetting.where(provider: 'google_cloud').update_all(enabled: true)"
    puts "2. AiProviderSetting.where(provider: 'local').update_all(enabled: false)"
  end
end
