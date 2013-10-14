require 'Qt'
require 'qtwebkit'
require 'metaruby/gui/html/page'
require 'metaruby/gui/html/button'
module Syskit
    module GUI
        module PageExtension
            # Adds a PlanDisplay widget with the given title and parameters
            def push_plan(title, id, plan, options)
                view_options, options = Kernel.filter_options options,
                    :buttons => [],
                    :id => id,
                    :zoom => 1,
                    :mode => id,
                    :external_objects => nil
                mode = view_options.delete(:mode)

                svg_io = Tempfile.open(mode)
                begin
                    Syskit::Graphviz.new(plan, self).
                        to_file(mode, 'svg', svg_io, options)
                    svg_io.flush
                    svg_io.rewind
                    svg = svg_io.read
                    svg = svg.encode 'utf-8', :invalid => :replace
                rescue DotCrashError, DotFailedError => e
                    svg = e.message
                end

                zoom = view_options.delete :zoom
                begin
                    if match = /svg width=\"(\d+)(\w+)\" height=\"(\d+)(\w+)\"/.match(svg)
                        width, w_unit, height, h_unit = *match.captures
                        svg = match.pre_match + "svg width=\"#{(Float(width) * zoom * 0.6)}#{w_unit}\" height=\"#{(Float(height) * zoom * 0.6)}#{h_unit}\"" + match.post_match
                    end
                rescue ArgumentError
                end
                if pattern = view_options.delete(:external_objects)
                    file = pattern % view_options[:id] + ".svg"
                    File.open(file, 'w') do |io|
                        io.write(svg)
                    end
                    push(title, "<object data=\"#{file}\" type=\"image/svg+xml\"></object>", view_options)
                else
                    push(title, svg, view_options)
                end
                emit :updated
            end
        end
        MetaRuby::GUI::HTML::Page.include PageExtension
    end
end
