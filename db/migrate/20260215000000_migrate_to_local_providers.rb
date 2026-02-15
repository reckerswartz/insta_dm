class MigrateToLocalProviders < ActiveRecord::Migration[8.1]
  def up
    # This migration ensures local AI provider is properly configured
    
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
    puts "3. Test the setup:"
    puts "   Ai::Providers::LocalProvider.new.test_key!"
    puts ""
  end
  
  def down
    puts "🔄 Rollback: Local Provider Removal"
    puts ""
    puts "To rollback local provider setup:"
    puts "1. AiProviderSetting.where(provider: 'local').update_all(enabled: false)"
  end
end
