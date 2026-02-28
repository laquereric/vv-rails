# modules/seeds_providers.rb — OpenAI, Anthropic, Ollama seed data
#
# Depends on: schema_llm

after_bundle do
  append_to_file "db/seeds.rb", <<~RUBY

    # --- OpenAI ---
    openai = Provider.find_or_create_by!(name: "OpenAI") do |p|
      p.api_base = "https://api.openai.com/v1"
      p.api_key_ciphertext = "sk-placeholder"
      p.priority = 1
      p.active = true
      p.requires_api_key = true
    end

    gpt4o = openai.models.find_or_create_by!(api_model_id: "gpt-4o") do |m|
      m.name = "GPT-4o"
      m.context_window = 128_000
      m.capabilities = { "vision" => true, "function_calling" => true, "streaming" => true }
      m.active = true
    end

    gpt4o.presets.find_or_create_by!(name: "default") do |p|
      p.temperature = 0.7
      p.max_tokens = 4096
      p.system_prompt = "You are a helpful assistant."
      p.active = true
    end

    openai.models.find_or_create_by!(api_model_id: "gpt-4o-mini") do |m|
      m.name = "GPT-4o Mini"
      m.context_window = 128_000
      m.capabilities = { "function_calling" => true, "streaming" => true }
      m.active = true
    end

    # --- Anthropic ---
    anthropic = Provider.find_or_create_by!(name: "Anthropic") do |p|
      p.api_base = "https://api.anthropic.com/v1"
      p.api_key_ciphertext = "sk-ant-placeholder"
      p.priority = 2
      p.active = true
      p.requires_api_key = true
    end

    claude_sonnet = anthropic.models.find_or_create_by!(api_model_id: "claude-sonnet-4-6") do |m|
      m.name = "Claude Sonnet 4.6"
      m.context_window = 200_000
      m.capabilities = { "vision" => true, "streaming" => true }
      m.active = true
    end

    claude_sonnet.presets.find_or_create_by!(name: "default") do |p|
      p.temperature = 0.7
      p.max_tokens = 4096
      p.system_prompt = "You are a helpful assistant."
      p.active = true
    end

    anthropic.models.find_or_create_by!(api_model_id: "claude-haiku-4-5") do |m|
      m.name = "Claude Haiku 4.5"
      m.context_window = 200_000
      m.capabilities = { "streaming" => true }
      m.active = true
    end

    # --- Ollama (local, no API key) ---
    ollama = Provider.find_or_create_by!(name: "Ollama") do |p|
      p.api_base = "http://localhost:11434"
      p.api_key_ciphertext = nil
      p.priority = 3
      p.active = false
      p.requires_api_key = false
    end

    ollama.models.find_or_create_by!(api_model_id: "llama3.1") do |m|
      m.name = "Llama 3.1"
      m.context_window = 128_000
      m.capabilities = { "streaming" => true }
      m.active = true
    end
  RUBY
end
