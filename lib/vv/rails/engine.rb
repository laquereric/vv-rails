module Vv
  module Rails
    class Engine < ::Rails::Engine
      isolate_namespace Vv::Rails

      initializer "vv_rails.action_cable" do
        ActiveSupport.on_load(:action_cable) do
          # VvChannel is auto-discovered from app/channels/
        end
      end

      initializer "vv_rails.routes" do |app|
        app.routes.append do
          mount Vv::Rails::Engine => "/vv"
        end
      end
    end
  end
end
