# modules/api_relay.rb — LLM relay endpoint
#
# Depends on: base, auth_token, schema_llm, schema_session

after_bundle do
  file "app/controllers/api/relay_controller.rb", <<~RUBY
    module Api
      class RelayController < BaseController
        def create
          model = find_model
          unless model
            render json: { error: "No active model available" }, status: :service_unavailable
            return
          end

          preset = params[:preset_id] ? Preset.find(params[:preset_id]) : nil
          session = params[:session_id] ? Session.find(params[:session_id]) : nil

          message_history = session ? session.messages_from_events : []

          turn = Turn.new(
            session: session,
            model: model,
            preset: preset,
            message_history: message_history,
            request: params[:content]
          )

          # Scaffold — implement HTTP client calls per provider API
          turn.completion = "Implement provider-specific HTTP relay in Api::RelayController#create"
          turn.save!

          render json: {
            turn_id: turn.id,
            provider: model.provider.name,
            model: model.api_model_id,
            preset: preset&.name,
            status: "relay_stub",
            message: turn.completion
          }
        end

        private

        def find_model
          if params[:model_id].present?
            Model.active.find_by(id: params[:model_id])
          elsif params[:model].present?
            Model.active.find_by(api_model_id: params[:model])
          else
            Model.active.joins(:provider).merge(Provider.active.by_priority).first
          end
        end
      end
    end
  RUBY

  route 'namespace :api do post "relay", to: "relay#create" end'
end
