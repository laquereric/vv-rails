# modules/deploy.rb — Deployment target management for platform_manager
#
# Provides: DeployTarget model, DeploymentService, DeployTargetsController,
# deploy panel views, deploy Stimulus controller, routes.
#
# Depends on: base


@vv_applied_modules ||= []; @vv_applied_modules << "deploy"

after_bundle do
  # --- Migration ---

  generate "migration", "CreateDeployTargets",
    "name:string",
    "domain:string",
    "host:string",
    "user:string",
    "port:integer",
    "provider:string",
    "profile:string",
    "compose_file:string",
    "image_tag:string",
    "status:string",
    "health_status:string",
    "last_deployed_at:datetime"

  # --- Model ---

  file "app/models/deploy_target.rb", <<~RUBY
    class DeployTarget < ApplicationRecord
      validates :name, presence: true, uniqueness: true
      validates :domain, presence: true

      scope :active, -> { where(status: [nil, "new", "deployed", "failed", "rolled_back", "deploying", "rolling_back"]) }

      def status_color
        case health_status
        when "healthy"     then "running"
        when "unhealthy"   then "exited"
        when "unreachable" then "exited"
        else "created"
        end
      end

      def deployed?
        last_deployed_at.present?
      end

      def stale?
        return false unless last_deployed_at
        last_deployed_at < 7.days.ago
      end
    end
  RUBY

  # --- Service ---

  file "app/services/deployment_service.rb", <<~'RUBY'
    class DeploymentService
      attr_reader :target

      def initialize(deploy_target)
        @target = deploy_target
      end

      def deploy!
        target.update!(status: "deploying")
        broadcast_status

        result = if target.host.present?
          run_ssh("cd ~/#{target.profile} && docker compose -f #{target.compose_file} pull && " \
                  "docker compose -f #{target.compose_file} up -d --remove-orphans")
        else
          { exit_code: -1, output: "No host configured — cannot deploy" }
        end

        if result[:exit_code] == 0
          target.update!(status: "deployed", last_deployed_at: Time.current)
          check_health!
        else
          target.update!(status: "failed")
        end

        broadcast_status
        result
      end

      def check_health!
        return unless target.domain.present?

        uri = URI("https://#{target.domain}/up")
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 10) do |http|
          http.get(uri.request_uri)
        end

        health = response.code.to_i < 400 ? "healthy" : "unhealthy"
        target.update!(health_status: health)
        broadcast_status
        { status: health, code: response.code.to_i }
      rescue StandardError => e
        target.update!(health_status: "unreachable")
        broadcast_status
        { status: "unreachable", error: e.message }
      end

      def rollback!
        target.update!(status: "rolling_back")
        broadcast_status

        result = run_ssh(
          "cd ~/#{target.profile} && docker compose -f #{target.compose_file} down && " \
          "docker compose -f #{target.compose_file} up -d"
        )

        target.update!(status: result[:exit_code] == 0 ? "rolled_back" : "failed")
        check_health!
        broadcast_status
        result
      end

      def logs(lines: 100)
        return { output: "No host configured" } unless target.host.present?

        run_ssh("cd ~/#{target.profile} && docker compose -f #{target.compose_file} logs --tail=#{lines} 2>&1")
      end

      def status_summary
        {
          id: target.id,
          name: target.name,
          domain: target.domain,
          status: target.status,
          health_status: target.health_status,
          last_deployed_at: target.last_deployed_at&.iso8601,
          deployed: target.deployed?,
          stale: target.stale?
        }
      end

      private

      def broadcast_status
        ActionCable.server.broadcast("deploy_status", status_summary)
      end

      def run_ssh(command)
        return { exit_code: -1, output: "No host" } unless target.host.present?

        ssh_cmd = ["ssh", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=10"]
        ssh_cmd += ["-p", target.port.to_s] if target.port && target.port != 22
        ssh_cmd += ["#{target.user}@#{target.host}", command]

        output = `#{ssh_cmd.shelljoin} 2>&1`
        { exit_code: $?.exitstatus, output: output }
      end
    end
  RUBY

  # --- Controller ---

  file "app/controllers/deploy_targets_controller.rb", <<~RUBY
    class DeployTargetsController < ApplicationController
      before_action :set_deploy_target, only: [:edit, :update, :destroy, :deploy, :check_status, :rollback, :logs]

      def index
        @deploy_targets = DeployTarget.active.order(:name)
      end

      def new
        @deploy_target = DeployTarget.new(port: 22, user: "deploy", image_tag: "latest", compose_file: "docker-compose.yml")
      end

      def create
        @deploy_target = DeployTarget.new(deploy_target_params)
        if @deploy_target.save
          redirect_to "/deploy", notice: "Deploy target added."
        else
          render :new, status: :unprocessable_entity
        end
      end

      def edit; end

      def update
        if @deploy_target.update(deploy_target_params)
          redirect_to "/deploy", notice: "Deploy target updated."
        else
          render :edit, status: :unprocessable_entity
        end
      end

      def destroy
        @deploy_target.destroy
        redirect_to "/deploy", notice: "Deploy target removed."
      end

      def deploy
        service = DeploymentService.new(@deploy_target)
        result = service.deploy!
        render json: { status: @deploy_target.reload.status, result: result }
      end

      def check_status
        service = DeploymentService.new(@deploy_target)
        health = service.check_health!
        render json: service.status_summary.merge(health: health)
      end

      def rollback
        service = DeploymentService.new(@deploy_target)
        result = service.rollback!
        render json: { status: @deploy_target.reload.status, result: result }
      end

      def logs
        service = DeploymentService.new(@deploy_target)
        result = service.logs(lines: params.fetch(:lines, 100).to_i)
        render json: result
      end

      private

      def set_deploy_target
        @deploy_target = DeployTarget.find(params[:id])
      end

      def deploy_target_params
        params.require(:deploy_target).permit(
          :name, :domain, :host, :user, :port,
          :provider, :profile, :compose_file, :image_tag
        )
      end
    end
  RUBY

  # --- Action Cable: DeployStatusChannel ---

  file "app/channels/deploy_status_channel.rb", <<~RUBY
    class DeployStatusChannel < ApplicationCable::Channel
      def subscribed
        stream_from "deploy_status"
      end
    end
  RUBY

  # --- Routes ---

  route <<~RUBY
    resources :deploy_targets, except: [:show] do
      member do
        post :deploy
        get :check_status
        post :rollback
        get :logs
      end
    end
  RUBY

  # --- Deploy panel partial (rendered by dashboard) ---

  file "app/views/dashboard/_deploy_panel.html.erb", <<~'ERB'
    <div data-controller="deploy">
      <div class="panel-header">
        <h2>Deploy Targets</h2>
        <div class="panel-header__actions">
          <button class="btn btn--secondary" data-action="click->deploy#refreshAll">Refresh All</button>
          <%= link_to "Add Target", new_deploy_target_path, class: "btn btn--primary" %>
        </div>
      </div>

      <% if @deploy_targets.empty? %>
        <div class="empty-state">
          <p>No deploy targets configured.</p>
          <p class="empty-state__hint">Add a deployment target to manage remote VV app instances.</p>
        </div>
      <% else %>
        <div class="deploy-grid">
          <% @deploy_targets.each do |target| %>
            <div class="deploy-card deploy-card--<%= target.status_color %>"
                 data-deploy-target="card"
                 data-deploy-id="<%= target.id %>">
              <div class="deploy-card__header">
                <span class="deploy-card__name"><%= target.name %></span>
                <span class="deploy-card__health-badge deploy-card__health-badge--<%= target.health_status || 'unknown' %>">
                  <%= target.health_status || "unknown" %>
                </span>
              </div>
              <div class="deploy-card__domain"><%= target.domain %></div>
              <div class="deploy-card__details">
                <div class="deploy-card__detail">
                  <span class="deploy-card__label">Provider</span>
                  <span class="deploy-card__value"><%= target.provider || "—" %></span>
                </div>
                <div class="deploy-card__detail">
                  <span class="deploy-card__label">Profile</span>
                  <span class="deploy-card__value"><%= target.profile || "—" %></span>
                </div>
                <div class="deploy-card__detail">
                  <span class="deploy-card__label">Host</span>
                  <span class="deploy-card__value"><%= target.host.present? ? target.host : "Not set" %></span>
                </div>
                <div class="deploy-card__detail">
                  <span class="deploy-card__label">Status</span>
                  <span class="deploy-card__value" data-deploy-target="status"><%= target.status || "new" %></span>
                </div>
                <div class="deploy-card__detail">
                  <span class="deploy-card__label">Last Deploy</span>
                  <span class="deploy-card__value"><%= target.last_deployed_at&.strftime("%Y-%m-%d %H:%M") || "Never" %></span>
                </div>
                <div class="deploy-card__detail">
                  <span class="deploy-card__label">Image</span>
                  <span class="deploy-card__value"><%= target.image_tag || "latest" %></span>
                </div>
              </div>
              <div class="deploy-card__actions">
                <button class="btn btn--sm btn--success"
                        data-action="click->deploy#deploy"
                        data-deploy-id-param="<%= target.id %>"
                        <%= "disabled" unless target.host.present? %>>
                  Deploy
                </button>
                <button class="btn btn--sm btn--secondary"
                        data-action="click->deploy#checkStatus"
                        data-deploy-id-param="<%= target.id %>">
                  Check
                </button>
                <button class="btn btn--sm btn--danger"
                        data-action="click->deploy#rollback"
                        data-deploy-id-param="<%= target.id %>"
                        <%= "disabled" unless target.deployed? %>>
                  Rollback
                </button>
                <%= link_to "Edit", edit_deploy_target_path(target), class: "btn btn--sm btn--secondary" %>
                <%= button_to "Remove", deploy_target_path(target), method: :delete, class: "btn btn--sm btn--danger", data: { turbo_confirm: "Remove #{target.name}?" } %>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
  ERB

  # --- Deploy target form ---

  file "app/views/deploy_targets/_form.html.erb", <<~'ERB'
    <%= form_with model: @deploy_target, class: "pm-form" do |f| %>
      <% if @deploy_target.errors.any? %>
        <div class="pm-form__errors">
          <% @deploy_target.errors.full_messages.each do |msg| %>
            <p><%= msg %></p>
          <% end %>
        </div>
      <% end %>

      <div class="pm-form__field">
        <%= f.label :name, class: "pm-form__label" %>
        <%= f.text_field :name, class: "pm-form__input", placeholder: "VerticalVertical.net" %>
      </div>

      <div class="pm-form__field">
        <%= f.label :domain, class: "pm-form__label" %>
        <%= f.text_field :domain, class: "pm-form__input", placeholder: "verticalvertical.net" %>
      </div>

      <div class="pm-form__field">
        <%= f.label :host, "Server IP/Host", class: "pm-form__label" %>
        <%= f.text_field :host, class: "pm-form__input", placeholder: "123.45.67.89" %>
      </div>

      <div class="pm-form__row">
        <div class="pm-form__field">
          <%= f.label :user, "SSH User", class: "pm-form__label" %>
          <%= f.text_field :user, class: "pm-form__input", placeholder: "deploy" %>
        </div>
        <div class="pm-form__field">
          <%= f.label :port, "SSH Port", class: "pm-form__label" %>
          <%= f.number_field :port, class: "pm-form__input", placeholder: "22" %>
        </div>
      </div>

      <div class="pm-form__row">
        <div class="pm-form__field">
          <%= f.label :provider, class: "pm-form__label" %>
          <%= f.text_field :provider, class: "pm-form__input", placeholder: "galaxygate" %>
        </div>
        <div class="pm-form__field">
          <%= f.label :profile, class: "pm-form__label" %>
          <%= f.text_field :profile, class: "pm-form__input", placeholder: "individual" %>
        </div>
      </div>

      <div class="pm-form__row">
        <div class="pm-form__field">
          <%= f.label :compose_file, "Compose File", class: "pm-form__label" %>
          <%= f.text_field :compose_file, class: "pm-form__input", placeholder: "docker-compose.yml" %>
        </div>
        <div class="pm-form__field">
          <%= f.label :image_tag, "Image Tag", class: "pm-form__label" %>
          <%= f.text_field :image_tag, class: "pm-form__input", placeholder: "latest" %>
        </div>
      </div>

      <div class="pm-form__actions">
        <%= f.submit class: "btn btn--primary" %>
        <%= link_to "Cancel", "/deploy", class: "btn btn--secondary" %>
      </div>
    <% end %>
  ERB

  file "app/views/deploy_targets/new.html.erb", <<~'ERB'
    <div class="pm-page">
      <h2>Add Deploy Target</h2>
      <%= render "form" %>
    </div>
  ERB

  file "app/views/deploy_targets/edit.html.erb", <<~'ERB'
    <div class="pm-page">
      <h2>Edit Deploy Target</h2>
      <%= render "form" %>
    </div>
  ERB

  # --- Stimulus: deploy controller ---

  file "app/javascript/controllers/deploy_controller.js", <<~JS
    import { Controller } from "@hotwired/stimulus"

    export default class extends Controller {
      static targets = ["card", "status"]

      async deploy(event) {
        const id = event.params.id
        const btn = event.currentTarget
        btn.disabled = true
        btn.textContent = "Deploying..."

        try {
          const response = await fetch(`/deploy_targets/${id}/deploy`, {
            method: "POST",
            headers: {
              "X-CSRF-Token": this.csrfToken,
              "Content-Type": "application/json"
            }
          })
          const data = await response.json()
          this.updateCardStatus(id, data.status)
        } catch (e) {
          console.error("Deploy failed:", e)
        } finally {
          btn.disabled = false
          btn.textContent = "Deploy"
        }
      }

      async checkStatus(event) {
        const id = event.params.id
        const btn = event.currentTarget
        btn.disabled = true
        btn.textContent = "Checking..."

        try {
          const response = await fetch(`/deploy_targets/${id}/check_status`)
          const data = await response.json()
          this.updateCardStatus(id, data.status)
          this.updateCardHealth(id, data.health_status)
        } catch (e) {
          console.error("Status check failed:", e)
        } finally {
          btn.disabled = false
          btn.textContent = "Check"
        }
      }

      async rollback(event) {
        if (!confirm("Are you sure you want to rollback?")) return

        const id = event.params.id
        const btn = event.currentTarget
        btn.disabled = true
        btn.textContent = "Rolling back..."

        try {
          const response = await fetch(`/deploy_targets/${id}/rollback`, {
            method: "POST",
            headers: {
              "X-CSRF-Token": this.csrfToken,
              "Content-Type": "application/json"
            }
          })
          const data = await response.json()
          this.updateCardStatus(id, data.status)
        } catch (e) {
          console.error("Rollback failed:", e)
        } finally {
          btn.disabled = false
          btn.textContent = "Rollback"
        }
      }

      refreshAll() {
        document.querySelectorAll("[data-deploy-id]").forEach(card => {
          const id = card.dataset.deployId
          fetch(`/deploy_targets/${id}/check_status`)
            .then(r => r.json())
            .then(data => {
              this.updateCardStatus(id, data.status)
              this.updateCardHealth(id, data.health_status)
            })
            .catch(e => console.error(`Status check failed for ${id}:`, e))
        })
      }

      updateCardStatus(id, status) {
        const card = this.element.querySelector(`[data-deploy-id="${id}"]`)
        if (!card) return
        const statusEl = card.querySelector("[data-deploy-target='status']")
        if (statusEl) statusEl.textContent = status || "unknown"
      }

      updateCardHealth(id, health) {
        const card = this.element.querySelector(`[data-deploy-id="${id}"]`)
        if (!card) return
        const badge = card.querySelector(".deploy-card__health-badge")
        if (badge) {
          badge.className = `deploy-card__health-badge deploy-card__health-badge--${health || "unknown"}`
          badge.textContent = health || "unknown"
        }
      }

      get csrfToken() {
        return document.querySelector("meta[name='csrf-token']")?.content
      }
    }
  JS

  # --- Deploy CSS (separate file, included by layout) ---

  file "app/assets/stylesheets/deploy.css", <<~CSS
    /* Deploy Grid */
    .deploy-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(350px, 1fr)); gap: 16px; }

    /* Deploy Card */
    .deploy-card { background: white; border-radius: 8px; padding: 16px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); border-left: 4px solid #ddd; transition: box-shadow 0.2s ease; }
    .deploy-card:hover { box-shadow: 0 4px 12px rgba(0,0,0,0.12); }
    .deploy-card--running { border-left-color: #28a745; }
    .deploy-card--exited { border-left-color: #dc3545; }
    .deploy-card--created { border-left-color: #ffc107; }
    .deploy-card__header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 4px; }
    .deploy-card__name { font-weight: 600; font-size: 16px; color: #1a1a2e; }
    .deploy-card__domain { font-family: monospace; font-size: 13px; color: #888; margin-bottom: 12px; }
    .deploy-card__details { margin-bottom: 12px; }
    .deploy-card__detail { display: flex; justify-content: space-between; padding: 4px 0; font-size: 13px; }
    .deploy-card__label { color: #888; }
    .deploy-card__value { color: #333; font-family: monospace; font-size: 12px; }
    .deploy-card__actions { display: flex; gap: 8px; flex-wrap: wrap; padding-top: 12px; border-top: 1px solid #f0f2f5; }
    .deploy-card__health-badge { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; padding: 3px 8px; border-radius: 12px; background: #e9ecef; color: #666; }
    .deploy-card__health-badge--healthy { background: #d4edda; color: #155724; }
    .deploy-card__health-badge--unhealthy { background: #f8d7da; color: #721c24; }
    .deploy-card__health-badge--unreachable { background: #f8d7da; color: #721c24; }
    .deploy-card__health-badge--unknown { background: #e9ecef; color: #666; }

    /* Panel header with multiple action buttons */
    .panel-header__actions { display: flex; gap: 8px; }

    /* Form row for side-by-side fields */
    .pm-form__row { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
  CSS

  # --- Seeds ---

  append_to_file "db/seeds.rb", <<~RUBY

    # Default deploy target
    DeployTarget.find_or_create_by!(name: "VerticalVertical.net") do |t|
      t.domain = "verticalvertical.net"
      t.user = "deploy"
      t.port = 22
      t.provider = "galaxygate"
      t.profile = "individual"
      t.compose_file = "docker-compose.yml"
      t.image_tag = "latest"
      t.status = "new"
    end
  RUBY
end
