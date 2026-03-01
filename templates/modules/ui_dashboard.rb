# modules/ui_dashboard.rb — Platform manager dashboard UI
#
# Provides: DashboardController, HostInstancesController, ContainerStatusChannel,
# dashboard views, 3 Stimulus controllers, platform manager CSS, layout, seeds.
#
# Depends on: base, schema_hosts, api_containers


@vv_applied_modules ||= []; @vv_applied_modules << "ui_dashboard"

after_bundle do
  # --- Routes ---

  route <<~RUBY
    get "attention", to: "dashboard#attention"
    get "domains", to: "dashboard#domains"
    get "local", to: "dashboard#local"
    get "public", to: "dashboard#public_tab"
    get "deploy", to: "dashboard#deploy_tab"
    get "planning", to: "dashboard#plans_tab"
    resources :host_instances, except: [:show]
  RUBY

  unless File.read("config/routes.rb").lines.any? { |l| l.strip.start_with?("root ") }
    route 'root "dashboard#index"'
  end

  # --- DashboardController ---

  file "app/controllers/dashboard_controller.rb", <<~RUBY
    class DashboardController < ApplicationController
      def index
        redirect_to action: :attention
      end

      def attention
        @attention = AttentionService.collect
        @attention_counts = AttentionService.counts
        @active_tab = "attention"
        render :dashboard
      end

      def domains
        @domains = DomainService.domains
        @active_tab = "domains"
        render :dashboard
      end

      def local
        @containers = DockerService.containers
        @active_tab = "local"
        render :dashboard
      end

      def public_tab
        @host_instances = HostInstance.all.order(:name)
        @active_tab = "public"
        render :dashboard
      end

      def deploy_tab
        @deploy_targets = defined?(DeployTarget) ? DeployTarget.active.order(:name) : []
        @active_tab = "deploy"
        render :dashboard
      end

      def plans_tab
        @plans = defined?(EnginePlanner::Plan) ? EnginePlanner::Plan.order(:status, :title) : []
        @active_tab = "plans"
        render :dashboard
      end
    end
  RUBY

  # --- DomainService ---

  file "app/services/domain_service.rb", <<~RUBY
    class DomainService
      PRIORITY_ORDER = %w[P0 P1 P2 P3 P4].freeze

      def self.domains(base_path: nil)
        base_path ||= ENV.fetch("GG_PATH", "/rails/gg")
        return [] unless Dir.exist?(base_path)

        Dir.glob(File.join(base_path, "gg-*")).select { |f| File.directory?(f) }.map { |dir|
          parse_domain(dir)
        }.compact.sort_by { |d| [PRIORITY_ORDER.index(d[:priority]) || 99, d[:domain].to_s] }
      end

      def self.parse_domain(dir)
        name = File.basename(dir)
        readme = File.join(dir, "README.md")
        priority = nil
        domain = nil
        description = nil

        if File.exist?(readme)
          lines = File.read(readme).lines
          lines.each do |line|
            if line.match?(/\\A\\*\\*GTM Priority:\\*\\*/)
              priority = line.strip.sub(/\\A\\*\\*GTM Priority:\\*\\*\\s*/, "")
            elsif line.match?(/\\A\\*\\*Domain:\\*\\*/)
              domain = line.strip.sub(/\\A\\*\\*Domain:\\*\\*\\s*/, "")
            elsif line.match?(/\\A## What this is/)
              # next non-blank line is the description
              idx = lines.index(line)
              desc_line = lines[(idx + 1)..].find { |l| l.strip.length > 0 }
              description = desc_line&.strip
            end
          end
        end

        # Fallback domain from folder name: gg-foo-bar-com → FooBarCom (best guess)
        domain ||= name.sub(/\\Agg-/, "").split("-").map(&:capitalize).join("") + ".unknown"
        priority ||= "P?"

        last_commit = git_last_commit(dir)
        github_url = git_remote_url(dir)
        legacy_engines = detect_legacy_engines(dir)

        {
          name: name,
          priority: priority,
          domain: domain,
          description: description || "No description available.",
          last_commit: last_commit,
          github_url: github_url,
          legacy_engines: legacy_engines
        }
      end

      def self.git_last_commit(dir)
        result = \`git -C \#{Shellwords.escape(dir)} log --oneline -1 2>/dev/null\`.strip
        result.empty? ? nil : result
      rescue
        nil
      end

      def self.git_remote_url(dir)
        result = \`git -C \#{Shellwords.escape(dir)} remote get-url origin 2>/dev/null\`.strip
        return nil if result.empty?
        # Convert SSH to HTTPS for display
        result.sub(/\\Agit@github.com:/, "https://github.com/").sub(/\\.git\\z/, "")
      rescue
        nil
      end

      def self.detect_legacy_engines(dir)
        engines = []
        Dir.glob(File.join(dir, "**", "engine-*")).each do |path|
          next unless File.directory?(path)
          engines << File.basename(path)
        end
        # Also check legacy/ subdirectory
        Dir.glob(File.join(dir, "legacy", "engine-*")).each do |path|
          next unless File.directory?(path)
          name = File.basename(path)
          engines << name unless engines.include?(name)
        end
        engines
      end

      private_class_method :parse_domain, :git_last_commit, :git_remote_url, :detect_legacy_engines
    end
  RUBY

  # --- HostInstancesController ---

  file "app/controllers/host_instances_controller.rb", <<~RUBY
    class HostInstancesController < ApplicationController
      def index
        @host_instances = HostInstance.all.order(:name)
      end

      def new
        @host_instance = HostInstance.new(active: true)
      end

      def create
        @host_instance = HostInstance.new(host_instance_params)
        if @host_instance.save
          redirect_to "/public", notice: "Host added."
        else
          render :new, status: :unprocessable_entity
        end
      end

      def edit
        @host_instance = HostInstance.find(params[:id])
      end

      def update
        @host_instance = HostInstance.find(params[:id])
        if @host_instance.update(host_instance_params)
          redirect_to "/public", notice: "Host updated."
        else
          render :edit, status: :unprocessable_entity
        end
      end

      def destroy
        HostInstance.find(params[:id]).destroy
        redirect_to "/public", notice: "Host removed."
      end

      private

      def host_instance_params
        params.require(:host_instance).permit(:name, :url, :cable_url, :active)
      end
    end
  RUBY

  # --- Action Cable: ContainerStatusChannel ---

  file "app/channels/container_status_channel.rb", <<~RUBY
    class ContainerStatusChannel < ApplicationCable::Channel
      def subscribed
        stream_from "container_status"
      end
    end
  RUBY

  # --- Layout ---

  remove_file "app/views/layouts/application.html.erb"
  file "app/views/layouts/application.html.erb", <<~'ERB'
    <!DOCTYPE html>
    <html>
      <head>
        <title><%= content_for(:title) || "Vv Platform Manager" %></title>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <link rel="icon" href="/icon.png" type="image/png">
        <%= stylesheet_link_tag :app, "data-turbo-track": "reload" %>
        <%= stylesheet_link_tag "platform_manager", "data-turbo-track": "reload" %>
        <% if (path = Rails.root.join("app/assets/stylesheets/deploy.css")).exist? %>
          <%= stylesheet_link_tag "deploy", "data-turbo-track": "reload" %>
        <% end %>
        <%= javascript_importmap_tags %>
      </head>

      <body>
        <header class="pm-header">
          <nav class="pm-nav">
            <a href="/" class="pm-nav__brand"><img src="/vv-logo.png" alt="Vv" style="height: 32px; vertical-align: middle; margin-right: 10px;">Platform Manager</a>
            <div class="pm-nav__tabs" data-controller="tab-badges">
              <a href="/attention" class="pm-nav__tab <%= 'pm-nav__tab--active' if @active_tab == 'attention' %>" data-tab-badges-target="tab" data-tab-path="/attention">
                Attention<span class="pm-nav__badge" data-tab-badges-target="attentionBadge"></span>
              </a>
              <a href="/domains" class="pm-nav__tab <%= 'pm-nav__tab--active' if @active_tab == 'domains' %>">Domains</a>
              <a href="/local" class="pm-nav__tab <%= 'pm-nav__tab--active' if @active_tab == 'local' %>" data-tab-badges-target="tab" data-tab-path="/local">
                Local<span class="pm-nav__badge" data-tab-badges-target="localBadge"></span>
              </a>
              <a href="/public" class="pm-nav__tab <%= 'pm-nav__tab--active' if @active_tab == 'public' %>" data-tab-badges-target="tab" data-tab-path="/public">
                Public<span class="pm-nav__badge" data-tab-badges-target="publicBadge"></span>
              </a>
              <a href="/deploy" class="pm-nav__tab <%= 'pm-nav__tab--active' if @active_tab == 'deploy' %>" data-tab-badges-target="tab" data-tab-path="/deploy">
                Deploy<span class="pm-nav__badge" data-tab-badges-target="deployBadge"></span>
              </a>
              <a href="/planning" class="pm-nav__tab <%= 'pm-nav__tab--active' if @active_tab == 'plans' %>" data-tab-badges-target="tab" data-tab-path="/planning">
                Plans<span class="pm-nav__badge" data-tab-badges-target="plansBadge"></span>
              </a>
            </div>
            <div class="pm-nav__version">v0.10.0</div>
          </nav>
        </header>

        <% if notice %>
          <div class="pm-flash"><%= notice %></div>
        <% end %>

        <main class="pm-main">
          <%= yield %>
        </main>
      </body>
    </html>
  ERB

  # --- Dashboard view ---

  file "app/views/dashboard/dashboard.html.erb", <<~'ERB'
    <div class="dashboard" data-controller="dashboard" data-dashboard-active-tab-value="<%= @active_tab %>">
      <% if @active_tab == "attention" %>
        <%= render "dashboard/attention_panel" %>
      <% elsif @active_tab == "domains" %>
        <%= render "dashboard/domains_panel" %>
      <% elsif @active_tab == "local" %>
        <%= render "dashboard/local_panel" %>
      <% elsif @active_tab == "deploy" %>
        <%= render "dashboard/deploy_panel" if defined?(DeployTarget) %>
      <% elsif @active_tab == "plans" %>
        <%= render "dashboard/plans_panel" %>
      <% else %>
        <%= render "dashboard/public_panel" %>
      <% end %>
    </div>
  ERB

  # --- Local panel partial ---

  file "app/views/dashboard/_local_panel.html.erb", <<~'ERB'
    <div data-controller="local-containers">
      <div class="panel-header">
        <h2>Docker Containers</h2>
        <button class="btn btn--secondary" data-action="click->local-containers#refresh">Refresh</button>
      </div>

      <div class="container-grid" data-local-containers-target="grid">
        <% if @containers.empty? %>
          <div class="empty-state">
            <p>No Docker containers found.</p>
            <p class="empty-state__hint">Run <code>docker compose up -d</code> to start the local environment.</p>
          </div>
        <% else %>
          <% @containers.each do |c| %>
            <div class="container-card container-card--<%= c[:state]&.downcase %>">
              <div class="container-card__header">
                <span class="container-card__name"><%= c[:service] || c[:name] %></span>
                <span class="container-card__state-badge"><%= c[:state] %></span>
              </div>
              <div class="container-card__details">
                <div class="container-card__detail">
                  <span class="container-card__label">Status</span>
                  <span class="container-card__value"><%= c[:status] %></span>
                </div>
                <div class="container-card__detail">
                  <span class="container-card__label">Ports</span>
                  <span class="container-card__value"><%= c[:ports].presence || "None" %></span>
                </div>
                <div class="container-card__detail">
                  <span class="container-card__label">Health</span>
                  <span class="container-card__value"><%= c[:health] %></span>
                </div>
              </div>
              <div class="container-card__actions">
                <button class="btn btn--sm btn--primary" data-action="click->local-containers#restart" data-local-containers-container-id-param="<%= c[:id] %>">Restart</button>
                <% if c[:state]&.downcase == "running" %>
                  <button class="btn btn--sm btn--danger" data-action="click->local-containers#stop" data-local-containers-container-id-param="<%= c[:id] %>">Stop</button>
                <% else %>
                  <button class="btn btn--sm btn--success" data-action="click->local-containers#start" data-local-containers-container-id-param="<%= c[:id] %>">Start</button>
                <% end %>
              </div>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
  ERB

  # --- Public panel partial ---

  file "app/views/dashboard/_public_panel.html.erb", <<~'ERB'
    <div data-controller="host-monitor">
      <div class="panel-header">
        <h2>Remote Hosts</h2>
        <%= link_to "Add Host", new_host_instance_path, class: "btn btn--primary" %>
      </div>

      <% if @host_instances.empty? %>
        <div class="empty-state">
          <p>No remote hosts configured.</p>
          <p class="empty-state__hint">Add a vv-host instance to monitor platform activity in real time.</p>
        </div>
      <% else %>
        <div class="host-grid">
          <% @host_instances.each do |host| %>
            <div class="host-card"
                 data-host-monitor-target="host"
                 data-host-cable-url="<%= host.cable_url %>"
                 data-host-id="<%= host.id %>"
                 data-host-name="<%= host.name %>">
              <div class="host-card__header">
                <span class="host-card__name"><%= host.name %></span>
                <span class="host-card__status" data-host-monitor-target="status">
                  <span class="status-dot"></span>
                  <span class="status-text">Connecting...</span>
                </span>
              </div>
              <div class="host-card__url"><%= host.url %></div>
              <div class="host-card__metrics" data-host-monitor-target="metrics">
                <div class="metric">
                  <span class="metric__label">Sessions</span>
                  <span class="metric__value" data-host-monitor-target="sessionCount">--</span>
                </div>
                <div class="metric">
                  <span class="metric__label">Clients</span>
                  <span class="metric__value" data-host-monitor-target="clientCount">--</span>
                </div>
                <div class="metric">
                  <span class="metric__label">Last Activity</span>
                  <span class="metric__value" data-host-monitor-target="lastActivity">--</span>
                </div>
              </div>
              <div class="host-card__actions">
                <%= link_to "Edit", edit_host_instance_path(host), class: "btn btn--sm btn--secondary" %>
                <%= button_to "Remove", host_instance_path(host), method: :delete, class: "btn btn--sm btn--danger", data: { turbo_confirm: "Remove #{host.name}?" } %>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
  ERB

  # --- Domains panel partial ---

  file "app/views/dashboard/_domains_panel.html.erb", <<~'ERB'
    <div class="panel-header">
      <h2>GTM Domains</h2>
    </div>

    <% if @domains.empty? %>
      <div class="empty-state">
        <p>No gg-* domain folders found.</p>
        <p class="empty-state__hint">Set <code>GG_PATH</code> to the directory containing your gg-* repos.</p>
      </div>
    <% else %>
      <div class="domain-grid">
        <% @domains.each do |d| %>
          <div class="domain-card domain-card--<%= d[:priority].downcase %>">
            <div class="domain-card__header">
              <span class="domain-card__name"><%= d[:domain] %></span>
              <span class="domain-card__priority domain-card__priority--<%= d[:priority].downcase %>"><%= d[:priority] %></span>
            </div>
            <div class="domain-card__description"><%= d[:description] %></div>
            <% if d[:github_url] %>
              <a href="<%= d[:github_url] %>" class="domain-card__repo" target="_blank"><%= d[:name] %></a>
            <% else %>
              <span class="domain-card__repo"><%= d[:name] %></span>
            <% end %>
            <% if d[:last_commit] %>
              <div class="domain-card__commit"><%= d[:last_commit] %></div>
            <% end %>
            <% if d[:legacy_engines].any? %>
              <div class="domain-card__legacy">Legacy: <%= d[:legacy_engines].join(", ") %></div>
            <% end %>
          </div>
        <% end %>
      </div>
    <% end %>
  ERB

  # --- Host instance form ---

  file "app/views/host_instances/_form.html.erb", <<~'ERB'
    <%= form_with model: @host_instance, class: "pm-form" do |f| %>
      <% if @host_instance.errors.any? %>
        <div class="pm-form__errors">
          <% @host_instance.errors.full_messages.each do |msg| %>
            <p><%= msg %></p>
          <% end %>
        </div>
      <% end %>

      <div class="pm-form__field">
        <%= f.label :name, class: "pm-form__label" %>
        <%= f.text_field :name, class: "pm-form__input", placeholder: "My Host" %>
      </div>

      <div class="pm-form__field">
        <%= f.label :url, "Host URL", class: "pm-form__label" %>
        <%= f.url_field :url, class: "pm-form__input", placeholder: "https://myhost.example.com" %>
      </div>

      <div class="pm-form__field">
        <%= f.label :cable_url, "Cable URL", class: "pm-form__label" %>
        <%= f.url_field :cable_url, class: "pm-form__input", placeholder: "wss://myhost.example.com/cable" %>
      </div>

      <div class="pm-form__field">
        <%= f.label :active, class: "pm-form__label" %>
        <%= f.check_box :active, class: "pm-form__checkbox" %>
      </div>

      <div class="pm-form__actions">
        <%= f.submit class: "btn btn--primary" %>
        <%= link_to "Cancel", "/public", class: "btn btn--secondary" %>
      </div>
    <% end %>
  ERB

  file "app/views/host_instances/new.html.erb", <<~'ERB'
    <div class="pm-page">
      <h2>Add Remote Host</h2>
      <%= render "form" %>
    </div>
  ERB

  file "app/views/host_instances/edit.html.erb", <<~'ERB'
    <div class="pm-page">
      <h2>Edit Remote Host</h2>
      <%= render "form" %>
    </div>
  ERB

  # --- Attention panel partial ---

  file "app/views/dashboard/_attention_panel.html.erb", <<~'ERB'
    <div data-controller="attention">
      <div class="panel-header">
        <h2>Attention</h2>
        <div class="attention-summary">
          <% if @attention_counts[:critical] > 0 %>
            <span class="attention-count attention-count--critical"><%= @attention_counts[:critical] %> critical</span>
          <% end %>
          <% if @attention_counts[:warning] > 0 %>
            <span class="attention-count attention-count--warning"><%= @attention_counts[:warning] %> warning</span>
          <% end %>
          <% if @attention_counts[:info] > 0 %>
            <span class="attention-count attention-count--info"><%= @attention_counts[:info] %> info</span>
          <% end %>
        </div>
      </div>

      <div class="attention-grid" data-attention-target="grid">
        <% if @attention.empty? %>
          <div class="empty-state">
            <p>No items need attention.</p>
            <p class="empty-state__hint">All systems healthy.</p>
          </div>
        <% else %>
          <% @attention.each do |item| %>
            <div class="attention-card attention-card--<%= item.severity %>">
              <div class="attention-card__header">
                <span class="attention-card__source"><%= item.source %></span>
                <span class="attention-card__severity attention-card__severity--<%= item.severity %>"><%= item.severity %></span>
              </div>
              <div class="attention-card__title"><%= item.title %></div>
              <div class="attention-card__message"><%= item.message %></div>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
  ERB

  # --- P3: Plans panel partial ---

  file "app/views/dashboard/_plans_panel.html.erb", <<~'ERB'
    <div class="panel-header">
      <h2>Plans</h2>
      <% if defined?(EnginePlanner) %>
        <a href="/plans" class="btn btn--secondary" target="_blank">Open Planner</a>
      <% end %>
    </div>

    <% if @plans.respond_to?(:any?) && @plans.any? %>
      <div class="plans-kanban">
        <% %w[input plan in_progress for_review done].each do |status| %>
          <% plans_in_status = @plans.select { |p| p.status == status } %>
          <div class="plans-column">
            <div class="plans-column__header">
              <span class="plans-column__title"><%= status.humanize %></span>
              <span class="plans-column__count"><%= plans_in_status.count %></span>
            </div>
            <% plans_in_status.each do |plan| %>
              <div class="plans-card">
                <div class="plans-card__title"><%= plan.title %></div>
                <% if plan.respond_to?(:description) && plan.description.present? %>
                  <div class="plans-card__desc"><%= plan.description.truncate(100) %></div>
                <% end %>
                <div class="plans-card__meta">
                  <span><%= plan.perspectives.count rescue 0 %> perspectives</span>
                  <span><%= plan.assertions.count rescue 0 %> assertions</span>
                </div>
              </div>
            <% end %>
            <% if plans_in_status.empty? %>
              <div class="plans-card plans-card--empty">No plans</div>
            <% end %>
          </div>
        <% end %>
      </div>
    <% else %>
      <div class="empty-state">
        <% if defined?(EnginePlanner) %>
          <p>No plans yet.</p>
          <p class="empty-state__hint">Run <code>rails db:seed</code> to load initial plans, or create one in the <a href="/plans">Planner</a>.</p>
        <% else %>
          <p>Planning module not available.</p>
          <p class="empty-state__hint">Add the <code>planning</code> module to your profile to enable.</p>
        <% end %>
      </div>
    <% end %>
  ERB

  # --- Stimulus: dashboard controller ---

  file "app/javascript/controllers/dashboard_controller.js", <<~JS
    import { Controller } from "@hotwired/stimulus"

    export default class extends Controller {
      static values = { activeTab: String }

      connect() {
        this.highlightTab()
      }

      highlightTab() {
        const tabs = document.querySelectorAll(".pm-nav__tab")
        tabs.forEach(tab => {
          tab.classList.remove("pm-nav__tab--active")
          if (tab.getAttribute("href") === `/${this.activeTabValue}`) {
            tab.classList.add("pm-nav__tab--active")
          }
        })
      }
    }
  JS

  # --- Stimulus: local-containers controller ---

  file "app/javascript/controllers/local_containers_controller.js", <<~JS
    import { Controller } from "@hotwired/stimulus"

    export default class extends Controller {
      static targets = ["grid"]

      connect() {
        this.poll = setInterval(() => this.fetchContainers(), 5000)
      }

      disconnect() {
        if (this.poll) clearInterval(this.poll)
      }

      async fetchContainers() {
        try {
          const response = await fetch("/api/local/containers")
          if (!response.ok) return
          const containers = await response.json()
          this.updateGrid(containers)
        } catch (e) {
          // silently retry on next interval
        }
      }

      updateGrid(containers) {
        if (!this.hasGridTarget) return

        if (containers.length === 0) {
          this.gridTarget.innerHTML = `
            <div class="empty-state">
              <p>No Docker containers found.</p>
              <p class="empty-state__hint">Run <code>docker compose up -d</code> to start the local environment.</p>
            </div>`
          return
        }

        this.gridTarget.innerHTML = containers.map(c => `
          <div class="container-card container-card--${(c.state || "").toLowerCase()}">
            <div class="container-card__header">
              <span class="container-card__name">${c.service || c.name}</span>
              <span class="container-card__state-badge">${c.state}</span>
            </div>
            <div class="container-card__details">
              <div class="container-card__detail">
                <span class="container-card__label">Status</span>
                <span class="container-card__value">${c.status}</span>
              </div>
              <div class="container-card__detail">
                <span class="container-card__label">Ports</span>
                <span class="container-card__value">${c.ports || "None"}</span>
              </div>
              <div class="container-card__detail">
                <span class="container-card__label">Health</span>
                <span class="container-card__value">${c.health || "N/A"}</span>
              </div>
            </div>
            <div class="container-card__actions">
              <button class="btn btn--sm btn--primary" data-action="click->local-containers#restart" data-local-containers-container-id-param="${c.id}">Restart</button>
              ${c.state?.toLowerCase() === "running"
                ? `<button class="btn btn--sm btn--danger" data-action="click->local-containers#stop" data-local-containers-container-id-param="${c.id}">Stop</button>`
                : `<button class="btn btn--sm btn--success" data-action="click->local-containers#start" data-local-containers-container-id-param="${c.id}">Start</button>`
              }
            </div>
          </div>
        `).join("")
      }

      async restart(event) {
        const id = event.params.containerId
        await this.containerAction(id, "restart")
      }

      async stop(event) {
        const id = event.params.containerId
        await this.containerAction(id, "stop")
      }

      async start(event) {
        const id = event.params.containerId
        await this.containerAction(id, "start")
      }

      async containerAction(id, action) {
        try {
          await fetch(`/api/local/containers/${id}/${action}`, { method: "POST", headers: { "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content } })
          setTimeout(() => this.fetchContainers(), 1000)
        } catch (e) {
          console.error(`Failed to ${action} container ${id}:`, e)
        }
      }

      refresh() {
        this.fetchContainers()
      }
    }
  JS

  # --- Stimulus: host-monitor controller ---

  file "app/javascript/controllers/host_monitor_controller.js", <<~JS
    import { Controller } from "@hotwired/stimulus"

    export default class extends Controller {
      static targets = ["host", "status", "metrics", "sessionCount", "clientCount", "lastActivity"]

      connect() {
        this.consumers = []
        this.hostTargets.forEach((hostEl, index) => {
          this.connectToHost(hostEl, index)
        })
      }

      disconnect() {
        this.consumers.forEach(consumer => {
          try { consumer.disconnect() } catch (e) { /* ignore */ }
        })
        this.consumers = []
      }

      connectToHost(hostEl, index) {
        const cableUrl = hostEl.dataset.hostCableUrl
        const hostName = hostEl.dataset.hostName
        if (!cableUrl) return

        const statusEl = this.statusTargets[index]

        try {
          const ws = new WebSocket(cableUrl)

          ws.onopen = () => {
            this.updateStatus(statusEl, "connected")
            ws.send(JSON.stringify({
              command: "subscribe",
              identifier: JSON.stringify({ channel: "VvChannel", page_id: "platform_monitor" })
            }))
          }

          ws.onmessage = (event) => {
            try {
              const msg = JSON.parse(event.data)
              if (msg.type === "ping" || msg.type === "welcome" || msg.type === "confirm_subscription") return
              if (msg.message) {
                this.updateMetrics(index, msg.message)
              }
            } catch (e) { /* ignore parse errors */ }
          }

          ws.onclose = () => {
            this.updateStatus(statusEl, "disconnected")
            setTimeout(() => this.connectToHost(hostEl, index), 5000)
          }

          ws.onerror = () => {
            this.updateStatus(statusEl, "error")
          }

          this.consumers.push(ws)
        } catch (e) {
          this.updateStatus(statusEl, "error")
        }
      }

      updateStatus(statusEl, state) {
        if (!statusEl) return
        const dot = statusEl.querySelector(".status-dot")
        const text = statusEl.querySelector(".status-text")

        if (dot) {
          dot.className = "status-dot"
          dot.classList.add(`status-dot--${state}`)
        }
        if (text) {
          const labels = { connected: "Connected", disconnected: "Disconnected", error: "Error", connecting: "Connecting..." }
          text.textContent = labels[state] || state
        }
      }

      updateMetrics(index, data) {
        if (this.sessionCountTargets[index]) {
          this.sessionCountTargets[index].textContent = data.sessions ?? "--"
        }
        if (this.clientCountTargets[index]) {
          this.clientCountTargets[index].textContent = data.clients ?? "--"
        }
        if (this.lastActivityTargets[index]) {
          this.lastActivityTargets[index].textContent = data.last_activity ?? new Date().toLocaleTimeString()
        }
      }
    }
  JS

  # --- Stimulus: attention controller ---

  file "app/javascript/controllers/attention_controller.js", <<~JS
    import { Controller } from "@hotwired/stimulus"

    export default class extends Controller {
      static targets = ["grid"]

      connect() {
        this.poll = setInterval(() => this.fetchAttention(), 5000)
      }

      disconnect() {
        if (this.poll) clearInterval(this.poll)
      }

      async fetchAttention() {
        try {
          const response = await fetch("/api/attention")
          if (!response.ok) return
          const data = await response.json()
          this.updateGrid(data.items)
        } catch (e) {
          // retry on next interval
        }
      }

      updateGrid(items) {
        if (!this.hasGridTarget) return

        if (items.length === 0) {
          this.gridTarget.innerHTML = `
            <div class="empty-state">
              <p>No items need attention.</p>
              <p class="empty-state__hint">All systems healthy.</p>
            </div>`
          return
        }

        this.gridTarget.innerHTML = items.map(item => `
          <div class="attention-card attention-card--${item.severity}">
            <div class="attention-card__header">
              <span class="attention-card__source">${item.source}</span>
              <span class="attention-card__severity attention-card__severity--${item.severity}">${item.severity}</span>
            </div>
            <div class="attention-card__title">${item.title}</div>
            <div class="attention-card__message">${item.message}</div>
          </div>
        `).join("")
      }
    }
  JS

  # --- Stimulus: tab-badges controller ---

  file "app/javascript/controllers/tab_badges_controller.js", <<~JS
    import { Controller } from "@hotwired/stimulus"

    export default class extends Controller {
      static targets = ["attentionBadge", "localBadge", "publicBadge", "deployBadge"]

      connect() {
        this.fetchBadges()
        this.poll = setInterval(() => this.fetchBadges(), 5000)
      }

      disconnect() {
        if (this.poll) clearInterval(this.poll)
      }

      async fetchBadges() {
        try {
          const response = await fetch("/api/attention")
          if (!response.ok) return
          const data = await response.json()
          this.updateBadges(data)
        } catch (e) {
          // retry on next interval
        }
      }

      updateBadges(data) {
        const counts = data.counts
        const actionable = counts.critical + counts.warning

        this.setBadge(this.attentionBadgeTarget, actionable, counts.critical > 0 ? "critical" : "warning")

        // Per-source badges
        const items = data.items || []
        const containerCount = items.filter(i => i.source === "containers" && i.severity !== "info").length
        const hostCount = items.filter(i => i.source === "hosts" && i.severity !== "info").length
        const deployCount = items.filter(i => i.source === "deploy" && i.severity !== "info").length

        if (this.hasLocalBadgeTarget) this.setBadge(this.localBadgeTarget, containerCount, "warning")
        if (this.hasPublicBadgeTarget) this.setBadge(this.publicBadgeTarget, hostCount, "warning")
        if (this.hasDeployBadgeTarget) this.setBadge(this.deployBadgeTarget, deployCount, "warning")
      }

      setBadge(el, count, severity) {
        if (!el) return
        if (count === 0) {
          el.textContent = ""
          el.className = "pm-nav__badge"
        } else {
          el.textContent = count
          el.className = `pm-nav__badge pm-nav__badge--${severity}`
        }
      }
    }
  JS

  # --- CSS ---

  file "app/assets/stylesheets/platform_manager.css", <<~CSS
    /* Reset & Base — inherits from DS foundation when ui_design_system is loaded */
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    html { font-size: 16px; }
    body { font-family: var(--vv-font-sans, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif); background: var(--vv-background, #f0f2f5); color: var(--pm-text, #333); min-height: 100vh; }

    /* Header */
    .pm-header { background: var(--pm-header-bg, #1a1a2e); color: var(--pm-header-text, white); padding: 0 24px; box-shadow: 0 2px 8px rgba(0,0,0,0.15); position: sticky; top: 0; z-index: 100; }
    .pm-nav { display: flex; align-items: center; height: 56px; max-width: 1200px; margin: 0 auto; }
    .pm-nav__brand { color: white; text-decoration: none; font-size: 18px; font-weight: 700; margin-right: 32px; white-space: nowrap; }
    .pm-nav__tabs { display: flex; gap: 4px; flex: 1; }
    .pm-nav__tab { color: rgba(255,255,255,0.6); text-decoration: none; padding: 8px 16px; border-radius: 6px; font-size: 14px; font-weight: 500; transition: all 0.2s ease; }
    .pm-nav__tab:hover { color: white; background: rgba(255,255,255,0.1); }
    .pm-nav__tab--active { color: white; background: rgba(255,255,255,0.15); }
    .pm-nav__version { font-size: 12px; color: rgba(255,255,255,0.4); font-family: monospace; }

    /* Flash */
    .pm-flash { max-width: 1200px; margin: 16px auto 0; padding: 12px 16px; background: #d4edda; color: #155724; border-radius: 6px; font-size: 14px; }

    /* Main */
    .pm-main { max-width: 1200px; margin: 0 auto; padding: 24px; }

    /* Panel Header */
    .panel-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; }
    .panel-header h2 { font-size: 22px; color: #1a1a2e; }

    /* Empty State */
    .empty-state { text-align: center; padding: 60px 20px; background: var(--pm-surface, white); border-radius: var(--pm-radius, 8px); box-shadow: var(--pm-surface-shadow, 0 1px 3px rgba(0,0,0,0.08)); }
    .empty-state p { color: #666; font-size: 16px; margin-bottom: 8px; }
    .empty-state__hint { font-size: 14px; color: #999; }
    .empty-state code { background: #f0f2f5; padding: 2px 6px; border-radius: 3px; font-size: 13px; }

    /* Container Grid */
    .container-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 16px; }

    /* Container Card */
    .container-card { background: var(--pm-surface, white); border-radius: var(--pm-radius, 8px); padding: var(--pm-gap, 16px); box-shadow: var(--pm-surface-shadow, 0 1px 3px rgba(0,0,0,0.08)); border-left: 4px solid var(--pm-border, #ddd); transition: box-shadow 0.2s ease; }
    .container-card:hover { box-shadow: 0 4px 12px rgba(0,0,0,0.12); }
    .container-card--running { border-left-color: #28a745; }
    .container-card--exited { border-left-color: #dc3545; }
    .container-card--created { border-left-color: #ffc107; }
    .container-card__header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; }
    .container-card__name { font-weight: 600; font-size: 16px; color: #1a1a2e; }
    .container-card__state-badge { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; padding: 3px 8px; border-radius: 12px; background: #e9ecef; color: #666; }
    .container-card--running .container-card__state-badge { background: #d4edda; color: #155724; }
    .container-card--exited .container-card__state-badge { background: #f8d7da; color: #721c24; }
    .container-card__details { margin-bottom: 12px; }
    .container-card__detail { display: flex; justify-content: space-between; padding: 4px 0; font-size: 13px; }
    .container-card__label { color: #888; }
    .container-card__value { color: #333; font-family: monospace; font-size: 12px; }
    .container-card__actions { display: flex; gap: 8px; padding-top: 12px; border-top: 1px solid #f0f2f5; }

    /* Host Grid */
    .host-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(350px, 1fr)); gap: 16px; }

    /* Host Card */
    .host-card { background: white; border-radius: 8px; padding: 16px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); }
    .host-card:hover { box-shadow: 0 4px 12px rgba(0,0,0,0.12); }
    .host-card__header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; }
    .host-card__name { font-weight: 600; font-size: 16px; color: #1a1a2e; }
    .host-card__status { display: flex; align-items: center; gap: 6px; font-size: 13px; }
    .host-card__url { font-family: monospace; font-size: 13px; color: #888; margin-bottom: 12px; }
    .host-card__metrics { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; margin-bottom: 12px; padding: 12px; background: #f8f9fa; border-radius: 6px; }
    .host-card__actions { display: flex; gap: 8px; padding-top: 12px; border-top: 1px solid #f0f2f5; }

    /* Domain Grid */
    .domain-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(350px, 1fr)); gap: 16px; }

    /* Domain Card */
    .domain-card { background: white; border-radius: 8px; padding: 16px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); border-left: 4px solid #ddd; transition: box-shadow 0.2s ease; }
    .domain-card:hover { box-shadow: 0 4px 12px rgba(0,0,0,0.12); }
    .domain-card--p0 { border-left-color: #dc3545; }
    .domain-card--p1 { border-left-color: #fd7e14; }
    .domain-card--p2 { border-left-color: #ffc107; }
    .domain-card--p3 { border-left-color: #007bff; }
    .domain-card--p4 { border-left-color: #6c757d; }
    .domain-card__header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; }
    .domain-card__name { font-weight: 600; font-size: 16px; color: #1a1a2e; }
    .domain-card__priority { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; padding: 3px 8px; border-radius: 12px; background: #e9ecef; color: #666; }
    .domain-card__priority--p0 { background: #f8d7da; color: #721c24; }
    .domain-card__priority--p1 { background: #ffe5d0; color: #984c0c; }
    .domain-card__priority--p2 { background: #fff3cd; color: #856404; }
    .domain-card__priority--p3 { background: #cce5ff; color: #004085; }
    .domain-card__priority--p4 { background: #e9ecef; color: #495057; }
    .domain-card__description { font-size: 14px; color: #555; margin-bottom: 10px; line-height: 1.4; }
    .domain-card__repo { display: block; font-family: monospace; font-size: 13px; color: #888; margin-bottom: 8px; text-decoration: none; }
    a.domain-card__repo:hover { color: #007bff; }
    .domain-card__commit { font-size: 12px; color: #999; font-family: monospace; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; margin-bottom: 4px; }
    .domain-card__legacy { font-size: 12px; color: #fd7e14; font-style: italic; }

    /* Metrics */
    .metric { text-align: center; }
    .metric__label { display: block; font-size: 11px; color: #888; text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 4px; }
    .metric__value { display: block; font-size: 18px; font-weight: 600; color: #1a1a2e; }

    /* Status Dot */
    .status-dot { width: 8px; height: 8px; border-radius: 50%; background: #ffc107; display: inline-block; }
    .status-dot--connected { background: #28a745; }
    .status-dot--disconnected { background: #dc3545; }
    .status-dot--error { background: #dc3545; animation: pulse 1.5s infinite; }
    @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.4; } }

    /* Attention Grid */
    .attention-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(350px, 1fr)); gap: 16px; }
    .attention-summary { display: flex; gap: 8px; }
    .attention-count { font-size: 13px; font-weight: 500; padding: 4px 10px; border-radius: 12px; }
    .attention-count--critical { background: #f8d7da; color: #721c24; }
    .attention-count--warning { background: #fff3cd; color: #856404; }
    .attention-count--info { background: #cce5ff; color: #004085; }

    /* Attention Card */
    .attention-card { background: white; border-radius: 8px; padding: 16px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); border-left: 4px solid #ddd; transition: box-shadow 0.2s ease; }
    .attention-card:hover { box-shadow: 0 4px 12px rgba(0,0,0,0.12); }
    .attention-card--critical { border-left-color: #dc3545; }
    .attention-card--warning { border-left-color: #ffc107; }
    .attention-card--info { border-left-color: #007bff; }
    .attention-card__header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; }
    .attention-card__source { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; color: #888; }
    .attention-card__severity { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; padding: 2px 8px; border-radius: 12px; }
    .attention-card__severity--critical { background: #f8d7da; color: #721c24; }
    .attention-card__severity--warning { background: #fff3cd; color: #856404; }
    .attention-card__severity--info { background: #cce5ff; color: #004085; }
    .attention-card__title { font-weight: 600; font-size: 15px; color: #1a1a2e; margin-bottom: 4px; }
    .attention-card__message { font-size: 13px; color: #666; line-height: 1.4; }

    /* Tab Badges */
    .pm-nav__badge { display: inline-flex; align-items: center; justify-content: center; min-width: 20px; height: 20px; font-size: 12px; font-weight: 600; border-radius: 10px; margin-left: 6px; padding: 0 5px; }
    .pm-nav__badge:empty { display: none; }
    .pm-nav__badge--critical { background: #dc3545; color: white; }
    .pm-nav__badge--warning { background: #ffc107; color: #333; }

    /* Plans Kanban */
    .plans-kanban { display: flex; gap: 16px; overflow-x: auto; padding-bottom: 8px; }
    .plans-column { flex: 1; min-width: 200px; background: #f8f9fa; border-radius: 8px; padding: 12px; }
    .plans-column__header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; padding-bottom: 8px; border-bottom: 2px solid #dee2e6; }
    .plans-column__title { font-size: 13px; font-weight: 600; text-transform: uppercase; color: #6c757d; letter-spacing: 0.5px; }
    .plans-column__count { background: #dee2e6; color: #495057; border-radius: 10px; padding: 2px 8px; font-size: 12px; font-weight: 600; }
    .plans-card { background: white; border: 1px solid #dee2e6; border-radius: 6px; padding: 12px; margin-bottom: 8px; }
    .plans-card__title { font-weight: 600; font-size: 14px; margin-bottom: 4px; }
    .plans-card__desc { font-size: 13px; color: #6c757d; margin-bottom: 8px; }
    .plans-card__meta { display: flex; gap: 12px; font-size: 12px; color: #adb5bd; }
    .plans-card--empty { color: #adb5bd; font-size: 13px; text-align: center; border-style: dashed; }

    /* Buttons */
    .btn { display: inline-block; padding: 8px 16px; border: 1px solid #ddd; border-radius: 6px; font-size: 14px; font-weight: 500; cursor: pointer; text-decoration: none; text-align: center; transition: all 0.2s ease; background: white; color: #333; }
    .btn--primary { background: #007bff; color: white; border-color: #007bff; }
    .btn--primary:hover { background: #0056b3; }
    .btn--secondary { background: #f8f9fa; color: #333; }
    .btn--secondary:hover { background: #e9ecef; }
    .btn--success { background: #28a745; color: white; border-color: #28a745; }
    .btn--success:hover { background: #218838; }
    .btn--danger { background: #dc3545; color: white; border-color: #dc3545; }
    .btn--danger:hover { background: #c82333; }
    .btn--sm { padding: 4px 10px; font-size: 12px; }

    /* Form */
    .pm-page { max-width: 600px; }
    .pm-page h2 { margin-bottom: 20px; }
    .pm-form { display: flex; flex-direction: column; gap: 16px; }
    .pm-form__errors { background: #f8d7da; color: #721c24; padding: 12px; border-radius: 6px; }
    .pm-form__errors p { margin-bottom: 4px; font-size: 14px; }
    .pm-form__field { display: flex; flex-direction: column; gap: 4px; }
    .pm-form__label { font-size: 14px; font-weight: 500; color: #555; }
    .pm-form__input { padding: 10px 12px; border: 1px solid #ddd; border-radius: 6px; font-size: 15px; }
    .pm-form__input:focus { outline: none; border-color: #007bff; box-shadow: 0 0 0 3px rgba(0,123,255,0.15); }
    .pm-form__checkbox { width: 18px; height: 18px; }
    .pm-form__actions { display: flex; gap: 12px; padding-top: 8px; }
  CSS

  # --- Seeds ---

  append_to_file "db/seeds.rb", <<~RUBY

    # Default local host instance for development
    HostInstance.find_or_create_by!(name: "Local Host") do |h|
      h.url = "http://localhost:3001"
      h.cable_url = "ws://localhost:3001/cable"
      h.active = true
    end

    # Public host: VerticalVertical.net
    HostInstance.find_or_create_by!(name: "VerticalVertical.net") do |h|
      h.url = "https://verticalvertical.net"
      h.cable_url = "wss://verticalvertical.net/cable"
      h.active = true
    end
  RUBY

  # --- E1: AttentionItem value object ---

  file "app/models/attention_item.rb", <<~RUBY
    class AttentionItem
      SEVERITIES = %w[critical warning info].freeze

      attr_reader :source, :severity, :title, :message, :context

      def initialize(source:, severity:, title:, message:, context: {})
        raise ArgumentError, "invalid severity: \#{severity}" unless SEVERITIES.include?(severity.to_s)
        @source   = source.to_s
        @severity = severity.to_s
        @title    = title.to_s
        @message  = message.to_s
        @context  = context || {}
        freeze
      end

      def as_json(*)
        { source: source, severity: severity, title: title, message: message, context: context }
      end
    end
  RUBY

  # --- E1: AttentionService registry ---

  file "app/services/attention_service.rb", <<~RUBY
    class AttentionService
      class << self
        def sources
          @sources ||= {}
        end

        def register(name, source)
          sources[name.to_sym] = source
        end

        def collect(severity: nil, source: nil)
          items = sources.flat_map do |name, src|
            src.check
          rescue StandardError => e
            Rails.logger.warn("[AttentionService] \#{name} failed: \#{e.message}")
            []
          end

          items = items.select { |i| i.severity == severity.to_s } if severity.present?
          items = items.select { |i| i.source == source.to_s } if source.present?
          items.sort_by { |i| AttentionItem::SEVERITIES.index(i.severity) || 99 }
        end

        def counts
          items = collect
          {
            critical: items.count { |i| i.severity == "critical" },
            warning: items.count { |i| i.severity == "warning" },
            info: items.count { |i| i.severity == "info" },
            total: items.length
          }
        end
      end
    end
  RUBY

  # --- E2: ContainerAlertSource ---

  file "app/services/container_alert_source.rb", <<~RUBY
    class ContainerAlertSource
      def check
        return [] unless defined?(DockerService)

        DockerService.containers.filter_map do |c|
          state = c[:state]&.downcase
          case state
          when "exited"
            AttentionItem.new(
              source: "containers",
              severity: "critical",
              title: "\#{c[:service] || c[:name]} exited",
              message: "Container is not running. Status: \#{c[:status]}",
              context: { container_id: c[:id], service: c[:service] }
            )
          when "restarting"
            AttentionItem.new(
              source: "containers",
              severity: "critical",
              title: "\#{c[:service] || c[:name]} restarting",
              message: "Container is in a restart loop. Status: \#{c[:status]}",
              context: { container_id: c[:id], service: c[:service] }
            )
          end
        end
      end
    end
  RUBY

  # --- E3: HostAlertSource ---

  file "app/services/host_alert_source.rb", <<~RUBY
    class HostAlertSource
      def check
        return [] unless defined?(HostInstance)

        HostInstance.active.map do |host|
          if host.last_seen_at.nil?
            AttentionItem.new(
              source: "hosts",
              severity: "info",
              title: "\#{host.name} never connected",
              message: "Host has not reported in yet.",
              context: { host_id: host.id, url: host.url }
            )
          elsif host.last_seen_at < 30.minutes.ago
            AttentionItem.new(
              source: "hosts",
              severity: "critical",
              title: "\#{host.name} disconnected",
              message: "Last seen \#{ApplicationController.helpers.time_ago_in_words(host.last_seen_at)} ago.",
              context: { host_id: host.id, url: host.url, last_seen_at: host.last_seen_at.iso8601 }
            )
          elsif host.last_seen_at < 5.minutes.ago
            AttentionItem.new(
              source: "hosts",
              severity: "warning",
              title: "\#{host.name} stale",
              message: "Last seen \#{ApplicationController.helpers.time_ago_in_words(host.last_seen_at)} ago.",
              context: { host_id: host.id, url: host.url, last_seen_at: host.last_seen_at.iso8601 }
            )
          end
        end.compact
      end
    end
  RUBY

  # --- E3: DeployAlertSource ---

  file "app/services/deploy_alert_source.rb", <<~RUBY
    class DeployAlertSource
      def check
        return [] unless defined?(DeployTarget)

        DeployTarget.active.filter_map do |target|
          if target.status == "failed"
            AttentionItem.new(
              source: "deploy",
              severity: "critical",
              title: "\#{target.name} deploy failed",
              message: "Last deployment failed. Domain: \#{target.domain}",
              context: { deploy_target_id: target.id, domain: target.domain }
            )
          elsif target.status == "deploying" && target.last_deployed_at.present? && target.last_deployed_at < 10.minutes.ago
            AttentionItem.new(
              source: "deploy",
              severity: "warning",
              title: "\#{target.name} deploy stalled",
              message: "Deployment has been running for over 10 minutes.",
              context: { deploy_target_id: target.id, domain: target.domain }
            )
          elsif target.stale?
            AttentionItem.new(
              source: "deploy",
              severity: "warning",
              title: "\#{target.name} stale deploy",
              message: "Last deployed \#{ApplicationController.helpers.time_ago_in_words(target.last_deployed_at)} ago.",
              context: { deploy_target_id: target.id, domain: target.domain, last_deployed_at: target.last_deployed_at&.iso8601 }
            )
          elsif target.health_status == "unhealthy"
            AttentionItem.new(
              source: "deploy",
              severity: "critical",
              title: "\#{target.name} unhealthy",
              message: "Health check failing for \#{target.domain}.",
              context: { deploy_target_id: target.id, domain: target.domain }
            )
          elsif target.health_status == "unreachable"
            AttentionItem.new(
              source: "deploy",
              severity: "critical",
              title: "\#{target.name} unreachable",
              message: "Cannot reach \#{target.domain}.",
              context: { deploy_target_id: target.id, domain: target.domain }
            )
          end
        end
      end
    end
  RUBY

  # --- E1: Attention API controller ---

  file "app/controllers/api/attention_controller.rb", <<~RUBY
    module Api
      class AttentionController < ActionController::API
        def index
          items = AttentionService.collect(
            severity: params[:severity],
            source: params[:source]
          )

          render json: {
            counts: AttentionService.counts,
            items: items.map(&:as_json)
          }
        end
      end
    end
  RUBY

  # --- C5: DriftAlertSource ---

  file "app/services/drift_alert_source.rb", <<~'RUBY'
    class DriftAlertSource
      def check
        return [] unless defined?(ManifestService)

        ManifestService.detect_drift.flat_map do |container|
          container[:issues]
            .select { |i| i[:severity] != "info" }
            .map do |issue|
              severity = issue[:severity] == "high" ? "critical" : "warning"
              AttentionItem.new(
                source: "manifests",
                severity: severity,
                title: "#{container[:service]}: #{issue[:category].humanize}",
                message: issue[:detail],
                context: { service: container[:service], profile: container[:profile] }
              )
            end
        end
      rescue StandardError => e
        Rails.logger.warn("[DriftAlertSource] #{e.message}")
        []
      end
    end
  RUBY

  # --- E1: Attention route ---

  route 'get "api/attention", to: "api/attention#index"'

  # --- E1-E3, C5: Register attention sources ---

  initializer "attention_sources.rb", <<~RUBY
    Rails.application.config.after_initialize do
      AttentionService.register(:containers, ContainerAlertSource.new) if defined?(ContainerAlertSource)
      AttentionService.register(:hosts, HostAlertSource.new) if defined?(HostAlertSource)
      AttentionService.register(:deploy, DeployAlertSource.new) if defined?(DeployAlertSource)
      AttentionService.register(:manifests, DriftAlertSource.new) if defined?(DriftAlertSource)
    end
  RUBY
end
