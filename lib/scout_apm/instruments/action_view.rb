# Note, this instrument has the same logic in both Tracer and Module Prepend
# versions. If you update, be sure you update in both spots.
#
# The prepend version was added for Rails 6 support - ActiveRecord prepends on
# top of PartialRenderer#collection_with_template, which can (and does) cause
# infinite loops with our alias_method approach.
#
# Even though Rails 6 forced us to use a prepend version, it is now used for
# all Rubies that support it.
module ScoutApm
  module Instruments
    class ActionView
      attr_reader :context

      def initialize(context)
        @context = context
        @installed = false
      end

      def logger
        context.logger
      end

      def installed?
        @installed
      end

      def prependable?
        context.environment.supports_module_prepend?
      end

      def install
        return unless defined?(::ActionView) && defined?(::ActionView::PartialRenderer)

        if prependable?
          install_using_prepend
        else
          install_using_tracer
        end
        @installed = true
      end

      def install_using_tracer
        logger.info "Instrumenting ActionView::PartialRenderer"
        ::ActionView::PartialRenderer.class_eval do
          include ScoutApm::Tracer

          instrument_method :render_partial,
            :type => "View",
            :name => '#{@template.virtual_path rescue "Unknown Partial"}/Rendering',
            :scope => true

          instrument_method :collection_with_template,
            :type => "View",
            :name => '#{@template.virtual_path rescue "Unknown Collection"}/Rendering',
            :scope => true
        end

        logger.info "Instrumenting ActionView::TemplateRenderer"
        ::ActionView::TemplateRenderer.class_eval do
          include ScoutApm::Tracer
          instrument_method :render_template,
            :type => "View",
            :name => '#{args[0].virtual_path rescue "Unknown"}/Rendering',
            :scope => true
        end
      end

      def install_using_prepend
        logger.info "Instrumenting ActionView::PartialRenderer"
        ::ActionView::PartialRenderer.prepend(ActionViewPartialRendererInstruments)

        logger.info "Instrumenting ActionView::TemplateRenderer"
        ::ActionView::TemplateRenderer.prepend(ActionViewTemplateRendererInstruments)
      end

      module ActionViewPartialRendererInstruments
        # In Rails 6, the signature changed to pass the view & template args directly, as opposed to through the instance var
        # New signature is: def render_partial(view, template)
        def render_partial(*args, **kwargs)
          req = ScoutApm::RequestManager.lookup

          maybe_template = args[1]

          template_name = @template.virtual_path rescue nil        # Works on Rails 3.2 -> end of Rails 5 series
          template_name ||= maybe_template.virtual_path rescue nil # Works on Rails 6 -> 6.0.3
          template_name ||= "Unknown Partial"

          layer_name = template_name + "/Rendering"
          layer = ScoutApm::Layer.new("View", layer_name)
          layer.subscopable!

          begin
            req.start_layer(layer)
            super(*args, **kwargs)
          ensure
            req.stop_layer
          end
        end

        def collection_with_template(*args, **kwargs)
          req = ScoutApm::RequestManager.lookup

          template_name = @template.virtual_path rescue "Unknown Collection"
          template_name ||= "Unknown Collection"
          layer_name = template_name + "/Rendering"

          layer = ScoutApm::Layer.new("View", layer_name)
          layer.subscopable!

          begin
            req.start_layer(layer)
            super(*args, **kwargs)
          ensure
            req.stop_layer
          end
        end
      end

      module ActionViewTemplateRendererInstruments
        def render_template(*args, **kwargs)
          req = ScoutApm::RequestManager.lookup

          template_name = args[0].virtual_path rescue "Unknown"
          template_name ||= "Unknown"
          layer_name = template_name + "/Rendering"

          layer = ScoutApm::Layer.new("View", layer_name)
          layer.subscopable!

          begin
            req.start_layer(layer)
            super(*args, **kwargs)
          ensure
            req.stop_layer
          end
        end
      end
    end
  end
end
