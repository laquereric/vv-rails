module Vv
  module Rails
    class ConfigController < ActionController::API
      def show
        render json: {
          cable_url: Vv::Rails.configuration.cable_url,
          channel: "VvChannel",
          version: Vv::Rails::VERSION,
          prefix: Vv::Rails.configuration.channel_prefix,
        }
      end
    end
  end
end
