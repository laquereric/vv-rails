# modules/planning.rb — Kanban planning engine for platform_manager
#
# Provides: EnginePlanner gem, pl_* tables, /plans routes (HTML + API),
# PlanAlertSource for Attention tab, PlanDiagramService (P4),
# NextActionsController + plan-driven workflow (P5).
#
# Depends on: base
# Vendor: engine-planner, engine-mermaid, library-exception, library-biological

@vv_applied_modules ||= []; @vv_applied_modules << "planning"

gem "library-platform", path: "vendor/library-platform"
gem "library-exception", path: "vendor/library-exception"
gem "library-biological", path: "vendor/library-biological"
gem "securerandom"
gem "uuid_v7"
gem "dry-monads", "~> 1.6"
gem "planner", path: "vendor/engine-planner"
gem "engine-mermaid", path: "vendor/engine-mermaid"

after_bundle do
  # --- Mount engine routes ---

  route <<~RUBY
    mount EnginePlanner::Engine, at: "/plans" if defined?(EnginePlanner)
    mount EngineMermaid::Engine, at: "/diagrams" if defined?(EngineMermaid)
  RUBY

  # --- Initializer ---

  initializer "engine_planner.rb", <<~RUBY
    if defined?(EnginePlanner) && EnginePlanner.respond_to?(:configure)
      EnginePlanner.configure do |config|
        config.enable_service_node = true
      end
    end
  RUBY

  # --- PlanAlertSource (E4: Plan Alerts) ---

  file "app/services/plan_alert_source.rb", <<~'RUBY'
    class PlanAlertSource
      STALE_PROPOSAL_DAYS = ENV.fetch("VV_STALE_PROPOSAL_DAYS", 7).to_i
      OVERDUE_ITEM_DAYS = ENV.fetch("VV_OVERDUE_ITEM_DAYS", 14).to_i

      def check
        return [] unless tables_exist?

        items = []
        items.concat(check_stale_proposals)
        items.concat(check_overdue_items)
        items.concat(check_pending_reviews)
        items
      end

      private

      def tables_exist?
        defined?(EnginePlanner::Assertion) &&
          ActiveRecord::Base.connection.table_exists?("pl_assertions")
      rescue StandardError
        false
      end

      def check_stale_proposals
        cutoff = STALE_PROPOSAL_DAYS.days.ago
        EnginePlanner::Assertion.where(status: "proposed")
          .where("created_at < ?", cutoff)
          .includes(:perspective)
          .map do |assertion|
            plan_name = assertion.perspective&.plan&.title || "Unknown plan"
            AttentionItem.new(
              source: "plans",
              severity: "warning",
              title: "Stale proposal: #{assertion.title.to_s.truncate(60)}",
              message: "Proposed #{((Time.current - assertion.created_at) / 1.day).to_i} days ago in #{plan_name}. Review or accept.",
              context: { assertion_id: assertion.id, plan: plan_name }
            )
          end
      rescue StandardError
        []
      end

      def check_overdue_items
        cutoff = OVERDUE_ITEM_DAYS.days.ago
        EnginePlanner::PlanItem.where(status: "in_progress")
          .where("updated_at < ?", cutoff)
          .includes(:plan)
          .map do |item|
            AttentionItem.new(
              source: "plans",
              severity: "warning",
              title: "Overdue: #{item.plan&.title.to_s.truncate(60)}",
              message: "In progress for #{((Time.current - item.updated_at) / 1.day).to_i} days. May need attention.",
              context: { plan_item_id: item.id }
            )
          end
      rescue StandardError
        []
      end

      def check_pending_reviews
        EnginePlanner::Plan.where(status: "for_review").map do |plan|
          AttentionItem.new(
            source: "plans",
            severity: "info",
            title: "Ready for review: #{plan.title.to_s.truncate(60)}",
            message: "Plan is awaiting review.",
            context: { plan_id: plan.id }
          )
        end
      rescue StandardError
        []
      end
    end
  RUBY

  # --- P4: Plan Diagram Service (engine-mermaid integration) ---

  file "app/services/plan_diagram_service.rb", <<~'RUBY'
    class PlanDiagramService
      AUTHORITY_SHAPES = {
        "human"  => { open: "([", close: "])" },  # stadium
        "system" => { open: "[",  close: "]" },    # rectangle
        "agent"  => { open: "{{", close: "}}" }    # hexagon
      }.freeze

      def initialize(plan)
        @plan = plan
      end

      # Generate a Mermaid flowchart of authorities and their connections
      def flowchart
        return nil unless defined?(EngineMermaid) && @plan

        lines = ["graph TD"]

        authorities = EnginePlanner::Authority.where(plan: @plan)
        authorities.each do |auth|
          shape = AUTHORITY_SHAPES[auth.authority_type] || AUTHORITY_SHAPES["system"]
          lines << "  #{auth_id(auth)}#{shape[:open]}#{auth.name}#{shape[:close]}"
        end

        connections = EnginePlanner::Connection.joins(:source_authority, :target_authority)
          .where(source_authority: { plan_id: @plan.id })
        connections.each do |conn|
          arrow = conn.connection_type == "data_flow" ? "-->" : "-.->"
          label = conn.label.present? ? "|#{conn.label}|" : ""
          lines << "  #{auth_id(conn.source_authority)} #{arrow}#{label} #{auth_id(conn.target_authority)}"
        end

        lines.join("\n")
      rescue StandardError => e
        Rails.logger.warn "[plan_diagram] flowchart error: #{e.message}"
        nil
      end

      # Generate a Mermaid sequence diagram for assertion flow
      def sequence_diagram
        return nil unless defined?(EngineMermaid) && @plan

        lines = ["sequenceDiagram"]

        perspectives = EnginePlanner::Perspective.where(plan: @plan).order(:position)
        perspectives.each do |persp|
          lines << "  participant #{persp_id(persp)} as #{persp.name}"
        end

        assertions = EnginePlanner::Assertion.where(perspective: perspectives)
          .order(:created_at).limit(20)
        assertions.each do |assertion|
          from = persp_id(assertion.perspective)
          lines << "  Note over #{from}: #{assertion.title.to_s.truncate(30)}"
          lines << "  #{from}->>#{from}: #{assertion.status}"
        end

        lines.join("\n")
      rescue StandardError => e
        Rails.logger.warn "[plan_diagram] sequence error: #{e.message}"
        nil
      end

      private

      def auth_id(auth)
        "auth_#{auth.id}"
      end

      def persp_id(persp)
        persp.name.gsub(/\s+/, "_")
      end
    end
  RUBY

  # --- P4: Diagram route ---

  route <<~RUBY
    get "api/v1/plans/:id/diagram", to: "api/plan_diagrams#show" if defined?(EnginePlanner)
  RUBY

  file "app/controllers/api/plan_diagrams_controller.rb", <<~'RUBY'
    module Api
      class PlanDiagramsController < ApplicationController
        skip_forgery_protection

        def show
          plan = EnginePlanner::Plan.find_by(id: params[:id])
          unless plan
            render json: { error: "Plan not found" }, status: :not_found
            return
          end

          service = PlanDiagramService.new(plan)
          render json: {
            plan_id: plan.id,
            title: plan.title,
            flowchart: service.flowchart,
            sequence_diagram: service.sequence_diagram
          }
        end
      end
    end
  RUBY

  # --- P5: Next Actions Controller (plan-driven workflow) ---

  file "app/services/next_actions_service.rb", <<~'RUBY'
    class NextActionsService
      def self.collect(plan: nil)
        return [] unless defined?(EnginePlanner) &&
          ActiveRecord::Base.connection.table_exists?("pl_assertions")

        actions = []
        scope = plan ? EnginePlanner::Assertion.joins(:perspective).where(perspectives: { plan_id: plan.id }) : EnginePlanner::Assertion.all

        # Proposed assertions needing human review
        scope.where(status: "proposed").includes(:perspective, :authority).each do |a|
          actions << {
            type: "review",
            assertion_id: a.id,
            title: a.title,
            perspective: a.perspective&.name,
            authority: a.authority&.name,
            authority_type: a.authority&.authority_type,
            created_at: a.created_at
          }
        end

        # Accepted system assertions pending scaffold generation
        scope.where(status: "accepted").includes(:authority).each do |a|
          next unless a.authority&.authority_type == "system"
          actions << {
            type: "scaffold",
            assertion_id: a.id,
            title: a.title,
            authority: a.authority&.name,
            message: "Accepted system assertion ready for code generation"
          }
        end

        # Accepted agent assertions pending LLM task
        scope.where(status: "accepted").includes(:authority).each do |a|
          next unless a.authority&.authority_type == "agent"
          actions << {
            type: "agent_task",
            assertion_id: a.id,
            title: a.title,
            authority: a.authority&.name,
            message: "Accepted agent assertion ready for LLM task"
          }
        end

        # Plans ready to advance
        plans_scope = plan ? EnginePlanner::Plan.where(id: plan.id) : EnginePlanner::Plan.all
        plans_scope.where(status: "for_review").each do |p|
          actions << {
            type: "advance_plan",
            plan_id: p.id,
            title: p.title,
            message: "Plan is ready for review and advancement"
          }
        end

        actions
      rescue StandardError
        []
      end
    end
  RUBY

  route <<~RUBY
    get "api/v1/next_actions", to: "api/next_actions#index" if defined?(EnginePlanner)
  RUBY

  file "app/controllers/api/next_actions_controller.rb", <<~'RUBY'
    module Api
      class NextActionsController < ApplicationController
        skip_forgery_protection

        def index
          plan_id = params[:plan_id]
          plan = plan_id ? EnginePlanner::Plan.find_by(id: plan_id) : nil

          actions = NextActionsService.collect(plan: plan)
          render json: {
            count: actions.length,
            actions: actions
          }
        end
      end
    end
  RUBY

  # --- P2: Seed existing epochs ---

  append_to_file "db/seeds.rb", <<~'RUBY'

    # Seed engine-planner plans (idempotent)
    if defined?(EnginePlanner) && ActiveRecord::Base.connection.table_exists?("pl_plans")
      username = "vv-platform"

      # Compose epoch
      compose = EnginePlanner::Plan.find_or_create_by!(title: "Compose") do |p|
        p.username = username
        p.status = "done"
        p.description = "Composable template generator for vv-rails"
        p.scope_type = "ecosystem"
      end

      # Llama Stack epoch
      lstack = EnginePlanner::Plan.find_or_create_by!(title: "Llama Stack") do |p|
        p.username = username
        p.status = "done"
        p.description = "Llama Stack client integration across all profiles"
        p.scope_type = "ecosystem"
      end

      # PLAN_10.6 epoch
      plan_106 = EnginePlanner::Plan.find_or_create_by!(title: "PLAN 10.6") do |p|
        p.username = username
        p.status = "in_progress"
        p.description = "Five epochs: Attention, Manifest, Beneficiary, Design System, Plan"
        p.scope_type = "ecosystem"
      end

      # Authorities
      human = EnginePlanner::Authority.find_or_create_by!(plan: plan_106, name: "Developer") do |a|
        a.authority_type = "human"
      end

      system = EnginePlanner::Authority.find_or_create_by!(plan: plan_106, name: "CI/CD") do |a|
        a.authority_type = "system"
      end

      # PLAN_10.6 perspectives (one per sub-epoch)
      epochs = [
        { name: "Attention",     position: 0 },
        { name: "Manifest",      position: 1 },
        { name: "Beneficiary",   position: 2 },
        { name: "Design System", position: 3 },
        { name: "Plan",          position: 4 }
      ]

      epochs.each do |ep|
        EnginePlanner::Perspective.find_or_create_by!(plan: plan_106, name: ep[:name]) do |p|
          p.position = ep[:position]
        end
      end

      Rails.logger.info "[planning seeds] Seeded #{EnginePlanner::Plan.count} plans, #{EnginePlanner::Perspective.count} perspectives"
    end
  RUBY

  # --- Register PlanAlertSource with AttentionService ---

  initializer "plan_attention_source.rb", <<~RUBY
    Rails.application.config.after_initialize do
      if defined?(AttentionService) && defined?(PlanAlertSource)
        AttentionService.register(:plans, PlanAlertSource.new)
      end
    end
  RUBY
end
