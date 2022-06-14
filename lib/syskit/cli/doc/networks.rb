# frozen_string_literal: true

require "syskit"

module Syskit
    module CLI
        module Doc
            # Generate the network graph for the model defined in a given path
            #
            # It is saved under the target path, in a folder that matches the
            # namespace (the same way YARD does)
            def self.generate_network_graphs(app, required_paths, target_path)
                required_paths = required_paths.map(&:to_s).to_set
                models = app.each_model.find_all do |m|
                    if (location = app.definition_file_for(m))
                        required_paths.include?(location)
                    end
                end

                models.each do |m|
                    save_model(target_path, m)
                end
            end

            def self.save_model(target_path, m)
                case m
                when Syskit::Actions::Profile
                when Syskit::Models::DataServiceModel
                    save_data_service_model(target_path, m)
                when Class
                    if m <= Syskit::Composition
                        save_composition_model(target_path, m)
                    elsif m <= Syskit::RubyTaskContext
                        save_ruby_task_context_model(target_path, m)
                    elsif m <= Syskit::TaskContext
                        save_task_context_model(target_path, m)
                    end
                else
                end
            end

            def self.save_data_service_model(target_path, service_m)
                task = Syskit::Models::Placeholder.for([service_m]).new
                interface = render_plan(task.plan, "dataflow")
                interface_path =
                    save(target_path, service_m, ".interface.svg", interface)

                description = service_model_description(service_m)
                description = description.merge(
                    { "graphs" => { "interface" => interface_path.to_s, } }
                )
                save target_path, service_m, ".yml", YAML.dump(description)
            end

            def self.save_composition_model(target_path, composition_m)
                hierarchy, dataflow = render_composition_graphs(composition_m)
                hierarchy_path =
                    save(target_path, composition_m, ".hierarchy.svg", hierarchy)
                dataflow_path =
                    save(target_path, composition_m, ".dataflow.svg", dataflow)

                description = composition_model_description(composition_m)
                description = description.merge(
                    {
                        "graphs" => {
                            "hierarchy" => hierarchy_path.to_s,
                            "dataflow" => dataflow_path.to_s
                        }
                    }
                )
                save target_path, composition_m, ".yml", YAML.dump(description)
            end

            def self.save_ruby_task_context_model(target_path, task_m)
                save_task_context_model(target_path, task_m)
            end

            def self.save_task_context_model(target_path, task_m)
                task = task_m.new
                interface = render_plan(task.plan, "dataflow")
                interface_path =
                    save(target_path, task_m, ".interface.svg", interface)

                description = component_model_description(task_m)
                description = description.merge(
                    { "graphs" => { "interface" => interface_path.to_s } }
                )
                save target_path, task_m, ".yml", YAML.dump(description)
            end

            def self.task_model_description(task_m)
                events = task_m.each_event.map do |name, ev|
                    { "name" => name.to_s, "description" => ev.doc }
                end
                { "events" => events }
            end

            def self.component_model_description(component_m)
                ports = list_ports(component_m)
                services = list_bound_services(component_m)
                task_model_description(component_m)
                    .merge({ "ports" => ports, "bound_services" => services })
            end

            ROOT_SERVICE_MODELS = [Syskit::DataService, Syskit::Device].freeze

            def self.service_model_description(service_m)
                ports = list_ports(service_m)
                services = service_m.each_fullfilled_model.map do |provided_service_m|
                    next if ROOT_SERVICE_MODELS.include?(provided_service_m)
                    next if provided_service_m == service_m

                    mappings = service_m.port_mappings_for(provided_service_m)
                    { "model" => provided_service_m.name, "mappings" => mappings }
                end
                { "ports" => ports, "provided_services" => services.compact }
            end

            def self.composition_model_description(composition_m)
                component_model_description(composition_m)
            end

            # Save data at the canonical path for the given model
            #
            # @param [Pathname] root_path the root of the output path hierarchy
            # @param model the model we save the data for
            # @param [String] suffix the file name suffix
            # @param [String] data the data to save
            # @return [Pathname,nil] full path to the saved data, or nil if the method
            #   could not save anything
            def self.save(root_path, model, suffix, data)
                name = model.name
                unless name
                    puts "ignoring model #{model} as its name is invalid"
                    return
                end

                components = name.split(/::|\./)
                target_path = components.inject(root_path, &:/)
                target_path.dirname.mkpath

                target_file = target_path.sub_ext(suffix)
                target_file.write(data)
                target_file
            end

            def self.render_composition_graphs(composition_m)
                task = instanciate_model(composition_m)
                [render_plan(task.plan, "hierarchy"),
                 render_plan(task.plan, "dataflow")]
            end

            # Compute the system network for a model
            #
            # @param [Model<Component>] model the model whose representation is
            #   needed
            # @param [Roby::Plan,nil] main_plan the plan in which we need to
            #   generate the network, if nil a new plan object is created
            # @return [Roby::Task] the toplevel task that represents the
            #   deployed model
            def self.compute_system_network(model, main_plan = nil)
                main_plan ||= Roby::Plan.new
                main_plan.add(original_task = model.as_plan)
                base_task = original_task.as_service
                engine = Syskit::NetworkGeneration::Engine.new(main_plan)
                engine.compute_system_network([base_task.task.planning_task])
                base_task.task
            ensure
                if engine && engine.work_plan.respond_to?(:commit_transaction)
                    engine.work_plan.commit_transaction
                    main_plan.remove_task(original_task)
                end
            end

            # Compute the deployed network for a model
            #
            # @param [Model<Component>] model the model whose representation is
            #   needed
            # @param [Roby::Plan,nil] main_plan the plan in which we need to
            #   generate the network, if nil a new plan object is created
            # @return [Roby::Task] the toplevel task that represents the
            #   deployed model
            def self.compute_deployed_network(model, main_plan = nil)
                main_plan ||= Roby::Plan.new
                main_plan.add(original_task = model.as_plan)
                base_task = original_task.as_service
                begin
                    engine = Syskit::NetworkGeneration::Engine.new(main_plan)
                    engine.resolve_system_network([base_task.task.planning_task])
                rescue RuntimeError
                    engine = Syskit::NetworkGeneration::Engine.new(main_plan)
                    engine.resolve_system_network(
                        [base_task.task.planning_task],
                        validate_abstract_network: false,
                        validate_generated_network: false,
                        validate_deployed_network: false
                    )
                end

                NetworkGeneration::LoggerConfigurationSupport
                    .add_logging_to_network(engine, engine.work_plan)
                base_task.task
            ensure
                if engine && engine.work_plan.respond_to?(:commit_transaction)
                    engine.commit_work_plan
                    main_plan.remove_task(original_task)
                end
            end

            # Instanciate a model
            #
            # @param [Model<Component>] model the model whose instanciation is
            #   needed
            # @param [Roby::Plan,nil] main_plan the plan in which we need to
            #   generate the network, if nil a new plan object is created
            # @param [Hash] options options to be passed to
            #   {Syskit::InstanceRequirements#instanciate}
            # @return [Roby::Task] the toplevel task that represents the
            #   deployed model
            def self.instanciate_model(model, main_plan = nil, options = {})
                main_plan ||= Roby::Plan.new
                requirements = model.to_instance_requirements
                task = requirements.instanciate(
                    main_plan,
                    Syskit::DependencyInjectionContext.new,
                    options
                )
                main_plan.add(task)
                task
            end

            # List the services provided by a component
            #
            # @param [Component] component_m the component model
            def self.list_bound_services(component_m)
                component_m.each_data_service.sort_by(&:first)
                           .map do |service_name, service|
                    model_hierarchy =
                        service
                        .model.ancestors
                        .find_all do |m|
                            m.kind_of?(Syskit::Models::DataServiceModel) &&
                                !ROOT_SERVICE_MODELS.include?(m) &&
                                m != component_m
                        end

                    provided_services = model_hierarchy.map do |m|
                        port_mappings = service.port_mappings_for(m).dup
                        port_mappings.delete_if do |from, to|
                            from == to
                        end
                        { "model" => m.name, "mappings" => port_mappings }
                    end
                    { "name" => service_name, "model" => service.model.name,
                      "provided_services" => provided_services }
                end
            end

            def self.list_ports(model)
                model.each_port.map do |p|
                    { "name" => p.name, "type" => p.type.name,
                      "direction" => p.output? ? "out" : "in",
                      "doc" => p.doc }
                end
            end

            def self.render_plan(plan, graph_kind, typelib_resolver: nil, **graphviz_options)
                begin
                    svg_io = Tempfile.open(graph_kind)
                    Syskit::Graphviz.new(plan, self, typelib_resolver: typelib_resolver)
                                    .to_file(graph_kind, "svg", svg_io, **graphviz_options)
                    svg_io.flush
                    svg_io.rewind
                    svg = svg_io.read
                    svg = svg.encode "utf-8", invalid: :replace
                rescue DotCrashError, DotFailedError => e
                    svg = e.message
                ensure
                    svg_io&.close
                end

                # Fixup a mixup in dot's SVG output. The URIs that contain < and >
                # are not properly escaped to &lt; and &gt;
                svg = svg.gsub(/xlink:href="[^"]+"/) do |match|
                    match.gsub("<", "&lt;").gsub(">", "&gt;")
                end

                begin
                    match = /svg width=\"(\d+)(\w+)\" height=\"(\d+)(\w+)\"/.match(svg)
                    if match
                        width, w_unit, height, h_unit = *match.captures
                        width = Float(width) * 0.6
                        height = Float(height) * 0.6
                        svg = match.pre_match +
                              "svg width=\"#{width}#{w_unit}\" "\
                              "height=\"#{height}#{h_unit}\"" + match.post_match
                    end
                rescue ArgumentError # rubocop:disable Lint/SuppressedException
                end

                svg
            end
        end
    end
end
