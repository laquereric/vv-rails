# vv-rails claw template
#
# Generates a PicoClaw workspace manager with markdown file editing,
# process control, inference playground, and Llama Stack API.
# Integrates vv-rails and vv-browser-manager for plugin discovery.
#
# Usage:
#   rails new myapp -m vendor/vv-rails/templates/claw.rb
#
# Default port: 3010

# --- Gems ---

gem "vv-rails", path: "vendor/vv-rails/engine"
gem "vv-browser-manager", path: "vendor/vv-browser-manager/engine"
gem "view_component", "~> 3.21"
gem "faraday"
gem "event_stream_parser"
gem "redcarpet"
gem "rack-cors"

# --- vv:install (initializer) ---

initializer "vv_rails.rb", <<~RUBY
  Vv::Rails.configure do |config|
    config.channel_prefix = "vv"
    config.cable_url = ENV.fetch("VV_CABLE_URL", "ws://localhost:3010/cable")
  end
RUBY

after_bundle do
  # --- Environment config ---

  environment <<~RUBY, env: :development
    config.action_cable.disable_request_forgery_protection = true
  RUBY

  environment <<~RUBY, env: :production
    config.action_cable.disable_request_forgery_protection = true
  RUBY

  # --- CORS ---

  initializer "cors.rb", <<~RUBY
    Rails.application.config.middleware.insert_before 0, Rack::Cors do
      allow do
        origins "*"
        resource "/api/*", headers: :any, methods: [:get, :post, :put, :patch, :delete, :options]
        resource "/vv/*",  headers: :any, methods: [:get, :options]
      end
    end
  RUBY

  # --- Importmap: pin marked.js ---

  append_to_file "config/importmap.rb", <<~RUBY
    pin "marked", to: "https://cdn.jsdelivr.net/npm/marked@15.0.7/lib/marked.esm.js"
  RUBY

  # --- Routes ---

  route <<~RUBY
    root "dashboard#index"

    resources :workspaces do
      member do
        post :start
        post :stop
        post :restart
        get "file/:name", action: :file, as: :file, constraints: { name: /[^\\/]+/ }
        patch "file/:name", action: :update_file, as: :update_file, constraints: { name: /[^\\/]+/ }
        post :create_agent_file
        get :log
      end

      resources :agents
      resources :conversations, only: [:index, :show]
    end

    get "inference", to: "inference#index"
    post "inference/chat", to: "inference#chat"

    get "deployments", to: "deployments#index"

    scope "api" do
      get "v1/health", to: "llama_stack_api#health"
      get "v1/models", to: "llama_stack_api#models"
      get "v1/models/:id", to: "llama_stack_api#show_model"
      get "v1/providers", to: "llama_stack_api#providers"
      get "v1/providers/:id", to: "llama_stack_api#show_provider"
      post "v1/inference/chat-completion", to: "llama_stack_api#chat_completion"
      post "v1/inference/completion", to: "llama_stack_api#completion"
      post "v1/inference/embeddings", to: "llama_stack_api#embeddings"
      post "v1/chat/completions", to: "llama_stack_api#chat_completion"
      post "v1/embeddings", to: "llama_stack_api#embeddings"
    end

    # Health check (Rails default already defines GET /up)
  RUBY

  # ============================================================
  # Migrations
  # ============================================================

  ts = Time.now.utc.to_i

  file "db/migrate/#{Time.at(ts + 1).utc.strftime("%Y%m%d%H%M%S")}_create_workspaces.rb", <<~RUBY
    class CreateWorkspaces < ActiveRecord::Migration[8.1]
      def change
        create_table :workspaces do |t|
          t.string :name
          t.string :path
          t.string :status, default: "stopped"
          t.integer :picoclaw_pid
          t.json :config, default: {}

          t.timestamps
        end

        add_index :workspaces, :name, unique: true
        add_index :workspaces, :status
      end
    end
  RUBY

  file "db/migrate/#{Time.at(ts + 2).utc.strftime("%Y%m%d%H%M%S")}_create_agents.rb", <<~RUBY
    class CreateAgents < ActiveRecord::Migration[8.1]
      def change
        create_table :agents do |t|
          t.references :workspace, null: false, foreign_key: true
          t.string :name
          t.text :soul_md
          t.text :agents_md
          t.text :memory_md
          t.text :heartbeat_md
          t.string :status, default: "stopped"

          t.timestamps
        end

        add_index :agents, :status
      end
    end
  RUBY

  file "db/migrate/#{Time.at(ts + 3).utc.strftime("%Y%m%d%H%M%S")}_create_conversations.rb", <<~RUBY
    class CreateConversations < ActiveRecord::Migration[8.1]
      def change
        create_table :conversations do |t|
          t.references :agent, null: false, foreign_key: true
          t.string :platform
          t.string :external_id

          t.timestamps
        end
      end
    end
  RUBY

  file "db/migrate/#{Time.at(ts + 4).utc.strftime("%Y%m%d%H%M%S")}_create_messages.rb", <<~RUBY
    class CreateMessages < ActiveRecord::Migration[8.1]
      def change
        create_table :messages do |t|
          t.references :conversation, null: false, foreign_key: true
          t.string :role
          t.text :content
          t.integer :tokens_used
          t.integer :latency_ms

          t.timestamps
        end
      end
    end
  RUBY

  file "db/migrate/#{Time.at(ts + 5).utc.strftime("%Y%m%d%H%M%S")}_create_providers.rb", <<~RUBY
    class CreateProviders < ActiveRecord::Migration[8.1]
      def change
        create_table :providers do |t|
          t.string :name
          t.string :api_base
          t.string :api_key
          t.boolean :requires_api_key
          t.string :provider_type

          t.timestamps
        end

        add_index :providers, :name, unique: true
      end
    end
  RUBY

  file "db/migrate/#{Time.at(ts + 6).utc.strftime("%Y%m%d%H%M%S")}_create_models.rb", <<~RUBY
    class CreateModels < ActiveRecord::Migration[8.1]
      def change
        create_table :models do |t|
          t.references :provider, null: false, foreign_key: true
          t.string :name
          t.string :api_model_id
          t.string :model_type
          t.integer :context_window
          t.json :capabilities

          t.timestamps
        end

        add_index :models, :api_model_id
        add_index :models, :name
      end
    end
  RUBY

  # ============================================================
  # Models
  # ============================================================

  file "app/models/workspace.rb", <<~RUBY
    class Workspace < ApplicationRecord
      has_many :agents, dependent: :destroy
      has_many :conversations, through: :agents

      validates :name, presence: true, uniqueness: true

      scope :running, -> { where(status: "running") }
      scope :stopped, -> { where(status: "stopped") }
      scope :errored, -> { where(status: "error") }

      def running?
        status == "running"
      end

      def stopped?
        status == "stopped"
      end

      def workspace_path
        path.presence || Rails.root.join("storage", "workspaces", id.to_s).to_s
      end
    end
  RUBY

  file "app/models/agent.rb", <<~RUBY
    class Agent < ApplicationRecord
      belongs_to :workspace
      has_many :conversations, dependent: :destroy
      has_many :messages, through: :conversations

      validates :name, presence: true

      scope :running, -> { where(status: "running") }
      scope :stopped, -> { where(status: "stopped") }

      def running?
        status == "running"
      end
    end
  RUBY

  file "app/models/conversation.rb", <<~RUBY
    class Conversation < ApplicationRecord
      belongs_to :agent
      has_many :messages, dependent: :destroy

      validates :platform, presence: true

      delegate :workspace, to: :agent

      def message_count
        messages.count
      end

      def last_message_at
        messages.maximum(:created_at)
      end
    end
  RUBY

  file "app/models/message.rb", <<~RUBY
    class Message < ApplicationRecord
      belongs_to :conversation

      validates :role, presence: true, inclusion: { in: %w[system user assistant] }
      validates :content, presence: true

      scope :ordered, -> { order(:created_at) }
      scope :by_role, ->(role) { where(role: role) }

      delegate :agent, to: :conversation
    end
  RUBY

  file "app/models/provider.rb", <<~RUBY
    class Provider < ApplicationRecord
      has_many :models, dependent: :destroy, class_name: "AiModel"

      validates :name, presence: true, uniqueness: true
      validates :api_base, presence: true
    end
  RUBY

  file "app/models/ai_model.rb", <<~RUBY
    # Named AiModel to avoid conflict with ActiveRecord::Base "Model"
    class AiModel < ApplicationRecord
      self.table_name = "models"

      belongs_to :provider

      validates :name, presence: true
      validates :api_model_id, presence: true

      scope :llm, -> { where(model_type: "llm") }
      scope :embedding, -> { where(model_type: "embedding") }
    end
  RUBY

  # ============================================================
  # Services
  # ============================================================

  file "app/services/pico_claw/workspace_manager.rb", <<~RUBY
    module PicoClaw
      class WorkspaceManager
        TEMPLATE_FILES = {
          "SOUL.md" => "# Soul\\n\\nDefine the agent's core identity and purpose here.\\n",
        }.freeze

        AGENT_SUB_FILE_PATTERN = /\\AAGENT_(.+)_(MEMORY|HEARTBEAT)\\.md\\z/i
        AGENT_FILE_PATTERN = /\\AAGENT_(?!.*_(MEMORY|HEARTBEAT)\\.md\\z)(.+)\\.md\\z/i

        DIRECTORIES = %w[cron skills].freeze

        attr_reader :workspace

        def initialize(workspace)
          @workspace = workspace
        end

        def create_structure
          base = workspace.workspace_path
          FileUtils.mkdir_p(base)

          DIRECTORIES.each { |dir| FileUtils.mkdir_p(File.join(base, dir)) }

          TEMPLATE_FILES.each do |filename, content|
            path = File.join(base, filename)
            File.write(path, content) unless File.exist?(path)
          end

          regenerate_agents_md

          init_git(base)
          workspace.update!(path: base) unless workspace.path == base

          base
        end

        def read_file(filename)
          path = File.join(workspace.workspace_path, filename)
          return nil unless File.exist?(path)
          File.read(path)
        end

        def write_file(filename, content)
          path = File.join(workspace.workspace_path, filename)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, content)
          regenerate_agents_md if filename.match?(AGENT_FILE_PATTERN)
          git_commit(filename, "Update \#{filename}")
          path
        end

        def agent_files
          list_files.select { |f| f.match?(AGENT_FILE_PATTERN) && !f.match?(AGENT_SUB_FILE_PATTERN) }.sort
        end

        def agent_slug(agent_file)
          match = agent_file.match(AGENT_FILE_PATTERN)
          match ? match[2] : nil
        end

        def agent_sub_files(agent_file)
          slug = agent_slug(agent_file)
          return [] unless slug

          %W[AGENT_\#{slug}_MEMORY.md AGENT_\#{slug}_HEARTBEAT.md].select do |f|
            File.exist?(File.join(workspace.workspace_path, f))
          end
        end

        def parent_agent_file(filename)
          match = filename.match(AGENT_SUB_FILE_PATTERN)
          return nil unless match
          "AGENT_\#{match[1]}.md"
        end

        def create_agent_file(name)
          slug = name.parameterize(separator: "_")
          filename = "AGENT_\#{slug}.md"
          path = File.join(workspace.workspace_path, filename)
          return filename if File.exist?(path)

          content = "# \#{name}\\n\\nDefine this agent's role and capabilities.\\n"
          File.write(path, content)

          memory_file = "AGENT_\#{slug}_MEMORY.md"
          heartbeat_file = "AGENT_\#{slug}_HEARTBEAT.md"
          memory_path = File.join(workspace.workspace_path, memory_file)
          heartbeat_path = File.join(workspace.workspace_path, heartbeat_file)

          File.write(memory_path, "# \#{name} - Memory\\n\\nPersistent memory for this agent.\\n") unless File.exist?(memory_path)
          File.write(heartbeat_path, "# \#{name} - Heartbeat\\n\\nScheduled tasks and periodic actions for this agent.\\n") unless File.exist?(heartbeat_path)

          regenerate_agents_md
          git_commit(filename, "Add \#{filename}")
          git_commit(memory_file, "Add \#{memory_file}")
          git_commit(heartbeat_file, "Add \#{heartbeat_file}")
          filename
        end

        def regenerate_agents_md
          files = agent_files
          content = "# Agents\\n\\n"
          if files.any?
            files.each do |f|
              agent_content = read_file(f)
              name = agent_slug(f).tr("_", " ").titleize
              sub_files = agent_sub_files(f)
              content += "## \#{name}\\n\\n\#{agent_content}\\n"
              if sub_files.any?
                content += "**Sub-files:** \#{sub_files.join(', ')}\\n"
              end
              content += "\\n---\\n\\n"
            end
          else
            content += "_No agents configured yet._\\n"
          end
          agents_path = File.join(workspace.workspace_path, "AGENTS.md")
          File.write(agents_path, content)
          git_commit("AGENTS.md", "Regenerate AGENTS.md")
        end

        def list_files
          base = workspace.workspace_path
          return [] unless Dir.exist?(base)

          Dir.glob("\#{base}/**/*")
            .select { |f| File.file?(f) }
            .map { |f| f.sub("\#{base}/", "") }
            .reject { |f| f.start_with?(".git/") }
            .sort
        end

        def destroy_structure
          FileUtils.rm_rf(workspace.workspace_path)
        end

        private

        def init_git(path)
          return if Dir.exist?(File.join(path, ".git"))
          system("git", "init", path, out: File::NULL, err: File::NULL)
          system("git", "-C", path, "add", ".", out: File::NULL, err: File::NULL)
          system("git", "-C", path, "commit", "-m", "Initial workspace", out: File::NULL, err: File::NULL)
        end

        def git_commit(filename, message)
          path = workspace.workspace_path
          system("git", "-C", path, "add", filename, out: File::NULL, err: File::NULL)
          system("git", "-C", path, "commit", "-m", message, out: File::NULL, err: File::NULL)
        end
      end
    end
  RUBY

  file "app/services/pico_claw/process_manager.rb", <<~RUBY
    module PicoClaw
      class ProcessManager
        attr_reader :workspace

        def initialize(workspace)
          @workspace = workspace
        end

        def start
          return { error: "Already running (PID: \#{workspace.picoclaw_pid})" } if running?
          return { error: "PicoClaw binary not found" } unless BinaryManager.exists?

          pid = spawn(
            BinaryManager.binary_path,
            "--workspace", workspace.workspace_path,
            out: log_path,
            err: log_path
          )
          Process.detach(pid)

          workspace.update!(status: "running", picoclaw_pid: pid)
          Rails.logger.info "[PicoClaw] Started workspace \#{workspace.name} (PID: \#{pid})"

          { pid: pid, status: "running" }
        rescue StandardError => e
          workspace.update!(status: "error")
          Rails.logger.error "[PicoClaw] Failed to start workspace \#{workspace.name}: \#{e.message}"
          { error: e.message }
        end

        def stop
          return { status: "already stopped" } unless workspace.picoclaw_pid

          begin
            Process.kill("TERM", workspace.picoclaw_pid)
            Rails.logger.info "[PicoClaw] Stopped workspace \#{workspace.name} (PID: \#{workspace.picoclaw_pid})"
          rescue Errno::ESRCH
            Rails.logger.warn "[PicoClaw] Process \#{workspace.picoclaw_pid} already dead"
          end

          workspace.update!(status: "stopped", picoclaw_pid: nil)
          { status: "stopped" }
        end

        def restart
          stop
          start
        end

        def running?
          return false unless workspace.picoclaw_pid
          Process.kill(0, workspace.picoclaw_pid)
          true
        rescue Errno::ESRCH, Errno::EPERM
          workspace.update!(status: "stopped", picoclaw_pid: nil) if workspace.status == "running"
          false
        end

        def status
          alive = running?
          {
            workspace_id: workspace.id,
            pid: workspace.picoclaw_pid,
            running: alive,
            status: alive ? "running" : "stopped",
          }
        end

        private

        def log_path
          File.join(workspace.workspace_path, "picoclaw.log")
        end
      end
    end
  RUBY

  file "app/services/pico_claw/binary_manager.rb", <<~RUBY
    module PicoClaw
      class BinaryManager
        BINARY_NAME = "picoclaw"

        def self.binary_path
          ENV.fetch("PICOCLAW_BINARY_PATH") { Rails.root.join("bin", BINARY_NAME).to_s }
        end

        def self.platform
          os = RbConfig::CONFIG["host_os"]
          cpu = RbConfig::CONFIG["host_cpu"]

          os_part = case os
          when /linux/i then "linux"
          when /darwin/i then "darwin"
          else "unknown"
          end

          arch_part = case cpu
          when /x86_64|amd64/i then "amd64"
          when /aarch64|arm64/i then "arm64"
          else "unknown"
          end

          "\#{os_part}-\#{arch_part}"
        end

        def self.exists?
          File.executable?(binary_path)
        end

        def self.version
          return nil unless exists?
          `\#{binary_path} --version 2>/dev/null`.strip
        rescue StandardError
          nil
        end

        def self.healthy?
          exists? && version.present?
        end

        def self.status
          {
            path: binary_path,
            exists: exists?,
            version: version,
            platform: platform,
            healthy: healthy?,
          }
        end
      end
    end
  RUBY

  file "app/services/vv_provider/health_check.rb", <<~RUBY
    require "net/http"
    require "json"
    require "uri"

    module VvProvider
      module HealthCheck
        DEFAULT_URL = "http://localhost:8321"
        TIMEOUT = 2

        def self.base_url
          ENV.fetch("VV_PROVIDER_URL", DEFAULT_URL)
        end

        def self.status
          url = base_url
          result = { connected: false, url: url, models: [], error: nil }

          begin
            health_uri = URI("\#{url}/v1/health")
            http = Net::HTTP.new(health_uri.host, health_uri.port)
            http.use_ssl = (health_uri.scheme == "https")
            http.open_timeout = TIMEOUT
            http.read_timeout = TIMEOUT

            response = http.get(health_uri.path)
            unless response.is_a?(Net::HTTPSuccess)
              result[:error] = "Health check returned HTTP \#{response.code}"
              return result
            end

            result[:connected] = true
            result[:models] = fetch_models(url)
          rescue Errno::ECONNREFUSED
            result[:error] = "Connection refused at \#{url}"
          rescue Net::OpenTimeout, Net::ReadTimeout
            result[:error] = "Connection timed out at \#{url}"
          rescue StandardError => e
            result[:error] = e.message
          end

          result
        end

        def self.connected?
          status[:connected]
        end

        def self.fetch_models(url = base_url)
          uri = URI("\#{url}/v1/models")
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == "https")
          http.open_timeout = TIMEOUT
          http.read_timeout = TIMEOUT

          response = http.get(uri.path)
          return [] unless response.is_a?(Net::HTTPSuccess)

          data = JSON.parse(response.body)
          models = data["data"] || data["models"] || []
          models.map { |m| m.is_a?(Hash) ? m : { "id" => m.to_s } }
        rescue StandardError
          []
        end

        private_class_method :fetch_models
      end
    end
  RUBY

  file "app/services/llama_stack/provider_client.rb", <<~RUBY
    require "json"
    require "net/http"
    require "uri"
    require "securerandom"

    module LlamaStack
      module ProviderClient
        def self.base_url
          VvProvider::HealthCheck.base_url
        end

        def self.chat_completion(model:, messages:, stream: false, **params, &block)
          uri = URI("\#{base_url}/v1/chat/completions")

          body = {
            model: model,
            messages: normalize_messages(messages),
            stream: stream,
          }
          body[:temperature] = params[:temperature] if params[:temperature]
          body[:max_tokens] = params[:max_tokens] if params[:max_tokens]
          body[:top_p] = params[:top_p] if params[:top_p]

          if stream && block
            stream_request(uri, body, &block)
          else
            start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            data = http_post_json(uri, body, timeout: params[:timeout] || 120)
            elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round

            ResponseFormatter.chat_completion(
              content: data.dig("choices", 0, "message", "content"),
              model: model,
              input_tokens: data.dig("usage", "prompt_tokens"),
              output_tokens: data.dig("usage", "completion_tokens"),
              latency_ms: elapsed_ms,
            )
          end
        end

        def self.completion(model:, prompt:, stream: false, **params, &block)
          uri = URI("\#{base_url}/v1/completions")

          body = {
            model: model,
            prompt: prompt,
            stream: stream,
          }
          body[:temperature] = params[:temperature] if params[:temperature]
          body[:max_tokens] = params[:max_tokens] if params[:max_tokens]

          if stream && block
            stream_request(uri, body, format: :completion, &block)
          else
            start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            data = http_post_json(uri, body, timeout: params[:timeout] || 120)
            elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round

            ResponseFormatter.text_completion(
              text: data.dig("choices", 0, "text"),
              model: model,
              input_tokens: data.dig("usage", "prompt_tokens"),
              output_tokens: data.dig("usage", "completion_tokens"),
              latency_ms: elapsed_ms,
            )
          end
        end

        def self.embeddings(model:, input:, **params)
          uri = URI("\#{base_url}/v1/embeddings")
          input = [input] if input.is_a?(String)

          body = { model: model, input: input }

          data = http_post_json(uri, body, timeout: params[:timeout] || 60)

          ResponseFormatter.embeddings(
            embeddings: (data["data"] || []).map { |d| d["embedding"] },
            model: model,
            input_count: input.size,
          )
        end

        def self.stream_request(uri, body, format: :chat, &block)
          completion_id = "chatcmpl-\#{SecureRandom.hex(12)}"
          http = build_http(uri, timeout: 300)
          request = Net::HTTP::Post.new(uri.path, "Content-Type" => "application/json")
          request.body = body.to_json

          http.request(request) do |response|
            unless response.is_a?(Net::HTTPSuccess)
              raise "VV Provider error: HTTP \#{response.code}"
            end

            response.read_body do |chunk|
              chunk.each_line do |line|
                line = line.strip
                next unless line.start_with?("data: ")
                payload = line.sub("data: ", "")
                break if payload == "[DONE]"
                data = JSON.parse(payload) rescue next

                if format == :chat
                  content = data.dig("choices", 0, "delta", "content")
                  next unless content
                  block.call(ResponseFormatter.chat_completion_chunk(
                    content: content,
                    completion_id: completion_id,
                    model: body[:model],
                  ))
                elsif format == :completion
                  text = data.dig("choices", 0, "text")
                  next unless text
                  block.call(ResponseFormatter.text_completion_chunk(
                    text: text,
                    completion_id: completion_id,
                    model: body[:model],
                  ))
                end
              end
            end
          end
        end

        def self.normalize_messages(messages)
          messages.map do |m|
            m = m.transform_keys(&:to_s)
            { "role" => m["role"], "content" => m["content"] }
          end
        end

        def self.http_post_json(uri, body, timeout: 120)
          http = build_http(uri, timeout: timeout)
          request = Net::HTTP::Post.new(uri.path, "Content-Type" => "application/json")
          request.body = body.to_json

          resp = http.request(request)
          unless resp.is_a?(Net::HTTPSuccess)
            raise "VV Provider error: HTTP \#{resp.code}: \#{resp.body}"
          end
          JSON.parse(resp.body)
        rescue Errno::ECONNREFUSED
          raise "VV Provider not reachable at \#{uri}. Is the VV Chrome extension running?"
        rescue Net::OpenTimeout, Net::ReadTimeout
          raise "VV Provider timed out at \#{uri}"
        end

        def self.build_http(uri, timeout: 120)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == "https")
          http.read_timeout = timeout
          http.open_timeout = 10
          http
        end

        private_class_method :normalize_messages, :http_post_json, :build_http, :stream_request
      end
    end
  RUBY

  file "app/services/llama_stack/response_formatter.rb", <<~RUBY
    require "securerandom"

    module LlamaStack
      module ResponseFormatter
        def self.chat_completion(content:, model:, input_tokens: nil, output_tokens: nil, latency_ms: nil)
          input_tokens ||= 0
          output_tokens ||= 0
          {
            id: "chatcmpl-\#{SecureRandom.hex(12)}",
            object: "chat.completion",
            created: Time.now.to_i,
            model: model,
            choices: [{
              index: 0,
              message: { role: "assistant", content: content },
              finish_reason: "stop",
            }],
            usage: {
              prompt_tokens: input_tokens,
              completion_tokens: output_tokens,
              total_tokens: input_tokens + output_tokens,
            },
          }
        end

        def self.chat_completion_chunk(content:, completion_id:, model:, done: false)
          {
            id: completion_id,
            object: "chat.completion.chunk",
            created: Time.now.to_i,
            model: model,
            choices: [{
              index: 0,
              delta: done ? {} : { role: "assistant", content: content },
              finish_reason: done ? "stop" : nil,
            }],
          }
        end

        def self.text_completion(text:, model:, input_tokens: nil, output_tokens: nil, latency_ms: nil)
          input_tokens ||= 0
          output_tokens ||= 0
          {
            id: "cmpl-\#{SecureRandom.hex(12)}",
            object: "text_completion",
            created: Time.now.to_i,
            model: model,
            choices: [{
              text: text,
              index: 0,
              finish_reason: "stop",
            }],
            usage: {
              prompt_tokens: input_tokens,
              completion_tokens: output_tokens,
              total_tokens: input_tokens + output_tokens,
            },
          }
        end

        def self.text_completion_chunk(text:, completion_id:, model:, done: false)
          {
            id: completion_id,
            object: "text_completion.chunk",
            created: Time.now.to_i,
            model: model,
            choices: [{
              text: done ? "" : text,
              index: 0,
              finish_reason: done ? "stop" : nil,
            }],
          }
        end

        def self.embeddings(embeddings:, model:, input_count: 1)
          data = (embeddings || []).each_with_index.map do |emb, i|
            { object: "embedding", index: i, embedding: emb }
          end
          {
            object: "list",
            data: data,
            model: model,
            usage: { prompt_tokens: input_count, total_tokens: input_count },
          }
        end

        def self.model(record)
          {
            identifier: record.api_model_id,
            provider_id: record.provider&.name&.downcase,
            provider_resource_id: record.api_model_id,
            model_type: "llm",
            metadata: {
              context_window: record.context_window,
              capabilities: record.capabilities,
            }.compact,
          }
        end

        def self.model_list(records)
          { object: "list", data: records.map { |r| model(r) } }
        end

        def self.provider(record)
          {
            provider_id: record.name.downcase,
            provider_type: "remote::\#{record.name.downcase}",
            config: {
              api_base: record.api_base,
              requires_api_key: record.requires_api_key,
            }.compact,
          }
        end

        def self.provider_list(records)
          { object: "list", data: records.map { |r| provider(r) } }
        end

        def self.list(data, has_more: false)
          result = { object: "list", data: data }
          result[:has_more] = has_more if has_more
          result
        end
      end
    end
  RUBY

  # ============================================================
  # ApplicationHelper
  # ============================================================

  remove_file "app/helpers/application_helper.rb"
  file "app/helpers/application_helper.rb", <<~RUBY
    module ApplicationHelper
      def render_markdown(text)
        return "" if text.blank?

        renderer = Redcarpet::Render::HTML.new(
          hard_wrap: true,
          link_attributes: { target: "_blank", rel: "noopener" }
        )
        markdown = Redcarpet::Markdown.new(renderer,
          autolink: true,
          tables: true,
          fenced_code_blocks: true,
          strikethrough: true,
          highlight: true,
        )
        markdown.render(text).html_safe
      end
    end
  RUBY

  # ============================================================
  # ViewComponents
  # ============================================================

  file "app/components/application_component.rb", <<~RUBY
    # frozen_string_literal: true

    class ApplicationComponent < ViewComponent::Base
    end
  RUBY

  # --- NavbarComponent ---

  file "app/components/navbar_component.rb", <<~RUBY
    # frozen_string_literal: true

    class NavbarComponent < ApplicationComponent
      NAV_ITEMS = [
        { label: "Dashboard", path: :root_path, match: ->(p) { p == "/" } },
        { label: "Workspaces", path: :workspaces_path, match: ->(p) { p.start_with?("/workspaces") } },
        { label: "Inference", path: :inference_path, match: ->(p) { p.start_with?("/inference") } },
        { label: "Deployments", path: :deployments_path, match: ->(p) { p.start_with?("/deployments") } }
      ].freeze

      def initialize(current_path:)
        @current_path = current_path
      end

      def active?(item)
        item[:match].call(@current_path)
      end

      def link_classes(item)
        base = "rounded-md px-3 py-2 text-sm font-medium"
        if active?(item)
          "\#{base} bg-gray-900 text-white"
        else
          "\#{base} text-gray-300 hover:bg-gray-700 hover:text-white"
        end
      end
    end
  RUBY

  file "app/components/navbar_component.html.erb", <<~'ERB'
    <nav class="bg-gray-800">
      <div class="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8">
        <div class="flex h-16 items-center justify-between">
          <div class="flex items-center">
            <div class="shrink-0">
              <span class="text-white font-bold text-xl">Rails-Claw</span>
            </div>
            <div class="ml-10 flex items-baseline space-x-4">
              <% NAV_ITEMS.each do |item| %>
                <%= link_to item[:label], send(item[:path]), class: link_classes(item) %>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </nav>
  ERB

  # --- FlashBannerComponent ---

  file "app/components/flash_banner_component.rb", <<~RUBY
    # frozen_string_literal: true

    class FlashBannerComponent < ApplicationComponent
      STYLES = {
        notice: { bg: "bg-green-50", text: "text-green-700" },
        alert:  { bg: "bg-red-50",   text: "text-red-700" }
      }.freeze

      def initialize(type:, message:)
        @type = type.to_sym
        @message = message
        @style = STYLES.fetch(@type, STYLES[:notice])
      end
    end
  RUBY

  file "app/components/flash_banner_component.html.erb", <<~'ERB'
    <div class="rounded-md <%= @style[:bg] %> p-4 mb-2">
      <p class="text-sm <%= @style[:text] %>"><%= @message %></p>
    </div>
  ERB

  # --- PageHeaderComponent ---

  file "app/components/page_header_component.rb", <<~RUBY
    # frozen_string_literal: true

    class PageHeaderComponent < ApplicationComponent
      renders_one :actions

      def initialize(title:, subtitle: nil)
        @title = title
        @subtitle = subtitle
      end
    end
  RUBY

  file "app/components/page_header_component.html.erb", <<~'ERB'
    <div class="flex justify-between items-center">
      <div>
        <h1 class="text-2xl font-bold text-gray-900"><%= @title %></h1>
        <% if @subtitle %>
          <p class="text-sm text-gray-500"><%= @subtitle %></p>
        <% end %>
      </div>
      <% if actions? %>
        <div class="flex gap-2">
          <%= actions %>
        </div>
      <% end %>
    </div>
  ERB

  # --- CardComponent ---

  file "app/components/card_component.rb", <<~RUBY
    # frozen_string_literal: true

    class CardComponent < ApplicationComponent
      def initialize(title: nil)
        @title = title
      end
    end
  RUBY

  file "app/components/card_component.html.erb", <<~'ERB'
    <div class="bg-white shadow rounded-lg p-6">
      <% if @title %>
        <h2 class="text-lg font-medium text-gray-900 mb-4"><%= @title %></h2>
      <% end %>
      <%= content %>
    </div>
  ERB

  # --- ButtonComponent ---

  file "app/components/button_component.rb", <<~RUBY
    # frozen_string_literal: true

    class ButtonComponent < ApplicationComponent
      VARIANTS = {
        primary:   "inline-flex items-center rounded-md bg-indigo-600 px-3 py-2 text-sm font-semibold text-white shadow-sm hover:bg-indigo-500",
        secondary: "inline-flex items-center rounded-md bg-white px-3 py-2 text-sm font-semibold text-gray-900 shadow-sm ring-1 ring-inset ring-gray-300 hover:bg-gray-50",
        danger:    "inline-flex items-center rounded-md bg-red-600 px-3 py-2 text-sm font-semibold text-white shadow-sm hover:bg-red-500",
        success:   "inline-flex items-center rounded-md bg-green-600 px-3 py-2 text-sm font-semibold text-white shadow-sm hover:bg-green-500",
        warning:   "inline-flex items-center rounded-md bg-yellow-600 px-3 py-2 text-sm font-semibold text-white shadow-sm hover:bg-yellow-500",
        dark:      "inline-flex items-center rounded-md bg-gray-600 px-3 py-2 text-sm font-semibold text-white shadow-sm hover:bg-gray-500"
      }.freeze

      def initialize(label:, path: nil, variant: :primary, method: nil, data: {})
        @label = label
        @path = path
        @variant = variant.to_sym
        @method = method
        @data = data
      end

      def css_classes
        VARIANTS.fetch(@variant, VARIANTS[:primary])
      end

      def button_to?
        @method.present?
      end
    end
  RUBY

  file "app/components/button_component.html.erb", <<~'ERB'
    <% if button_to? %>
      <%= button_to @label, @path, method: @method, class: css_classes, data: @data %>
    <% elsif @path %>
      <%= link_to @label, @path, class: css_classes, data: @data %>
    <% else %>
      <button type="submit" class="<%= css_classes %> cursor-pointer" data-controller="<%= @data[:controller] %>"><%= @label %></button>
    <% end %>
  ERB

  # --- StatCardComponent ---

  file "app/components/stat_card_component.rb", <<~RUBY
    # frozen_string_literal: true

    class StatCardComponent < ApplicationComponent
      COLORS = {
        gray:  "text-gray-900",
        green: "text-green-600",
        blue:  "text-blue-600",
        red:   "text-red-600"
      }.freeze

      def initialize(label:, value:, color: :gray)
        @label = label
        @value = value
        @value_color = COLORS.fetch(color.to_sym, COLORS[:gray])
      end
    end
  RUBY

  file "app/components/stat_card_component.html.erb", <<~'ERB'
    <div class="overflow-hidden rounded-lg bg-white px-4 py-5 shadow sm:p-6">
      <dt class="truncate text-sm font-medium text-gray-500"><%= @label %></dt>
      <dd class="mt-1 text-3xl font-semibold tracking-tight <%= @value_color %>"><%= @value %></dd>
    </div>
  ERB

  # --- StatusBadgeComponent ---

  file "app/components/status_badge_component.rb", <<~RUBY
    # frozen_string_literal: true

    class StatusBadgeComponent < ApplicationComponent
      COLORS = {
        "running"   => "bg-green-100 text-green-800",
        "connected" => "bg-green-100 text-green-800",
        "stopped"   => "bg-gray-100 text-gray-800",
        "error"     => "bg-red-100 text-red-800"
      }.freeze

      DEFAULT_COLOR = "bg-gray-100 text-gray-800"

      def initialize(status:)
        @status = status.to_s
      end

      def color_classes
        COLORS.fetch(@status, DEFAULT_COLOR)
      end
    end
  RUBY

  file "app/components/status_badge_component.html.erb", <<~'ERB'
    <span class="inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium <%= color_classes %>">
      <%= @status %><%= content %>
    </span>
  ERB

  # --- PlatformBadgeComponent ---

  file "app/components/platform_badge_component.rb", <<~RUBY
    # frozen_string_literal: true

    class PlatformBadgeComponent < ApplicationComponent
      def initialize(platform:)
        @platform = platform
      end
    end
  RUBY

  file "app/components/platform_badge_component.html.erb", <<~'ERB'
    <span class="inline-flex items-center rounded-full bg-blue-100 px-2.5 py-0.5 text-xs font-medium text-blue-800"><%= @platform %></span>
  ERB

  # --- EmptyStateComponent ---

  file "app/components/empty_state_component.rb", <<~RUBY
    # frozen_string_literal: true

    class EmptyStateComponent < ApplicationComponent
      def initialize(message:, action_text: nil, action_path: nil)
        @message = message
        @action_text = action_text
        @action_path = action_path
      end

      def action?
        @action_text.present? && @action_path.present?
      end
    end
  RUBY

  file "app/components/empty_state_component.html.erb", <<~'ERB'
    <div class="text-center py-12 bg-white rounded-lg shadow">
      <p class="text-gray-500"><%= @message %></p>
      <% if action? %>
        <%= link_to @action_text, @action_path, class: "mt-2 inline-block text-indigo-600 hover:text-indigo-500" %>
      <% end %>
    </div>
  ERB

  # --- FlashBannerComponent (already defined above) ---

  # --- FormErrorsComponent ---

  file "app/components/form_errors_component.rb", <<~RUBY
    # frozen_string_literal: true

    class FormErrorsComponent < ApplicationComponent
      def initialize(record:)
        @record = record
      end

      def render?
        @record.errors.any?
      end

      def messages
        @record.errors.full_messages
      end
    end
  RUBY

  file "app/components/form_errors_component.html.erb", <<~'ERB'
    <div class="rounded-md bg-red-50 p-4">
      <ul class="list-disc list-inside text-sm text-red-700">
        <% messages.each do |msg| %>
          <li><%= msg %></li>
        <% end %>
      </ul>
    </div>
  ERB

  # --- ConversationRowComponent ---

  file "app/components/conversation_row_component.rb", <<~RUBY
    # frozen_string_literal: true

    class ConversationRowComponent < ApplicationComponent
      def initialize(conversation:, workspace: nil)
        @conversation = conversation
        @workspace = workspace
      end

      def linkable?
        @workspace.present?
      end
    end
  RUBY

  file "app/components/conversation_row_component.html.erb", <<~'ERB'
    <% if linkable? %>
      <%= link_to workspace_conversation_path(@workspace, @conversation), class: "block p-4 hover:bg-gray-50" do %>
        <div class="flex justify-between items-center">
          <div>
            <span class="text-sm font-medium text-gray-900"><%= @conversation.agent.name %></span>
            <%= render PlatformBadgeComponent.new(platform: @conversation.platform) %>
            <span class="ml-2 text-xs text-gray-500"><%= @conversation.message_count %> messages</span>
          </div>
          <span class="text-sm text-gray-500"><%= time_ago_in_words(@conversation.updated_at) %> ago</span>
        </div>
      <% end %>
    <% else %>
      <div class="py-3 flex justify-between items-center">
        <div>
          <span class="text-sm font-medium text-gray-900"><%= @conversation.agent.name %></span>
          <%= render PlatformBadgeComponent.new(platform: @conversation.platform) %>
        </div>
        <span class="text-sm text-gray-500"><%= time_ago_in_words(@conversation.updated_at) %> ago</span>
      </div>
    <% end %>
  ERB

  # --- MessageBubbleComponent ---

  file "app/components/message_bubble_component.rb", <<~RUBY
    # frozen_string_literal: true

    class MessageBubbleComponent < ApplicationComponent
      AVATAR_COLORS = {
        "user"      => "bg-blue-500",
        "assistant" => "bg-green-500",
        "system"    => "bg-gray-500"
      }.freeze

      def initialize(message:)
        @message = message
      end

      def avatar_color
        AVATAR_COLORS.fetch(@message.role, "bg-gray-500")
      end

      def avatar_letter
        @message.role[0].upcase
      end

      def user?
        @message.role == "user"
      end

      def bubble_bg
        user? ? "bg-blue-50" : "bg-gray-50"
      end

      def flex_direction
        user? ? "flex-row-reverse" : ""
      end

      def has_metadata?
        @message.tokens_used.present? || @message.latency_ms.present?
      end
    end
  RUBY

  file "app/components/message_bubble_component.html.erb", <<~'ERB'
    <div class="flex gap-3 <%= flex_direction %>">
      <div class="shrink-0 w-8 h-8 rounded-full flex items-center justify-center text-xs font-medium text-white <%= avatar_color %>">
        <%= avatar_letter %>
      </div>
      <div class="max-w-2xl rounded-lg p-3 text-sm <%= bubble_bg %>">
        <p class="text-gray-900"><%= @message.content %></p>
        <% if has_metadata? %>
          <p class="mt-1 text-xs text-gray-400">
            <% if @message.tokens_used %>tokens: <%= @message.tokens_used %><% end %>
            <% if @message.latency_ms %> | latency: <%= @message.latency_ms %>ms<% end %>
          </p>
        <% end %>
      </div>
    </div>
  ERB

  # --- WorkspaceCardComponent ---

  file "app/components/workspace_card_component.rb", <<~RUBY
    # frozen_string_literal: true

    class WorkspaceCardComponent < ApplicationComponent
      MAX_VISIBLE_AGENTS = 3

      STATUS_DOT_COLORS = {
        "running"   => "bg-green-400",
        "connected" => "bg-green-400",
        "error"     => "bg-red-400"
      }.freeze

      DEFAULT_DOT_COLOR = "bg-gray-400"

      def initialize(workspace:)
        @workspace = workspace
      end

      def agents
        @agents ||= @workspace.agents.order(:name)
      end

      def visible_agents
        agents.first(MAX_VISIBLE_AGENTS)
      end

      def remaining_count
        [agents.size - MAX_VISIBLE_AGENTS, 0].max
      end

      def dot_color(status)
        STATUS_DOT_COLORS.fetch(status.to_s, DEFAULT_DOT_COLOR)
      end
    end
  RUBY

  file "app/components/workspace_card_component.html.erb", <<~'ERB'
    <div class="bg-white shadow rounded-lg hover:shadow-md transition-shadow">
      <%= link_to workspace_path(@workspace), class: "block p-6" do %>
        <div class="flex justify-between items-start">
          <h3 class="text-lg font-medium text-gray-900"><%= @workspace.name %></h3>
          <%= render StatusBadgeComponent.new(status: @workspace.status) %>
        </div>
        <p class="mt-2 text-sm text-gray-500"><%= agents.size %> agents</p>
        <% if visible_agents.any? %>
          <div class="mt-1 space-y-0.5">
            <% visible_agents.each do |agent| %>
              <div class="flex items-center gap-1.5">
                <span class="inline-block h-2 w-2 rounded-full <%= dot_color(agent.status) %>"></span>
                <span class="text-xs text-gray-600 truncate"><%= agent.name %></span>
              </div>
            <% end %>
            <% if remaining_count > 0 %>
              <p class="text-xs text-gray-400 pl-3.5">+<%= remaining_count %> more</p>
            <% end %>
          </div>
        <% end %>
        <p class="mt-1 text-xs text-gray-400">Created <%= time_ago_in_words(@workspace.created_at) %> ago</p>
      <% end %>
      <div class="px-6 pb-4 flex justify-end">
        <%= button_to "Delete", workspace_path(@workspace), method: :delete, data: { turbo_confirm: "Delete workspace \"#{@workspace.name}\"? This cannot be undone." }, class: "text-xs text-red-500 hover:text-red-700" %>
      </div>
    </div>
  ERB

  # --- VvProviderStatusComponent ---

  file "app/components/vv_provider_status_component.rb", <<~RUBY
    # frozen_string_literal: true

    class VvProviderStatusComponent < ApplicationComponent
      def initialize(provider:)
        @provider = provider
      end

      def connected?
        @provider[:connected]
      end

      def url
        @provider[:url]
      end

      def model_count
        @provider[:models]&.size || 0
      end

      def error
        @provider[:error]
      end

      def model_label
        "model\#{model_count == 1 ? '' : 's'}"
      end
    end
  RUBY

  file "app/components/vv_provider_status_component.html.erb", <<~'ERB'
    <% if connected? %>
      <div class="rounded-lg bg-green-50 border border-green-200 p-4">
        <div class="flex items-center">
          <div class="flex-shrink-0">
            <span class="inline-block h-3 w-3 rounded-full bg-green-400"></span>
          </div>
          <div class="ml-3">
            <h3 class="text-sm font-medium text-green-800">VV Provider Connected</h3>
            <p class="mt-1 text-sm text-green-700">
              <%= url %> &mdash; <%= model_count %> <%= model_label %> available
            </p>
          </div>
        </div>
      </div>
    <% else %>
      <div class="rounded-lg bg-red-50 border border-red-200 p-4">
        <div class="flex items-start">
          <div class="flex-shrink-0 pt-0.5">
            <span class="inline-block h-3 w-3 rounded-full bg-red-400"></span>
          </div>
          <div class="ml-3 flex-1">
            <h3 class="text-sm font-medium text-red-800">VV Provider Not Connected</h3>
            <p class="mt-1 text-sm text-red-700">
              Install the VV Plugin from the Chrome Web Store to enable inference.
            </p>
            <% if error %>
              <p class="mt-1 text-xs text-red-600"><%= error %></p>
            <% end %>
            <div class="mt-3 flex gap-3">
              <a href="https://chromewebstore.google.com/detail/vv-chrome-extension" target="_blank" rel="noopener noreferrer"
                class="inline-flex items-center rounded-md bg-red-600 px-3 py-2 text-sm font-semibold text-white shadow-sm hover:bg-red-500">
                Install VV Extension
              </a>
              <%= link_to "Retry", request.path, class: "inline-flex items-center rounded-md bg-white px-3 py-2 text-sm font-semibold text-red-700 shadow-sm ring-1 ring-inset ring-red-300 hover:bg-red-50" %>
            </div>
          </div>
        </div>
      </div>
    <% end %>
  ERB

  # ============================================================
  # Controllers
  # ============================================================

  remove_file "app/controllers/application_controller.rb"
  file "app/controllers/application_controller.rb", <<~RUBY
    class ApplicationController < ActionController::Base
      allow_browser versions: :modern
      stale_when_importmap_changes
    end
  RUBY

  file "app/controllers/dashboard_controller.rb", <<~RUBY
    class DashboardController < ApplicationController
      def index
        @workspaces = Workspace.all
        @running_workspaces = Workspace.running
        @running_agents = Agent.running
        @recent_conversations = Conversation.includes(:agent).order(updated_at: :desc).limit(10)
        @vv_provider = VvProvider::HealthCheck.status
      end
    end
  RUBY

  file "app/controllers/workspaces_controller.rb", <<~RUBY
    class WorkspacesController < ApplicationController
      before_action :set_workspace, only: [:show, :edit, :update, :destroy, :start, :stop, :restart, :file, :update_file, :create_agent_file, :log]

      def index
        @workspaces = Workspace.all.order(:name)
      end

      def show
        @manager = PicoClaw::WorkspaceManager.new(@workspace)
        @files = @manager.list_files
        @current_file = params[:file] || "SOUL.md"
        if @current_file == "LOG"
          log_path = File.join(@workspace.workspace_path, "picoclaw.log")
          @file_content = File.exist?(log_path) ? File.read(log_path) : "No log output yet."
        else
          @file_content = @manager.read_file(@current_file)
        end
        soul_content = @manager.read_file("SOUL.md")
        @soul_saved = soul_content.present? && soul_content != PicoClaw::WorkspaceManager::TEMPLATE_FILES["SOUL.md"]
        @agent_files = @manager.agent_files
        @agents = @workspace.agents.order(:name)
        @log_available = @workspace.running? || File.exist?(File.join(@workspace.workspace_path, "picoclaw.log"))

        if @current_file.match?(PicoClaw::WorkspaceManager::AGENT_SUB_FILE_PATTERN)
          @current_agent = @manager.parent_agent_file(@current_file)
        elsif @current_file.match?(PicoClaw::WorkspaceManager::AGENT_FILE_PATTERN)
          @current_agent = @current_file
        else
          @current_agent = nil
        end

        @current_agent_sub_files = @current_agent ? @manager.agent_sub_files(@current_agent) : []
      end

      def new
        @workspace = Workspace.new
      end

      def create
        @workspace = Workspace.new(workspace_params)
        @workspace.path = Rails.root.join("storage", "workspaces", SecureRandom.hex(8)).to_s

        if @workspace.save
          PicoClaw::WorkspaceManager.new(@workspace).create_structure
          redirect_to @workspace, notice: "Workspace created."
        else
          render :new, status: :unprocessable_entity
        end
      end

      def edit
      end

      def update
        if @workspace.update(workspace_params)
          redirect_back fallback_location: workspace_path(@workspace), notice: "Workspace renamed."
        else
          redirect_back fallback_location: workspace_path(@workspace), alert: "Name can't be blank."
        end
      end

      def destroy
        PicoClaw::WorkspaceManager.new(@workspace).destroy_structure
        @workspace.destroy
        redirect_to workspaces_path, notice: "Workspace deleted."
      end

      def start
        result = PicoClaw::ProcessManager.new(@workspace).start
        if result[:error]
          redirect_back fallback_location: workspace_path(@workspace), alert: result[:error]
        else
          redirect_to workspace_path(@workspace, file: "LOG"), notice: "Agent started (PID: \#{result[:pid]})."
        end
      end

      def stop
        PicoClaw::ProcessManager.new(@workspace).stop
        redirect_back fallback_location: workspace_path(@workspace), notice: "Agent stopped."
      end

      def restart
        PicoClaw::ProcessManager.new(@workspace).restart
        redirect_back fallback_location: workspace_path(@workspace), notice: "Agent restarted."
      end

      def create_agent_file
        manager = PicoClaw::WorkspaceManager.new(@workspace)
        filename = manager.create_agent_file(params[:agent_name])
        redirect_to workspace_path(@workspace, file: filename), notice: "Agent file created."
      end

      def log
        log_path = File.join(@workspace.workspace_path, "picoclaw.log")
        content = File.exist?(log_path) ? File.read(log_path) : "No log output yet."
        render plain: content
      end

      def file
        manager = PicoClaw::WorkspaceManager.new(@workspace)
        @current_file = params[:name]
        @file_content = manager.read_file(@current_file) || ""

        respond_to do |format|
          format.turbo_stream
          format.html { redirect_to workspace_path(@workspace, file: @current_file) }
        end
      end

      def update_file
        manager = PicoClaw::WorkspaceManager.new(@workspace)
        manager.write_file(params[:name], params[:content])

        if params[:name] == "SOUL.md"
          soul_content = manager.read_file("SOUL.md")
          soul_saved = soul_content.present? && soul_content != PicoClaw::WorkspaceManager::TEMPLATE_FILES["SOUL.md"]
          if soul_saved
            redirect_to workspace_path(@workspace, file: "AGENTS.md"), notice: "SOUL.md saved."
            return
          end
        end

        respond_to do |format|
          format.turbo_stream { render turbo_stream: turbo_stream.replace("file-status", partial: "workspaces/file_status", locals: { message: "\#{params[:name]} saved." }) }
          format.html { redirect_to workspace_path(@workspace, file: params[:name]), notice: "\#{params[:name]} saved." }
        end
      end

      private

      def set_workspace
        @workspace = Workspace.find(params[:id])
      end

      def workspace_params
        params.require(:workspace).permit(:name)
      end
    end
  RUBY

  file "app/controllers/agents_controller.rb", <<~RUBY
    class AgentsController < ApplicationController
      before_action :set_workspace
      before_action :set_agent, only: [:show, :edit, :update, :destroy]

      def index
        @agents = @workspace.agents.order(:name)
      end

      def show
        @conversations = @agent.conversations.order(updated_at: :desc)
      end

      def new
        @agent = @workspace.agents.build
      end

      def create
        @agent = @workspace.agents.build(agent_params)

        if @agent.save
          redirect_to workspace_agent_path(@workspace, @agent), notice: "Agent created."
        else
          render :new, status: :unprocessable_entity
        end
      end

      def edit
      end

      def update
        if @agent.update(agent_params)
          redirect_to workspace_agent_path(@workspace, @agent), notice: "Agent updated."
        else
          render :edit, status: :unprocessable_entity
        end
      end

      def destroy
        @agent.destroy
        redirect_to workspace_agents_path(@workspace), notice: "Agent deleted."
      end

      private

      def set_workspace
        @workspace = Workspace.find(params[:workspace_id])
      end

      def set_agent
        @agent = @workspace.agents.find(params[:id])
      end

      def agent_params
        params.require(:agent).permit(:name, :soul_md, :agents_md, :memory_md, :heartbeat_md)
      end
    end
  RUBY

  file "app/controllers/conversations_controller.rb", <<~RUBY
    class ConversationsController < ApplicationController
      before_action :set_workspace
      before_action :set_conversation, only: [:show]

      def index
        @conversations = Conversation.joins(:agent)
          .where(agents: { workspace_id: @workspace.id })
          .includes(:agent, :messages)
          .order(updated_at: :desc)
      end

      def show
        @messages = @conversation.messages.ordered
      end

      private

      def set_workspace
        @workspace = Workspace.find(params[:workspace_id])
      end

      def set_conversation
        @conversation = Conversation.find(params[:id])
      end
    end
  RUBY

  file "app/controllers/inference_controller.rb", <<~RUBY
    class InferenceController < ApplicationController
      def index
        @vv_provider = VvProvider::HealthCheck.status
        @models = @vv_provider[:models] if @vv_provider[:connected]
      end

      def chat
        unless VvProvider::HealthCheck.connected?
          render json: { error: "VV Provider not connected. Install the VV Chrome extension to enable inference." }, status: :service_unavailable
          return
        end

        messages = params[:messages] || [{ role: "user", content: params[:message] }]
        model = params[:model]

        begin
          if params[:stream] == "true"
            response.headers["Content-Type"] = "text/event-stream"
            response.headers["Cache-Control"] = "no-cache"

            LlamaStack::ProviderClient.chat_completion(
              model: model,
              messages: messages,
              stream: true,
            ) do |chunk|
              response.stream.write("data: \#{chunk.to_json}\\n\\n")
            end
            response.stream.write("data: [DONE]\\n\\n")
            response.stream.close
          else
            result = LlamaStack::ProviderClient.chat_completion(
              model: model,
              messages: messages,
            )
            render json: result
          end
        rescue ArgumentError => e
          render json: { error: e.message }, status: :bad_request
        rescue StandardError => e
          render json: { error: e.message }, status: :internal_server_error
        end
      end
    end
  RUBY

  file "app/controllers/deployments_controller.rb", <<~RUBY
    class DeploymentsController < ApplicationController
      def index
        @docker_available = system("docker", "info", out: File::NULL, err: File::NULL)
      end
    end
  RUBY

  file "app/controllers/llama_stack_api_controller.rb", <<~RUBY
    class LlamaStackApiController < ApplicationController
      skip_forgery_protection

      def health
        render json: { status: "ok" }
      end

      def models
        status = VvProvider::HealthCheck.status
        if status[:connected]
          render json: { object: "list", data: status[:models] }
        else
          render json: { object: "list", data: [], error: status[:error] }
        end
      end

      def show_model
        status = VvProvider::HealthCheck.status
        unless status[:connected]
          render json: { error: "VV Provider not connected" }, status: :service_unavailable
          return
        end

        model = status[:models].find { |m| m["id"] == params[:id] }
        if model
          render json: model
        else
          render json: { error: "Model not found" }, status: :not_found
        end
      end

      def providers
        status = VvProvider::HealthCheck.status
        render json: {
          object: "list",
          data: [{
            provider_id: "vv-local-provider",
            provider_type: "remote::vv-local-provider",
            config: { url: status[:url] },
            connected: status[:connected],
          }],
        }
      end

      def show_provider
        status = VvProvider::HealthCheck.status
        render json: {
          provider_id: "vv-local-provider",
          provider_type: "remote::vv-local-provider",
          config: { url: status[:url] },
          connected: status[:connected],
        }
      end

      def chat_completion
        result = LlamaStack::ProviderClient.chat_completion(
          model: params[:model],
          messages: params[:messages],
          stream: false,
          temperature: params[:temperature],
          max_tokens: params[:max_tokens],
        )
        render json: result
      rescue ArgumentError => e
        render json: { error: e.message }, status: :bad_request
      rescue StandardError => e
        render json: { error: e.message }, status: :internal_server_error
      end

      def completion
        result = LlamaStack::ProviderClient.completion(
          model: params[:model],
          prompt: params[:prompt],
          stream: false,
        )
        render json: result
      rescue ArgumentError => e
        render json: { error: e.message }, status: :bad_request
      end

      def embeddings
        result = LlamaStack::ProviderClient.embeddings(
          model: params[:model],
          input: params[:input],
        )
        render json: result
      rescue ArgumentError => e
        render json: { error: e.message }, status: :bad_request
      end
    end
  RUBY

  # ============================================================
  # Layout
  # ============================================================

  remove_file "app/views/layouts/application.html.erb"
  file "app/views/layouts/application.html.erb", <<~'ERB'
    <!DOCTYPE html>
    <html class="h-full bg-gray-50">
      <head>
        <title><%= content_for(:title) || "Rails-Claw" %></title>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="application-name" content="Rails-Claw">
        <%= csrf_meta_tags %>
        <%= csp_meta_tag %>
        <%= yield :head %>
        <link rel="icon" href="/icon.png" type="image/png">
        <%= stylesheet_link_tag :app, "data-turbo-track": "reload" %>
        <%= javascript_importmap_tags %>
      </head>

      <body class="h-full">
        <div class="min-h-full">
          <%= render NavbarComponent.new(current_path: request.path) %>

          <% if notice.present? || alert.present? %>
            <div class="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 mt-4">
              <%= render FlashBannerComponent.new(type: :notice, message: notice) if notice.present? %>
              <%= render FlashBannerComponent.new(type: :alert, message: alert) if alert.present? %>
            </div>
          <% end %>

          <main class="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 py-8">
            <%= yield %>
          </main>
        </div>
      </body>
    </html>
  ERB

  # ============================================================
  # Views
  # ============================================================

  file "app/views/dashboard/index.html.erb", <<~'ERB'
    <% content_for(:title) { "Dashboard - Rails-Claw" } %>

    <div class="space-y-8">
      <h1 class="text-2xl font-bold text-gray-900">Dashboard</h1>

      <%= render VvProviderStatusComponent.new(provider: @vv_provider) %>

      <div class="grid grid-cols-1 gap-5 sm:grid-cols-2 lg:grid-cols-4">
        <%= render StatCardComponent.new(label: "Total Workspaces", value: @workspaces.count) %>
        <%= render StatCardComponent.new(label: "Running Workspaces", value: @running_workspaces.count, color: :green) %>
        <%= render StatCardComponent.new(label: "Running Agents", value: @running_agents.count, color: :blue) %>
        <div class="overflow-hidden rounded-lg bg-white px-4 py-5 shadow sm:p-6">
          <dt class="truncate text-sm font-medium text-gray-500">VV Provider</dt>
          <dd class="mt-1 text-lg font-semibold tracking-tight <%= @vv_provider[:connected] ? 'text-green-600' : 'text-red-600' %>">
            <% if @vv_provider[:connected] %>
              Connected (<%= @vv_provider[:models].size %> model<%= @vv_provider[:models].size == 1 ? "" : "s" %>)
            <% else %>
              Not Connected
            <% end %>
          </dd>
        </div>
      </div>

      <%= render CardComponent.new(title: "Quick Actions") do %>
        <div class="flex gap-4">
          <%= render ButtonComponent.new(label: "New Workspace", path: new_workspace_path) %>
          <%= render ButtonComponent.new(label: "Inference Playground", path: inference_path, variant: :dark) %>
        </div>
      <% end %>

      <%= render CardComponent.new(title: "Recent Conversations") do %>
        <% if @recent_conversations.any? %>
          <div class="divide-y divide-gray-200">
            <% @recent_conversations.each do |conv| %>
              <%= render ConversationRowComponent.new(conversation: conv) %>
            <% end %>
          </div>
        <% else %>
          <p class="text-sm text-gray-500">No conversations yet.</p>
        <% end %>
      <% end %>
    </div>
  ERB

  file "app/views/workspaces/index.html.erb", <<~'ERB'
    <% content_for(:title) { "Workspaces - Rails-Claw" } %>

    <div class="space-y-6">
      <%= render PageHeaderComponent.new(title: "Workspaces") do |header| %>
        <% header.with_actions do %>
          <%= render ButtonComponent.new(label: "New Workspace", path: new_workspace_path) %>
        <% end %>
      <% end %>

      <% if @workspaces.any? %>
        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <% @workspaces.each do |workspace| %>
            <%= render WorkspaceCardComponent.new(workspace: workspace) %>
          <% end %>
        </div>
      <% else %>
        <%= render EmptyStateComponent.new(message: "No workspaces yet.", action_text: "Create your first workspace", action_path: new_workspace_path) %>
      <% end %>
    </div>
  ERB

  file "app/views/workspaces/show.html.erb", <<~'ERB'
    <% content_for(:title) { "#{@workspace.name} - Rails-Claw" } %>

    <div class="space-y-6">
      <div class="flex justify-between items-center" data-controller="inline-edit">
        <div>
          <div data-inline-edit-target="display" class="flex items-center gap-3">
            <h1 class="text-2xl font-bold text-gray-900"><%= @workspace.name %></h1>
            <button type="button" data-action="click->inline-edit#toggle" class="inline-flex items-center rounded-md bg-white px-2 py-1 text-xs font-semibold text-gray-700 shadow-sm ring-1 ring-inset ring-gray-300 hover:bg-gray-50">Edit</button>
          </div>
          <div data-inline-edit-target="form" class="hidden" style="display:none">
            <%= form_with model: @workspace, class: "flex items-center gap-2" do |f| %>
              <%= f.text_field :name, value: @workspace.name, class: "text-2xl font-bold text-gray-900 border-b-2 border-indigo-500 focus:outline-none bg-transparent py-0 px-0" %>
              <%= f.submit "Save", class: "inline-flex items-center rounded-md bg-indigo-600 px-2 py-1 text-xs font-semibold text-white shadow-sm hover:bg-indigo-500 cursor-pointer" %>
              <button type="button" data-action="click->inline-edit#cancel" class="text-xs text-gray-500 hover:text-gray-700">Cancel</button>
            <% end %>
          </div>
        </div>
        <div class="flex gap-2">
          <%= render ButtonComponent.new(label: "Conversations", path: workspace_conversations_path(@workspace), variant: :secondary) %>
          <% if @workspace.running? %>
            <%= render ButtonComponent.new(label: "Restart", path: restart_workspace_path(@workspace), variant: :warning, method: :post) %>
            <%= render ButtonComponent.new(label: "Stop", path: stop_workspace_path(@workspace), variant: :danger, method: :post) %>
          <% else %>
            <%= render ButtonComponent.new(label: "Start", path: start_workspace_path(@workspace), variant: :success, method: :post) %>
          <% end %>
          <%= render ButtonComponent.new(label: "Delete", path: workspace_path(@workspace), variant: :danger, method: :delete, data: { turbo_confirm: "Delete workspace \"#{@workspace.name}\"? This cannot be undone." }) %>
        </div>
      </div>

      <div class="mt-1">
        <%= render StatusBadgeComponent.new(status: @workspace.status) do %>
          <% if @workspace.picoclaw_pid %> (PID: <%= @workspace.picoclaw_pid %>)<% end %>
        <% end %>
      </div>

      <!-- File Editor -->
      <div class="bg-white shadow rounded-lg overflow-hidden" data-controller="dirty-form">
        <%# === L1: Primary tabs (SOUL.md + AGENTS.md + Log) === %>
        <div class="border-b border-gray-200">
          <nav class="flex flex-wrap -mb-px" aria-label="Primary tabs">
            <% l1_active_soul = @current_file == "SOUL.md" %>
            <% l1_active_agents = @current_file != "SOUL.md" && @current_file != "LOG" %>
            <% l1_active_log = @current_file == "LOG" %>
            <%= link_to "SOUL.md", workspace_path(@workspace, file: "SOUL.md"),
              data: { action: "click->dirty-form#confirmNavigation" },
              class: "px-4 py-3 text-sm font-medium border-b-2 #{l1_active_soul ? 'border-indigo-500 text-indigo-600' : 'border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300'}" %>
            <% if @soul_saved %>
              <%= link_to "AGENTS.md", workspace_path(@workspace, file: "AGENTS.md"),
                data: { action: "click->dirty-form#confirmNavigation" },
                class: "px-4 py-3 text-sm font-medium border-b-2 #{l1_active_agents ? 'border-indigo-500 text-indigo-600' : 'border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300'}" %>
            <% end %>
            <% if @log_available %>
              <%= link_to "Log", workspace_path(@workspace, file: "LOG"),
                data: { action: "click->dirty-form#confirmNavigation" },
                class: "px-4 py-3 text-sm font-medium border-b-2 #{l1_active_log ? 'border-indigo-500 text-indigo-600' : 'border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300'}" %>
            <% end %>
          </nav>
        </div>

        <% if @soul_saved && @current_file != "SOUL.md" && @current_file != "LOG" %>
          <%# === L2: Secondary tabs (AGENTS.md overview + each AGENT_x.md + Add Agent) === %>
          <div class="bg-gray-50 border-b border-gray-200">
            <nav class="flex flex-wrap items-center -mb-px" aria-label="Agent tabs">
              <% l2_active_agents_overview = @current_file == "AGENTS.md" %>
              <%= link_to "AGENTS.md", workspace_path(@workspace, file: "AGENTS.md"),
                data: { action: "click->dirty-form#confirmNavigation" },
                class: "px-3 py-2 text-xs font-medium border-b-2 #{l2_active_agents_overview ? 'border-indigo-400 text-indigo-600' : 'border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300'}" %>
              <% @agent_files.each do |agent_file| %>
                <% l2_active = (@current_agent == agent_file) %>
                <%= link_to agent_file, workspace_path(@workspace, file: agent_file),
                  data: { action: "click->dirty-form#confirmNavigation" },
                  class: "px-3 py-2 text-xs font-medium border-b-2 #{l2_active ? 'border-indigo-400 text-indigo-600' : 'border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300'}" %>
              <% end %>
              <%# Inline Add Agent form %>
              <div class="ml-2 py-1">
                <%= form_with url: create_agent_file_workspace_path(@workspace), method: :post, class: "inline-flex items-center gap-1" do |f| %>
                  <input type="text" name="agent_name" placeholder="Agent name" required class="rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 text-xs py-1 px-2 w-28" />
                  <%= f.submit "+ Add", class: "inline-flex items-center rounded-md bg-indigo-600 px-2 py-1 text-xs font-semibold text-white shadow-sm hover:bg-indigo-500 cursor-pointer" %>
                <% end %>
              </div>
            </nav>
          </div>

          <% if @current_agent.present? %>
            <%# === L3: Tertiary tabs (AGENT_x.md + AGENT_x_MEMORY.md + AGENT_x_HEARTBEAT.md) === %>
            <div class="bg-gray-100 border-b border-gray-200">
              <nav class="flex flex-wrap -mb-px" aria-label="Agent sub-file tabs">
                <% l3_active_main = (@current_file == @current_agent) %>
                <%= link_to @current_agent, workspace_path(@workspace, file: @current_agent),
                  data: { action: "click->dirty-form#confirmNavigation" },
                  class: "px-3 py-1.5 text-xs font-medium border-b-2 #{l3_active_main ? 'border-indigo-300 text-indigo-500' : 'border-transparent text-gray-400 hover:text-gray-600 hover:border-gray-300'}" %>
                <% @current_agent_sub_files.each do |sub_file| %>
                  <% l3_active = (@current_file == sub_file) %>
                  <%= link_to sub_file, workspace_path(@workspace, file: sub_file),
                    data: { action: "click->dirty-form#confirmNavigation" },
                    class: "px-3 py-1.5 text-xs font-medium border-b-2 #{l3_active ? 'border-indigo-300 text-indigo-500' : 'border-transparent text-gray-400 hover:text-gray-600 hover:border-gray-300'}" %>
                <% end %>
              </nav>
            </div>
          <% end %>
        <% end %>

        <div class="p-4" id="file-editor">
          <% if @current_file == "LOG" %>
            <%# Live log viewer with auto-refresh %>
            <div data-controller="log-poll" data-log-poll-url-value="<%= log_workspace_path(@workspace) %>" data-log-poll-interval-value="2000">
              <label class="block text-sm font-medium text-gray-700 mb-1">picoclaw.log <span class="text-gray-400">(live — refreshes every 2s)</span></label>
              <pre data-log-poll-target="output" class="block w-full rounded-md border shadow-sm font-mono text-xs p-4 overflow-y-auto whitespace-pre-wrap" style="background:#111827;color:#4ade80;height:500px"><%= @file_content || "No log output yet." %></pre>
            </div>
          <% elsif @current_file == "AGENTS.md" %>
            <%# AGENTS.md is auto-generated — read-only view %>
            <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">AGENTS.md <span class="text-gray-400">(auto-generated)</span></label>
                <textarea rows="20" disabled class="block w-full rounded-md border-gray-300 bg-gray-50 shadow-sm font-mono text-sm text-gray-500"><%= @file_content %></textarea>
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">Preview</label>
                <div class="prose prose-sm max-w-none p-4 border rounded-md bg-gray-50 h-[480px] overflow-y-auto">
                  <%= render_markdown(@file_content || "") %>
                </div>
              </div>
            </div>

            <% if @agent_files.empty? %>
              <div class="border-t border-gray-200 mt-4 pt-6 text-center">
                <p class="text-sm text-gray-500 mb-3">No agent files yet. Use the "+ Add" form in the tab bar above to create your first agent.</p>
              </div>
            <% end %>
          <% else %>
            <%# Editable file (SOUL.md, AGENT_x.md, MEMORY.md, etc.) %>
            <%= form_with url: update_file_workspace_path(@workspace, name: @current_file), method: :patch, class: "space-y-4", data: { action: "submit->dirty-form#markClean" } do |f| %>
              <div class="grid grid-cols-1 lg:grid-cols-2 gap-4" data-controller="markdown-preview">
                <div>
                  <label class="block text-sm font-medium text-gray-700 mb-1">Edit: <%= @current_file %></label>
                  <textarea name="content" rows="20" data-dirty-form-target="input" data-markdown-preview-target="input" data-action="input->markdown-preview#render input->dirty-form#markDirty" class="block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 font-mono text-sm"><%= @file_content %></textarea>
                </div>
                <div>
                  <label class="block text-sm font-medium text-gray-700 mb-1">Preview</label>
                  <div data-markdown-preview-target="preview" class="prose prose-sm max-w-none p-4 border rounded-md bg-gray-50 h-[480px] overflow-y-auto">
                    <%= render_markdown(@file_content || "") %>
                  </div>
                </div>
              </div>
              <div class="flex items-center gap-4">
                <%= f.submit "Save", class: "inline-flex items-center rounded-md bg-indigo-600 px-3 py-2 text-sm font-semibold text-white shadow-sm hover:bg-indigo-500 cursor-pointer" %>
                <span id="file-status" class="text-sm text-gray-500"></span>
              </div>
            <% end %>
          <% end %>
        </div>
      </div>
    </div>
  ERB

  file "app/views/workspaces/new.html.erb", <<~'ERB'
    <% content_for(:title) { "New Workspace - Rails-Claw" } %>

    <div class="max-w-lg mx-auto">
      <%= render PageHeaderComponent.new(title: "New Workspace") %>
      <div class="mt-6">
        <%= render "form", workspace: @workspace %>
      </div>
    </div>
  ERB

  file "app/views/workspaces/edit.html.erb", <<~'ERB'
    <% content_for(:title) { "Edit #{@workspace.name} - Rails-Claw" } %>

    <div class="max-w-lg mx-auto">
      <%= render PageHeaderComponent.new(title: "Edit Workspace") %>
      <div class="mt-6">
        <%= render "form", workspace: @workspace %>
      </div>
    </div>
  ERB

  file "app/views/workspaces/_form.html.erb", <<~'ERB'
    <%= form_with(model: workspace, class: "space-y-6") do |f| %>
      <%= render FormErrorsComponent.new(record: workspace) %>

      <div>
        <%= f.label :name, class: "block text-sm font-medium text-gray-700" %>
        <%= f.text_field :name, class: "mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm", placeholder: "My Agent Workspace" %>
      </div>

      <div class="flex gap-4">
        <%= f.submit class: "inline-flex items-center rounded-md bg-indigo-600 px-3 py-2 text-sm font-semibold text-white shadow-sm hover:bg-indigo-500 cursor-pointer" %>
        <%= render ButtonComponent.new(label: "Cancel", path: workspaces_path, variant: :secondary) %>
      </div>
    <% end %>
  ERB

  file "app/views/workspaces/_file_status.html.erb", <<~'ERB'
    <span class="text-sm text-green-600"><%= message %></span>
  ERB

  file "app/views/agents/index.html.erb", <<~'ERB'
    <% content_for(:title) { "Agents - #{@workspace.name}" } %>

    <div class="space-y-6">
      <%= render PageHeaderComponent.new(title: "Agents", subtitle: "Workspace: #{@workspace.name}") do |header| %>
        <% header.with_actions do %>
          <%= render ButtonComponent.new(label: "New Agent", path: new_workspace_agent_path(@workspace)) %>
          <%= render ButtonComponent.new(label: "Back", path: workspace_path(@workspace), variant: :secondary) %>
        <% end %>
      <% end %>

      <% if @agents.any? %>
        <div class="bg-white shadow rounded-lg divide-y divide-gray-200">
          <% @agents.each do |agent| %>
            <div class="p-4 flex justify-between items-center">
              <div>
                <%= link_to agent.name, workspace_agent_path(@workspace, agent), class: "text-sm font-medium text-indigo-600 hover:text-indigo-500" %>
                <%= render StatusBadgeComponent.new(status: agent.status) %>
                <p class="text-xs text-gray-500 mt-1"><%= agent.conversations.count %> conversations</p>
              </div>
            </div>
          <% end %>
        </div>
      <% else %>
        <%= render EmptyStateComponent.new(message: "No agents yet.") %>
      <% end %>
    </div>
  ERB

  file "app/views/agents/show.html.erb", <<~'ERB'
    <% content_for(:title) { "#{@agent.name} - Rails-Claw" } %>

    <div class="space-y-6">
      <%= render PageHeaderComponent.new(title: @agent.name, subtitle: "Workspace: #{@workspace.name}") do |header| %>
        <% header.with_actions do %>
          <%= render ButtonComponent.new(label: "Edit", path: edit_workspace_agent_path(@workspace, @agent), variant: :secondary) %>
          <%= render ButtonComponent.new(label: "Back", path: workspace_agents_path(@workspace), variant: :secondary) %>
        <% end %>
      <% end %>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <%= render CardComponent.new(title: "Details") do %>
          <dl class="space-y-3">
            <div>
              <dt class="text-sm font-medium text-gray-500">Status</dt>
              <dd class="mt-1"><%= render StatusBadgeComponent.new(status: @agent.status) %></dd>
            </div>
            <div>
              <dt class="text-sm font-medium text-gray-500">Conversations</dt>
              <dd class="mt-1 text-sm text-gray-900"><%= @agent.conversations.count %></dd>
            </div>
            <div>
              <dt class="text-sm font-medium text-gray-500">Total Messages</dt>
              <dd class="mt-1 text-sm text-gray-900"><%= @agent.messages.count %></dd>
            </div>
          </dl>
        <% end %>

        <%= render CardComponent.new(title: "Recent Conversations") do %>
          <% if @conversations.any? %>
            <div class="divide-y divide-gray-200">
              <% @conversations.limit(5).each do |conv| %>
                <div class="py-2 flex justify-between">
                  <span class="text-sm text-gray-900"><%= conv.platform %></span>
                  <span class="text-xs text-gray-500"><%= time_ago_in_words(conv.updated_at) %> ago</span>
                </div>
              <% end %>
            </div>
          <% else %>
            <p class="text-sm text-gray-500">No conversations yet.</p>
          <% end %>
        <% end %>
      </div>
    </div>
  ERB

  file "app/views/agents/new.html.erb", <<~'ERB'
    <% content_for(:title) { "New Agent - Rails-Claw" } %>

    <div class="max-w-lg mx-auto">
      <%= render PageHeaderComponent.new(title: "New Agent") %>
      <div class="mt-6">
        <%= render "form", agent: @agent, workspace: @workspace %>
      </div>
    </div>
  ERB

  file "app/views/agents/edit.html.erb", <<~'ERB'
    <% content_for(:title) { "Edit #{@agent.name} - Rails-Claw" } %>

    <div class="max-w-lg mx-auto">
      <%= render PageHeaderComponent.new(title: "Edit Agent") %>
      <div class="mt-6">
        <%= render "form", agent: @agent, workspace: @workspace %>
      </div>
    </div>
  ERB

  file "app/views/agents/_form.html.erb", <<~'ERB'
    <%= form_with(model: [workspace, agent], class: "space-y-6") do |f| %>
      <%= render FormErrorsComponent.new(record: agent) %>

      <div>
        <%= f.label :name, class: "block text-sm font-medium text-gray-700" %>
        <%= f.text_field :name, class: "mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm" %>
      </div>

      <div class="flex gap-4">
        <%= f.submit class: "inline-flex items-center rounded-md bg-indigo-600 px-3 py-2 text-sm font-semibold text-white shadow-sm hover:bg-indigo-500 cursor-pointer" %>
        <%= render ButtonComponent.new(label: "Cancel", path: workspace_agents_path(workspace), variant: :secondary) %>
      </div>
    <% end %>
  ERB

  file "app/views/conversations/index.html.erb", <<~'ERB'
    <% content_for(:title) { "Conversations - #{@workspace.name}" } %>

    <div class="space-y-6">
      <%= render PageHeaderComponent.new(title: "Conversations", subtitle: "Workspace: #{@workspace.name}") do |header| %>
        <% header.with_actions do %>
          <%= render ButtonComponent.new(label: "Back", path: workspace_path(@workspace), variant: :secondary) %>
        <% end %>
      <% end %>

      <% if @conversations.any? %>
        <div class="bg-white shadow rounded-lg divide-y divide-gray-200">
          <% @conversations.each do |conv| %>
            <%= render ConversationRowComponent.new(conversation: conv, workspace: @workspace) %>
          <% end %>
        </div>
      <% else %>
        <%= render EmptyStateComponent.new(message: "No conversations yet.") %>
      <% end %>
    </div>
  ERB

  file "app/views/conversations/show.html.erb", <<~'ERB'
    <% content_for(:title) { "Conversation - Rails-Claw" } %>

    <div class="space-y-6">
      <%= render PageHeaderComponent.new(title: "Conversation", subtitle: "Agent: #{@conversation.agent.name} | Platform: #{@conversation.platform} | #{@messages.count} messages") do |header| %>
        <% header.with_actions do %>
          <%= render ButtonComponent.new(label: "Back", path: workspace_conversations_path(@workspace), variant: :secondary) %>
        <% end %>
      <% end %>

      <%= render CardComponent.new do %>
        <div class="space-y-4">
          <% @messages.each do |message| %>
            <%= render MessageBubbleComponent.new(message: message) %>
          <% end %>
        </div>
      <% end %>
    </div>
  ERB

  file "app/views/inference/index.html.erb", <<~'ERB'
    <% content_for(:title) { "Inference Playground - Rails-Claw" } %>

    <div class="space-y-6">
      <%= render PageHeaderComponent.new(title: "Inference Playground") %>

      <% unless @vv_provider[:connected] %>
        <div class="bg-white shadow rounded-lg p-8 text-center">
          <div class="mx-auto flex h-12 w-12 items-center justify-center rounded-full bg-red-100">
            <span class="inline-block h-4 w-4 rounded-full bg-red-400"></span>
          </div>
          <h2 class="mt-4 text-lg font-semibold text-gray-900">Inference Requires the VV Provider</h2>
          <p class="mt-2 text-sm text-gray-600">
            The VV local provider is not reachable. Install the VV Chrome extension to get started.
          </p>
          <% if @vv_provider[:error] %>
            <p class="mt-1 text-xs text-gray-500"><%= @vv_provider[:error] %></p>
          <% end %>
          <div class="mt-6 flex justify-center gap-4">
            <a href="https://chromewebstore.google.com/detail/vv-chrome-extension" target="_blank" rel="noopener noreferrer"
              class="inline-flex items-center rounded-md bg-indigo-600 px-4 py-2 text-sm font-semibold text-white shadow-sm hover:bg-indigo-500">
              Install VV Extension
            </a>
            <%= render ButtonComponent.new(label: "Check Again", path: inference_path, variant: :secondary) %>
          </div>
        </div>
      <% else %>
        <div class="grid grid-cols-1 lg:grid-cols-4 gap-6" data-controller="chat">
          <div class="bg-white shadow rounded-lg p-4">
            <h2 class="text-sm font-medium text-gray-900 mb-4">Settings</h2>

            <div class="space-y-4">
              <div>
                <label class="block text-sm font-medium text-gray-700">Model</label>
                <select data-chat-target="model" class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm">
                  <% if @models.present? %>
                    <% @models.each do |model| %>
                      <option value="<%= model["id"] %>"><%= model["id"] %></option>
                    <% end %>
                  <% else %>
                    <option value="" disabled>No models available</option>
                  <% end %>
                </select>
              </div>

              <div class="rounded-md bg-green-50 p-3">
                <div class="flex items-center">
                  <span class="inline-block h-2 w-2 rounded-full bg-green-400 mr-2"></span>
                  <p class="text-xs text-green-700">VV Provider connected &mdash; <%= @models&.size || 0 %> model<%= @models&.size == 1 ? "" : "s" %></p>
                </div>
              </div>
            </div>
          </div>

          <div class="lg:col-span-3 bg-white shadow rounded-lg flex flex-col" style="height: 600px;">
            <div data-chat-target="messages" class="flex-1 overflow-y-auto p-4 space-y-4">
              <p class="text-sm text-gray-400 text-center">Send a message to begin.</p>
            </div>

            <div class="border-t border-gray-200 p-4">
              <form data-action="submit->chat#send" class="flex gap-2">
                <input type="text" data-chat-target="input" placeholder="Type a message..."
                  class="flex-1 rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm">
                <button type="submit" class="inline-flex items-center rounded-md bg-indigo-600 px-4 py-2 text-sm font-semibold text-white shadow-sm hover:bg-indigo-500">
                  Send
                </button>
              </form>
            </div>
          </div>
        </div>
      <% end %>
    </div>
  ERB

  file "app/views/deployments/index.html.erb", <<~'ERB'
    <% content_for(:title) { "Deployments - Rails-Claw" } %>

    <div class="space-y-6">
      <%= render PageHeaderComponent.new(title: "Deployments") %>

      <%= render CardComponent.new(title: "Docker Status") do %>
        <div class="flex items-center gap-2">
          <span class="inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium <%= @docker_available ? 'bg-green-100 text-green-800' : 'bg-red-100 text-red-800' %>">
            <%= @docker_available ? "Docker Available" : "Docker Not Found" %>
          </span>
        </div>
      <% end %>

      <%= render CardComponent.new(title: "Deployment Options") do %>
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div class="border rounded-lg p-4">
            <h3 class="font-medium text-gray-900">Docker Compose</h3>
            <p class="mt-1 text-sm text-gray-500">Run rails-claw with Ollama using docker-compose.</p>
            <code class="mt-2 block text-xs bg-gray-50 p-2 rounded">docker compose -f docker/docker-compose.yml up</code>
          </div>
          <div class="border rounded-lg p-4">
            <h3 class="font-medium text-gray-900">Docker Desktop Extension</h3>
            <p class="mt-1 text-sm text-gray-500">Install as a Docker Desktop extension.</p>
            <code class="mt-2 block text-xs bg-gray-50 p-2 rounded">docker extension install rails-claw</code>
          </div>
        </div>
      <% end %>
    </div>
  ERB

  # ============================================================
  # Stimulus Controllers
  # ============================================================

  file "app/javascript/controllers/chat_controller.js", <<~'JS'
    import { Controller } from "@hotwired/stimulus"

    export default class extends Controller {
      static targets = ["messages", "input", "model"]

      connect() {
        this.conversationMessages = []
      }

      async send(event) {
        event.preventDefault()

        const message = this.inputTarget.value.trim()
        if (!message) return

        const model = this.modelTarget.value
        if (!model) {
          alert("Please select a model first.")
          return
        }

        // Add user message to UI
        this.appendMessage("user", message)
        this.inputTarget.value = ""

        // Track conversation
        this.conversationMessages.push({ role: "user", content: message })

        // Send to server
        try {
          const response = await fetch("/inference/chat", {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content,
            },
            body: JSON.stringify({
              model: model,
              messages: this.conversationMessages,
            }),
          })

          const data = await response.json()

          if (data.error) {
            this.appendMessage("system", `Error: ${data.error}`)
          } else {
            const content = data.choices?.[0]?.message?.content || "No response"
            this.appendMessage("assistant", content)
            this.conversationMessages.push({ role: "assistant", content: content })
          }
        } catch (error) {
          this.appendMessage("system", `Error: ${error.message}`)
        }
      }

      appendMessage(role, content) {
        // Clear placeholder
        const placeholder = this.messagesTarget.querySelector("p.text-gray-400")
        if (placeholder) placeholder.remove()

        const wrapper = document.createElement("div")
        wrapper.className = `flex gap-3 ${role === "user" ? "flex-row-reverse" : ""}`

        const avatar = document.createElement("div")
        const colors = { user: "bg-blue-500", assistant: "bg-green-500", system: "bg-gray-500" }
        avatar.className = `shrink-0 w-8 h-8 rounded-full flex items-center justify-center text-xs font-medium text-white ${colors[role] || "bg-gray-500"}`
        avatar.textContent = role[0].toUpperCase()

        const bubble = document.createElement("div")
        bubble.className = `max-w-xl rounded-lg p-3 text-sm ${role === "user" ? "bg-blue-50" : "bg-gray-50"}`
        bubble.textContent = content

        wrapper.appendChild(avatar)
        wrapper.appendChild(bubble)
        this.messagesTarget.appendChild(wrapper)
        this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight
      }
    }
  JS

  file "app/javascript/controllers/dirty_form_controller.js", <<~'JS'
    import { Controller } from "@hotwired/stimulus"

    export default class extends Controller {
      static targets = ["input"]

      connect() {
        this.dirty = false
        this.originalValue = this.hasInputTarget ? this.inputTarget.value : ""
        this.boundBeforeUnload = this.beforeUnload.bind(this)
        window.addEventListener("beforeunload", this.boundBeforeUnload)
      }

      disconnect() {
        window.removeEventListener("beforeunload", this.boundBeforeUnload)
      }

      markDirty() {
        if (!this.hasInputTarget) return
        this.dirty = this.inputTarget.value !== this.originalValue
      }

      markClean() {
        this.dirty = false
        if (this.hasInputTarget) this.originalValue = this.inputTarget.value
      }

      confirmNavigation(event) {
        if (this.dirty) {
          if (!confirm("You have unsaved changes. Leave without saving?")) {
            event.preventDefault()
          }
        }
      }

      beforeUnload(event) {
        if (this.dirty) {
          event.preventDefault()
          event.returnValue = ""
        }
      }
    }
  JS

  file "app/javascript/controllers/markdown_preview_controller.js", <<~'JS'
    import { Controller } from "@hotwired/stimulus"
    import { marked } from "marked"

    export default class extends Controller {
      static targets = ["input", "preview"]

      connect() {
        marked.setOptions({ breaks: true, gfm: true })
        this.render()
      }

      render() {
        this.previewTarget.innerHTML = marked.parse(this.inputTarget.value || "")
      }
    }
  JS

  file "app/javascript/controllers/log_poll_controller.js", <<~'JS'
    import { Controller } from "@hotwired/stimulus"

    export default class extends Controller {
      static values = { url: String, interval: { type: Number, default: 3000 } }
      static targets = ["output"]

      connect() {
        this.poll()
        this.timer = setInterval(() => this.poll(), this.intervalValue)
        this.scrollToBottom()
      }

      disconnect() {
        if (this.timer) clearInterval(this.timer)
      }

      async poll() {
        try {
          const response = await fetch(this.urlValue)
          if (response.ok) {
            const text = await response.text()
            if (text !== this.outputTarget.textContent) {
              this.outputTarget.textContent = text
              this.scrollToBottom()
            }
          }
        } catch (e) {
          // silently ignore fetch errors
        }
      }

      scrollToBottom() {
        this.outputTarget.scrollTop = this.outputTarget.scrollHeight
      }
    }
  JS

  file "app/javascript/controllers/inline_edit_controller.js", <<~'JS'
    import { Controller } from "@hotwired/stimulus"

    export default class extends Controller {
      static targets = ["display", "form"]

      toggle() {
        const showing = this.formTarget.style.display === "none"
        this.displayTarget.style.display = showing ? "none" : ""
        this.formTarget.style.display = showing ? "" : "none"
        if (showing) {
          const input = this.formTarget.querySelector("input")
          input.focus()
          input.select()
        }
      }

      cancel() {
        this.displayTarget.style.display = ""
        this.formTarget.style.display = "none"
      }
    }
  JS

  # ============================================================
  # Seeds
  # ============================================================

  append_to_file "db/seeds.rb", <<~RUBY

    # --- VV Provider (default provider) ---
    vv = Provider.find_or_create_by!(name: "VV Local Provider") do |p|
      p.api_base = "http://localhost:8321"
      p.requires_api_key = false
      p.provider_type = "vv-local-provider"
    end
  RUBY

  # ============================================================
  # Success message
  # ============================================================

  say ""
  say "Rails-Claw app generated!", :green
  say "  Dashboard:     /"
  say "  Workspaces:    /workspaces"
  say "  Inference:     /inference"
  say "  Deployments:   /deployments"
  say "  Llama Stack:   /api/v1/health"
  say "  Plugin config: GET /vv/config.json"
  say ""
  say "Next steps:"
  say "  1. rails db:create db:migrate db:seed"
  say "  2. rails server -p 3010"
  say "  3. Visit http://localhost:3010"
  say ""
end
