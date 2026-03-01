# vv-rails platform_manager template
#
# Generates a local development dashboard that monitors Docker-based vv apps
# and connects to remote vv-host instances via Action Cable WebSocket
# for a real-time platform activity view.
#
# Usage:
#   rails new myapp -m vendor/vv-rails/templates/platform_manager.rb
#

# --- Gems ---

gem "vv-rails", path: "vendor/vv-rails/engine"
gem "vv-browser-manager", path: "vendor/vv-browser-manager/engine"

# --- vv:install (inlined — creates initializer and mounts engine) ---

initializer "vv_rails.rb", <<~RUBY
  Vv::Rails.configure do |config|
    config.channel_prefix = "vv_platform"
    # config.cable_url = "ws://localhost:3000/cable"
  end
RUBY

after_bundle do
  # --- Vv logo ---
  logo_src = File.join(File.dirname(__FILE__), "vv-logo.png")
  copy_file logo_src, "public/vv-logo.png" if File.exist?(logo_src)

  # --- Routes (engine auto-mounts at /vv via initializer) ---

  route <<~RUBY
    root "dashboard#index"
    get "local", to: "dashboard#local"
    get "public", to: "dashboard#public_tab"

    namespace :api do
      namespace :local do
        resources :containers, only: [:index] do
          member do
            post :start
            post :stop
            post :restart
          end
        end
      end
    end

    resources :host_instances, except: [:show]
  RUBY

  # --- Migrations ---

  generate "migration", "CreateHostInstances name:string url:string cable_url:string active:boolean last_seen_at:datetime"

  # --- Models ---

  file "app/models/host_instance.rb", <<~RUBY
    class HostInstance < ApplicationRecord
      validates :name, presence: true, uniqueness: true
      validates :url, presence: true
      validates :cable_url, presence: true

      scope :active, -> { where(active: true) }

      def status
        return "unknown" if last_seen_at.nil?
        last_seen_at > 30.seconds.ago ? "connected" : "disconnected"
      end
    end
  RUBY

  # --- Service: DockerService ---

  file "app/services/docker_service.rb", <<~'RUBY'
    class DockerService
      COMPOSE_PROJECT = ENV.fetch("COMPOSE_PROJECT_NAME", "vv-platform")

      def self.containers
        json = `docker compose -p #{COMPOSE_PROJECT} ps --format json 2>/dev/null`
        return [] if json.blank?

        json.lines.filter_map do |line|
          data = JSON.parse(line) rescue next
          {
            id: data["ID"],
            name: data["Name"],
            service: data["Service"],
            state: data["State"],
            status: data["Status"],
            ports: data["Ports"],
            health: data["Health"] || "N/A"
          }
        end
      end

      def self.restart(container_id)
        system("docker", "restart", container_id.to_s)
      end

      def self.stop(container_id)
        system("docker", "stop", container_id.to_s)
      end

      def self.start(container_id)
        system("docker", "start", container_id.to_s)
      end
    end
  RUBY

  # --- DashboardController ---

  file "app/controllers/dashboard_controller.rb", <<~RUBY
    class DashboardController < ApplicationController
      def index
        redirect_to action: :local
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
    end
  RUBY

  # --- API: ContainersController ---

  file "app/controllers/api/local/containers_controller.rb", <<~RUBY
    module Api
      module Local
        class ContainersController < ActionController::API
          def index
            render json: DockerService.containers
          end

          def restart
            DockerService.restart(params[:id])
            render json: { status: "restarting", id: params[:id] }
          end

          def stop
            DockerService.stop(params[:id])
            render json: { status: "stopping", id: params[:id] }
          end

          def start
            DockerService.start(params[:id])
            render json: { status: "starting", id: params[:id] }
          end
        end
      end
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

  # --- Action Cable base classes ---

  file "app/channels/application_cable/connection.rb", <<~RUBY
    module ApplicationCable
      class Connection < ActionCable::Connection::Base
      end
    end
  RUBY

  file "app/channels/application_cable/channel.rb", <<~RUBY
    module ApplicationCable
      class Channel < ActionCable::Channel::Base
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
        <%= javascript_importmap_tags %>
      </head>

      <body>
        <header class="pm-header">
          <nav class="pm-nav">
            <a href="/" class="pm-nav__brand"><img src="/vv-logo.png" alt="Vv" style="height: 32px; vertical-align: middle; margin-right: 10px;">Platform Manager</a>
            <div class="pm-nav__tabs">
              <a href="/local" class="pm-nav__tab <%= 'pm-nav__tab--active' if @active_tab == 'local' %>">Local</a>
              <a href="/public" class="pm-nav__tab <%= 'pm-nav__tab--active' if @active_tab == 'public' %>">Public</a>
            </div>
            <div class="pm-nav__version">v0.7.2</div>
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
      <% if @active_tab == "local" %>
        <%= render "dashboard/local_panel" %>
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
        const metricsEl = this.metricsTargets[index]

        try {
          // Create ActionCable consumer for this remote host
          const ws = new WebSocket(cableUrl)

          ws.onopen = () => {
            this.updateStatus(statusEl, "connected")
            // Subscribe to VvChannel for platform events
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
            // Attempt reconnect after 5 seconds
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

  # --- CSS ---

  file "app/assets/stylesheets/platform_manager.css", <<~CSS
    /* Reset & Base */
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    html { font-size: 16px; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #f0f2f5; color: #333; min-height: 100vh; }

    /* Header */
    .pm-header { background: #1a1a2e; color: white; padding: 0 24px; box-shadow: 0 2px 8px rgba(0,0,0,0.15); position: sticky; top: 0; z-index: 100; }
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
    .empty-state { text-align: center; padding: 60px 20px; background: white; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); }
    .empty-state p { color: #666; font-size: 16px; margin-bottom: 8px; }
    .empty-state__hint { font-size: 14px; color: #999; }
    .empty-state code { background: #f0f2f5; padding: 2px 6px; border-radius: 3px; font-size: 13px; }

    /* Container Grid */
    .container-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 16px; }

    /* Container Card */
    .container-card { background: white; border-radius: 8px; padding: 16px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); border-left: 4px solid #ddd; transition: box-shadow 0.2s ease; }
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
  RUBY

  say ""
  say "vv-platform-manager app generated!", :green
  say "  Dashboard:     GET / (redirects to /local)"
  say "  Local tab:     GET /local"
  say "  Public tab:    GET /public"
  say "  Container API: GET /api/local/containers"
  say "  Host mgmt:     /host_instances"
  say "  Plugin config: GET /vv/config.json"
  say ""
  say "Next steps:"
  say "  1. rails db:create db:migrate db:seed"
  say "  2. docker compose up -d  (to have containers to monitor)"
  say "  3. rails server -p 3000"
  say ""
end
