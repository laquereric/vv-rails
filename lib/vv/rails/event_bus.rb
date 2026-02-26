module Vv
  module Rails
    class EventBus
      class << self
        def on(event, &block)
          listeners[event] ||= []
          listeners[event] << block
          block
        end

        def off(event, &block)
          return unless listeners[event]
          listeners[event].delete(block)
        end

        def emit(event, data, context = {})
          return unless listeners[event]
          listeners[event].each { |cb| cb.call(data, context) }
        end

        def listeners
          @listeners ||= {}
        end

        def clear!
          @listeners = {}
        end
      end
    end
  end
end
