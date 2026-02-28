# modules/api_containers.rb — Docker container control API
#
# Depends on: base

after_bundle do
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

  route <<~RUBY
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
  RUBY
end
