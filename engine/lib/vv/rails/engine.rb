module Vv
  module Rails
    class Engine < ::Rails::Engine
      isolate_namespace Vv::Rails

      initializer "vv_rails.action_cable" do
        ActiveSupport.on_load(:action_cable) do
          # VvChannel is auto-discovered from app/channels/
        end
      end

      # Route mounting moved to vv-browser-manager gem (mounts /vv)
    end
  end
end
