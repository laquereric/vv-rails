# modules/events_browser_manager.rb — Browser manager event handlers
#
# model:discovery:report, llm:complete, precharge:complete
#
# Depends on: base

after_bundle do
  append_to_file "config/initializers/vv_rails.rb", <<~'RUBY'

    # --- Browser manager event handlers ---

    Vv::Rails::EventBus.on("model:discovery:report") do |data, context|
      category = data["category"] || "unknown"
      discovered = data["models"] || []
      correlation_id = data["correlationId"]

      Vv::BrowserManager::ModelDiscovery.report(
        correlation_id: correlation_id,
        category: category,
        models: discovered.map { |m| m.symbolize_keys }
      )

      Rails.logger.info("[Vv] Model discovery: #{discovered.size} #{category} models reported")
    end

    Vv::Rails::EventBus.on("llm:complete") do |data, context|
      correlation_id = data["correlationId"]
      content = data["content"]
      model = data["model"]
      tokens = data["tokens"]

      if correlation_id && content
        Vv::BrowserManager::LlmServer.complete(
          correlation_id: correlation_id,
          content: content,
          model: model,
          tokens: tokens
        )
      end
    end

    Vv::Rails::EventBus.on("precharge:complete") do |data, context|
      Vv::BrowserManager::PrechargeClient.complete(
        correlation_id: data["correlationId"],
        model_id: data["modelId"],
        category: data["category"],
        status: data["status"] || "ready",
        context_tokens: data["contextTokens"],
        load_time_ms: data["loadTimeMs"],
        prefill_time_ms: data["prefillTimeMs"],
        error: data["error"]
      )

      Rails.logger.info("[Vv] Precharge complete: #{data["modelId"]} (#{data["status"]})")
    end
  RUBY
end
