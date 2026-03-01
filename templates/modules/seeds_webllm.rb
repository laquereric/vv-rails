# modules/seeds_webllm.rb — WebLLM provider seed data
#
# Depends on: schema_llm


@vv_applied_modules ||= []; @vv_applied_modules << "seeds_webllm"

after_bundle do
  append_to_file "db/seeds.rb", <<~RUBY

    webllm = Provider.find_or_create_by!(name: "WebLLM") do |p|
      p.api_base = "client://webgpu"
      p.api_key_ciphertext = nil
      p.priority = 1
      p.active = true
      p.requires_api_key = false
    end

    model = webllm.models.find_or_create_by!(api_model_id: "webllm-default") do |m|
      m.name = "WebLLM (Browser)"
      m.context_window = 4096
      m.capabilities = { "streaming" => true }
      m.active = true
    end

    model.presets.find_or_create_by!(name: "default") do |p|
      p.temperature = 0.3
      p.max_tokens = 256
      p.system_prompt = "You are a helpful form validation assistant."
      p.active = true
    end
  RUBY
end
