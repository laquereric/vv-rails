class VvChannel < ApplicationCable::Channel
  def subscribed
    page_id = params[:page_id] || "default"
    prefix = Vv::Rails.configuration.channel_prefix

    stream_from "#{prefix}:#{page_id}"
    stream_from "#{prefix}:broadcast"

    if (on_connect = Vv::Rails.configuration.on_connect)
      on_connect.call(self, params)
    end
  end

  def unsubscribed
    if (on_disconnect = Vv::Rails.configuration.on_disconnect)
      on_disconnect.call(self, params)
    end
  end

  # Receives messages from the browser plugin
  def receive(data)
    event = data["event"]
    payload = data["data"]

    # Route through server-side event bus
    Vv::Rails::EventBus.emit(event, payload, channel: self)
  end

  # Broadcast a render command to the plugin's content script
  def render_to(target, html, action: "append")
    page_id = params[:page_id] || "default"
    prefix = Vv::Rails.configuration.channel_prefix

    ActionCable.server.broadcast(
      "#{prefix}:#{page_id}",
      { event: "render", data: { action: action, target: target, html: html } }
    )
  end

  # Broadcast an arbitrary event to the connected plugin
  def emit(event, data = {})
    page_id = params[:page_id] || "default"
    prefix = Vv::Rails.configuration.channel_prefix

    ActionCable.server.broadcast(
      "#{prefix}:#{page_id}",
      { event: event, data: data }
    )
  end
end
