# modules/api_rest.rb — Full REST API for sessions, providers, models, presets, turns, events
#
# Depends on: base, auth_token, schema_llm, schema_session, schema_res


@vv_applied_modules ||= []; @vv_applied_modules << "api_rest"

after_bundle do
  # --- Sessions controller ---

  file "app/controllers/api/sessions_controller.rb", <<~RUBY
    module Api
      class SessionsController < BaseController
        def index
          sessions = Session.order(updated_at: :desc)
          render json: sessions
        end

        def show
          session = Session.includes(:turns).find(params[:id])
          render json: session.as_json(include: [:turns]).merge(
            events: session.events.map { |e|
              { event_id: e.event_id, event_type: e.event_type, data: e.data, timestamp: e.metadata[:timestamp] }
            }
          )
        end

        def create
          session = Session.new(session_params)
          if session.save
            render json: session, status: :created
          else
            render json: { errors: session.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          session = Session.find(params[:id])
          session.destroy
          head :no_content
        end

        private

        def session_params
          params.require(:session).permit(:title, metadata: {})
        end
      end
    end
  RUBY

  # --- Events controller ---

  file "app/controllers/api/events_controller.rb", <<~RUBY
    module Api
      class EventsController < BaseController
        def index
          session = Session.find(params[:session_id])
          render json: session.events.map { |e| event_json(e) }
        end

        def create
          session = Session.find(params[:session_id])
          event_class = Vv::Rails::Events.for(params[:message_type])
          unless event_class
            render json: { error: "Unknown message_type: \#{params[:message_type]}" }, status: :unprocessable_entity
            return
          end

          event = event_class.new(data: {
            role: params[:role],
            content: params[:content],
            **(params[:metadata]&.permit!&.to_h || {})
          })
          Rails.configuration.event_store.publish(event, stream_name: "session:\#{session.id}")

          broadcast_event(session, event)
          render json: event_json(event), status: :created
        end

        private

        def event_json(e)
          { event_id: e.event_id, event_type: e.event_type, data: e.data, timestamp: e.metadata[:timestamp] }
        end

        def broadcast_event(session, event)
          prefix = Vv::Rails.configuration.channel_prefix
          ActionCable.server.broadcast(
            "\#{prefix}:session:\#{session.id}",
            { event: "event:new", data: event_json(event) }
          )
        end
      end
    end
  RUBY

  # --- Turns controller ---

  file "app/controllers/api/turns_controller.rb", <<~RUBY
    module Api
      class TurnsController < BaseController
        def index
          session = Session.find(params[:session_id])
          render json: session.turns.as_json(include: [:model, :preset])
        end

        def show
          session = Session.find(params[:session_id])
          turn = session.turns.find(params[:id])
          render json: turn.as_json(include: [:model, :preset])
        end
      end
    end
  RUBY

  # --- Providers controller ---

  file "app/controllers/api/providers_controller.rb", <<~RUBY
    module Api
      class ProvidersController < BaseController
        def index
          providers = Provider.active.by_priority
          render json: providers.as_json(except: :api_key_ciphertext, include: :models)
        end

        def show
          provider = Provider.find(params[:id])
          render json: provider.as_json(except: :api_key_ciphertext, include: { models: { include: :presets } })
        end

        def create
          provider = Provider.new(provider_params)
          if provider.save
            render json: provider.as_json(except: :api_key_ciphertext), status: :created
          else
            render json: { errors: provider.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          provider = Provider.find(params[:id])
          if provider.update(provider_params)
            render json: provider.as_json(except: :api_key_ciphertext)
          else
            render json: { errors: provider.errors.full_messages }, status: :unprocessable_entity
          end
        end

        private

        def provider_params
          params.require(:provider).permit(:name, :api_base, :api_key_ciphertext, :priority, :active, :requires_api_key)
        end
      end
    end
  RUBY

  # --- Models controller ---

  file "app/controllers/api/models_controller.rb", <<~RUBY
    module Api
      class ModelsController < BaseController
        def index
          models = if params[:provider_id]
            Provider.find(params[:provider_id]).models.active
          else
            Model.active.includes(:provider)
          end
          render json: models.as_json(include: :provider)
        end

        def show
          model = Model.find(params[:id])
          render json: model.as_json(include: [:provider, :presets])
        end

        def create
          provider = Provider.find(params[:provider_id])
          model = provider.models.build(model_params)
          if model.save
            render json: model, status: :created
          else
            render json: { errors: model.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          model = Model.find(params[:id])
          if model.update(model_params)
            render json: model
          else
            render json: { errors: model.errors.full_messages }, status: :unprocessable_entity
          end
        end

        private

        def model_params
          params.require(:model).permit(:name, :api_model_id, :context_window, :active, capabilities: {})
        end
      end
    end
  RUBY

  # --- Presets controller ---

  file "app/controllers/api/presets_controller.rb", <<~RUBY
    module Api
      class PresetsController < BaseController
        def index
          model = Model.find(params[:model_id])
          render json: model.presets.active
        end

        def create
          model = Model.find(params[:model_id])
          preset = model.presets.build(preset_params)
          if preset.save
            render json: preset, status: :created
          else
            render json: { errors: preset.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          preset = Preset.find(params[:id])
          if preset.update(preset_params)
            render json: preset
          else
            render json: { errors: preset.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          preset = Preset.find(params[:id])
          preset.destroy
          head :no_content
        end

        private

        def preset_params
          params.require(:preset).permit(:name, :temperature, :max_tokens, :system_prompt, :top_p, :active, parameters: {})
        end
      end
    end
  RUBY

  # --- API routes ---

  route <<~RUBY
    namespace :api do
      resources :sessions, only: [:index, :show, :create, :destroy] do
        resources :events, only: [:index, :create]
        resources :turns, only: [:index, :show]
      end

      resources :providers, only: [:index, :show, :create, :update] do
        resources :models, only: [:index, :create, :update]
      end

      resources :models, only: [:index, :show] do
        resources :presets, only: [:index, :create, :update, :destroy]
      end
    end
  RUBY
end
