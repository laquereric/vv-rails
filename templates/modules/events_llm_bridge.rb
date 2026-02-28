# modules/events_llm_bridge.rb — Ollama inference bridge
#
# Provides: llm:request EventBus handler, HealthController, VvLocalProvider module
#
# Depends on: base, schema_res

after_bundle do
  # Append to initializer
  append_to_file "config/initializers/vv_rails.rb", <<~'RUBY'

    # --- Request counter (in-memory, resets on restart) ---

    module VvLocalProvider
      mattr_accessor :request_count
      self.request_count = 0
    end

    # --- EventBus: llm:request -> Ollama -> llm:response ---

    Vv::Rails::EventBus.on("llm:request") do |data, context|
      channel = context[:channel]
      model = data["model"] || "llama3.2"
      prompt = data["prompt"] || data["content"]
      system_prompt = data["system_prompt"]

      messages = []
      messages << { role: "system", content: system_prompt } if system_prompt
      messages << { role: "user", content: prompt }

      require "net/http"
      require "json"

      uri = URI("http://localhost:11434/api/chat")
      body = {
        model: model,
        messages: messages,
        stream: false,
        options: { temperature: 0.3, num_predict: 1024 }
      }

      http = Net::HTTP.new(uri.host, uri.port)
      http.read_timeout = 120
      request = Net::HTTP::Post.new(uri.path, "Content-Type" => "application/json")
      request.body = body.to_json

      begin
        VvLocalProvider.request_count += 1
        resp = http.request(request)
        result = JSON.parse(resp.body)

        channel.emit("llm:response", {
          content: result.dig("message", "content"),
          model: model,
          input_tokens: result["prompt_eval_count"],
          output_tokens: result["eval_count"],
          duration_ms: result["total_duration"]&.then { |ns| ns / 1_000_000 },
          request_id: data["request_id"],
          correlation_id: data["correlation_id"]
        })
      rescue => e
        Rails.logger.error "[vv-local-provider] Ollama error: #{e.message}"
        channel.emit("llm:response", {
          error: e.message,
          model: model,
          request_id: data["request_id"],
          correlation_id: data["correlation_id"]
        })
      end
    end
  RUBY

  # --- Health controller ---

  file "app/controllers/health_controller.rb", <<~RUBY
    require "net/http"

    class HealthController < ActionController::API
      def show
        ollama_ok, models = check_ollama
        model_loaded = models.any? { |m| m["name"]&.start_with?("llama3.2") }

        status = ollama_ok && model_loaded ? :ok : :service_unavailable
        render json: {
          status: status == :ok ? "ok" : "degraded",
          ollama: ollama_ok ? "reachable" : "unreachable",
          model: model_loaded ? "llama3.2" : "not_loaded",
          available_models: models.map { |m| m["name"] }
        }, status: status
      end

      private

      def check_ollama
        uri = URI("http://localhost:11434/api/tags")
        resp = Net::HTTP.get(uri)
        data = JSON.parse(resp)
        [true, data["models"] || []]
      rescue
        [false, []]
      end
    end
  RUBY

  route 'get "health", to: "health#show"'
end
